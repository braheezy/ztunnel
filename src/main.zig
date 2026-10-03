const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Target = @import("target.zig").Target;
const readHeaders = @import("headers.zig").readHeaders;
const response = @import("response.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--listen")) {
        std.log.err("usage: ztunnel --listen 127.0.0.1:PORT", .{});
        return error.InvalidArguments;
    }
    const address = parseListenAddress(args[2]) catch {
        std.log.err("listen address must be 127.0.0.1:PORT (1-65535)", .{});
        return error.InvalidListenAddress;
    };

    const io = init.io;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    std.log.info("listening on {s}", .{args[2]});

    while (true) {
        const client = try server.accept(io);
        defer client.close(io);

        handleClient(io, client) catch |err| {
            std.log.warn("client session ended: {s}", .{@errorName(err)});
        };
    }
}

fn parseListenAddress(text: []const u8) !net.IpAddress {
    const prefix = "127.0.0.1:";
    if (!std.mem.startsWith(u8, text, prefix)) return error.InvalidListenAddress;
    const port_text = text[prefix.len..];
    if (port_text.len == 0) return error.InvalidListenAddress;
    for (port_text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidListenAddress;
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidListenAddress;
    if (port == 0) return error.InvalidListenAddress;
    return .{ .ip4 = .loopback(port) };
}

fn handleClient(io: std.Io, client: net.Stream) !void {
    var read_buffer: [1024]u8 = undefined;
    var client_reader = client.reader(io, &read_buffer);
    const reader = &client_reader.interface;

    var header_storage: [8192]u8 = undefined;

    var write_buffer: [1024]u8 = undefined;
    var client_writer = client.writer(io, &write_buffer);
    const writer = &client_writer.interface;

    const headers = readHeaders(reader, &header_storage) catch |err| switch (err) {
        error.IncompleteHeaders, error.HeadersTooLarge => {
            try writer.writeAll(response.bytes(.bad_request));
            try writer.flush();
            return;
        },
        else => return err,
    };
    const target = Target.initFromHeaders(headers) catch |err| {
        switch (err) {
            error.NotConnect => {
                try writer.writeAll(response.bytes(.method_not_allowed));
                try writer.flush();
                return;
            },
            else => {
                try writer.writeAll(response.bytes(.bad_request));
                try writer.flush();
                return;
            },
        }
    };

    const upstream = connectTarget(io, target) catch {
        try writer.writeAll(response.bytes(.bad_gateway));
        try writer.flush();
        return;
    };
    defer upstream.close(io);
    try writer.writeAll(response.bytes(.connection_established));
    try writer.flush();

    var upstream_read_buffer: [1024]u8 = undefined;
    var upstream_write_buffer: [1024]u8 = undefined;
    var upstream_reader = upstream.reader(io, &upstream_read_buffer);
    var upstream_writer = upstream.writer(io, &upstream_write_buffer);

    const PumpResult = union(enum) {
        to_target: anyerror!void,
        to_client: anyerror!void,
    };
    var results: [2]PumpResult = undefined;
    var pumps = Io.Select(PumpResult).init(io, &results);
    errdefer pumps.cancelDiscard();

    try pumps.concurrent(.to_target, pumpDirection, .{ io, reader, &upstream_writer.interface, upstream });
    try pumps.concurrent(.to_client, pumpDirection, .{ io, &upstream_reader.interface, writer, client });

    for (0..2) |_| {
        switch (try pumps.await()) {
            .to_target => |result| try result,
            .to_client => |result| try result,
        }
    }
    try pumps.group.await(io);
}

fn pumpDirection(
    io: Io,
    source_reader: *Io.Reader,
    destination_writer: *Io.Writer,
    destination: net.Stream,
) !void {
    try copyBytes(source_reader, destination_writer);
    try destination_writer.flush();
    try destination.shutdown(io, .send);
}

fn connectTarget(io: Io, target: Target) !net.Stream {
    const options: net.IpAddress.ConnectOptions = .{ .mode = .stream, .protocol = .tcp };
    if (net.IpAddress.parseIp4(target.host, target.port)) |address| {
        return address.connect(io, options);
    } else |_| {
        const host = try net.HostName.init(target.host);
        return host.connect(io, target.port, options);
    }
}

fn copyBytes(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var copy_buffer: [4096]u8 = undefined;

    while (true) {
        const pending = reader.buffered();
        if (pending.len > 0) {
            try writer.writeAll(pending);
            try writer.flush();
            reader.toss(pending.len);
        }

        var destinations: [1][]u8 = .{&copy_buffer};
        const count = reader.readVec(&destinations) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        if (count == 0) continue;

        try writer.writeAll(copy_buffer[0..count]);
        try writer.flush();
    }
}

test "listen address is restricted to IPv4 loopback" {
    const address = try parseListenAddress("127.0.0.1:8080");
    try std.testing.expectEqual(@as(u16, 8080), address.getPort());
    const invalid = [_][]const u8{
        "0.0.0.0:8080",
        "127.0.0.2:8080",
        "localhost:8080",
        "127.0.0.1",
        "127.0.0.1:",
        "127.0.0.1:0",
        "127.0.0.1:65536",
        "127.0.0.1:+80",
        "127.0.0.1:4_43",
        "127.0.0.1:80:90",
    };
    for (invalid) |text| {
        try std.testing.expectError(error.InvalidListenAddress, parseListenAddress(text));
    }
}

test "copyBytes copies an empty input" {
    var reader = Io.Reader.fixed("");
    var output: [8]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    try copyBytes(&reader, &writer);
    try std.testing.expectEqualStrings("", writer.buffered());
}

test "copyBytes copies buffered bytes" {
    var reader = Io.Reader.fixed("hello");
    var output: [8]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    try copyBytes(&reader, &writer);
    try std.testing.expectEqualStrings("hello", writer.buffered());
}

test "copyBytes copies binary bytes without interpreting them" {
    const input = [_]u8{ 0, 1, 255, 13, 10, 0, 42 };
    var reader = Io.Reader.fixed(&input);
    var output: [input.len]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    try copyBytes(&reader, &writer);
    try std.testing.expectEqualSlices(u8, &input, writer.buffered());
}

test "copyBytes copies input larger than its copy buffer" {
    var input: [4096 * 2 + 17]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var source = Io.Reader.fixed(&input);
    var limited = source.limited(.unlimited, &.{});
    var output: [input.len]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    try copyBytes(&limited.interface, &writer);
    try std.testing.expectEqualSlices(u8, &input, writer.buffered());
}

test "copyBytes reads when no bytes are already buffered" {
    var source = Io.Reader.fixed("from source");
    var limited = source.limited(.unlimited, &.{});
    var output: [32]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    try copyBytes(&limited.interface, &writer);
    try std.testing.expectEqualStrings("from source", writer.buffered());
}

test "copyBytes reports an output buffer that is too small" {
    var reader = Io.Reader.fixed("too much data");
    var output: [4]u8 = undefined;
    var writer = Io.Writer.fixed(&output);

    try std.testing.expectError(error.WriteFailed, copyBytes(&reader, &writer));
}

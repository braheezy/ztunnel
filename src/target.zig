const std = @import("std");

pub const Target = struct {
    host: []const u8,
    port: u16,

    fn init(line: []const u8) !Target {
        if (line.len == 0) return error.NoTarget;
        if (std.mem.startsWith(u8, line, " ")) return error.BadTarget;

        var it = std.mem.splitScalar(u8, line, ' ');
        const method = it.first();
        if (!std.mem.eql(u8, method, "CONNECT")) return error.NotConnect;

        const target = it.next() orelse return error.BadTarget;
        const idx = std.mem.indexOfScalar(u8, target, ':') orelse return error.BadTarget;

        const host = target[0..idx];
        if (host.len == 0) return error.BadTarget;
        try std.Io.net.HostName.validate(host);

        const port_str = target[idx + 1 .. target.len];
        if (std.mem.containsAtLeast(u8, port_str, 1, "+")) return error.BadTarget;
        if (std.mem.containsAtLeast(u8, port_str, 1, "-")) return error.BadTarget;
        if (std.mem.containsAtLeast(u8, port_str, 1, "_")) return error.BadTarget;
        const port = try std.fmt.parseInt(u16, port_str, 10);
        if (port == 0) return error.BadTarget;

        const http = it.rest();
        if (!std.mem.eql(u8, http, "HTTP/1.1")) return error.BadTarget;

        return .{
            .host = host,
            .port = port,
        };
    }

    pub fn initFromHeaders(headers: []const u8) !Target {
        const idx = std.mem.find(u8, headers, "\r\n") orelse return error.BadTarget;
        return init(headers[0..idx]);
    }
};

test "Target.initFromHeaders parses the first line of a complete header block" {
    const headers = "CONNECT localhost:9000 HTTP/1.1\r\nHost: localhost:9000\r\n\r\n";
    const target = try Target.initFromHeaders(headers);

    try std.testing.expectEqualStrings("localhost", target.host);
    try std.testing.expectEqual(@as(u16, 9000), target.port);
}

test "Target.initFromHeaders rejects input without a line ending" {
    try std.testing.expectError(error.BadTarget, Target.initFromHeaders("CONNECT localhost:9000 HTTP/1.1"));
    try std.testing.expectError(error.BadTarget, Target.initFromHeaders(""));
}

test "Target.initFromHeaders preserves unsupported method errors" {
    try std.testing.expectError(error.NotConnect, Target.initFromHeaders("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"));
}

test "Target.initFromHeaders rejects a malformed authority" {
    try std.testing.expectError(error.BadTarget, Target.initFromHeaders("CONNECT :9000 HTTP/1.1\r\n\r\n"));
}

test "header reader output can be parsed without consuming tunnel bytes" {
    const request = "CONNECT 127.0.0.1:9000 HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n";
    var reader = std.Io.Reader.fixed(request ++ "Z");
    var storage: [8192]u8 = undefined;

    const headers = try @import("headers.zig").readHeaders(&reader, &storage);
    const target = try Target.initFromHeaders(headers);

    try std.testing.expectEqualStrings("127.0.0.1", target.host);
    try std.testing.expectEqual(@as(u16, 9000), target.port);
    try std.testing.expectEqual(@as(u8, 'Z'), try reader.takeByte());
}

// Target.init parses only the request line, excluding its CRLF and headers.
// Reading through the header block's CRLFCRLF is a separate responsibility.
test "Target.init parses a DNS target" {
    const target = try Target.init("CONNECT example.com:443 HTTP/1.1");
    try std.testing.expectEqualStrings("example.com", target.host);
    try std.testing.expectEqual(@as(u16, 443), target.port);
}

test "Target.init parses an IPv4 target" {
    const target = try Target.init("CONNECT 127.0.0.1:9000 HTTP/1.1");
    try std.testing.expectEqualStrings("127.0.0.1", target.host);
    try std.testing.expectEqual(@as(u16, 9000), target.port);
}

test "Target.init accepts port boundaries" {
    const low = try Target.init("CONNECT localhost:1 HTTP/1.1");
    const high = try Target.init("CONNECT localhost:65535 HTTP/1.1");
    try std.testing.expectEqual(@as(u16, 1), low.port);
    try std.testing.expectEqual(@as(u16, 65535), high.port);
}

test "Target.init rejects empty input" {
    try std.testing.expectError(error.NoTarget, Target.init(""));
}

test "Target.init distinguishes unsupported methods" {
    const lines = [_][]const u8{
        "GET / HTTP/1.1",
        "POST / HTTP/1.1",
        "connect example.com:443 HTTP/1.1",
    };
    for (lines) |line| {
        try std.testing.expectError(error.NotConnect, Target.init(line));
    }
}

test "Target.init rejects malformed request lines" {
    const lines = [_][]const u8{
        "CONNECT",
        "CONNECT example.com:443",
        "CONNECT example.com:443 HTTP/1.1 extra",
        " CONNECT example.com:443 HTTP/1.1",
        "CONNECT  example.com:443 HTTP/1.1",
        "CONNECT example.com:443  HTTP/1.1",
        "CONNECT example.com:443 HTTP/1.1 ",
        "CONNECT\texample.com:443\tHTTP/1.1",
        "CONNECT example.com:443 NOT-HTTP",
        "CONNECT example.com:443 HTTP/2.0",
        "CONNECT example.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1 \r\n\r\n",
    };
    for (lines) |line| {
        if (Target.init(line)) |_| {
            std.debug.print("\nunexpectedly accepted request line: {s}\n", .{line});
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "Target.init rejects malformed authorities" {
    const lines = [_][]const u8{
        "CONNECT :443 HTTP/1.1",
        "CONNECT example.com HTTP/1.1",
        "CONNECT example.com: HTTP/1.1",
        "CONNECT example.com:443:80 HTTP/1.1",
        "CONNECT user@example.com:443 HTTP/1.1",
        "CONNECT example.com/path:443 HTTP/1.1",
        "CONNECT example.com?query:443 HTTP/1.1",
        "CONNECT example.com#fragment:443 HTTP/1.1",
        "CONNECT [::1]:443 HTTP/1.1",
    };
    for (lines) |line| {
        if (Target.init(line)) |_| {
            std.debug.print("\nunexpectedly accepted authority in: {s}\n", .{line});
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "Target.init rejects invalid ports" {
    const lines = [_][]const u8{
        "CONNECT example.com:0 HTTP/1.1",
        "CONNECT example.com:65536 HTTP/1.1",
        "CONNECT example.com:999999999999999999999 HTTP/1.1",
        "CONNECT example.com:-1 HTTP/1.1",
        "CONNECT example.com:+443 HTTP/1.1",
        "CONNECT example.com:https HTTP/1.1",
        "CONNECT example.com:44x HTTP/1.1",
        "CONNECT example.com:4_43 HTTP/1.1",
        "CONNECT example.com:0x1bb HTTP/1.1",
    };
    for (lines) |line| {
        if (Target.init(line)) |_| {
            std.debug.print("\nunexpectedly accepted port in: {s}\n", .{line});
            return error.TestExpectedError;
        } else |_| {}
    }
}

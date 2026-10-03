const std = @import("std");

pub fn readHeaders(reader: *std.Io.Reader, storage: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < storage.len) {
        const byte = reader.takeByte() catch |err| {
            return if (err == error.EndOfStream) error.IncompleteHeaders else err;
        };
        storage[used] = byte;
        used += 1;
        if (std.mem.endsWith(u8, storage[0..used], "\r\n\r\n")) {
            return storage[0..used];
        }
    }
    return error.HeadersTooLarge;
}

test "readHeaders stops before tunnel bytes" {
    const request = "CONNECT localhost:9000 HTTP/1.1\r\n\r\n";
    var reader = std.Io.Reader.fixed(request ++ "XYZ");
    var storage: [8192]u8 = undefined;

    const headers = try readHeaders(&reader, &storage);

    try std.testing.expectEqualStrings(request, headers);
    try std.testing.expectEqual(@as(u8, 'X'), try reader.takeByte());
}

test "readHeaders includes headers through the blank line" {
    const request = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nUser-Agent: test\r\n\r\n";
    var reader = std.Io.Reader.fixed(request);
    var storage: [8192]u8 = undefined;

    try std.testing.expectEqualStrings(request, try readHeaders(&reader, &storage));
}

test "readHeaders reports EOF before the empty line" {
    var reader = std.Io.Reader.fixed("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n");
    var storage: [8192]u8 = undefined;

    try std.testing.expectError(error.IncompleteHeaders, readHeaders(&reader, &storage));
}

test "readHeaders reports EOF for empty input" {
    var reader = std.Io.Reader.fixed("");
    var storage: [8192]u8 = undefined;

    try std.testing.expectError(error.IncompleteHeaders, readHeaders(&reader, &storage));
}

test "readHeaders accepts a block ending exactly at storage capacity" {
    const request = "CONNECT localhost:9000 HTTP/1.1\r\n\r\n";
    var reader = std.Io.Reader.fixed(request ++ "Z");
    var storage: [request.len]u8 = undefined;

    try std.testing.expectEqualStrings(request, try readHeaders(&reader, &storage));
    try std.testing.expectEqual(@as(u8, 'Z'), try reader.takeByte());
}

test "readHeaders rejects a block one byte longer than storage" {
    const request = "CONNECT localhost:9000 HTTP/1.1\r\n\r\n";
    var reader = std.Io.Reader.fixed(request);
    var storage: [request.len - 1]u8 = undefined;

    try std.testing.expectError(error.HeadersTooLarge, readHeaders(&reader, &storage));
    try std.testing.expectEqual(@as(u8, '\n'), try reader.takeByte());
}

test "readHeaders accepts a full 8 KiB block" {
    var input: [8192]u8 = undefined;
    @memset(&input, 'x');
    @memcpy(input[input.len - 4 ..], "\r\n\r\n");
    var reader = std.Io.Reader.fixed(&input);
    var storage: [8192]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &input, try readHeaders(&reader, &storage));
}

test "readHeaders rejects a header terminator past 8 KiB" {
    var input: [8193]u8 = undefined;
    @memset(&input, 'x');
    @memcpy(input[input.len - 4 ..], "\r\n\r\n");
    var reader = std.Io.Reader.fixed(&input);
    var storage: [8192]u8 = undefined;

    try std.testing.expectError(error.HeadersTooLarge, readHeaders(&reader, &storage));
    try std.testing.expectEqual(@as(u8, '\n'), try reader.takeByte());
}

test "readHeaders does not consume input when storage has no capacity" {
    var reader = std.Io.Reader.fixed("CONNECT localhost:9000 HTTP/1.1\r\n\r\n");
    var storage: [0]u8 = .{};

    try std.testing.expectError(error.HeadersTooLarge, readHeaders(&reader, &storage));
    try std.testing.expectEqual(@as(u8, 'C'), try reader.takeByte());
}

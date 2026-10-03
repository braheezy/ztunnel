const std = @import("std");

pub const Status = enum {
    bad_request,
    method_not_allowed,
    bad_gateway,
    connection_established,
};

pub fn bytes(status: Status) []const u8 {
    return switch (status) {
        .bad_request => "HTTP/1.1 400 Bad Request\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .method_not_allowed => "HTTP/1.1 405 Method Not Allowed\r\n" ++
            "Allow: CONNECT\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .bad_gateway => "HTTP/1.1 502 Bad Gateway\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .connection_established => "HTTP/1.1 200 Connection Established\r\n\r\n",
    };
}

test "CONNECT responses have the expected status and header terminator" {
    const cases = .{
        .{ .bad_request, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" },
        .{ .method_not_allowed, "HTTP/1.1 405 Method Not Allowed\r\nAllow: CONNECT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" },
        .{ .bad_gateway, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" },
        .{ .connection_established, "HTTP/1.1 200 Connection Established\r\n\r\n" },
    };
    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], bytes(case[0]));
    }
}

# ztunnel

A loopback-only HTTP proxy supporting the `CONNECT host:port` method.

```
ztunnel --listen 127.0.0.1:8080
```

## Usage

Clone the repo, build, and run it. Requires Zig:

```
git clone https://github.com/braheezy/ztunnel
cd ztunnel
zig build
./zig-out/bin/ztunnel
```

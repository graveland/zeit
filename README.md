# zeit

A time library for Zig.

## Usage

```zig
const std = @import("std");
const zeit = @import("zeit");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Get an instant in time. The default source is "now" in UTC,
    // and requires io to read from the system clock
    const now = try zeit.instant(.{ .source = .now, .io = io });

    // Load the local timezone. This needs an allocator. Optionally pass in a
    // *const std.process.EnvMap to support TZ and TZDIR environment variables
    const local = try zeit.local(allocator, io, &env);
    defer local.deinit();

    // Convert the instant to a different timezone
    const now_local = now.in(&local);

    // Generate date/time info for this instant
    const dt = now_local.time();

    // Print it out
    std.debug.print("{}", .{dt});
    // zeit.Time{
    //    .year = 2024,
    //    .month = zeit.Month.mar,
    //    .day = 16,
    //    .hour = 8,
    //    .minute = 38,
    //    .second = 29,
    //    .millisecond = 496,
    //    .microsecond = 706,
    //    .nanosecond = 64,
    //    .offset = -18000,
    // }

    // Format using strftime specifiers (format strings are not required to be comptime)
    var buf: [64]u8 = undefined;
    var writer = std.io.fixedBufferWriter(&buf);
    try dt.strftime(&writer, "%Y-%m-%d %H:%M:%S %Z");

    // Or use Go-style magic date specifiers
    try dt.gofmt(&writer, "2006-01-02 15:04:05 MST");

    // Load an arbitrary location using IANA location syntax
    const vienna = try zeit.loadTimeZone(allocator, io, .@"Europe/Vienna", &env);
    defer vienna.deinit();

    // Parse an Instant from an ISO8601 or RFC3339 string (io is not needed)
    _ = try zeit.instant(.{
        .source = .{ .iso8601 = "2024-03-16T08:38:29.496-1200" },
    });

    _ = try zeit.instant(.{
        .source = .{ .rfc3339 = "2024-03-16T08:38:29.496706064-12:00" },
    });

    // Parse from a unix timestamp
    _ = try zeit.instant(.{
        .source = .{ .unix_timestamp = 1710592709 },
    });
}
```

## Timer

`zeit.Timer` provides a simple way to measure elapsed time, useful for benchmarking and metrics:

```zig
const zeit = @import("zeit");

pub fn example(io: std.Io) void {
    // Start a timer
    const timer = zeit.Timer.start(io);

    // ... do some work ...

    // Get elapsed time in any unit and numeric type
    const micros = timer.elapsed(u64, .micros);    // microseconds as u64
    const millis = timer.elapsed(f64, .millis);    // milliseconds as f64
    const nanos = timer.elapsed(i128, .nanos);     // nanoseconds as i128
    const secs = timer.elapsed(f64, .seconds);     // seconds as f64
}
```

Available units: `.nanos`, `.micros`, `.millis`, `.seconds`

The timer can also be reset to measure a new interval:

```zig
var timer = zeit.Timer.start(io);
// ... first operation ...
const first_duration = timer.elapsed(u64, .micros);

timer.reset();
// ... second operation ...
const second_duration = timer.elapsed(u64, .micros);
```

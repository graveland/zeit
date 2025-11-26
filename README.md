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
const Unit = zeit.Unit;

pub fn example(io: std.Io) void {
    // Start a timer
    const timer = zeit.Timer.start(io);

    // ... do some work ...

    // Simple case - get elapsed time as u64
    const millis = timer.elapsed(.millis);

    // Advanced - specify return type for fractional values
    const secs_f64 = timer.elapsedAs(f64, .seconds);

    // Get as Duration for formatting
    const duration = timer.elapsedDuration();
    std.debug.print("Took: {}\n", .{duration}); // e.g., "Took: 1h30m"
}
```

Available units: `.nanos`, `.micros`, `.millis`, `.seconds`, `.minutes`, `.hours`, `.days`

The timer can also be reset to measure a new interval:

```zig
var timer = zeit.Timer.start(io);
// ... first operation ...
const first_duration = timer.elapsed(.micros);

timer.reset();
// ... second operation ...
const second_duration = timer.elapsed(.micros);
```

## Duration

`zeit.Duration` represents a span of time with nanosecond precision. It provides Go-style duration parsing and formatting, with the addition of days (`d`) as a unit.

### Creating Durations

```zig
const zeit = @import("zeit");
const Unit = zeit.Unit;

// From values and units
const d1 = zeit.Duration.from(15, .seconds);
const d2 = zeit.Duration.from(1.5, .hours);

// Or use struct literals
const d3 = zeit.Duration{ .hours = 1, .minutes = 30 };

// Or parse strings (supports ns, us, ms, s, m, h, d)
const d4 = try zeit.Duration.parse("1h30m");
const d5 = try zeit.Duration.parse("2d12h45m30s");
const d6 = try zeit.Duration.parse("1.5h");  // 1 hour 30 minutes
const d7 = try zeit.Duration.parse("-45m");

// Or create from nanoseconds
const d8 = zeit.Duration.fromNanoseconds(1_500_000_000);  // 1.5 seconds
```

### Formatting Durations

```zig
var buf: [64]u8 = undefined;
const duration = zeit.Duration{ .hours = 1, .minutes = 30 };

// Format to a buffer
const str = try duration.bufPrint(&buf);
// str = "1h30m"

// Or write to a writer
var writer = std.Io.Writer.fixed(&buf);
try duration.format(&writer);
```

Examples of formatted durations:
- `300ms` - 300 milliseconds
- `1h30m` - 1 hour 30 minutes
- `2d12h` - 2 days 12 hours
- `1h23m45s` - 1 hour 23 minutes 45 seconds
- `0s` - zero duration

### Rounding and Truncating

```zig
// Round to nearest hour (halfway rounds away from zero)
const d1 = try zeit.Duration.parse("1h45m");
const rounded = try d1.round(zeit.Duration{ .hours = 1 });
// rounded = "2h"

// Round to nearest 15 minutes
const d2 = try zeit.Duration.parse("1h8m");
const rounded15 = try d2.round(zeit.Duration{ .minutes = 15 });
// rounded15 = "1h15m"

// Truncate toward zero
const d3 = try zeit.Duration.parse("1h45m");
const truncated = try d3.truncate(zeit.Duration{ .hours = 1 });
// truncated = "1h"
```

### Converting Durations

```zig
const zeit = @import("zeit");
const Unit = zeit.Unit;

const duration = try zeit.Duration.parse("1h30m");

// Convert to different units as u64
const hours = try duration.in(.hours);     // 1
const minutes = try duration.in(.minutes); // 90
const seconds = try duration.in(.seconds); // 5400
const ns = try duration.inNanoseconds();   // 5_400_000_000_000

// Convert with fractional precision
const hours_f64 = try duration.inAs(f64, .hours); // 1.5

// Convert to linux.timespec for use with nanosleep (Linux only)
const ts = try duration.toTimespec();
```

### Duration Units

The `zeit.Unit` enum provides standard time units:

```zig
const unit = zeit.Unit.seconds;
const ns_per_unit = unit.toNanoseconds();  // 1_000_000_000
const unit_duration = unit.toDuration();   // Duration{ .seconds = 1 }
```

Available units: `.nanos`, `.micros`, `.millis`, `.seconds`, `.minutes`, `.hours`, `.days`

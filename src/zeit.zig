const std = @import("std");
const builtin = @import("builtin");
const location = @import("location.zig");
pub const timezone = @import("timezone.zig");

const assert = std.debug.assert;

pub const TimeZone = timezone.TimeZone;
pub const Location = location.Location;

pub const Days = i64;
pub const Nanoseconds = i128;
pub const Milliseconds = i128;
pub const Seconds = i64;

const ns_per_us = std.time.ns_per_us;
const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;
const ns_per_min = std.time.ns_per_min;
const ns_per_hour = std.time.ns_per_hour;
const ns_per_day = std.time.ns_per_day;
const s_per_min = std.time.s_per_min;
const s_per_hour = std.time.s_per_hour;
const s_per_day = std.time.s_per_day;
const days_per_era = 365 * 400 + 97;

/// A simple timer for measuring elapsed time.
/// Useful for benchmarking and metrics.
pub const Timer = struct {
    start_ns: i128,
    io: std.Io,

    /// Start a new timer from the current time.
    /// Uses the monotonic clock (.awake) which is not affected by system time changes.
    pub fn start(io: std.Io) Timer {
        const start_ns = if (std.Io.Clock.Timestamp.now(io, .awake)) |ts| ts.raw.nanoseconds else |_| 0;
        return .{ .start_ns = start_ns, .io = io };
    }

    /// Returns elapsed time in the requested unit and type.
    /// Usage: timer.elapsed(u64, .micros) or timer.elapsed(f64, .millis)
    pub fn elapsed(self: Timer, comptime T: type, comptime unit: Unit) T {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake) catch return 0;
        const elapsed_ns = now.raw.nanoseconds - self.start_ns;
        const divisor: i128 = switch (unit) {
            .nanos => 1,
            .micros => ns_per_us,
            .millis => ns_per_ms,
            .seconds => ns_per_s,
        };
        const value = @divFloor(elapsed_ns, divisor);
        return switch (@typeInfo(T)) {
            .float => @floatFromInt(value),
            .int => @intCast(value),
            else => @compileError("Timer.elapsed requires int or float type"),
        };
    }

    /// Reset the timer to now
    pub fn reset(self: *Timer) void {
        const ts = std.Io.Clock.Timestamp.now(self.io, .awake) catch return;
        self.start_ns = ts.raw.nanoseconds;
    }

    pub const Unit = enum {
        nanos,
        micros,
        millis,
        seconds,
    };
};

pub const utc: TimeZone = .{ .fixed = .{
    .name = "UTC",
    .offset = 0,
    .is_dst = false,
} };

pub fn local(alloc: std.mem.Allocator, io: std.Io, maybe_env: ?*const std.process.EnvMap) !TimeZone {
    switch (builtin.os.tag) {
        .windows => {
            const win = try timezone.Windows.local(alloc);
            return .{ .windows = win };
        },
        else => {
            if (maybe_env) |env| {
                if (env.get("TZ")) |tz| {
                    return localFromEnv(alloc, io, tz, env);
                }
            }

            const f = try std.fs.cwd().openFile("/etc/localtime", .{});
            defer f.close();
            var io_buffer: [2048]u8 = undefined;
            var reader = f.reader(io, &io_buffer);
            return .{ .tzinfo = try timezone.TZInfo.parse(alloc, &reader.interface) };
        },
    }
}

// Returns the local time zone from the given TZ environment variable
// TZ can be one of three things:
// 1. A POSIX TZ string (TZ=CST6CDT,M3.2.0,M11.1.0)
// 2. An absolute path, prefixed with ':' (TZ=:/etc/localtime)
// 3. A relative path, prefixed with ':'
fn localFromEnv(
    alloc: std.mem.Allocator,
    io: std.Io,
    tz: []const u8,
    env: *const std.process.EnvMap,
) !TimeZone {
    assert(tz.len != 0); // TZ is empty string

    // Return early we we are a posix TZ string
    if (tz[0] != ':') return .{ .posix = try timezone.Posix.parse(tz) };

    assert(tz.len > 1); // TZ not long enough
    if (tz[1] == '/') {
        const f = try std.fs.cwd().openFile(tz[1..], .{});
        defer f.close();
        var io_buffer: [1024]u8 = undefined;
        var reader = f.reader(io, &io_buffer);
        return .{ .tzinfo = try timezone.TZInfo.parse(alloc, &reader.interface) };
    }

    if (std.meta.stringToEnum(Location, tz[1..])) |loc|
        return loadTimeZone(alloc, io, loc, env)
    else
        return error.UnknownLocation;
}

pub fn loadTimeZone(
    alloc: std.mem.Allocator,
    io: std.Io,
    loc: Location,
    maybe_env: ?*const std.process.EnvMap,
) !TimeZone {
    switch (builtin.os.tag) {
        .windows => {
            const tz = try timezone.Windows.loadFromName(alloc, loc.asText());
            return .{ .windows = tz };
        },
        else => {},
    }

    var dir: std.fs.Dir = blk: {
        // If we have an env and a TZDIR, use that
        if (maybe_env) |env| {
            if (env.get("TZDIR")) |tzdir| {
                const dir = try std.fs.openDirAbsolute(tzdir, .{});
                break :blk dir;
            }
        }
        // Otherwise check well-known locations
        const zone_dirs = [_][]const u8{
            "/usr/share/zoneinfo/",
            "/usr/share/lib/zoneinfo/",
            "/usr/lib/locale/TZ/",
            "/share/zoneinfo/",
            "/etc/zoneinfo/",
        };
        for (zone_dirs) |zone_dir| {
            const dir = std.fs.openDirAbsolute(zone_dir, .{}) catch continue;
            break :blk dir;
        } else return error.FileNotFound;
    };

    defer dir.close();
    const f = try dir.openFile(loc.asText(), .{});
    defer f.close();
    var io_buffer: [2048]u8 = undefined;
    var reader = f.reader(io, &io_buffer);
    return .{ .tzinfo = try timezone.TZInfo.parse(alloc, &reader.interface) };
}

/// An Instant in time. Instants occur at a precise time and place, thus must
/// always carry with them a timezone.
pub const Instant = struct {
    /// the instant of time, in nanoseconds
    timestamp: Nanoseconds = 0,
    /// every instant occurs in a timezone. This is the timezone
    timezone: *const TimeZone,

    pub const Config = struct {
        source: Source = .now,
        timezone: *const TimeZone = &utc,
        /// io required when capturing current time (e.g. zeit.instant(.{ .io = io }))
        io: ?std.Io = null,
    };

    /// possible sources to create an Instant
    pub const Source = union(enum) {
        /// the current system time (requires io in Config)
        now,

        /// a specific unix timestamp (in seconds)
        unix_timestamp: Seconds,

        /// a specific unix timestamp (in nanoseconds)
        unix_nano: Nanoseconds,

        /// create an Instant from a calendar date and time
        time: Time,

        /// parse a datetime from an ISO8601 string
        /// Supports most ISO8601 formats, _except_:
        /// - Week numbers (ie YYYY-Www)
        /// - Fractional minutes (ie YYYY-MM-DDTHH:MM.mmm)
        ///
        /// Strings can be in the extended or compact format and use ' ' or "T"
        /// as the time delimiter
        /// Examples of paresable strings:
        /// YYYY-MM-DD
        /// YYYY-MM-DDTHH
        /// YYYY-MM-DDTHH:MM
        /// YYYY-MM-DDTHH:MM:SS
        /// YYYY-MM-DDTHH:MM:SS.sss
        /// YYYY-MM-DDTHH:MM:SS.ssssss
        /// YYYY-MM-DDTHH:MM:SSZ
        /// YYYY-MM-DDTHH:MM:SS+hh:mm
        /// YYYYMMDDTHHMMSSZ
        iso8601: []const u8,

        /// Parse a datetime from an RFC3339 string. RFC3339 is similar to
        /// ISO8601 but is more strict, and allows for arbitrary fractional
        /// seconds. Using this field will use the same parser `iso8601`, but is
        /// provided for clarity
        /// Format: YYYY-MM-DDTHH:MM:SS.sss+hh:mm
        rfc3339: []const u8,

        /// Parse a datetime from an RFC5322 date-time spec
        rfc5322: []const u8,

        /// Parse a datetime from an RFC2822 date-time spec. This is an alias for RFC5322
        rfc2822: []const u8,

        /// Parse a datetime from an RFC1123 date-time spec
        rfc1123: []const u8,
    };

    /// convert this Instant to another timezone
    pub fn in(self: Instant, zone: *const TimeZone) Instant {
        return .{
            .timestamp = self.timestamp,
            .timezone = zone,
        };
    }

    // convert the nanosecond timestamp into a unix timestamp (in seconds)
    pub fn unixTimestamp(self: Instant) Seconds {
        return @intCast(@divFloor(self.timestamp, ns_per_s));
    }

    pub fn milliTimestamp(self: Instant) Milliseconds {
        return @intCast(@divFloor(self.timestamp, ns_per_ms));
    }

    // generate a calendar date and time for this instant
    pub fn time(self: Instant) Time {
        const adjusted = self.timezone.adjust(self.unixTimestamp());
        const days = daysSinceEpoch(adjusted.timestamp);
        const date = civilFromDays(days);

        var seconds = @mod(adjusted.timestamp, s_per_day);
        const hours = @divFloor(seconds, s_per_hour);
        seconds -= hours * s_per_hour;
        const minutes = @divFloor(seconds, s_per_min);
        seconds -= minutes * s_per_min;

        // get the nanoseconds from the original timestamp
        var nanos = @mod(self.timestamp, ns_per_s);
        const millis = @divFloor(nanos, ns_per_ms);
        nanos -= millis * ns_per_ms;
        const micros = @divFloor(nanos, ns_per_us);
        nanos -= micros * ns_per_us;

        return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = @intCast(hours),
            .minute = @intCast(minutes),
            .second = @intCast(seconds),
            .millisecond = @intCast(millis),
            .microsecond = @intCast(micros),
            .nanosecond = @intCast(nanos),
            .offset = @intCast(adjusted.timestamp - self.unixTimestamp()),
            .designation = adjusted.designation,
        };
    }

    /// add the duration to the Instant
    pub fn add(self: Instant, duration: Duration) error{Overflow}!Instant {
        const ns = try duration.inNanoseconds();

        // check for addition with overflow
        const timestamp = @addWithOverflow(self.timestamp, ns);
        if (timestamp[1] == 1) return error.Overflow;

        return .{
            .timestamp = timestamp[0],
            .timezone = self.timezone,
        };
    }

    /// subtract the duration from the Instant
    pub fn subtract(self: Instant, duration: Duration) error{Overflow}!Instant {
        const ns = try duration.inNanoseconds();

        // check for subtraction with overflow
        const timestamp = @subWithOverflow(self.timestamp, ns);
        if (timestamp[1] == 1) return error.Overflow;

        return .{
            .timestamp = timestamp[0],
            .timezone = self.timezone,
        };
    }
};

/// create a new Instant
pub fn instant(cfg: Instant.Config) !Instant {
    const ts: Nanoseconds = switch (cfg.source) {
        .now => blk: {
            const io = cfg.io orelse return error.IoRequired;
            const now = try std.Io.Clock.Timestamp.now(io, .real);
            break :blk now.raw.nanoseconds;
        },
        .unix_timestamp => |unix| @as(i128, unix) * ns_per_s,
        .unix_nano => |nano| nano,
        .time => |time| time.instant().timestamp,
        .iso8601,
        .rfc3339,
        => |iso| blk: {
            const t = try Time.fromISO8601(iso);
            break :blk t.instant().timestamp;
        },
        .rfc2822,
        .rfc5322,
        => |eml| blk: {
            const t = try Time.fromRFC5322(eml);
            break :blk t.instant().timestamp;
        },
        .rfc1123 => |http_date| blk: {
            const t = try Time.fromRFC1123(http_date);
            break :blk t.instant().timestamp;
        },
    };
    return .{
        .timestamp = ts,
        .timezone = cfg.timezone,
    };
}

test "instant" {
    const now = try std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const original = Instant{
        .timestamp = now.raw.nanoseconds,
        .timezone = &utc,
    };
    const time = original.time();
    const round_trip = time.instant();
    try std.testing.expectEqual(original.timestamp, round_trip.timestamp);
}

pub const Month = enum(u4) {
    jan = 1,
    feb,
    mar,
    apr,
    may,
    jun,
    jul,
    aug,
    sep,
    oct,
    nov,
    dec,

    /// returns the last day of the month
    /// Neri/Schneider algorithm
    pub fn lastDay(self: Month, year: i32) u5 {
        const m: u5 = @intFromEnum(self);
        if (m == 2) return if (isLeapYear(year)) 29 else 28;
        return 30 | (m ^ (m >> 3));
    }

    /// returns the full name of the month, eg "January"
    pub fn name(self: Month) []const u8 {
        return switch (self) {
            .jan => "January",
            .feb => "February",
            .mar => "March",
            .apr => "April",
            .may => "May",
            .jun => "June",
            .jul => "July",
            .aug => "August",
            .sep => "September",
            .oct => "October",
            .nov => "November",
            .dec => "December",
        };
    }

    /// returns the short name of the month, eg "Jan"
    pub fn shortName(self: Month) []const u8 {
        return self.name()[0..3];
    }

    test "lastDayOfMonth" {
        try std.testing.expectEqual(29, Month.feb.lastDay(2000));

        try std.testing.expectEqual(31, Month.jan.lastDay(2001));
        try std.testing.expectEqual(28, Month.feb.lastDay(2001));
        try std.testing.expectEqual(31, Month.mar.lastDay(2001));
        try std.testing.expectEqual(30, Month.apr.lastDay(2001));
        try std.testing.expectEqual(31, Month.may.lastDay(2001));
        try std.testing.expectEqual(30, Month.jun.lastDay(2001));
        try std.testing.expectEqual(31, Month.jul.lastDay(2001));
        try std.testing.expectEqual(31, Month.aug.lastDay(2001));
        try std.testing.expectEqual(30, Month.sep.lastDay(2001));
        try std.testing.expectEqual(31, Month.oct.lastDay(2001));
        try std.testing.expectEqual(30, Month.nov.lastDay(2001));
        try std.testing.expectEqual(31, Month.dec.lastDay(2001));
    }

    /// the number of days in a year before this month
    pub fn daysBefore(self: Month, year: i32) u9 {
        // Precomputed cumulative days for non-leap year (index 0 unused, 1=Jan, 2=Feb, etc.)
        const days_before_month = [_]u9{ 0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        const m = @intFromEnum(self);
        const base = days_before_month[m];
        // Add 1 for leap years if month is after February
        return if (m > 2 and isLeapYear(year)) base + 1 else base;
    }

    test "daysBefore" {
        try std.testing.expectEqual(60, Month.mar.daysBefore(2000));
        try std.testing.expectEqual(0, Month.jan.daysBefore(2001));
        try std.testing.expectEqual(31, Month.feb.daysBefore(2001));
        try std.testing.expectEqual(59, Month.mar.daysBefore(2001));
    }
};

pub const Duration = struct {
    days: usize = 0,
    hours: usize = 0,
    minutes: usize = 0,
    seconds: usize = 0,
    milliseconds: usize = 0,
    microseconds: usize = 0,
    nanoseconds: usize = 0,

    /// Standard duration units for rounding operations
    pub const Unit = enum {
        nanosecond,
        microsecond,
        millisecond,
        second,
        minute,
        hour,
        day,

        /// Convert unit to nanoseconds
        pub fn toNanoseconds(self: Unit) u64 {
            return switch (self) {
                .nanosecond => 1,
                .microsecond => ns_per_us,
                .millisecond => ns_per_ms,
                .second => ns_per_s,
                .minute => ns_per_min,
                .hour => ns_per_hour,
                .day => ns_per_day,
            };
        }

        /// Convert unit to a Duration
        pub fn toDuration(self: Unit) Duration {
            return switch (self) {
                .nanosecond => .{ .nanoseconds = 1 },
                .microsecond => .{ .microseconds = 1 },
                .millisecond => .{ .milliseconds = 1 },
                .second => .{ .seconds = 1 },
                .minute => .{ .minutes = 1 },
                .hour => .{ .hours = 1 },
                .day => .{ .days = 1 },
            };
        }
    };

    /// duration expressed as the total number of nanoseconds
    pub fn inNanoseconds(self: Duration) error{Overflow}!u64 {
        // check for multiplication with overflow
        const days_in_ns = @mulWithOverflow(self.days, ns_per_day);
        const hours_in_ns = @mulWithOverflow(self.hours, ns_per_hour);
        const minutes_in_ns = @mulWithOverflow(self.minutes, ns_per_min);
        const seconds_in_ns = @mulWithOverflow(self.seconds, ns_per_s);
        const milliseconds_in_ns = @mulWithOverflow(self.milliseconds, ns_per_ms);
        const microseconds_in_ns = @mulWithOverflow(self.microseconds, ns_per_us);
        if (days_in_ns[1] == 1 or
            hours_in_ns[1] == 1 or
            minutes_in_ns[1] == 1 or
            seconds_in_ns[1] == 1 or
            milliseconds_in_ns[1] == 1 or
            microseconds_in_ns[1] == 1) return error.Overflow;

        // check for addition with overflow
        var ns = days_in_ns[0];
        const components = [_]usize{
            hours_in_ns[0],
            minutes_in_ns[0],
            seconds_in_ns[0],
            milliseconds_in_ns[0],
            microseconds_in_ns[0],
            self.nanoseconds,
        };
        for (components) |value| {
            const sum_with_overflow = @addWithOverflow(ns, value);
            if (sum_with_overflow[1] == 1) return error.Overflow;
            ns = sum_with_overflow[0];
        }

        return ns;
    }

    /// Parse a Go-style duration string with support for days.
    /// Valid time units are "ns", "us", "ms", "s", "m", "h", "d".
    /// Examples: "300ms", "1.5h", "2h45m", "-1.5h", "1h30m45s", "2d12h"
    pub fn parse(s: []const u8) !Duration {
        if (s.len == 0) return error.InvalidDuration;

        var result: i128 = 0; // Total nanoseconds as signed
        var i: usize = 0;
        const negative = s[0] == '-';
        if (negative) i += 1;

        while (i < s.len) {
            // Parse number (integer or float)
            const num_start = i;
            var has_dot = false;

            // Skip digits and optional decimal point
            while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {
                if (s[i] == '.') {
                    if (has_dot) return error.InvalidDuration;
                    has_dot = true;
                }
            }

            if (i == num_start) return error.InvalidDuration;
            if (i >= s.len) return error.InvalidDuration; // No unit

            // Parse unit
            const unit_start = i;
            while (i < s.len and std.ascii.isAlphabetic(s[i])) : (i += 1) {}
            if (i == unit_start) return error.InvalidDuration;

            const num_str = s[num_start..unit_start];
            const unit_str = s[unit_start..i];

            // Determine unit multiplier
            const multiplier: i128 = if (std.mem.eql(u8, unit_str, "ns"))
                1
            else if (std.mem.eql(u8, unit_str, "us"))
                ns_per_us
            else if (std.mem.eql(u8, unit_str, "ms"))
                ns_per_ms
            else if (std.mem.eql(u8, unit_str, "s"))
                ns_per_s
            else if (std.mem.eql(u8, unit_str, "m"))
                ns_per_min
            else if (std.mem.eql(u8, unit_str, "h"))
                ns_per_hour
            else if (std.mem.eql(u8, unit_str, "d"))
                ns_per_day
            else
                return error.InvalidDuration;

            // Parse the number
            const value: i128 = if (has_dot) blk: {
                // Parse as float
                const float_val = try std.fmt.parseFloat(f64, num_str);
                break :blk @intFromFloat(float_val * @as(f64, @floatFromInt(multiplier)));
            } else blk: {
                // Parse as integer
                const int_val = try std.fmt.parseInt(i128, num_str, 10);
                break :blk int_val * multiplier;
            };

            result += value;
        }

        if (negative) result = -result;

        // Convert total nanoseconds to Duration struct
        return fromNanoseconds(result);
    }

    /// Create a Duration from a signed nanosecond value
    pub fn fromNanoseconds(ns: i128) Duration {
        const abs_ns: u128 = @intCast(@abs(ns));

        const days = abs_ns / ns_per_day;
        var remainder = abs_ns % ns_per_day;

        const hours = remainder / ns_per_hour;
        remainder = remainder % ns_per_hour;

        const minutes = remainder / ns_per_min;
        remainder = remainder % ns_per_min;

        const seconds = remainder / ns_per_s;
        remainder = remainder % ns_per_s;

        const milliseconds = remainder / ns_per_ms;
        remainder = remainder % ns_per_ms;

        const microseconds = remainder / ns_per_us;
        const nanoseconds = remainder % ns_per_us;

        return .{
            .days = @intCast(days),
            .hours = @intCast(hours),
            .minutes = @intCast(minutes),
            .seconds = @intCast(seconds),
            .milliseconds = @intCast(milliseconds),
            .microseconds = @intCast(microseconds),
            .nanoseconds = @intCast(nanoseconds),
        };
    }

    /// Format duration as a Go-style string.
    /// Uses the largest non-zero units, with appropriate precision.
    /// Examples: "1h30m", "500ms", "1.5h", "0s", "2d12h"
    pub fn format(self: Duration, writer: *std.Io.Writer) !void {
        const ns = try self.inNanoseconds();
        if (ns == 0) {
            try writer.writeAll("0s");
            return;
        }

        var remaining = ns;
        var wrote_any = false;

        // Days
        if (remaining >= ns_per_day) {
            const d = remaining / ns_per_day;
            remaining = remaining % ns_per_day;
            try writer.print("{d}d", .{d});
            wrote_any = true;
        }

        // Hours
        if (remaining >= ns_per_hour) {
            const h = remaining / ns_per_hour;
            remaining = remaining % ns_per_hour;
            try writer.print("{d}h", .{h});
            wrote_any = true;
        }

        // Minutes
        if (remaining >= ns_per_min) {
            const m = remaining / ns_per_min;
            remaining = remaining % ns_per_min;
            try writer.print("{d}m", .{m});
            wrote_any = true;
        }

        // Seconds
        if (remaining >= ns_per_s) {
            const s = remaining / ns_per_s;
            remaining = remaining % ns_per_s;
            try writer.print("{d}s", .{s});
            wrote_any = true;
        }

        // Milliseconds
        if (remaining >= ns_per_ms) {
            const ms = remaining / ns_per_ms;
            remaining = remaining % ns_per_ms;
            try writer.print("{d}ms", .{ms});
            wrote_any = true;
        }

        // Microseconds
        if (remaining >= ns_per_us) {
            const us = remaining / ns_per_us;
            remaining = remaining % ns_per_us;
            try writer.print("{d}us", .{us});
            wrote_any = true;
        }

        // Nanoseconds
        if (remaining > 0) {
            try writer.print("{d}ns", .{remaining});
            wrote_any = true;
        }

        if (!wrote_any) {
            try writer.writeAll("0s");
        }
    }

    /// Format to a buffer and return the slice
    pub fn bufPrint(self: Duration, buf: []u8) ![]u8 {
        var writer = std.Io.Writer.fixed(buf);
        try self.format(&writer);
        return writer.buffered();
    }

    /// Round returns a duration rounded to the nearest multiple of m.
    /// The rounding behavior for halfway values is to round away from zero.
    /// If m <= 0, round returns d unchanged.
    /// Example: Duration.parse("1h15m").round(Duration{ .hours = 1 }) returns "1h"
    pub fn round(self: Duration, m: Duration) error{Overflow}!Duration {
        const d_ns = try self.inNanoseconds();
        const m_ns = try m.inNanoseconds();

        if (m_ns <= 0) return self;

        // Calculate remainder and quotient
        const q = d_ns / m_ns;
        const r = d_ns % m_ns;

        // Round away from zero at halfway point
        const rounded_ns = if (r + r < m_ns)
            q * m_ns
        else
            (q + 1) * m_ns;

        return fromNanoseconds(@intCast(rounded_ns));
    }

    /// Truncate returns the result of rounding d toward zero to a multiple of m.
    /// If m <= 0, truncate returns d unchanged.
    pub fn truncate(self: Duration, m: Duration) error{Overflow}!Duration {
        const d_ns = try self.inNanoseconds();
        const m_ns = try m.inNanoseconds();

        if (m_ns <= 0) return self;

        const q = d_ns / m_ns;
        return fromNanoseconds(@intCast(q * m_ns));
    }

    /// Round to the nearest standard unit.
    /// Example: Duration.parse("1h23m45s").roundTo(.minute) returns "1h24m"
    pub fn roundTo(self: Duration, unit: Unit) error{Overflow}!Duration {
        return self.round(unit.toDuration());
    }

    /// Truncate to a standard unit.
    /// Example: Duration.parse("1h23m45s").truncateTo(.minute) returns "1h23m"
    pub fn truncateTo(self: Duration, unit: Unit) error{Overflow}!Duration {
        return self.truncate(unit.toDuration());
    }

    test "parse and format basic units" {
        // Basic units
        {
            const d = try Duration.parse("300ms");
            try std.testing.expectEqual(300, d.milliseconds);
            try std.testing.expectEqual(0, d.seconds);
        }
        {
            const d = try Duration.parse("1s");
            try std.testing.expectEqual(1, d.seconds);
        }
        {
            const d = try Duration.parse("5m");
            try std.testing.expectEqual(5, d.minutes);
        }
        {
            const d = try Duration.parse("2h");
            try std.testing.expectEqual(2, d.hours);
        }
        {
            const d = try Duration.parse("3d");
            try std.testing.expectEqual(3, d.days);
        }
        {
            const d = try Duration.parse("1000ns");
            try std.testing.expectEqual(1, d.microseconds);
        }
        {
            const d = try Duration.parse("500us");
            try std.testing.expectEqual(500, d.microseconds);
        }
    }

    test "parse combined units" {
        {
            const d = try Duration.parse("1h30m");
            try std.testing.expectEqual(1, d.hours);
            try std.testing.expectEqual(30, d.minutes);
        }
        {
            const d = try Duration.parse("2h45m30s");
            try std.testing.expectEqual(2, d.hours);
            try std.testing.expectEqual(45, d.minutes);
            try std.testing.expectEqual(30, d.seconds);
        }
        {
            const d = try Duration.parse("1d12h30m");
            try std.testing.expectEqual(1, d.days);
            try std.testing.expectEqual(12, d.hours);
            try std.testing.expectEqual(30, d.minutes);
        }
    }

    test "parse fractional durations" {
        {
            const d = try Duration.parse("1.5h");
            try std.testing.expectEqual(1, d.hours);
            try std.testing.expectEqual(30, d.minutes);
        }
        {
            const d = try Duration.parse("2.5s");
            try std.testing.expectEqual(2, d.seconds);
            try std.testing.expectEqual(500, d.milliseconds);
        }
    }

    test "format basic durations" {
        var buf: [64]u8 = undefined;
        {
            const d = Duration{ .milliseconds = 300 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("300ms", s);
        }
        {
            const d = Duration{ .seconds = 45 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("45s", s);
        }
        {
            const d = Duration{ .minutes = 5 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("5m", s);
        }
        {
            const d = Duration{ .hours = 2 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("2h", s);
        }
        {
            const d = Duration{ .days = 3 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("3d", s);
        }
    }

    test "format combined durations" {
        var buf: [64]u8 = undefined;
        {
            const d = Duration{ .hours = 1, .minutes = 30 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h30m", s);
        }
        {
            const d = Duration{ .hours = 2, .minutes = 45, .seconds = 30 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("2h45m30s", s);
        }
        {
            const d = Duration{ .days = 1, .hours = 12, .minutes = 30 };
            const s = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings("1d12h30m", s);
        }
    }

    test "format zero duration" {
        var buf: [64]u8 = undefined;
        const d = Duration{};
        const s = try d.bufPrint(&buf);
        try std.testing.expectEqualStrings("0s", s);
    }

    test "round-trip parse and format" {
        var buf: [64]u8 = undefined;
        const cases = [_][]const u8{
            "300ms",
            "1s",
            "5m",
            "2h",
            "3d",
            "1h30m",
            "2h45m30s",
            "1d12h30m",
        };

        for (cases) |input| {
            const d = try Duration.parse(input);
            const output = try d.bufPrint(&buf);
            try std.testing.expectEqualStrings(input, output);
        }
    }

    test "round duration" {
        var buf: [64]u8 = undefined;

        // Round to nearest hour
        {
            const d = try Duration.parse("1h15m");
            const rounded = try d.round(Duration{ .hours = 1 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }
        {
            const d = try Duration.parse("1h45m");
            const rounded = try d.round(Duration{ .hours = 1 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("2h", s);
        }
        {
            const d = try Duration.parse("1h30m");
            const rounded = try d.round(Duration{ .hours = 1 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("2h", s); // Halfway rounds away from zero
        }

        // Round to nearest 15 minutes
        {
            const d = try Duration.parse("1h7m");
            const rounded = try d.round(Duration{ .minutes = 15 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }
        {
            const d = try Duration.parse("1h8m");
            const rounded = try d.round(Duration{ .minutes = 15 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h15m", s);
        }

        // Round to nearest second
        {
            const d = try Duration.parse("1h23m45s");
            const rounded = try d.round(Duration{ .seconds = 1 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h23m45s", s);
        }
        {
            const d = Duration{ .seconds = 1, .milliseconds = 499 };
            const rounded = try d.round(Duration{ .seconds = 1 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1s", s);
        }
        {
            const d = Duration{ .seconds = 1, .milliseconds = 500 };
            const rounded = try d.round(Duration{ .seconds = 1 });
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("2s", s);
        }
    }

    test "truncate duration" {
        var buf: [64]u8 = undefined;

        // Truncate to hours
        {
            const d = try Duration.parse("1h15m");
            const truncated = try d.truncate(Duration{ .hours = 1 });
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }
        {
            const d = try Duration.parse("1h45m");
            const truncated = try d.truncate(Duration{ .hours = 1 });
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }

        // Truncate to 15 minutes
        {
            const d = try Duration.parse("1h23m");
            const truncated = try d.truncate(Duration{ .minutes = 15 });
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h15m", s);
        }

        // Truncate to seconds
        {
            const d = Duration{ .seconds = 1, .milliseconds = 999 };
            const truncated = try d.truncate(Duration{ .seconds = 1 });
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1s", s);
        }
    }

    test "roundTo with unit enum" {
        var buf: [64]u8 = undefined;

        // Round to nearest hour
        {
            const d = try Duration.parse("1h23m45s");
            const rounded = try d.roundTo(.hour);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }
        {
            const d = try Duration.parse("1h45m");
            const rounded = try d.roundTo(.hour);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("2h", s);
        }

        // Round to nearest minute
        {
            const d = try Duration.parse("1h23m45s");
            const rounded = try d.roundTo(.minute);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h24m", s);
        }
        {
            const d = try Duration.parse("1h23m29s");
            const rounded = try d.roundTo(.minute);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h23m", s);
        }

        // Round to nearest second
        {
            const d = Duration{ .seconds = 5, .milliseconds = 600 };
            const rounded = try d.roundTo(.second);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("6s", s);
        }

        // Round to nearest millisecond
        {
            const d = Duration{ .milliseconds = 5, .microseconds = 600 };
            const rounded = try d.roundTo(.millisecond);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("6ms", s);
        }
    }

    test "truncateTo with unit enum" {
        var buf: [64]u8 = undefined;

        // Truncate to hours
        {
            const d = try Duration.parse("1h59m59s");
            const truncated = try d.truncateTo(.hour);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }

        // Truncate to minutes
        {
            const d = try Duration.parse("1h23m59s");
            const truncated = try d.truncateTo(.minute);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h23m", s);
        }

        // Truncate to seconds
        {
            const d = Duration{ .seconds = 5, .milliseconds = 999 };
            const truncated = try d.truncateTo(.second);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("5s", s);
        }

        // Truncate to milliseconds
        {
            const d = Duration{ .milliseconds = 5, .microseconds = 999 };
            const truncated = try d.truncateTo(.millisecond);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("5ms", s);
        }
    }
};

pub const Weekday = enum(u3) {
    sun = 0,
    mon,
    tue,
    wed,
    thu,
    fri,
    sat,

    /// number of days from self until other. Returns 0 when self == other
    pub fn daysUntil(self: Weekday, other: Weekday) u3 {
        const d: u8 = @as(u8, @intFromEnum(other)) -% @as(u8, @intFromEnum(self));
        return if (d <= 6) @intCast(d) else @intCast(d +% 7);
    }

    /// returns the full name of the day, eg "Tuesday"
    pub fn name(self: Weekday) []const u8 {
        return switch (self) {
            .sun => "Sunday",
            .mon => "Monday",
            .tue => "Tuesday",
            .wed => "Wednesday",
            .thu => "Thursday",
            .fri => "Friday",
            .sat => "Saturday",
        };
    }

    /// returns the short name of the day, eg "Tue"
    pub fn shortName(self: Weekday) []const u8 {
        return self.name()[0..3];
    }

    test "daysUntil" {
        const wed: Weekday = .wed;
        try std.testing.expectEqual(0, wed.daysUntil(.wed));
        try std.testing.expectEqual(6, wed.daysUntil(.tue));
        try std.testing.expectEqual(5, wed.daysUntil(.mon));
        try std.testing.expectEqual(4, wed.daysUntil(.sun));
    }
};

pub const Date = struct {
    year: i32,
    month: Month,
    day: u5, // 1-31

    /// Checks for equality of two dates
    pub fn eql(date1: Date, date2: Date) bool {
        return date1.year == date2.year and
            date1.month == date2.month and
            date1.day == date2.day;
    }

    test "Date-Equality" {
        const date: Date = .{
            .year = 2025,
            .month = Month.sep,
            .day = 13,
        };
        try std.testing.expect(date.eql(Date{ .year = 2025, .month = Month.sep, .day = 13 }));
        try std.testing.expect(!date.eql(Date{ .year = 2025, .month = Month.sep, .day = 12 }));
        try std.testing.expect(!date.eql(Date{ .year = 2025, .month = Month.aug, .day = 13 }));
        try std.testing.expect(!date.eql(Date{ .year = 2024, .month = Month.sep, .day = 13 }));
    }

    /// Compares two dates with another. If `date2` happens after `date1`, then the `TimeComparison.after` is returned.
    /// If `date2` happens before `date1`, then `TimeComparison.before` is returned. If both represent the same date, `TimeComparison.equal` is returned;
    pub fn compare(date1: Date, date2: Date) TimeComparison {
        if (date1.year > date2.year) {
            return .before;
        } else if (date1.year < date2.year) {
            return .after;
        }

        if (@intFromEnum(date1.month) > @intFromEnum(date2.month)) {
            return .before;
        } else if (@intFromEnum(date1.month) < @intFromEnum(date2.month)) {
            return .after;
        }

        if (date1.day > date2.day) {
            return .before;
        } else if (date1.day < date2.day) {
            return .after;
        }

        return .equal;
    }

    test "Date-Comparison" {
        const date: Date = .{
            .year = 2025,
            .month = Month.sep,
            .day = 13,
        };

        try std.testing.expectEqual(TimeComparison.before, date.compare(Date{ .year = 2025, .month = Month.sep, .day = 12 }));
        try std.testing.expectEqual(TimeComparison.before, date.compare(Date{ .year = 2025, .month = Month.aug, .day = 13 }));
        try std.testing.expectEqual(TimeComparison.before, date.compare(Date{ .year = 2024, .month = Month.sep, .day = 13 }));
        try std.testing.expectEqual(TimeComparison.before, date.compare(Date{ .year = 2024, .month = Month.dec, .day = 31 }));
        try std.testing.expectEqual(TimeComparison.before, date.compare(Date{ .year = 2025, .month = Month.aug, .day = 31 }));

        try std.testing.expectEqual(TimeComparison.after, date.compare(Date{ .year = 2025, .month = Month.sep, .day = 14 }));
        try std.testing.expectEqual(TimeComparison.after, date.compare(Date{ .year = 2025, .month = Month.oct, .day = 13 }));
        try std.testing.expectEqual(TimeComparison.after, date.compare(Date{ .year = 2026, .month = Month.sep, .day = 13 }));
        try std.testing.expectEqual(TimeComparison.after, date.compare(Date{ .year = 2026, .month = Month.jan, .day = 1 }));
        try std.testing.expectEqual(TimeComparison.after, date.compare(Date{ .year = 2025, .month = Month.oct, .day = 1 }));

        try std.testing.expectEqual(TimeComparison.equal, date.compare(Date{ .year = 2025, .month = Month.sep, .day = 13 }));
    }
};

pub const TimeComparison = enum(u2) {
    after,
    before,
    equal,
};

pub const Time = struct {
    year: i32 = 1970,
    month: Month = .jan,
    day: u5 = 1, // 1-31
    hour: u5 = 0, // 0-23
    minute: u6 = 0, // 0-59
    second: u6 = 0, // 0-60
    millisecond: u10 = 0, // 0-999
    microsecond: u10 = 0, // 0-999
    nanosecond: u10 = 0, // 0-999
    offset: i32 = 0, // offset from UTC in seconds
    designation: []const u8 = "",

    /// Returns the nanosecond timestamp for this time (UTC)
    pub fn timestamp(self: Time) Nanoseconds {
        const days = daysFromCivil(.{
            .year = self.year,
            .month = self.month,
            .day = self.day,
        });
        return @as(i128, days) * ns_per_day +
            @as(i128, self.hour) * ns_per_hour +
            @as(i128, self.minute) * ns_per_min +
            @as(i128, self.second) * ns_per_s +
            @as(i128, self.millisecond) * ns_per_ms +
            @as(i128, self.microsecond) * ns_per_us +
            @as(i128, self.nanosecond) -
            @as(i128, self.offset) * ns_per_s;
    }

    /// Creates a UTC Instant for this time
    pub fn instant(self: Time) Instant {
        return .{
            .timestamp = self.timestamp(),
            .timezone = &utc,
        };
    }

    pub fn fromISO8601(iso: []const u8) !Time {
        const parseInt = std.fmt.parseInt;
        var time: Time = .{};
        const State = enum {
            year,
            month_or_ordinal,
            day,
            hour,
            minute,
            minute_fraction_or_second,
            second_fraction_or_offset,
        };
        var state: State = .year;
        var i: usize = 0;
        while (i < iso.len) {
            switch (state) {
                .year => {
                    if (iso.len <= 4) {
                        // year only data
                        const int = try parseInt(i32, iso, 10);
                        time.year = int * std.math.pow(i32, 10, @as(i32, @intCast(4 - iso.len)));
                        break;
                    } else {
                        time.year = try parseInt(i32, iso[0..4], 10);
                        state = .month_or_ordinal;
                        i += 4;
                        if (iso[i] == '-') i += 1;
                    }
                },
                .month_or_ordinal => {
                    const token_end = std.mem.indexOfAnyPos(u8, iso, i, "- T") orelse iso.len;
                    switch (token_end - i) {
                        2 => {
                            const m: u4 = try parseInt(u4, iso[i..token_end], 10);
                            time.month = @enumFromInt(m);
                            state = .day;
                        },
                        3 => { // ordinal
                            const doy = try parseInt(u9, iso[i..token_end], 10);
                            var m: u4 = 1;
                            var days: u9 = 0;
                            while (m <= 12) : (m += 1) {
                                const month: Month = @enumFromInt(m);

                                if (days + month.lastDay(time.year) < doy) {
                                    days += month.lastDay(time.year);
                                    continue;
                                }
                                time.month = month;
                                time.day = @intCast(doy - days);
                                break;
                            }
                            state = .hour;
                        },
                        4 => { // MMDD
                            const m: u4 = try parseInt(u4, iso[i .. i + 2], 10);
                            time.month = @enumFromInt(m);
                            time.day = try parseInt(u5, iso[i + 2 .. token_end], 10);
                            state = .hour;
                        },
                        else => return error.InvalidISO8601,
                    }
                    i = token_end + 1;
                },
                .day => {
                    time.day = try parseInt(u5, iso[i .. i + 2], 10);
                    // add 3 instead of 2 because we either have a trailing ' ',
                    // 'T', or EOF
                    i += 3;
                    state = .hour;
                },
                .hour => {
                    time.hour = try parseInt(u5, iso[i .. i + 2], 10);
                    i += 2;
                    state = .minute;
                },
                .minute => {
                    if (iso[i] == ':') i += 1;
                    time.minute = try parseInt(u6, iso[i .. i + 2], 10);
                    i += 2;
                    state = .minute_fraction_or_second;
                },
                .minute_fraction_or_second => {
                    const b = iso[i];
                    if (b == '.') return error.UnhandledFormat; // TODO:
                    if (b == ':') i += 1;
                    if (std.ascii.isDigit(iso[i])) {
                        time.second = try parseInt(u6, iso[i .. i + 2], 10);
                        i += 2;
                    }
                    state = .second_fraction_or_offset;
                },
                .second_fraction_or_offset => {
                    switch (iso[i]) {
                        'Z' => break,
                        '+', '-' => {
                            const sign: i32 = if (iso[i] == '-') -1 else 1;
                            i += 1;
                            const hour = try parseInt(u5, iso[i .. i + 2], 10);
                            i += 2;
                            time.offset = sign * hour * s_per_hour;
                            if (i >= iso.len - 1) break;
                            if (iso[i] == ':') i += 1;
                            const minute = try parseInt(u6, iso[i .. i + 2], 10);
                            time.offset += sign * minute * s_per_min;
                            i += 2;
                            break;
                        },
                        '.' => {
                            i += 1;
                            const frac_end = std.mem.indexOfAnyPos(u8, iso, i, "Z+-") orelse iso.len;
                            const rhs = try parseInt(u64, iso[i..frac_end], 10);
                            const sigs = frac_end - i;
                            // convert sigs to nanoseconds
                            const pow = std.math.pow(u64, 10, @as(u64, @intCast(9 - sigs)));
                            var nanos = rhs * pow;
                            time.millisecond = @intCast(@divFloor(nanos, ns_per_ms));
                            nanos -= @as(u64, time.millisecond) * ns_per_ms;
                            time.microsecond = @intCast(@divFloor(nanos, ns_per_us));
                            nanos -= @as(u64, time.microsecond) * ns_per_us;
                            time.nanosecond = @intCast(nanos);
                            i = frac_end;
                        },
                        else => return error.InvalidISO8601,
                    }
                },
            }
        }
        return time;
    }

    test "fromISO8601" {
        {
            const year = try Time.fromISO8601("2000");
            try std.testing.expectEqual(2000, year.year);
        }
        {
            const ym = try Time.fromISO8601("200002");
            try std.testing.expectEqual(2000, ym.year);
            try std.testing.expectEqual(.feb, ym.month);

            const ym_ext = try Time.fromISO8601("2000-02");
            try std.testing.expectEqual(2000, ym_ext.year);
            try std.testing.expectEqual(.feb, ym_ext.month);
        }
        {
            const ymd = try Time.fromISO8601("20000212");
            try std.testing.expectEqual(2000, ymd.year);
            try std.testing.expectEqual(.feb, ymd.month);
            try std.testing.expectEqual(12, ymd.day);

            const ymd_ext = try Time.fromISO8601("2000-02-12");
            try std.testing.expectEqual(2000, ymd_ext.year);
            try std.testing.expectEqual(.feb, ymd_ext.month);
            try std.testing.expectEqual(12, ymd_ext.day);
        }
        {
            const ordinal = try Time.fromISO8601("2000031");
            try std.testing.expectEqual(2000, ordinal.year);
            try std.testing.expectEqual(.jan, ordinal.month);
            try std.testing.expectEqual(31, ordinal.day);

            const ordinal_ext = try Time.fromISO8601("2000-043");
            try std.testing.expectEqual(2000, ordinal_ext.year);
            try std.testing.expectEqual(.feb, ordinal_ext.month);
            try std.testing.expectEqual(12, ordinal_ext.day);
        }
        {
            const ymdh = try Time.fromISO8601("20000212 11");
            try std.testing.expectEqual(2000, ymdh.year);
            try std.testing.expectEqual(.feb, ymdh.month);
            try std.testing.expectEqual(12, ymdh.day);
            try std.testing.expectEqual(11, ymdh.hour);

            const ymdh_ext = try Time.fromISO8601("2000-02-12T11");
            try std.testing.expectEqual(2000, ymdh_ext.year);
            try std.testing.expectEqual(.feb, ymdh_ext.month);
            try std.testing.expectEqual(12, ymdh_ext.day);
            try std.testing.expectEqual(11, ymdh_ext.hour);
        }
        {
            const ymdhm = try Time.fromISO8601("2025-05-19T11:23");
            try std.testing.expectEqual(2025, ymdhm.year);
            try std.testing.expectEqual(.may, ymdhm.month);
            try std.testing.expectEqual(19, ymdhm.day);
            try std.testing.expectEqual(11, ymdhm.hour);
            try std.testing.expectEqual(23, ymdhm.minute);
        }
        {
            const full = try Time.fromISO8601("20000212 111213Z");
            try std.testing.expectEqual(2000, full.year);
            try std.testing.expectEqual(.feb, full.month);
            try std.testing.expectEqual(12, full.day);
            try std.testing.expectEqual(11, full.hour);
            try std.testing.expectEqual(12, full.minute);
            try std.testing.expectEqual(13, full.second);

            const full_ext = try Time.fromISO8601("2000-02-12T11:12:13Z");
            try std.testing.expectEqual(2000, full_ext.year);
            try std.testing.expectEqual(.feb, full_ext.month);
            try std.testing.expectEqual(12, full_ext.day);
            try std.testing.expectEqual(11, full_ext.hour);
            try std.testing.expectEqual(12, full_ext.minute);
            try std.testing.expectEqual(13, full_ext.second);
        }
        {
            const s_frac = try Time.fromISO8601("2000-02-12T11:12:13.123Z");
            try std.testing.expectEqual(123, s_frac.millisecond);
            try std.testing.expectEqual(0, s_frac.microsecond);
            try std.testing.expectEqual(0, s_frac.nanosecond);
        }
        {
            const offset = try Time.fromISO8601("2000-02-12T11:12:13.123-12:00");
            try std.testing.expectEqual(-12 * s_per_hour, offset.offset);
        }
        {
            const offset = try Time.fromISO8601("2000-02-12T11:12:13+12:30");
            try std.testing.expectEqual(12 * s_per_hour + 30 * s_per_min, offset.offset);
        }
        {
            const offset = try Time.fromISO8601("2025-05-19T11:23+0200");
            try std.testing.expectEqual(2 * s_per_hour, offset.offset);
        }
        {
            const offset = try Time.fromISO8601("20000212T111213+1230");
            try std.testing.expectEqual(12 * s_per_hour + 30 * s_per_min, offset.offset);
        }
        {
            const basic = try Time.fromISO8601("20240224T154944");
            try std.testing.expectEqual(2024, basic.year);
            try std.testing.expectEqual(Month.feb, basic.month);
            try std.testing.expectEqual(24, basic.day);
            try std.testing.expectEqual(15, basic.hour);
            try std.testing.expectEqual(49, basic.minute);
            try std.testing.expectEqual(44, basic.second);
            try std.testing.expectEqual(0, basic.offset);
        }
        {
            const basic = try Time.fromISO8601("20240224T154944Z");
            try std.testing.expectEqual(2024, basic.year);
            try std.testing.expectEqual(Month.feb, basic.month);
            try std.testing.expectEqual(24, basic.day);
            try std.testing.expectEqual(15, basic.hour);
            try std.testing.expectEqual(49, basic.minute);
            try std.testing.expectEqual(44, basic.second);
            try std.testing.expectEqual(0, basic.offset);
        }
    }

    pub fn fromRFC5322(eml: []const u8) !Time {
        const parseInt = std.fmt.parseInt;
        var time: Time = .{};
        var i: usize = 0;
        // day
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            const end = std.mem.indexOfScalarPos(u8, eml, i, ' ') orelse return error.InvalidFormat;
            time.day = try parseInt(u5, eml[i..end], 10);
            i = end + 1;
        }

        // month
        {
            // consume until an alpha
            while (i < eml.len and !std.ascii.isAlphabetic(eml[i])) : (i += 1) {}
            assert(eml.len >= i + 3);
            var buf: [3]u8 = undefined;
            buf[0] = std.ascii.toLower(eml[i]);
            buf[1] = std.ascii.toLower(eml[i + 1]);
            buf[2] = std.ascii.toLower(eml[i + 2]);
            time.month = std.meta.stringToEnum(Month, &buf) orelse return error.InvalidFormat;
            i += 3;
        }

        // year
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            assert(eml.len >= i + 4);
            time.year = try parseInt(i32, eml[i .. i + 4], 10);
            i += 4;
        }

        // hour
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            const end = std.mem.indexOfScalarPos(u8, eml, i, ':') orelse return error.InvalidFormat;
            time.hour = try parseInt(u5, eml[i..end], 10);
            i = end + 1;
        }
        // minute
        {
            // consume until a digit
            while (i < eml.len and !std.ascii.isDigit(eml[i])) : (i += 1) {}
            assert(i + 2 < eml.len);
            time.minute = try parseInt(u6, eml[i .. i + 2], 10);
            i += 2;
        }
        // second and zone
        {
            assert(i < eml.len);
            // seconds are optional
            if (eml[i] == ':') {
                i += 1;
                assert(i + 2 < eml.len);
                time.second = try parseInt(u6, eml[i .. i + 2], 10);
                i += 2;
            }
            // consume whitespace
            while (i < eml.len and std.ascii.isWhitespace(eml[i])) : (i += 1) {}
            assert(i + 5 <= eml.len);
            const hours = try parseInt(i32, eml[i .. i + 3], 10);
            const minutes = try parseInt(i32, eml[i + 3 .. i + 5], 10);
            const offset_minutes: i32 = if (hours > 0)
                hours * 60 + minutes
            else
                hours * 60 - minutes;
            time.offset = offset_minutes * 60;
        }
        return time;
    }

    test "fromRFC5322" {
        {
            const time = try Time.fromRFC5322("Thu, 13 Feb 1969 23:32:54 -0330");
            try std.testing.expectEqual(1969, time.year);
            try std.testing.expectEqual(.feb, time.month);
            try std.testing.expectEqual(13, time.day);
            try std.testing.expectEqual(23, time.hour);
            try std.testing.expectEqual(32, time.minute);
            try std.testing.expectEqual(54, time.second);
            try std.testing.expectEqual(-12_600, time.offset);
        }
        {
            // FWS everywhere
            const time = try Time.fromRFC5322("  Thu,    13 \tFeb 1969\t\r\n 23:32:54    -0330");
            try std.testing.expectEqual(1969, time.year);
            try std.testing.expectEqual(.feb, time.month);
            try std.testing.expectEqual(13, time.day);
            try std.testing.expectEqual(23, time.hour);
            try std.testing.expectEqual(32, time.minute);
            try std.testing.expectEqual(54, time.second);
            try std.testing.expectEqual(-12_600, time.offset);
        }
    }

    pub fn fromRFC1123(http_date: []const u8) !Time {
        const parseInt = std.fmt.parseInt;
        var time: Time = .{};
        var i: usize = 0;

        // day
        {
            // consume until a digit
            while (i < http_date.len and !std.ascii.isDigit(http_date[i])) : (i += 1) {}
            const end = std.mem.indexOfScalarPos(u8, http_date, i, ' ') orelse return error.InvalidFormat;
            time.day = try parseInt(u5, http_date[i..end], 10);
            i = end + 1;
        }

        // month
        {
            // consume until an alpha
            while (i < http_date.len and !std.ascii.isAlphabetic(http_date[i])) : (i += 1) {}
            assert(http_date.len >= i + 3);
            var buf: [3]u8 = undefined;
            buf[0] = std.ascii.toLower(http_date[i]);
            buf[1] = std.ascii.toLower(http_date[i + 1]);
            buf[2] = std.ascii.toLower(http_date[i + 2]);
            time.month = std.meta.stringToEnum(Month, &buf) orelse return error.InvalidFormat;
            i += 3;
        }

        // year
        {
            // consume until a digit
            while (i < http_date.len and !std.ascii.isDigit(http_date[i])) : (i += 1) {}
            assert(http_date.len >= i + 4);
            time.year = try parseInt(i32, http_date[i .. i + 4], 10);
            i += 4;
        }

        // hour
        {
            // consume until a digit
            while (i < http_date.len and !std.ascii.isDigit(http_date[i])) : (i += 1) {}
            const end = std.mem.indexOfScalarPos(u8, http_date, i, ':') orelse return error.InvalidFormat;
            time.hour = try parseInt(u5, http_date[i..end], 10);
            i = end + 1;
        }
        // minute
        {
            // consume until a digit
            while (i < http_date.len and !std.ascii.isDigit(http_date[i])) : (i += 1) {}
            assert(i + 2 < http_date.len);
            time.minute = try parseInt(u6, http_date[i .. i + 2], 10);
            i += 2;
        }
        // second
        {
            assert(i < http_date.len);
            i += 1;
            assert(i + 2 < http_date.len);
            time.second = try parseInt(u6, http_date[i .. i + 2], 10);
            i += 2;
        }
        // zone
        {
            // consume whitespace
            while (i < http_date.len and std.ascii.isWhitespace(http_date[i])) : (i += 1) {}
            assert(std.mem.eql(u8, http_date[i..], "GMT"));
            time.offset = 0;
        }
        return time;
    }

    test "fromRFC1123" {
        {
            const time = try Time.fromRFC1123("Sun, 06 Nov 1994 08:49:37 GMT");
            try std.testing.expectEqual(1994, time.year);
            try std.testing.expectEqual(.nov, time.month);
            try std.testing.expectEqual(6, time.day);
            try std.testing.expectEqual(8, time.hour);
            try std.testing.expectEqual(49, time.minute);
            try std.testing.expectEqual(37, time.second);
            try std.testing.expectEqual(0, time.offset);
        }
    }

    pub const Format = union(enum) {
        rfc3339, // YYYY-MM-DD-THH:MM:SS.sss+00:00
    };

    pub fn bufPrint(self: Time, buf: []u8, fmt: Format) ![]u8 {
        switch (fmt) {
            .rfc3339 => {
                if (self.year < 0) return error.InvalidTime;
                if (self.offset == 0)
                    return std.fmt.bufPrint(
                        buf,
                        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
                        .{
                            @as(u32, @intCast(self.year)),
                            @intFromEnum(self.month),
                            self.day,
                            self.hour,
                            self.minute,
                            self.second,
                            self.millisecond,
                        },
                    )
                else {
                    const h = @divFloor(@abs(self.offset), s_per_hour);
                    const min = @divFloor(@abs(self.offset) - h * s_per_hour, s_per_min);
                    const sign: u8 = if (self.offset > 0) '+' else '-';
                    return std.fmt.bufPrint(
                        buf,
                        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{c}{d:0>2}:{d:0>2}",
                        .{
                            @as(u32, @intCast(self.year)),
                            @intFromEnum(self.month),
                            self.day,
                            self.hour,
                            self.minute,
                            self.second,
                            self.millisecond,
                            sign,
                            h,
                            min,
                        },
                    );
                }
            },
        }
    }

    inline fn getCachedDays(self: Time, cache: *?Days) Days {
        if (cache.*) |d| return d;
        const d = daysFromCivil(.{ .year = self.year, .month = self.month, .day = self.day });
        cache.* = d;
        return d;
    }

    /// Format time using strftime(3) specified, eg %Y-%m-%dT%H:%M:%S
    pub fn strftime(self: Time, writer: *std.Io.Writer, fmt: []const u8) !void {
        const inst = self.instant();
        // Lazy cache for days calculation (used by weekday specifiers)
        var cached_days: ?Days = null;
        var i: usize = 0;
        while (i < fmt.len) {
            const last = i;
            i = std.mem.indexOfScalarPos(u8, fmt, i, '%') orelse {
                try writer.writeAll(fmt[i..]);
                i = fmt.len;
                break;
            };
            if (i + 1 >= fmt.len) return error.InvalidFormat;

            try writer.writeAll(fmt[last..i]);
            defer i = i + 2;
            const b = fmt[i + 1];
            switch (b) {
                '%' => try writer.writeByte('%'),
                'a' => {
                    const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                    try writer.writeAll(weekday.shortName());
                },
                'A' => {
                    const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                    try writer.writeAll(weekday.name());
                },
                'b', 'h' => try writer.writeAll(self.month.shortName()),
                'B' => try writer.writeAll(self.month.name()),
                'c' => try self.strftime(writer, "%a %b %e %H:%M:%S %Y"), // locale specific
                'C' => {
                    if (self.year > 9999 or self.year < -9999) return error.Overflow;
                    var buf: [5]u8 = undefined;
                    // year is an i64, which gets printed with a + or a -
                    _ = try std.fmt.bufPrint(&buf, "{d:0>4}", .{self.year});
                    try writer.writeAll(buf[1..3]);
                },
                'd' => try writer.print("{d:0>2}", .{self.day}),
                'D' => try self.strftime(writer, "%m/%d/%y"),
                'e' => try writer.print("{d: >2}", .{self.day}),
                'f' => try writer.print("{d:0>3}{d:0>3}", .{ self.millisecond, self.microsecond }),
                'F' => try self.strftime(writer, "%Y-%m-%d"),
                'G' => return error.UnsupportedSpecifier,
                'g' => return error.UnsupportedSpecifier,
                'H' => try writer.print("{d:0>2}", .{self.hour}),
                'I' => {
                    switch (self.hour) {
                        0 => try writer.writeAll("12"),
                        1...12 => try writer.print("{d:0>2}", .{self.hour}),
                        else => try writer.print("{d:0>2}", .{self.hour - 12}),
                    }
                },
                'j' => {
                    const before_month = self.month.daysBefore(self.year);
                    try writer.print("{d:0>3}", .{self.day + before_month});
                },
                'k' => try writer.print("{d}", .{self.hour}),
                'l' => {
                    switch (self.hour) {
                        0 => try writer.writeAll("12"),
                        1...12 => try writer.print("{d}", .{self.hour}),
                        else => try writer.print("{d}", .{self.hour - 12}),
                    }
                },
                'm' => try writer.print("{d:0>2}", .{@intFromEnum(self.month)}),
                'M' => try writer.print("{d:0>2}", .{self.minute}),
                'n' => try writer.writeByte('\n'),
                'O' => return error.UnsupportedSpecifier,
                'p' => {
                    if (self.hour >= 12)
                        try writer.writeAll("PM")
                    else
                        try writer.writeAll("AM");
                },
                'P' => {
                    if (self.hour >= 12)
                        try writer.writeAll("pm")
                    else
                        try writer.writeAll("am");
                },
                'r' => try self.strftime(writer, "%I:%M:%S %p"),
                'R' => try self.strftime(writer, "%H:%M"),
                's' => try writer.print("{d}", .{inst.unixTimestamp()}),
                'S' => try writer.print("{d:0>2}", .{self.second}),
                't' => try writer.writeByte('\t'),
                'T' => try self.strftime(writer, "%H:%M:%S"),
                'u' => {
                    const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                    switch (weekday) {
                        .sun => try writer.writeByte('7'),
                        else => try writer.writeByte(@as(u8, @intFromEnum(weekday)) + 0x30),
                    }
                },
                'U' => {
                    const day_of_year = self.day + self.month.daysBefore(self.year);
                    // find the date of the first sunday
                    const weekd_jan_1 = blk: {
                        const jan_1: Date = .{ .year = self.year, .month = .jan, .day = 1 };
                        const days = daysFromCivil(jan_1);
                        break :blk weekdayFromDays(days);
                    };
                    // Day of year of first sunday. This represents the start of week 1
                    const first_sunday = switch (weekd_jan_1) {
                        .sun => 1,
                        else => 7 - @intFromEnum(weekd_jan_1) + 1,
                    };
                    if (day_of_year < first_sunday)
                        try writer.writeAll("00")
                    else
                        try writer.print("{d:0>2}", .{(day_of_year + 7 - first_sunday) / 7});
                },
                'V' => return error.UnsupportedSpecifier,
                'w' => {
                    const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                    try writer.writeByte(@as(u8, @intFromEnum(weekday)) + 0x30);
                },
                'W' => {
                    const day_of_year = self.day + self.month.daysBefore(self.year);
                    // find the date of the first sunday
                    const weekd_jan_1 = blk: {
                        const jan_1: Date = .{ .year = self.year, .month = .jan, .day = 1 };
                        const days = daysFromCivil(jan_1);
                        break :blk weekdayFromDays(days);
                    };
                    // Day of year of first sunday. This represents the start of week 1
                    const first_monday = switch (weekd_jan_1) {
                        .sun => 2,
                        .mon => 1,
                        else => 7 - @intFromEnum(weekd_jan_1) + 2,
                    };
                    if (day_of_year < first_monday)
                        try writer.writeAll("00")
                    else
                        try writer.print("{d:0>2}", .{(day_of_year + 7 - first_monday) / 7});
                },
                'x' => try self.strftime(writer, "%m/%d/%y"),
                'X' => try self.strftime(writer, "%H:%M:%S"),
                'y' => {
                    var buf: [16]u8 = undefined;
                    _ = try std.fmt.bufPrint(&buf, "{d:0>16}", .{self.year});
                    try writer.writeAll(buf[14..16]);
                },
                'Y' => try writer.print("{d}", .{self.year}),
                'z' => {
                    const hours = absHoursFromSeconds(self.offset);
                    const minutes = absMinutesFromSeconds(self.offset);
                    if (self.offset < 0)
                        try writer.print("-{d:0>2}{d:0>2}", .{ hours, minutes })
                    else
                        try writer.print("+{d:0>2}{d:0>2}", .{ hours, minutes });
                },
                'Z' => try writer.writeAll(self.designation),
                else => return error.UnknownSpecifier,
            }
        }
    }

    /// Format using golang magic date format.
    pub fn gofmt(self: Time, writer: *std.Io.Writer, fmt: []const u8) !void {
        // Lazy cache for days calculation (used by weekday specifiers)
        var cached_days: ?Days = null;
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            const b = fmt[i];
            switch (b) {
                'J' => { // Jan, January
                    if (std.mem.startsWith(u8, fmt[i..], "January")) {
                        try writer.writeAll(self.month.name());
                        i += 6;
                    } else if (std.mem.startsWith(u8, fmt[i..], "Jan")) {
                        try writer.writeAll(self.month.shortName());
                        i += 2;
                    } else try writer.writeByte(b);
                },
                'M' => { // Monday, Mon, MST
                    if (std.mem.startsWith(u8, fmt[i..], "Monday")) {
                        const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                        try writer.writeAll(weekday.name());
                        i += 5;
                    } else if (std.mem.startsWith(u8, fmt[i..], "Mon")) {
                        if (i + 3 >= fmt.len) {
                            const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                            try writer.writeAll(weekday.shortName());
                            i += 2;
                        } else if (!std.ascii.isLower(fmt[i + 3])) {
                            // We only write "Mon" if the next char is *not* a lowercase
                            const weekday = weekdayFromDays(self.getCachedDays(&cached_days));
                            try writer.writeAll(weekday.shortName());
                            i += 2;
                        }
                    } else if (std.mem.startsWith(u8, fmt[i..], "MST")) {
                        try writer.writeAll(self.designation);
                        i += 2;
                    } else try writer.writeByte(b);
                },
                '0' => { // 01, 02, 03, 04, 05, 06, 002
                    if (i == fmt.len - 1) {
                        try writer.writeByte(b);
                        continue;
                    }
                    i += 1;
                    const b2 = fmt[i];
                    switch (b2) {
                        '1' => try writer.print("{d:0>2}", .{@intFromEnum(self.month)}),
                        '2' => try writer.print("{d:0>2}", .{self.day}),
                        '3' => {
                            if (self.hour == 0)
                                try writer.writeAll("12")
                            else if (self.hour > 12)
                                try writer.print("{d:0>2}", .{self.hour - 12})
                            else
                                try writer.print("{d:0>2}", .{self.hour});
                        },
                        '4' => try writer.print("{d:0>2}", .{self.minute}),
                        '5' => try writer.print("{d:0>2}", .{self.second}),
                        '6' => {
                            var buf: [16]u8 = undefined;
                            _ = try std.fmt.bufPrint(&buf, "{d:0>16}", .{self.year});
                            try writer.writeAll(buf[14..16]);
                        },
                        else => {
                            if (std.mem.startsWith(u8, fmt[i..], "02")) {
                                i += 1;
                                const before_month = self.month.daysBefore(self.year);
                                try writer.print("{d:0>3}", .{self.day + before_month});
                            } else {
                                try writer.writeByte(b);
                                try writer.writeByte(b2);
                            }
                        },
                    }
                },
                '1' => { // 15, 1
                    if (std.mem.startsWith(u8, fmt[i..], "15")) {
                        i += 1;
                        try writer.print("{d:0>2}", .{self.hour});
                    } else {
                        try writer.print("{d}", .{@intFromEnum(self.month)});
                    }
                },
                '2' => { // 2006, 2
                    if (std.mem.startsWith(u8, fmt[i..], "2006")) {
                        i += 3;
                        if (self.year < 0)
                            try writer.print("{d}", .{self.year})
                        else
                            try writer.print("{d}", .{@as(u32, @intCast(self.year))});
                    } else try writer.print("{d}", .{self.day});
                },
                '_' => { // _2, __2
                    if (std.mem.startsWith(u8, fmt[i..], "_2")) {
                        i += 1;
                        try writer.print("{d: >2}", .{self.day});
                    } else if (std.mem.startsWith(u8, fmt[i..], "__2")) {
                        i += 2;
                        const before_month = self.month.daysBefore(self.year);
                        try writer.print("{d: >3}", .{self.day + before_month});
                    } else try writer.writeByte(b);
                },
                '3' => {
                    if (self.hour == 0)
                        try writer.writeAll("12")
                    else if (self.hour > 12)
                        try writer.print("{d}", .{self.hour - 12})
                    else
                        try writer.print("{d}", .{self.hour});
                },
                '4' => try writer.print("{d}", .{self.minute}),
                '5' => try writer.print("{d}", .{self.second}),
                'P' => {
                    if (i + 1 < fmt.len and fmt[i + 1] == 'M') {
                        i += 1;
                        if (self.hour >= 12)
                            try writer.writeAll("PM")
                        else
                            try writer.writeAll("AM");
                    } else try writer.writeByte(b);
                },
                'p' => {
                    if (i + 1 < fmt.len and fmt[i + 1] == 'm') {
                        i += 1;
                        if (self.hour >= 12)
                            try writer.writeAll("pm")
                        else
                            try writer.writeAll("am");
                    } else try writer.writeByte(b);
                },
                '-', 'Z' => { // -070000, -07:00:00, -0700, -07:00, -07
                    if (i == fmt.len - 1) {
                        try writer.writeByte(b);
                        continue;
                    }
                    if (std.mem.startsWith(u8, fmt[i + 1 ..], "070000")) {
                        i += 6;
                        if (self.offset == 0 and b == 'Z') {
                            try writer.writeByte('Z');
                            continue;
                        }
                        const hours = absHoursFromSeconds(self.offset);
                        const minutes = absMinutesFromSeconds(self.offset);
                        const seconds = absSecondsFromSeconds(self.offset);
                        const sign: u8 = if (self.offset < 0) '-' else '+';
                        try writer.print("{c}{d:0>2}{d:0>2}{d:0>2}", .{ sign, hours, minutes, seconds });
                    } else if (std.mem.startsWith(u8, fmt[i + 1 ..], "07:00:00")) {
                        i += 8;
                        if (self.offset == 0 and b == 'Z') {
                            try writer.writeByte('Z');
                            continue;
                        }
                        const hours = absHoursFromSeconds(self.offset);
                        const minutes = absMinutesFromSeconds(self.offset);
                        const seconds = absSecondsFromSeconds(self.offset);
                        const sign: u8 = if (self.offset < 0) '-' else '+';
                        try writer.print("{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, hours, minutes, seconds });
                    } else if (std.mem.startsWith(u8, fmt[i + 1 ..], "0700")) {
                        i += 4;
                        if (self.offset == 0 and b == 'Z') {
                            try writer.writeByte('Z');
                            continue;
                        }
                        const hours = absHoursFromSeconds(self.offset);
                        const minutes = absMinutesFromSeconds(self.offset);
                        const sign: u8 = if (self.offset < 0) '-' else '+';
                        try writer.print("{c}{d:0>2}{d:0>2}", .{ sign, hours, minutes });
                    } else if (std.mem.startsWith(u8, fmt[i + 1 ..], "07:00")) {
                        i += 5;
                        if (self.offset == 0 and b == 'Z') {
                            try writer.writeByte('Z');
                            continue;
                        }
                        const hours = absHoursFromSeconds(self.offset);
                        const minutes = absMinutesFromSeconds(self.offset);
                        const sign: u8 = if (self.offset < 0) '-' else '+';
                        try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, hours, minutes });
                    } else if (std.mem.startsWith(u8, fmt[i + 1 ..], "07")) {
                        i += 2;
                        if (self.offset == 0 and b == 'Z') {
                            try writer.writeByte('Z');
                            continue;
                        }
                        const hours = absHoursFromSeconds(self.offset);
                        const sign: u8 = if (self.offset < 0) '-' else '+';
                        try writer.print("{c}{d:0>2}", .{ sign, hours });
                    } else try writer.writeByte(b);
                },
                '.', ',' => { // ,000, or .000, or ,999, or .999 - repeated digits for fractional seconds.
                    try writer.writeByte(b);

                    if (i == fmt.len - 1) continue;

                    const c = fmt[i + 1];
                    switch (c) {
                        '0' => {
                            var n: usize = 0;
                            const j: usize = i + 1;
                            while (j + n < fmt.len and fmt[j + n] == '0') : (n += 1) {}

                            // If we ended on a digit, it wasn't a 0. That means this was not a
                            // valid fractional second
                            if (j + n < fmt.len and std.ascii.isDigit(fmt[j + n])) continue;
                            i += n;

                            var buf: [9]u8 = undefined;
                            const str = try std.fmt.bufPrint(
                                &buf,
                                "{d:0>3}{d:0>3}{d:0>3}",
                                .{ self.millisecond, self.microsecond, self.nanosecond },
                            );
                            try writer.writeAll(str[0..@min(n, str.len)]);
                            if (n > str.len)
                                try writer.splatBytesAll("0", n - str.len);
                        },
                        '9' => {
                            var n: usize = 0;
                            const j: usize = i + 1;
                            while (j + n < fmt.len and fmt[j + n] == '9') : (n += 1) {}

                            // If we ended on a digit, it wasn't a 0. That means this was not a
                            // valid fractional second
                            if (j + n < fmt.len and std.ascii.isDigit(fmt[j + n])) continue;
                            i += n;

                            var buf: [9]u8 = undefined;
                            const str = try std.fmt.bufPrint(
                                &buf,
                                "{d:0>3}{d:0>3}{d:0>3}",
                                .{ self.millisecond, self.microsecond, self.nanosecond },
                            );

                            var iter = std.mem.reverseIterator(str[0..@min(n, str.len)]);
                            var last_non_zero = @min(n, str.len);
                            while (iter.next()) |d| {
                                if (d != '0') break;
                                last_non_zero -= 1;
                            }
                            try writer.writeAll(str[0..last_non_zero]);
                        },
                        else => continue,
                    }
                },
                'N' => {
                    if (std.mem.startsWith(u8, fmt[i..], "ND")) {
                        i += 1;
                        switch (self.day) {
                            0, 4...20, 24...30 => try writer.writeAll("TH"),
                            1, 21, 31 => try writer.writeAll("ST"),
                            2, 22 => try writer.writeAll("ND"),
                            3, 23 => try writer.writeAll("RD"),
                        }
                    } else try writer.writeByte(b);
                },
                'n' => {
                    if (std.mem.startsWith(u8, fmt[i..], "nd")) {
                        i += 1;
                        switch (self.day) {
                            0, 4...20, 24...30 => try writer.writeAll("th"),
                            1, 21, 31 => try writer.writeAll("st"),
                            2, 22 => try writer.writeAll("nd"),
                            3, 23 => try writer.writeAll("rd"),
                        }
                    } else try writer.writeByte(b);
                },
                else => try writer.writeByte(b),
            }
        }
    }

    fn absHoursFromSeconds(seconds: Seconds) u32 {
        if (seconds < 0)
            return @intCast(@divTrunc(-seconds, 60 * 60))
        else
            return @intCast(@divTrunc(seconds, 60 * 60));
    }

    fn absMinutesFromSeconds(seconds: Seconds) u32 {
        const hours = absHoursFromSeconds(seconds);
        if (seconds < 0)
            return @intCast(@divTrunc((-seconds) - hours * 3600, 60))
        else
            return @intCast(@divTrunc(seconds - hours * 3600, 60));
    }

    fn absSecondsFromSeconds(seconds: Seconds) u32 {
        const hours = absHoursFromSeconds(seconds);
        const minutes = absMinutesFromSeconds(seconds);
        if (seconds < 0)
            return @intCast(@divTrunc((-seconds) - hours * 3600 - minutes * 60, 1))
        else
            return @intCast(@divTrunc(seconds - hours * 3600 - minutes * 60, 1));
    }

    pub fn compare(self: Time, time: Time) TimeComparison {
        const self_ts = self.timestamp();
        const time_ts = time.timestamp();

        if (self_ts > time_ts) {
            return .after;
        } else if (self_ts < time_ts) {
            return .before;
        } else {
            return .equal;
        }
    }

    pub fn after(self: Time, time: Time) bool {
        return self.timestamp() > time.timestamp();
    }

    pub fn before(self: Time, time: Time) bool {
        return self.timestamp() < time.timestamp();
    }

    pub fn eql(self: Time, time: Time) bool {
        return self.timestamp() == time.timestamp();
    }
};

/// Returns the number of days since the Unix epoch. timestamp should be the number of seconds from
/// the Unix epoch
pub fn daysSinceEpoch(timestamp: Seconds) Days {
    return @divFloor(timestamp, s_per_day);
}

test "days since epoch" {
    try std.testing.expectEqual(0, daysSinceEpoch(0));
    try std.testing.expectEqual(0, daysSinceEpoch(1));
    try std.testing.expectEqual(-1, daysSinceEpoch(-1));
    try std.testing.expectEqual(-2, daysSinceEpoch(-(s_per_day + 1)));
    try std.testing.expectEqual(1, daysSinceEpoch(s_per_day + 1));
    try std.testing.expectEqual(19797, daysSinceEpoch(1710523947));
}

pub fn isLeapYear(year: i32) bool {
    // Neri/Schneider algorithm
    const d: i32 = if (@mod(year, 100) != 0) 4 else 16;
    return (year & (d - 1)) == 0;
}

/// returns the weekday given a number of days since the unix epoch
/// https://howardhinnant.github.io/date_algorithms.html#weekday_from_days
pub fn weekdayFromDays(days: Days) Weekday {
    if (days >= -4)
        return @enumFromInt(@mod((days + 4), 7))
    else
        return @enumFromInt(@mod((days + 5), 7) + 6);
}

test "weekdayFromDays" {
    try std.testing.expectEqual(.thu, weekdayFromDays(0));
}

/// return the civil date from the number of days since the epoch
/// This is an implementation of Howard Hinnant's algorithm
/// https://howardhinnant.github.io/date_algorithms.html#civil_from_days
pub fn civilFromDays(days: Days) Date {
    // shift epoch from 1970-01-01 to 0000-03-01
    const z = days + 719468;

    // Compute era
    const era = if (z >= 0)
        @divFloor(z, days_per_era)
    else
        @divFloor(z - days_per_era - 1, days_per_era);

    const doe: u32 = @intCast(z - era * days_per_era); // [0, days_per_era-1]
    const yoe: u32 = @intCast(
        @divFloor(
            doe -
                @divFloor(doe, 1460) +
                @divFloor(doe, 36524) -
                @divFloor(doe, 146096),
            365,
        ),
    ); // [0, 399]
    const y: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @enumFromInt(m),
        .day = @truncate(d),
    };
}
/// return the number of days since the epoch from the civil date
pub fn daysFromCivil(date: Date) Days {
    const m = @intFromEnum(date.month);
    const y = if (m <= 2) date.year - 1 else date.year;
    const era = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const doy = blk: {
        const a: u32 = if (m > 2) m - 3 else m + 9;
        const b = a * 153 + 2;
        break :blk @divFloor(b, 5) + date.day - 1;
    };
    const doe: i32 = @intCast(yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy);
    return era * days_per_era + doe - 719468;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("timezone.zig");
}

test "fmtStrftime" {
    var buf: [128]u8 = undefined;
    const epoch = try instant(.{ .source = .{ .unix_timestamp = 0 } });
    const time = epoch.time();

    var writer = std.Io.Writer.fixed(&buf);

    try std.testing.expectError(error.InvalidFormat, time.strftime(&writer, "no trailing lone percent %"));

    writer.end = 0;
    try time.strftime(&writer, "%%");
    try std.testing.expectEqualStrings("%", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%a %A %b %B %c %C");
    try std.testing.expectEqualStrings("Thu Thursday Jan January Thu Jan  1 00:00:00 1970 19", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%d %D %e %F %h");
    try std.testing.expectEqualStrings("01 01/01/70  1 1970-01-01 Jan", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%H %I %j %k %l %m %M");
    try std.testing.expectEqualStrings("00 12 001 0 12 01 00", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%p %P %r %R %s %S");
    try std.testing.expectEqualStrings("AM am 12:00:00 AM 00:00 0 00", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%T %u");
    try std.testing.expectEqualStrings("00:00:00 4", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%U");
    try std.testing.expectEqualStrings("00", writer.buffered());

    writer.end = 0;
    const d2 = (try time.instant().add(.{ .days = 3 })).time();
    try d2.strftime(&writer, "%U");
    try std.testing.expectEqualStrings("01", writer.buffered());

    writer.end = 0;
    try time.strftime(&writer, "%w %W %x %X %y %Y %z %Z");
    try std.testing.expectEqualStrings("4 00 01/01/70 00:00:00 70 1970 +0000 UTC", writer.buffered());

    writer.end = 0;
    var d3 = time;
    d3.offset = -3600;
    try d3.strftime(&writer, "%z");
    try std.testing.expectEqualStrings("-0100", writer.buffered());
}

test "gofmt" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const time: Time = .{
        .year = 1970,
        .month = .feb,
        .day = 3,
        .hour = 1,
        .minute = 2,
        .second = 3,
        .millisecond = 4,
        .designation = "UTC",
    };

    writer.end = 0;
    try time.gofmt(&writer, "2006-01-02T15:04:05.999999999Z07:00");
    try std.testing.expectEqualStrings("1970-02-03T01:02:03.004Z", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "Jan January J 01 02 03 04 05 06 002 Jan");
    try std.testing.expectEqualStrings("Feb February J 02 03 01 02 03 70 034 Feb", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "Mon Monday MST M 1 15 2 2006 _2 __2 Mon");
    try std.testing.expectEqualStrings("Tue Tuesday UTC M 2 01 3 1970  3  34 Tue", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "3 4 5");
    try std.testing.expectEqualStrings("1 2 3", writer.buffered());

    const time2: Time = .{
        .offset = 3661, // 1 hour, 1 minute, 1 second
        .millisecond = 123,
        .microsecond = 456,
        .nanosecond = 789,
    };

    writer.end = 0;
    try time2.gofmt(&writer, "-070000 -07:00:00 -0700 -07:00 -07 -00");
    try std.testing.expectEqualStrings("+010101 +01:01:01 +0101 +01:01 +01 -00", writer.buffered());

    writer.end = 0;
    try time2.gofmt(&writer, "Z070000 Z07:00:00 Z0700 Z07:00 Z07 Z00");
    try std.testing.expectEqualStrings("+010101 +01:01:01 +0101 +01:01 +01 Z00", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "Z070000 Z07:00:00 Z0700 Z07:00 Z07 Z00");
    try std.testing.expectEqualStrings("Z Z Z Z Z Z00", writer.buffered());

    writer.end = 0;
    try time2.gofmt(&writer, "frac .");
    try std.testing.expectEqualStrings("frac .", writer.buffered());

    writer.end = 0;
    try time2.gofmt(&writer, "frac .000000000");
    try std.testing.expectEqualStrings("frac .123456789", writer.buffered());

    writer.end = 0;
    try time2.gofmt(&writer, "frac .999999999");
    try std.testing.expectEqualStrings("frac .123456789", writer.buffered());

    writer.end = 0;
    try time2.gofmt(&writer, "frac .000000000000");
    try std.testing.expectEqualStrings("frac .123456789000", writer.buffered());

    writer.end = 0;
    try time2.gofmt(&writer, "frac .0000000");
    try std.testing.expectEqualStrings("frac .1234567", writer.buffered());

    const time3: Time = .{
        .offset = 3661, // 1 hour, 1 minute, 1 second
        .millisecond = 123,
        .microsecond = 456,
    };

    writer.end = 0;
    try time3.gofmt(&writer, "frac .999999999");
    try std.testing.expectEqualStrings("frac .123456", writer.buffered());
}

test Instant {
    const zeit = @This();

    const alloc = std.testing.allocator;
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    var threaded = std.Io.Threaded.init(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    // Get an instant in time. The default gets "now" in UTC
    const now = try instant(.{ .io = io });

    // Load our local timezone. This needs an allocator. Optionally pass in a
    // *const std.process.EnvMap to support TZ and TZDIR environment variables
    const local_tz = try zeit.local(alloc, io, &env);
    defer local_tz.deinit();

    // Convert our instant to a new timezone
    const now_local = now.in(&local_tz);

    // Generate date/time info for this instant
    const dt = now_local.time();

    // Print it out
    std.log.info("{}", .{dt});

    // zeit.Time{
    //    .year = 2024,
    //    .month = zeit.Month.mar,
    //    .day = 16,
    //    .hour = 8,
    //    .minute = 38,
    //    .second = 29,
    //    .millisecond = 496,
    //    .microsecond = 706,
    //    .nanosecond = 64
    //    .offset = -18000,
    // }

    var buf: [256]u8 = undefined;
    var anywriter = std.Io.Writer.fixed(&buf);
    // Format using strftime specifier. Format strings are not required to be comptime
    try dt.strftime(&anywriter, "%Y-%m-%d %H:%M:%S %Z");

    // Or...golang magic date specifiers. Format strings are not required to be comptime
    anywriter.end = 0;
    try dt.gofmt(&anywriter, "2006-01-02 15:04:05 MST");

    // Load an arbitrary location using IANA location syntax. The location name
    // comes from an enum which will automatically map IANA location names to
    // Windows names, as needed. Pass an optional EnvMap to support TZDIR
    const vienna = try zeit.loadTimeZone(alloc, io, .@"Europe/Vienna", &env);
    defer vienna.deinit();

    // Parse an Instant from an ISO8601 or RFC3339 string
    _ = try zeit.instant(.{
        .source = .{
            .iso8601 = "2024-03-16T08:38:29.496-1200",
        },
    });

    _ = try zeit.instant(.{
        .source = .{
            .rfc3339 = "2024-03-16T08:38:29.496706064-1200",
        },
    });
}

test "github.com/rockorager/zeit/issues/15" {
    // https://github.com/rockorager/zeit/issues/15
    const timestamp = 1732838300;
    const allocator = std.testing.allocator;
    const tz = try loadTimeZone(allocator, std.testing.io, .@"Europe/Berlin", null);
    defer tz.deinit();
    const inst = try instant(.{ .source = .{ .unix_timestamp = timestamp }, .timezone = &tz });
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const time = inst.time();

    try std.testing.expectEqual(timestamp, time.instant().unixTimestamp());

    try std.testing.expectEqual(2024, time.year);
    try std.testing.expectEqual(Month.nov, time.month);
    try std.testing.expectEqual(29, time.day);
    try std.testing.expectEqual(0, time.hour);
    try std.testing.expectEqual(58, time.minute);
    try std.testing.expectEqual(20, time.second);

    try time.strftime(&writer, "%a %A %u");
    try std.testing.expectEqualStrings("Fri Friday 5", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "Mon Monday");
    try std.testing.expectEqualStrings("Fri Friday", writer.buffered());
}

test "github.com/rockorager/zeit/issues/27" {
    // April 23, 2025
    const timestamp = 1745414170;
    const inst = try instant(.{ .source = .{ .unix_timestamp = timestamp } });
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const time = inst.time();

    try time.gofmt(&writer, "02.01.2006");
    try std.testing.expectEqualStrings("23.04.2025", writer.buffered());
}

test "github.com/rockorager/zeit/issues/24" {
    // April 23, 2025
    const timestamp = 1745414170;
    const inst = try instant(.{ .source = .{ .unix_timestamp = timestamp } });
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const time = inst.time();

    try time.gofmt(&writer, "3pm MST");
    try std.testing.expectEqualStrings("1pm UTC", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "3p MST");
    try std.testing.expectEqualStrings("1p UTC", writer.buffered());
}

test "github.com/rockorager/zeit/issues/26" {
    // April 23, 2025
    const timestamp = 1745414170;
    const inst = try instant(.{ .source = .{ .unix_timestamp = timestamp } });
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const time = inst.time();

    try time.gofmt(&writer, "02nd");
    try std.testing.expectEqualStrings("23rd", writer.buffered());

    writer.end = 0;
    try time.gofmt(&writer, "02ND");
    try std.testing.expectEqualStrings("23RD", writer.buffered());
}

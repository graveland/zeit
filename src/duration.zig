const std = @import("std");
const constants = @import("constants.zig");
const linux = std.os.linux;

const ns_per_us = std.time.ns_per_us;
const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;
const ns_per_min = std.time.ns_per_min;
const ns_per_hour = std.time.ns_per_hour;
const ns_per_day = std.time.ns_per_day;

pub const Duration = struct {
    days: usize = 0,
    hours: usize = 0,
    minutes: usize = 0,
    seconds: usize = 0,
    milliseconds: usize = 0,
    microseconds: usize = 0,
    nanoseconds: usize = 0,

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

    /// Convert duration to specified unit as u64 (common case).
    /// Usage: duration.in(.seconds)
    pub fn in(self: Duration, comptime unit: constants.Unit) error{Overflow}!u64 {
        const ns = try self.inNanoseconds();
        return ns / unit.toNanoseconds();
    }

    /// Convert duration to specified unit with custom return type.
    /// Supports both integer and floating-point types.
    /// Usage: duration.inAs(f64, .seconds) or duration.inAs(u32, .millis)
    pub fn inAs(self: Duration, comptime T: type, comptime unit: constants.Unit) error{Overflow}!T {
        const ns = try self.inNanoseconds();
        const divisor = unit.toNanoseconds();
        return switch (@typeInfo(T)) {
            .float => @as(T, @floatFromInt(ns)) / @as(T, @floatFromInt(divisor)),
            .int => @intCast(ns / divisor),
            else => @compileError("Duration.inAs requires int or float type"),
        };
    }

    /// Convert duration to linux.timespec for use with nanosleep.
    /// Only available on Linux platforms.
    pub fn toTimespec(self: Duration) !linux.timespec {
        const ns = try self.inNanoseconds();
        return linux.timespec{
            .sec = @intCast(@divFloor(ns, ns_per_s)),
            .nsec = @intCast(@mod(ns, ns_per_s)),
        };
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

    /// Create Duration from value and unit.
    /// Usage: Duration.from(15, .seconds) or Duration.from(1.5, .hours)
    pub fn from(value: anytype, comptime unit: constants.Unit) Duration {
        const T = @TypeOf(value);
        const multiplier = unit.toNanoseconds();

        const ns: i128 = switch (@typeInfo(T)) {
            .float, .comptime_float => @intFromFloat(value * @as(f64, @floatFromInt(multiplier))),
            .int, .comptime_int => @as(i128, value) * @as(i128, multiplier),
            else => @compileError("Duration.from requires int or float value"),
        };

        return fromNanoseconds(ns);
    }

    /// Create a Duration from a time unit
    pub fn fromUnit(unit: constants.Unit) Duration {
        return switch (unit) {
            .nanos => .{ .nanoseconds = 1 },
            .micros => .{ .microseconds = 1 },
            .millis => .{ .milliseconds = 1 },
            .seconds => .{ .seconds = 1 },
            .minutes => .{ .minutes = 1 },
            .hours => .{ .hours = 1 },
            .days => .{ .days = 1 },
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
    pub fn roundTo(self: Duration, unit: constants.Unit) error{Overflow}!Duration {
        return self.round(Duration.fromUnit(unit));
    }

    /// Truncate to a standard unit.
    /// Example: Duration.parse("1h23m45s").truncateTo(.minute) returns "1h23m"
    pub fn truncateTo(self: Duration, unit: constants.Unit) error{Overflow}!Duration {
        return self.truncate(Duration.fromUnit(unit));
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
            const rounded = try d.roundTo(.hours);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }
        {
            const d = try Duration.parse("1h45m");
            const rounded = try d.roundTo(.hours);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("2h", s);
        }

        // Round to nearest minute
        {
            const d = try Duration.parse("1h23m45s");
            const rounded = try d.roundTo(.minutes);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h24m", s);
        }
        {
            const d = try Duration.parse("1h23m29s");
            const rounded = try d.roundTo(.minutes);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h23m", s);
        }

        // Round to nearest second
        {
            const d = Duration{ .seconds = 5, .milliseconds = 600 };
            const rounded = try d.roundTo(.seconds);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("6s", s);
        }

        // Round to nearest millisecond
        {
            const d = Duration{ .milliseconds = 5, .microseconds = 600 };
            const rounded = try d.roundTo(.millis);
            const s = try rounded.bufPrint(&buf);
            try std.testing.expectEqualStrings("6ms", s);
        }
    }

    test "truncateTo with unit enum" {
        var buf: [64]u8 = undefined;

        // Truncate to hours
        {
            const d = try Duration.parse("1h59m59s");
            const truncated = try d.truncateTo(.hours);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h", s);
        }

        // Truncate to minutes
        {
            const d = try Duration.parse("1h23m59s");
            const truncated = try d.truncateTo(.minutes);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("1h23m", s);
        }

        // Truncate to seconds
        {
            const d = Duration{ .seconds = 5, .milliseconds = 999 };
            const truncated = try d.truncateTo(.seconds);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("5s", s);
        }

        // Truncate to milliseconds
        {
            const d = Duration{ .milliseconds = 5, .microseconds = 999 };
            const truncated = try d.truncateTo(.millis);
            const s = try truncated.bufPrint(&buf);
            try std.testing.expectEqualStrings("5ms", s);
        }
    }

    test "Duration.in conversions" {
        const d = Duration{ .seconds = 5 };
        try std.testing.expectEqual(5, try d.in(.seconds));
        try std.testing.expectEqual(5000, try d.in(.millis));
        try std.testing.expectEqual(5_000_000, try d.in(.micros));
        try std.testing.expectEqual(5_000_000_000, try d.in(.nanos));
    }

    test "Duration.inAs with float" {
        const d = Duration{ .seconds = 5, .milliseconds = 500 };
        const secs = try d.inAs(f64, .seconds);
        // f64 conversion loses some precision, so we need a wider tolerance
        try std.testing.expectApproxEqAbs(5.5, secs, 0.01);
    }

    test "Duration.inAs with integer" {
        const d = Duration{ .minutes = 2, .seconds = 30 };
        const secs_u64 = try d.inAs(u64, .seconds);
        try std.testing.expectEqual(150, secs_u64);

        const secs_u32 = try d.inAs(u32, .seconds);
        try std.testing.expectEqual(150, secs_u32);
    }

    test "Duration.from with integer" {
        const d1 = Duration.from(15, .seconds);
        try std.testing.expectEqual(15, d1.seconds);
        try std.testing.expectEqual(0, d1.minutes);

        const d2 = Duration.from(90, .seconds);
        try std.testing.expectEqual(30, d2.seconds);
        try std.testing.expectEqual(1, d2.minutes);
    }

    test "Duration.from with float" {
        const d1 = Duration.from(1.5, .hours);
        try std.testing.expectEqual(1, d1.hours);
        try std.testing.expectEqual(30, d1.minutes);

        const d2 = Duration.from(2.5, .seconds);
        try std.testing.expectEqual(2, d2.seconds);
        try std.testing.expectEqual(500, d2.milliseconds);
    }

    test "Duration.toTimespec" {
        // Test simple second conversion
        {
            const d = Duration{ .seconds = 5 };
            const ts = try d.toTimespec();
            try std.testing.expectEqual(5, ts.sec);
            try std.testing.expectEqual(0, ts.nsec);
        }

        // Test with nanoseconds
        {
            const d = Duration{ .seconds = 3, .nanoseconds = 500_000_000 };
            const ts = try d.toTimespec();
            try std.testing.expectEqual(3, ts.sec);
            try std.testing.expectEqual(500_000_000, ts.nsec);
        }

        // Test with multiple units
        {
            const d = Duration{ .minutes = 1, .seconds = 30, .milliseconds = 250 };
            const ts = try d.toTimespec();
            try std.testing.expectEqual(90, ts.sec);
            try std.testing.expectEqual(250_000_000, ts.nsec);
        }

        // Test with larger durations
        {
            const d = Duration{ .hours = 1 };
            const ts = try d.toTimespec();
            try std.testing.expectEqual(3600, ts.sec);
            try std.testing.expectEqual(0, ts.nsec);
        }

        // Test zero duration
        {
            const d = Duration{};
            const ts = try d.toTimespec();
            try std.testing.expectEqual(0, ts.sec);
            try std.testing.expectEqual(0, ts.nsec);
        }
    }
};

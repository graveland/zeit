const std = @import("std");
const constants = @import("constants.zig");
const Duration = @import("duration.zig").Duration;

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
    /// Supports both integer and floating-point return types.
    /// Usage: timer.elapsedAs(u64, .micros) or timer.elapsedAs(f64, .millis)
    pub fn elapsedAs(self: Timer, comptime T: type, comptime unit: constants.Unit) T {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake) catch return 0;
        const elapsed_ns = now.raw.nanoseconds - self.start_ns;
        const divisor: i128 = unit.toNanoseconds();
        const value = @divFloor(elapsed_ns, divisor);
        return switch (@typeInfo(T)) {
            .float => @floatFromInt(value),
            .int => @intCast(value),
            else => @compileError("Timer.elapsedAs requires int or float type"),
        };
    }

    /// Get elapsed time as u64 in specified unit (common case).
    /// Usage: timer.elapsed(.millis)
    pub fn elapsed(self: Timer, comptime unit: constants.Unit) u64 {
        return self.elapsedAs(u64, unit);
    }

    /// Get elapsed time as a Duration.
    /// Usage: const dur = timer.elapsedDuration();
    pub fn elapsedDuration(self: Timer) Duration {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake) catch return Duration{};
        const elapsed_ns = now.raw.nanoseconds - self.start_ns;
        return Duration.fromNanoseconds(elapsed_ns);
    }

    /// Reset the timer to now
    pub fn reset(self: *Timer) void {
        const ts = std.Io.Clock.Timestamp.now(self.io, .awake) catch return;
        self.start_ns = ts.raw.nanoseconds;
    }

    test "Timer.elapsed simple API" {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        const timer = Timer.start(io);
        const elapsed_ns = timer.elapsed(.nanos);
        try std.testing.expect(elapsed_ns >= 0);
    }

    test "Timer.elapsedAs with different types" {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        const timer = Timer.start(io);

        // Test u64
        const elapsed_u64 = timer.elapsedAs(u64, .micros);
        try std.testing.expect(elapsed_u64 >= 0);

        // Test f64
        const elapsed_f64 = timer.elapsedAs(f64, .millis);
        try std.testing.expect(elapsed_f64 >= 0.0);
    }

    test "Timer.elapsedDuration" {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        const timer = Timer.start(io);
        const dur = timer.elapsedDuration();
        try std.testing.expect((try dur.inNanoseconds()) >= 0);
    }
};

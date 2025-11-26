const std = @import("std");
const constants = @import("constants.zig");

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
    pub fn elapsed(self: Timer, comptime T: type, comptime unit: constants.Unit) T {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake) catch return 0;
        const elapsed_ns = now.raw.nanoseconds - self.start_ns;
        const divisor: i128 = unit.toNanoseconds();
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
};

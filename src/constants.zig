const std = @import("std");
const timezone = @import("timezone.zig");

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

/// Time unit enum with plural abbreviations
/// Used by Timer and Duration for specifying time units
pub const Unit = enum {
    nanos,
    micros,
    millis,
    seconds,
    minutes,
    hours,
    days,

    /// Convert unit to nanoseconds
    pub fn toNanoseconds(self: Unit) u64 {
        return switch (self) {
            .nanos => 1,
            .micros => ns_per_us,
            .millis => ns_per_ms,
            .seconds => ns_per_s,
            .minutes => ns_per_min,
            .hours => ns_per_hour,
            .days => ns_per_day,
        };
    }
};

pub const utc: timezone.TimeZone = .{ .fixed = .{
    .name = "UTC",
    .offset = 0,
    .is_dst = false,
} };

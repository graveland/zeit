const std = @import("std");
const builtin = @import("builtin");
const location = @import("location.zig");
const build_options = @import("build_options");

pub const version = build_options.version;

// Module imports
pub const timezone = @import("timezone.zig");
pub const constants_mod = @import("constants.zig");
pub const timer_mod = @import("timer.zig");
pub const duration_mod = @import("duration.zig");
pub const calendar_mod = @import("calendar.zig");
pub const datetime_mod = @import("datetime.zig");

// Re-export types from timezone and location
pub const TimeZone = timezone.TimeZone;
pub const Location = location.Location;

// Re-export type aliases from constants
pub const Days = constants_mod.Days;
pub const Nanoseconds = constants_mod.Nanoseconds;
pub const Milliseconds = constants_mod.Milliseconds;
pub const Seconds = constants_mod.Seconds;
pub const Unit = constants_mod.Unit;

// Re-export constants
pub const utc = &constants_mod.utc;

// Re-export Timer
pub const Timer = timer_mod.Timer;

// Re-export Duration
pub const Duration = duration_mod.Duration;

// Re-export calendar types
pub const Month = calendar_mod.Month;
pub const Weekday = calendar_mod.Weekday;
pub const Date = calendar_mod.Date;
pub const TimeComparison = calendar_mod.TimeComparison;

// Re-export calendar utility functions
pub const daysSinceEpoch = calendar_mod.daysSinceEpoch;
pub const isLeapYear = calendar_mod.isLeapYear;
pub const weekdayFromDays = calendar_mod.weekdayFromDays;
pub const civilFromDays = calendar_mod.civilFromDays;
pub const daysFromCivil = calendar_mod.daysFromCivil;

// Re-export datetime types
pub const Instant = datetime_mod.Instant;
pub const Time = datetime_mod.Time;

// Re-export instant factory function
pub const instant = datetime_mod.instant;

const assert = std.debug.assert;

pub fn local(alloc: std.mem.Allocator, io: std.Io, maybe_env: ?*const std.process.Environ.Map) !TimeZone {
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

            const f = std.Io.Dir.openFileAbsolute(io, "/etc/localtime", .{}) catch return utc.*;
            defer f.close(io);
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
    env: *const std.process.Environ.Map,
) !TimeZone {
    assert(tz.len != 0); // TZ is empty string

    // Return early we we are a posix TZ string
    if (tz[0] != ':') return .{ .posix = try timezone.Posix.parse(tz) };

    assert(tz.len > 1); // TZ not long enough
    if (tz[1] == '/') {
        const f = std.Io.Dir.openFileAbsolute(io, tz[1..], .{}) catch return error.FileNotFound;
        defer f.close(io);
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
    maybe_env: ?*const std.process.Environ.Map,
) !TimeZone {
    switch (builtin.os.tag) {
        .windows => {
            const tz = try timezone.Windows.loadFromName(alloc, loc.asText());
            return .{ .windows = tz };
        },
        else => {},
    }

    var dir: std.Io.Dir = blk: {
        // If we have an env and a TZDIR, use that
        if (maybe_env) |env| {
            if (env.get("TZDIR")) |tzdir| {
                const d = std.Io.Dir.openDirAbsolute(io, tzdir, .{}) catch return error.FileNotFound;
                break :blk d;
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
            const d = std.Io.Dir.openDirAbsolute(io, zone_dir, .{}) catch continue;
            break :blk d;
        } else return error.FileNotFound;
    };

    defer dir.close(io);
    const f = try dir.openFile(io, loc.asText(), .{});
    defer f.close(io);
    var io_buffer: [2048]u8 = undefined;
    var reader = f.reader(io, &io_buffer);
    return .{ .tzinfo = try timezone.TZInfo.parse(alloc, &reader.interface) };
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
    const io = std.testing.io;

    // Get an instant in time. The default gets "now" in UTC
    const now = try instant(.{ .io = io });

    // Load our local timezone. This needs an allocator. Optionally pass in a
    // *const std.process.Environ.Map to support TZ and TZDIR environment variables
    const local_tz = try zeit.local(alloc, io, null);
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
    const vienna = try zeit.loadTimeZone(alloc, io, .@"Europe/Vienna", null);
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

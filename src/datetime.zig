const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const calendar = @import("calendar.zig");
const timezone_mod = @import("timezone.zig");
const location = @import("location.zig");
const duration_mod = @import("duration.zig");

pub const TimeZone = timezone_mod.TimeZone;
pub const Duration = duration_mod.Duration;
pub const Month = calendar.Month;
pub const Date = calendar.Date;
pub const TimeComparison = calendar.TimeComparison;
pub const Weekday = calendar.Weekday;

const assert = std.debug.assert;

const Nanoseconds = constants.Nanoseconds;
const Milliseconds = constants.Milliseconds;
const Seconds = constants.Seconds;
const Days = constants.Days;

const utc = &constants.utc;

const ns_per_us = std.time.ns_per_us;
const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;
const ns_per_min = std.time.ns_per_min;
const ns_per_hour = std.time.ns_per_hour;
const ns_per_day = std.time.ns_per_day;
const s_per_min = std.time.s_per_min;
const s_per_hour = std.time.s_per_hour;
const s_per_day = std.time.s_per_day;

const daysSinceEpoch = calendar.daysSinceEpoch;
const civilFromDays = calendar.civilFromDays;
const daysFromCivil = calendar.daysFromCivil;
const weekdayFromDays = calendar.weekdayFromDays;

pub const Instant = struct {
    /// the instant of time, in nanoseconds
    timestamp: Nanoseconds = 0,
    /// every instant occurs in a timezone. This is the timezone
    timezone: *const TimeZone,

    pub const Config = struct {
        source: Source = .now,
        timezone: *const TimeZone = utc,
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
            const now = std.Io.Clock.Timestamp.now(io, .real);
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
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const original = Instant{
        .timestamp = now.raw.nanoseconds,
        .timezone = utc,
    };
    const time = original.time();
    const round_trip = time.instant();
    try std.testing.expectEqual(original.timestamp, round_trip.timestamp);
}
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
            .timezone = utc,
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
                    if (b == '.') {
                        // Minute fraction (e.g., "12:30.5" = 12:30:30)
                        i += 1;
                        const frac_end = std.mem.indexOfAnyPos(u8, iso, i, "Z+-") orelse iso.len;
                        const rhs = try parseInt(u64, iso[i..frac_end], 10);
                        const sigs = frac_end - i;
                        // Convert minute fraction to seconds and sub-second units
                        // 0.5 minutes = 30 seconds, stored as nanoseconds first
                        const pow = std.math.pow(u64, 10, @as(u64, @intCast(9 - sigs)));
                        const nanos_in_minute = rhs * pow; // fractional minute in nanoseconds (scaled to 1 minute = 10^9)
                        // Convert to actual nanoseconds: nanos_in_minute represents fraction of minute
                        // So multiply by 60 to get nanoseconds worth of seconds
                        const total_nanos = (nanos_in_minute * 60);
                        const total_seconds = @divFloor(total_nanos, ns_per_s);
                        time.second = @intCast(@min(total_seconds, 59));
                        var remaining_nanos = total_nanos - (total_seconds * ns_per_s);
                        time.millisecond = @intCast(@divFloor(remaining_nanos, ns_per_ms));
                        remaining_nanos -= @as(u64, time.millisecond) * ns_per_ms;
                        time.microsecond = @intCast(@divFloor(remaining_nanos, ns_per_us));
                        remaining_nanos -= @as(u64, time.microsecond) * ns_per_us;
                        time.nanosecond = @intCast(remaining_nanos);
                        i = frac_end;
                        // Skip to offset handling (no seconds field after minute fraction)
                        state = .second_fraction_or_offset;
                        continue;
                    }
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
            // Minute fraction: 12:30.5 = 12:30:30
            const m_frac = try Time.fromISO8601("2000-02-12T12:30.5Z");
            try std.testing.expectEqual(12, m_frac.hour);
            try std.testing.expectEqual(30, m_frac.minute);
            try std.testing.expectEqual(30, m_frac.second);
            try std.testing.expectEqual(0, m_frac.millisecond);
        }
        {
            // Minute fraction with offset: 12:30.25 = 12:30:15
            const m_frac_off = try Time.fromISO8601("2000-02-12T12:30.25+01:00");
            try std.testing.expectEqual(30, m_frac_off.minute);
            try std.testing.expectEqual(15, m_frac_off.second);
            try std.testing.expectEqual(s_per_hour, m_frac_off.offset);
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

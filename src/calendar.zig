const std = @import("std");
const constants = @import("constants.zig");

const Days = constants.Days;
const Seconds = constants.Seconds;

const s_per_day = std.time.s_per_day;
const days_per_era = 365 * 400 + 97;

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

pub const TimeComparison = enum(u2) {
    after,
    before,
    equal,
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

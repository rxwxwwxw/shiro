// The campaign clock: weeks of seven days, each day six slots (dawn to night). Important actions
// spend slots; talking and shopping are free unless a scene says otherwise. Headless Model,
// integer only.
module campaign.calendar;

enum Day : ubyte {
    mon,
    tue,
    wed,
    thu,
    fri,
    sat,
    sun
}

enum Slot : ubyte {
    dawn,
    morning,
    midday,
    afternoon,
    evening,
    night
}

enum int daysPerWeek = 7, slotsPerDay = 6, slotsPerWeek = daysPerWeek * slotsPerDay;

immutable string[daysPerWeek] dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
immutable string[daysPerWeek] dayTitles = [
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
];
immutable string[slotsPerDay] slotNames = [
    "dawn", "morning", "midday", "afternoon", "evening", "night"
];
immutable string[slotsPerDay] slotTitles = [
    "Dawn", "Morning", "Midday", "Afternoon", "Evening", "Night"
];

/// Index of `name` in `names`, or -1.
int nameIndex(const(char)[] name, const(string)[] names) @nogc nothrow pure @safe {
    foreach (i, n; names)
        if (n == name)
            return cast(int)i;
    return -1;
}

struct Calendar {
    /// 1-based.
    int week = 1;
    Day day;
    Slot slot;

    /// Slots since Monday dawn of week 1.
    int absolute() const @nogc nothrow pure @safe {
        return (week - 1) * slotsPerWeek + day * slotsPerDay + slot;
    }

    static Calendar at(int absolute) @nogc nothrow pure @safe {
        assert(absolute >= 0);
        Calendar c;
        c.week = absolute / slotsPerWeek + 1;
        c.day = cast(Day)(absolute % slotsPerWeek / slotsPerDay);
        c.slot = cast(Slot)(absolute % slotsPerDay);
        return c;
    }

    /// One slot later.
    Calendar next() const @nogc nothrow pure @safe {
        return at(absolute + 1);
    }

    /// Slots from now until (day, slot) this week, or -1 when it has passed.
    int until(Day d, Slot s) const @nogc nothrow pure @safe {
        immutable target = d * slotsPerDay + s, now = day * slotsPerDay + slot;
        return target >= now ? target - now : -1;
    }

    bool opEquals(const Calendar o) const @nogc nothrow pure @safe {
        return absolute == o.absolute;
    }
}

@nogc nothrow pure @safe unittest {
    Calendar c;
    assert(c.absolute == 0 && c.day == Day.mon && c.slot == Slot.dawn);
    foreach (i; 0 .. slotsPerWeek * 3)
        c = c.next();
    assert(c.week == 4 && c.day == Day.mon && c.slot == Slot.dawn);
    immutable sat = Calendar.at(Day.sat * slotsPerDay + Slot.afternoon);
    assert(sat.week == 1 && sat.day == Day.sat && sat.slot == Slot.afternoon);
    assert(Calendar.at(slotsPerWeek - 1).day == Day.sun && Calendar.at(slotsPerWeek - 1).slot == Slot.night);
    assert(Calendar.init.until(Day.wed, Slot.night) == 2 * slotsPerDay + 5);
    assert(sat.until(Day.wed, Slot.night) == -1 && sat.until(Day.sat, Slot.afternoon) == 0);
    assert(nameIndex("wed", dayNames[]) == Day.wed && nameIndex("noon", slotNames[]) == -1);
}

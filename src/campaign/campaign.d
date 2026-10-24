// The week loop. The game starts on Monday at dawn; important actions spend slots of the clock
// (`spend n` in a scene, or an action from the story's `data actions` table), minor ones are
// free. Each slot fires the story's `on slot` triggers (and `on day` at dawn), and the fixed beats
// come round: Wednesday night the director plans Saturday's attack, Saturday afternoon the battle
// must be fought before time moves on, Sunday is for the aftermath, and Monday starts the next
// week until the campaign's last week ends.
//
// The story sees the clock as `week` (1-based), `today` (:mon .. :sun) and `time` (:dawn ..
// :night). Headless Model: no SDL, @nogc nothrow.
module campaign.campaign;

import campaign.calendar;
import story.program;
import story.state;
import story.value;
import story.vm;

/// Story variables the clock writes.
enum string varWeek = "week", varToday = "today", varTime = "time";
/// Story data tables the campaign reads: `data campaign = {weeks: 6}` and
/// `data actions = {rest: 1, ...}` (slots each action costs).
enum string varCampaignData = "campaign", varActions = "actions";

/// Weeks a campaign lasts when the story does not say.
enum int defaultWeeks = 6;
/// When the beats fall.
enum Day directorDay = Day.wed, battleDay = Day.sat;
enum Slot directorSlot = Slot.night, battleSlot = Slot.afternoon;

/// Interns the clock's variables before compiling, so scripts may read them without warnings.
void internClockVars(ref StoryState st) @nogc nothrow @safe {
    foreach (n; [varWeek, varToday, varTime])
        st.intern(n);
}

struct Campaign {
    Calendar cal;
    int weeks = defaultWeeks;
    /// The last week has ended.
    bool over;
    /// Wednesday night came: the director should plan Saturday's attack (it clears this).
    bool directorDue;
    /// Saturday afternoon came: time stands still until `battleOver`.
    bool battleDue;
    private bool foughtThisWeek;
    private const(StoryProgram)* prog;
    private StoryState* st;
    private int[16] scenes;
    private int numScenes;
    /// Scenes dropped because too many triggers fired at once (a story bug).
    uint droppedScenes;

    /// Attaches to a compiled, initialized story (both must outlive the campaign) and reads its
    /// `campaign` table.
    void setup(const(StoryProgram)* p, StoryState* s) @nogc nothrow @trusted {
        prog = p;
        st = s;
        internClockVars(*st);
        immutable data = st.value(st.find(varCampaignData));
        int w;
        if (toIntExact(st.at(data, Value.constText("weeks")), w) && w > 0)
            weeks = w;
    }

    /// Monday dawn of week 1: publishes the clock and fires the first day's triggers.
    void begin() @nogc nothrow @trusted {
        cal = Calendar.init;
        over = directorDue = battleDue = foughtThisWeek = false;
        numScenes = 0;
        publish();
        fire();
    }

    /// Spends up to `n` slots; time stops at the battle while it is unfought and at the end of the
    /// campaign. Returns the slots that passed.
    int spend(int n) @nogc nothrow @trusted {
        int done = 0;
        while (done < n && !over && !battleDue && step())
            done++;
        return done;
    }

    /// Slots an action costs (`data actions`), or `fallback` when the story does not say.
    int actionCost(const(char)[] action, int fallback) const @nogc nothrow @trusted {
        int c;
        immutable table = st.value(st.find(varActions));
        immutable v = st.at(table, Value.constText(action));
        return !v.isNil && toIntExact(v, c) && c >= 0 ? c : fallback;
    }

    /// Spends the time an action costs; returns the slots that passed.
    int act(const(char)[] action, int fallback = 1) @nogc nothrow @trusted {
        return spend(actionCost(action, fallback));
    }

    /// Saturday's battle was fought (won or lost): time may move on.
    void battleOver() @nogc nothrow @safe {
        battleDue = false;
        foughtThisWeek = true;
    }

    /// Slots until this week's battle, or -1 once it has been fought.
    int slotsToBattle() const @nogc nothrow pure @safe {
        return foughtThisWeek ? -1 : cal.until(battleDay, battleSlot);
    }

    /// The next scene a trigger queued (scene code to run as a conversation), if any.
    bool popScene(out int entry) @nogc nothrow @safe {
        if (numScenes == 0)
            return false;
        entry = scenes[0];
        foreach (i; 1 .. numScenes)
            scenes[i - 1] = scenes[i];
        numScenes--;
        return true;
    }

    int pendingScenes() const @nogc nothrow pure @safe {
        return numScenes;
    }

    /// Moves the clock one slot; false (and over) when the campaign has run out of weeks.
    private bool step() @nogc nothrow @trusted {
        immutable next = cal.next();
        if (next.week > weeks) {
            over = true;
            return false;
        }
        cal = next;
        if (cal.day == Day.mon && cal.slot == Slot.dawn)
            foughtThisWeek = false;
        publish();
        if (cal.day == directorDay && cal.slot == directorSlot)
            directorDue = true;
        if (cal.day == battleDay && cal.slot == battleSlot && !foughtThisWeek)
            battleDue = true;
        fire();
        return true;
    }

    private void publish() @nogc nothrow @trusted {
        st.set(st.find(varWeek), cal.week);
        st.setValue(st.find(varToday), st.symbol(dayNames[cal.day]));
        st.setValue(st.find(varTime), st.symbol(slotNames[cal.slot]));
    }

    /// Queues the scenes of the day trigger (at dawn) and the slot trigger.
    private void fire() @nogc nothrow @trusted {
        int entry;
        if (cal.slot == Slot.dawn && trigger(*prog, TriggerKind.day, dayNames[cal.day], *st, entry) >= 0)
            queue(entry);
        if (trigger(*prog, TriggerKind.slot, slotNames[cal.slot], *st, entry) >= 0)
            queue(entry);
    }

    private void queue(int entry) @nogc nothrow @safe {
        if (entry < 0)
            return;
        if (numScenes == scenes.length) {
            droppedScenes++;
            return;
        }
        scenes[numScenes++] = entry;
    }

    /// Digest of the clock (determinism checks; the story state has its own).
    ulong hash() const @nogc nothrow pure @safe {
        ulong h = 0xCBF29CE484222325UL;
        foreach (v; [cal.absolute, weeks, over, directorDue, battleDue, foughtThisWeek, numScenes])
            h = (h ^ cast(ulong)v) * 0x100000001B3UL;
        return h;
    }
}

version (unittest) {
    import story.compile : compileText;

    private immutable clockStory = `
data campaign = {weeks: 2}
data actions = {rest: 1, dig: 2, chat: 0}
on day mon:
    : A new week. {week}
on slot night if today == :wed:
    : The village sleeps uneasily.
on day sat once:
    : Saturday. The drums start at dawn.
label nothing:
    spend 3
`;

    private void setupClock(ref StoryProgram p, ref StoryState st, ref Campaign c) @nogc nothrow @trusted {
        internClockVars(st);
        immutable err = compileText(p, st, clockStory);
        assert(err == StoryError.none);
        initialize(p, st);
        c.setup(&p, &st);
    }
}

@nogc nothrow @trusted unittest {
    // A two-week campaign: day and slot triggers queue scenes, Wednesday night asks for the
    // director, Saturday afternoon holds the clock until the battle is fought, and it ends after
    // week 2's Sunday night.
    StoryProgram p;
    StoryState st;
    Campaign c;
    setupClock(p, st, c);
    assert(c.weeks == 2);
    c.begin();
    assert(st.named(varWeek) == 1 && st.symbolName(st.value(st.find(varToday))) == "mon");
    int entry;
    assert(c.popScene(entry) && !c.popScene(entry));
    assert(c.actionCost("dig", 1) == 2 && c.actionCost("chat", 1) == 0 && c.actionCost("swim", 4) == 4);
    // Minor things cost nothing.
    assert(c.act("chat") == 0 && c.cal.absolute == 0);
    assert(c.spend(Day.wed * slotsPerDay + Slot.evening) == Day.wed * slotsPerDay + Slot.evening);
    assert(!c.directorDue);
    c.numScenes = 0;
    assert(c.act("rest") == 1 && c.directorDue && c.cal.day == Day.wed && c.cal.slot == Slot.night);
    assert(st.symbolName(st.value(st.find(varTime))) == "night" && c.pendingScenes == 1);
    c.directorDue = false;
    // The clock runs to Saturday afternoon and holds there.
    immutable toBattle = c.slotsToBattle;
    assert(toBattle > 0 && c.spend(100) == toBattle && c.battleDue);
    assert(c.cal.day == Day.sat && c.cal.slot == Slot.afternoon && c.spend(5) == 0);
    c.battleOver();
    assert(c.slotsToBattle == -1 && c.spend(1) == 1 && c.cal.slot == Slot.evening);
    // Into week 2: Monday's trigger fires again, Saturday's `once` does not.
    c.numScenes = 0;
    c.spend(Day.sun * slotsPerDay - Day.sat * slotsPerDay - Slot.evening + slotsPerDay + 1);
    assert(c.cal.week == 2 && c.cal.day == Day.mon && st.named(varWeek) == 2);
    c.numScenes = 0;
    c.spend(c.slotsToBattle);
    // Only Wednesday night's scene: Saturday's `once` trigger was spent in week 1.
    assert(c.battleDue && c.pendingScenes == 1);
    c.battleOver();
    // Evening, night and Sunday's six slots are left.
    assert(!c.over && c.spend(100) == 8 && c.over);
    assert(c.cal.week == 2 && c.cal.day == Day.sun && c.cal.slot == Slot.night);
}

@nogc nothrow @trusted unittest {
    // `spend` in a scene reaches the game as a story event; the clock replays exactly.
    StoryProgram p;
    StoryState st;
    Campaign a, b;
    setupClock(p, st, a);
    StoryRunner r;
    StoryEvents ev;
    r.start(p, p.findLabel("nothing"), st, ev);
    assert(ev.length == 1 && ev.items[0].kind == StoryEventKind.spend && ev.items[0].num == 3);
    a.begin();
    a.spend(17);
    StoryState st2;
    StoryProgram p2;
    setupClock(p2, st2, b);
    b.begin();
    b.spend(17);
    assert(a.hash() == b.hash() && a.cal == b.cal);
}

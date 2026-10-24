// A compiled story: the tables the compiler (story.compile) fills from `.story` files and the
// runner (story.vm) executes. Everything is flat records in malloc'd pools; strings are slices of
// the program's own text arena, so the source files may be freed once compiling is done.
// Model layer: no SDL, @nogc nothrow.
module story.program;

import story.pool;
import story.state : StoryState;
import story.value;

enum StoryError : ubyte {
    none,
    /// The entry file or an import could not be read.
    notFound,
    /// A line does not parse.
    syntax,
    /// A line parses but means nothing (unknown label, speaker, field...).
    semantic,
    outOfMemory
}

/// Most choices one menu shows at once (the UI maps them to keys 1..maxChoices).
enum int maxChoices = 6;

enum TriggerKind : ubyte {
    /// Once, when a new playthrough starts in the village.
    start,
    /// The player interacts with the NPC whose id is `target`.
    talk,
    /// The player walks into the village zone `target`.
    enter,
    /// The player comes back from tower defense; `target` is "won" or "lost" (empty: either).
    returned
}

struct Speaker {
    const(char)[] id, name, portrait, figure;
    /// Row of the speaker's walk sheet in the villager sprite atlas, or -1.
    int sprite = -1;
}

/// Where a character lives in the village (`home` is a landmark name).
struct NpcSpot {
    int speaker;
    const(char)[] home;
    int wander = 1;
}

struct PlaceWare {
    const(char)[] name, desc;
    int price;
    /// Story variable set once bought.
    int flag = -1;
}

struct PlaceTopic {
    const(char)[] ask, answer;
}

/// A building interior (`id` is a landmark name).
struct Place {
    const(char)[] id, title, image, look;
    int host = -1;
    uint wareStart, wareLen, topicStart, topicLen;
}

struct Trigger {
    TriggerKind on;
    const(char)[] target;
    /// Condition expression, or -1 (always).
    int cond = -1;
    /// Scene code to run when it fires.
    int entry;
    /// Variable marking a `once` trigger as spent, or -1.
    int onceVar = -1;
}

/// Scene instructions.
enum Op : ubyte {
    /// Shows say record `a` and waits (with the choices of a `menu` right after it, if any).
    say,
    /// `a` options follow as `option` instructions; waits for a choice, or falls through past
    /// them when no option's condition holds.
    menu,
    /// Caption template `a`, condition expression `b` (-1: always), target pc `c`.
    option,
    jump,
    /// Jumps to `b` unless expression `a` is true.
    jumpIfNot,
    call,
    /// Returns from a `call`; ends the conversation when nothing called. In a function, returns
    /// the value of expression `a` (-1: nil).
    ret,
    /// Variable `a` (sub: AssignOp) with expression `b` (-1: `true`).
    assign,
    /// Raises story event `a` with optional numeric argument expression `b`.
    event,
    /// Presentation command (sub: PresentKind) with string args `a`, `b` (-1: none).
    present,
    /// `container[key] op= value`: expressions `a` (container), `b` (key), `c` (value; -1:
    /// `true`), sub: AssignOp.
    store,
    /// Evaluates expression `a` for its effect (`append(xs, 1)`).
    exec,
}

enum AssignOp : ubyte {
    set,
    add,
    sub,
    mul,
    div,
    mod,
    clear
}

enum PresentKind : ubyte {
    show,
    hide,
    scene,
    playMusic,
    playSound,
    stopMusic,
    stopSound,
    battle
}

struct Ins {
    Op op;
    ubyte sub;
    int a = -1, b = -1, c = -1;
}

struct SayRec {
    /// Speaker index, or -1 for narration.
    int speaker = -1;
    const(char)[] mood;
    int text;
    /// Label (or `label.sub`) the line sits under, for tests and debugging.
    const(char)[] label;
}

/// One piece of a text template: literal text, or an expression whose value is shown.
struct Segment {
    const(char)[] lit;
    int expr = -1;
}

struct Template {
    uint start, len;
}

/// Expression instructions (a stack machine; every expression ends in `ret`).
enum XOp : ubyte {
    konst,
    load,
    neg,
    not,
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    /// Short circuit: when the top is false, replace it with `false` and jump to `arg`; else pop.
    andJump,
    /// When the top is true, replace it with `true` and jump to `arg`; else pop.
    orJump,
    toBool,
    /// Joins the display forms of the top `argc` values into a run-time string.
    concat,
    /// Built-in `arg` (Builtin) on the top `argc` values.
    call,
    /// A new list of the top `argc` values.
    list,
    /// A new map of the top `argc` key/value pairs (2 * argc values).
    map,
    /// `c[key]` (key on top, container below); nil when absent.
    index,
    /// Loop step: element `i` of a list or key `i` of a map (i on top, collection below).
    iter,
    /// Story function `arg` (a `def`) on the top `argc` values.
    callFn,
    /// Host function `arg` (StoryProgram.hosts) on the top `argc` values.
    callHost,
    ret
}

/// A `def`: its code, and the hidden variables holding its parameters (first `argc`) and locals.
struct StoryFn {
    const(char)[] name;
    int entry = -1;
    ubyte argc;
    uint localStart, localLen;
}

/// A function the game offers to scripts (`tower_hp(t)`). Hosts must not run story code.
alias HostCallback = Value function(scope const(Value)[] args, ref StoryState st, void* ctx) @nogc nothrow;

struct HostFn {
    const(char)[] name;
    ubyte minArgs, maxArgs;
    HostCallback fn;
}

struct XIns {
    XOp op;
    ubyte argc;
    int arg;
}

enum Builtin : ubyte {
    min,
    max,
    abs,
    floor,
    ceil,
    round,
    clamp,
    rand,
    len,
    str,
    append,
    remove,
    keys,
    has,
    range
}

/// Most values one expression keeps on the stack (the compiler rejects deeper expressions).
enum int maxExprStack = 128;

enum Severity : ubyte {
    error,
    warning
}

struct Diagnostic {
    Severity severity;
    const(char)[] file;
    uint line, col;
    const(char)[] message;
}

enum StoryEventKind : ubyte {
    /// `event name [arg]`: `id` is the event id, `num` the argument (0 without one).
    custom,
    /// A presentation command (`present`), with its string args.
    present
}

struct StoryEvent {
    StoryEventKind kind;
    PresentKind present;
    short id = -1;
    double num = 0;
    const(char)[] a, b;
}

/// Story events raised during one step; the controller drains them.
struct StoryEvents {
    enum int capacity = 16;
    StoryEvent[capacity] items;
    int length;

    void push(StoryEvent e) @nogc nothrow pure @safe {
        if (length < capacity)
            items[length++] = e;
    }

    void clear() @nogc nothrow pure @safe {
        length = 0;
    }

    /// True when custom event `id` was raised.
    bool has(int id) const @nogc nothrow pure @safe {
        foreach (i; 0 .. length)
            if (items[i].kind == StoryEventKind.custom && items[i].id == id)
                return true;
        return false;
    }
}

@nogc nothrow pure @safe unittest {
    StoryEvents ev;
    foreach (i; 0 .. 20)
        ev.push(StoryEvent(StoryEventKind.custom, PresentKind.show, cast(short)i));
    assert(ev.length == StoryEvents.capacity && ev.has(3) && !ev.has(17));
    ev.clear();
    assert(ev.length == 0 && !ev.has(3));
}

struct StoryProgram {
    package Pool!Speaker speakers_;
    package Pool!NpcSpot npcs_;
    package Pool!Place places_;
    package Pool!PlaceWare wares_;
    package Pool!PlaceTopic topics_;
    package Pool!Trigger triggers_;
    package Pool!Ins code_;
    package Pool!SayRec says_;
    package Pool!Segment segments_;
    package Pool!Template templates_;
    package Pool!XIns xcode_;
    package Pool!Value consts_;
    package Pool!(const(char)[]) strings_;
    package Pool!(const(char)[]) events_;
    package Pool!(const(char)[]) labelNames_;
    package Pool!int labelPcs_;
    package Pool!Diagnostic diags_;
    package Pool!StoryFn fns_;
    package Pool!int fnLocals_;
    package Pool!int dataSlots_;
    /// Host functions the program was compiled against (owned by the game, outliving the program).
    package const(HostFn)[] hosts_;
    package TextArena text_;
    /// Scene code setting every declared starting value, or -1.
    package int init_ = -1;
    /// Passed to every host function call (the game sets it before running story code).
    void* hostContext;

    @disable this(this);

    const(Speaker)[] speakers() const return @nogc nothrow @safe {
        return speakers_.slice;
    }

    const(NpcSpot)[] npcs() const return @nogc nothrow @safe {
        return npcs_.slice;
    }

    const(Place)[] places() const return @nogc nothrow @safe {
        return places_.slice;
    }

    const(PlaceWare)[] wares(ref const Place p) const return @nogc nothrow @safe {
        return wares_.slice[p.wareStart .. p.wareStart + p.wareLen];
    }

    const(PlaceTopic)[] topics(ref const Place p) const return @nogc nothrow @safe {
        return topics_.slice[p.topicStart .. p.topicStart + p.topicLen];
    }

    const(Trigger)[] triggers() const return @nogc nothrow @safe {
        return triggers_.slice;
    }

    const(Ins)[] code() const return @nogc nothrow @safe {
        return code_.slice;
    }

    const(SayRec)[] says() const return @nogc nothrow @safe {
        return says_.slice;
    }

    const(Segment)[] segments(int template_) const return @nogc nothrow @safe {
        const t = templates_.slice[template_];
        return segments_.slice[t.start .. t.start + t.len];
    }

    const(XIns)[] xcode() const return @nogc nothrow @safe {
        return xcode_.slice;
    }

    const(Value)[] constants() const return @nogc nothrow @safe {
        return consts_.slice;
    }

    const(char)[] str(int i) const return @nogc nothrow @safe {
        return i >= 0 ? strings_.slice[i] : null;
    }

    const(char)[][] eventNames() const return @nogc nothrow @trusted {
        return cast(const(char)[][])events_.slice;
    }

    const(Diagnostic)[] diagnostics() const return @nogc nothrow @safe {
        return diags_.slice;
    }

    const(StoryFn)[] functions() const return @nogc nothrow @safe {
        return fns_.slice;
    }

    /// Hidden variables of function `f` (parameters first).
    const(int)[] locals(ref const StoryFn f) const return @nogc nothrow @safe {
        return fnLocals_.slice[f.localStart .. f.localStart + f.localLen];
    }

    int findFunction(const(char)[] name) const @nogc nothrow @safe {
        foreach (i, ref f; fns_.slice)
            if (f.name == name)
                return cast(int)i;
        return -1;
    }

    const(HostFn)[] hosts() const return @nogc nothrow @safe {
        return hosts_;
    }

    /// Variables declared with `data` (read-only, frozen by `initialize`).
    const(int)[] dataSlots() const return @nogc nothrow @safe {
        return dataSlots_.slice;
    }

    int initEntry() const @nogc nothrow pure @safe {
        return init_;
    }

    /// Label names (sub-labels as `label.sub`) and their entry pcs.
    const(char)[][] labelNames() const return @nogc nothrow @trusted {
        return cast(const(char)[][])labelNames_.slice;
    }

    int findLabel(const(char)[] name) const @nogc nothrow @safe {
        foreach (i, n; labelNames_.slice)
            if (n == name)
                return labelPcs_.slice[i];
        return -1;
    }

    int findSpeaker(const(char)[] id) const @nogc nothrow @safe {
        foreach (i, ref s; speakers_.slice)
            if (s.id == id)
                return cast(int)i;
        return -1;
    }

    int findEvent(const(char)[] name) const @nogc nothrow @safe {
        foreach (i, n; events_.slice)
            if (n == name)
                return cast(int)i;
        return -1;
    }

    /// The first error, as `file:line: message` text in `buf` (empty when there is none).
    const(char)[] firstError(char[] buf) const @nogc nothrow @trusted {
        import core.stdc.stdio : snprintf;

        foreach (ref d; diags_.slice)
            if (d.severity == Severity.error) {
                immutable n = snprintf(buf.ptr, buf.length, "%.*s:%u:%u: %.*s",
                        cast(int)d.file.length, d.file.ptr, d.line, d.col, cast(int)d.message.length, d.message.ptr);
                return buf[0 .. n < 0 ? 0 : (n < buf.length ? n : buf.length - 1)];
            }
        return buf[0 .. 0];
    }

    /// Empties every table (before compiling again).
    package void clear() @nogc nothrow @safe {
        speakers_.clear();
        npcs_.clear();
        places_.clear();
        wares_.clear();
        topics_.clear();
        triggers_.clear();
        code_.clear();
        says_.clear();
        segments_.clear();
        templates_.clear();
        xcode_.clear();
        consts_.clear();
        strings_.clear();
        events_.clear();
        labelNames_.clear();
        labelPcs_.clear();
        diags_.clear();
        fns_.clear();
        fnLocals_.clear();
        dataSlots_.clear();
        hosts_ = null;
        text_.clear();
        init_ = -1;
    }
}

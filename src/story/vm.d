// Runs compiled story code: an expression stack machine and the scene runner that walks one
// conversation (lines, choices, jumps, calls, assignments, events). Triggers pick which code runs
// when the player talks to someone, walks somewhere, starts or comes home. Runs are bounded (fixed
// stacks, a step cap per resume), so a looping script stops instead of hanging the game.
// Model layer: no SDL, @nogc nothrow, no allocation outside the StoryState text heap.
module story.vm;

import story.program;
import story.state;
import story.value;

/// Instructions one resume may execute before the runner gives up on a runaway loop.
enum int maxSteps = 100_000;
/// Nested `call`s.
enum int maxCallDepth = 32;
/// Bytes of run-time strings after which assignments compact the text heap.
private enum size_t collectAt = 64 * 1024;

// ---- values ----------------------------------------------------------------------------------

/// Display form of `v` (numbers and collections are written into `numBuf`, truncated).
const(char)[] display(const Value v, ref const StoryState st, char[] numBuf) @nogc nothrow @trusted {
    if (v.isCollection) {
        size_t n = 0;
        writeCollection(v, st, numBuf, n, 0);
        return numBuf[0 .. n];
    }
    final switch (v.kind) {
    case ValueKind.nil:
        return null;
    case ValueKind.boolean:
        return v.b ? "true" : "false";
    case ValueKind.number:
        return formatNumber(v.n, numBuf);
    case ValueKind.text:
    case ValueKind.heapText:
        return st.text(v);
    case ValueKind.symbol:
        return st.symbolName(v);
    case ValueKind.list:
    case ValueKind.map:
        assert(0);
    }
}

/// `[1, two]` / `{a: 1}`; nested collections past depth 3 show as `...`.
private void writeCollection(const Value v, ref const StoryState st, char[] buf, ref size_t n, int depth) @nogc nothrow @trusted {
    void put(const(char)[] s) {
        foreach (c; s)
            if (n < buf.length)
                buf[n++] = c;
    }

    if (depth > 3)
        return put("...");
    immutable isMap = v.kind == ValueKind.map;
    put(isMap ? "{" : "[");
    const ks = st.keys(v);
    foreach (i, ref e; st.items(v)) {
        if (i)
            put(", ");
        if (isMap) {
            put(st.text(ks[i]));
            put(": ");
        }
        if (e.isCollection)
            writeCollection(e, st, buf, n, depth + 1);
        else {
            char[32] nb;
            put(display(e, st, nb[]));
        }
    }
    put(isMap ? "}" : "]");
}

/// `==` on story values: strings compare by content (and never equal a non-string); everything
/// else compares as numbers, so nil == 0 == false.
bool equal(const Value a, const Value b, ref const StoryState st) @nogc nothrow @trusted {
    if (a.isCollection || b.isCollection || a.isSymbol || b.isSymbol)
        return a.kind == b.kind && a.off == b.off;
    if (a.isText || b.isText)
        return a.isText && b.isText && st.text(a) == st.text(b);
    return toNumber(a) == toNumber(b);
}

/// Ordering: strings lexicographically (bytes), everything else as numbers. NaN orders nowhere.
private int order(const Value a, const Value b, ref const StoryState st, out bool unordered) @nogc nothrow @safe {
    unordered = false;
    if ((a.isText && b.isText) || (a.isSymbol && b.isSymbol)) {
        const x = st.keyText(a), y = st.keyText(b);
        return x < y ? -1 : (x > y ? 1 : 0);
    }
    immutable x = toNumber(a), y = toNumber(b);
    if (x != x || y != y) {
        unordered = true;
        return 0;
    }
    return x < y ? -1 : (x > y ? 1 : 0);
}

/// `+`: numbers add; when either side is a string, the display forms are joined.
Value plus(const Value a, const Value b, ref StoryState st) @nogc nothrow @safe {
    if (!a.isText && !b.isText)
        return Value.number(toNumber(a) + toNumber(b));
    char[128] na, nb;
    return st.makeText(display(a, st, na[]), display(b, st, nb[]));
}

private size_t codePoints(const(char)[] s) @nogc nothrow pure @safe {
    size_t n = 0;
    foreach (c; s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}

private Value builtin(Builtin f, Value[] args, ref StoryState st) @nogc nothrow @safe {
    double num(size_t i) {
        return toNumber(args[i]);
    }

    final switch (f) {
    case Builtin.min:
    case Builtin.max: {
            double r = num(0);
            foreach (i; 1 .. args.length) {
                immutable v = num(i);
                if (f == Builtin.min ? v < r : v > r)
                    r = v;
            }
            return Value.number(r);
        }
    case Builtin.abs:
        return Value.number(num(0) < 0 ? -num(0) : num(0));
    case Builtin.floor:
        return Value.number(floorOf(num(0)));
    case Builtin.ceil:
        return Value.number(ceilOf(num(0)));
    case Builtin.round:
        return Value.number(roundOf(num(0)));
    case Builtin.clamp: {
            immutable v = num(0), lo = num(1), hi = num(2);
            return Value.number(v < lo ? lo : (v > hi ? hi : v));
        }
    case Builtin.rand: {
            if (args.length == 0)
                return Value.number(st.rng.uniform01());
            double lo = 0, hi = floorOf(num(0)) - 1;
            if (args.length == 2) {
                lo = floorOf(num(0));
                hi = floorOf(num(1));
            }
            if (!(hi >= lo) || hi - lo >= uint.max)
                return Value.number(lo);
            return Value.number(lo + st.rng.below(cast(uint)(hi - lo) + 1));
        }
    case Builtin.len:
        return Value.number(args[0].isCollection ? st.count(args[0]) : codePoints(st.text(args[0])));
    case Builtin.append:
        st.append(args[0], args[1]);
        return args[0];
    case Builtin.remove:
        return Value.boolean(st.remove(args[0], args[1]));
    case Builtin.keys: {
            auto l = st.newCollection(false);
            foreach (ref k; st.keys(args[0]))
                st.append(l, k);
            return l;
        }
    case Builtin.has:
        if (args[0].kind == ValueKind.map) {
            foreach (ref k; st.keys(args[0]))
                if (args[1].isText && st.text(k) == st.text(args[1]))
                    return Value.boolean(true);
            return Value.boolean(false);
        }
        foreach (ref e; st.items(args[0]))
            if (equal(e, args[1], st))
                return Value.boolean(true);
        return Value.boolean(false);
    case Builtin.range: {
            double lo = 0, hi = floorOf(num(0));
            if (args.length == 2) {
                lo = floorOf(num(0));
                hi = floorOf(num(1));
            }
            auto l = st.newCollection(false);
            for (double i = lo; i < hi && st.count(l) < maxCollectionLen; i++)
                st.append(l, Value.number(i));
            return l;
        }
    case Builtin.str: {
            char[128] b;
            return args[0].isText ? args[0] : st.makeText(display(args[0], st, b[]));
        }
    }
}

/// `cur op= rhs`.
private Value combine(AssignOp op, const Value cur, const Value rhs, ref StoryState st) @nogc nothrow @safe {
    if (op == AssignOp.add)
        return plus(cur, rhs, st);
    immutable a = toNumber(cur), b = toNumber(rhs);
    return Value.number(op == AssignOp.sub ? a - b : (op == AssignOp.mul ? a * b : (op == AssignOp.div
            ? a / b : modOf(a, b))));
}

/// An `assign` instruction (no garbage collection: callers decide when that is safe).
private void doAssign(ref const StoryProgram p, AssignOp op, int slot, int expr, ref StoryState st) @nogc nothrow @safe {
    if (op == AssignOp.clear) {
        st.setValue(slot, Value.boolean(false));
        return;
    }
    immutable rhs = expr < 0 ? Value.boolean(true) : evaluate(p, expr, st);
    st.setValue(slot, op == AssignOp.set ? rhs : combine(op, st.value(slot), rhs, st));
}

/// A `store` instruction: `container[key] op= value`.
private void doStore(ref const StoryProgram p, ref const Ins ins, ref StoryState st) @nogc nothrow @safe {
    immutable c = evaluate(p, ins.a, st), k = evaluate(p, ins.b, st);
    Value v = ins.c < 0 ? Value.boolean(true) : evaluate(p, ins.c, st);
    immutable op = cast(AssignOp)ins.sub;
    if (op == AssignOp.clear)
        v = Value.boolean(false);
    else if (op != AssignOp.set)
        v = combine(op, st.at(c, k), v, st);
    st.put(c, k, v);
}

/// Runs `def` number `fn` on `args` and returns its result (nil when it falls off its end or
/// runs away). Functions only compute and assign; the compiler keeps lines, menus, jumps to
/// labels and events out of them, and rejects recursion, so nesting is bounded by the number of
/// functions. No garbage is collected here: the caller's expression stack is live.
Value callFunction(ref const StoryProgram p, int fn, scope const(Value)[] args, ref StoryState st) @nogc nothrow @trusted {
    const f = &p.functions[fn];
    const locals = p.locals(*f);
    foreach (i, slot; locals)
        st.setValue(slot, i < args.length ? args[i] : Value.init);
    Value result;
    const code = p.code;
    int pc = f.entry, steps = 0;
    run: while (pc >= 0 && pc < code.length && ++steps <= maxSteps) {
        const ins = &code[pc];
        switch (ins.op) {
        case Op.jump:
            pc = ins.a;
            break;
        case Op.jumpIfNot:
            pc = truthy(evaluate(p, ins.a, st)) ? pc + 1 : ins.b;
            break;
        case Op.assign:
            doAssign(p, cast(AssignOp)ins.sub, ins.a, ins.b, st);
            pc++;
            break;
        case Op.store:
            doStore(p, *ins, st);
            pc++;
            break;
        case Op.exec:
            evaluate(p, ins.a, st);
            pc++;
            break;
        case Op.ret:
            if (ins.a >= 0)
                result = evaluate(p, ins.a, st);
            break run;
        default:
            break run;
        }
    }
    // Locals do not outlive the call (the result is on the caller's stack until it is stored).
    foreach (slot; locals)
        st.setValue(slot, Value.init);
    return result;
}

/// Evaluates the expression starting at `pc`.
Value evaluate(ref const StoryProgram p, int pc, ref StoryState st) @nogc nothrow @trusted {
    Value[maxExprStack + 1] stack = void;
    int sp = 0;
    const code = p.xcode;
    const consts = p.constants;
    while (true) {
        const x = code[pc++];
        final switch (x.op) {
        case XOp.konst:
            stack[sp++] = consts[x.arg];
            break;
        case XOp.load:
            stack[sp++] = st.value(x.arg);
            break;
        case XOp.neg:
            stack[sp - 1] = Value.number(-toNumber(stack[sp - 1]));
            break;
        case XOp.not:
            stack[sp - 1] = Value.boolean(!truthy(stack[sp - 1]));
            break;
        case XOp.toBool:
            stack[sp - 1] = Value.boolean(truthy(stack[sp - 1]));
            break;
        case XOp.add:
            sp--;
            stack[sp - 1] = plus(stack[sp - 1], stack[sp], st);
            break;
        case XOp.sub:
        case XOp.mul:
        case XOp.div:
        case XOp.mod: {
                sp--;
                immutable a = toNumber(stack[sp - 1]), b = toNumber(stack[sp]);
                double r = x.op == XOp.sub ? a - b : (x.op == XOp.mul ? a * b : (x.op == XOp.div ? a / b : modOf(a, b)));
                stack[sp - 1] = Value.number(r);
                break;
            }
        case XOp.eq:
        case XOp.ne:
            sp--;
            stack[sp - 1] = Value.boolean(equal(stack[sp - 1], stack[sp], st) == (x.op == XOp.eq));
            break;
        case XOp.lt:
        case XOp.le:
        case XOp.gt:
        case XOp.ge: {
                sp--;
                bool unordered;
                immutable c = order(stack[sp - 1], stack[sp], st, unordered);
                bool r = !unordered && (x.op == XOp.lt ? c < 0 : (x.op == XOp.le ? c <= 0 : (x.op == XOp.gt
                        ? c > 0 : c >= 0)));
                stack[sp - 1] = Value.boolean(r);
                break;
            }
        case XOp.andJump:
            if (!truthy(stack[sp - 1])) {
                stack[sp - 1] = Value.boolean(false);
                pc = x.arg;
            } else
                sp--;
            break;
        case XOp.orJump:
            if (truthy(stack[sp - 1])) {
                stack[sp - 1] = Value.boolean(true);
                pc = x.arg;
            } else
                sp--;
            break;
        case XOp.concat: {
                const(char)[][16] parts;
                char[64][16] bufs;
                immutable n = x.argc;
                assert(n <= parts.length);
                foreach (i; 0 .. n)
                    parts[i] = display(stack[sp - n + i], st, bufs[i][]);
                sp -= n;
                stack[sp++] = st.makeText(parts[0 .. n]);
                break;
            }
        case XOp.call: {
                immutable n = x.argc;
                immutable r = builtin(cast(Builtin)x.arg, stack[sp - n .. sp], st);
                sp -= n;
                stack[sp++] = r;
                break;
            }
        case XOp.callFn: {
                immutable n = x.argc;
                immutable r = callFunction(p, x.arg, stack[sp - n .. sp], st);
                sp -= n;
                stack[sp++] = r;
                break;
            }
        case XOp.callHost: {
                immutable n = x.argc;
                immutable r = p.hosts[x.arg].fn(stack[sp - n .. sp], st, cast(void*)p.hostContext);
                sp -= n;
                stack[sp++] = r;
                break;
            }
        case XOp.list: {
                immutable n = x.argc;
                auto l = st.newCollection(false);
                foreach (i; 0 .. n)
                    st.append(l, stack[sp - n + i]);
                sp -= n;
                stack[sp++] = l;
                break;
            }
        case XOp.map: {
                immutable n = x.argc;
                auto m = st.newCollection(true);
                foreach (i; 0 .. n)
                    st.put(m, stack[sp - 2 * n + 2 * i], stack[sp - 2 * n + 2 * i + 1]);
                sp -= 2 * n;
                stack[sp++] = m;
                break;
            }
        case XOp.index:
            sp--;
            stack[sp - 1] = st.at(stack[sp - 1], stack[sp]);
            break;
        case XOp.iter: {
                sp--;
                immutable i = cast(size_t)toNumber(stack[sp]);
                const c = stack[sp - 1];
                const src = c.kind == ValueKind.map ? st.keys(c) : st.items(c);
                stack[sp - 1] = i < src.length ? src[i] : Value.init;
                break;
            }
        case XOp.ret:
            assert(sp == 1);
            return stack[0];
        }
        assert(sp >= 0 && sp <= maxExprStack);
    }
}

/// Renders text template `t` into `buf`, truncating at a UTF-8 boundary.
const(char)[] render(ref const StoryProgram p, int t, ref StoryState st, char[] buf) @nogc nothrow @trusted {
    size_t n = 0;
    void put(const(char)[] s) {
        auto take = s.length;
        if (n + take > buf.length) {
            take = buf.length - n;
            while (take > 0 && (s[take] & 0xC0) == 0x80)
                take--;
        }
        buf[n .. n + take] = s[0 .. take];
        n += take;
    }

    foreach (ref seg; p.segments(t)) {
        if (seg.expr < 0) {
            put(seg.lit);
            continue;
        }
        char[32] nb;
        put(display(evaluate(p, seg.expr, st), st, nb[]));
    }
    return buf[0 .. n];
}

// ---- conversations ---------------------------------------------------------------------------

/// The line on screen.
struct Line {
    /// Label (or `label.sub`) the line belongs to.
    const(char)[] id;
    int speaker = -1;
    /// Mood (portrait expression), empty for the default.
    const(char)[] expr;
    const(char)[] text;
}

struct ChoiceView {
    const(char)[] text;
}

/// Walks one conversation. Lines and captions are rendered (interpolated) once, when shown.
struct StoryRunner {
    private const(StoryProgram)* prog;
    private int pc = -1;
    private int[maxCallDepth] calls;
    private int depth;
    private bool active_;
    private int say_ = -1;
    private int shownAt_ = -1;
    private int menuPc = -1;
    private ubyte[maxChoices] visible;
    private int numVisible;
    private char[1024] textBuf;
    private uint textLen;
    private char[192][maxChoices] capBuf;
    private ushort[maxChoices] capLen;
    /// Runs stopped for exceeding `maxSteps` or `maxCallDepth` (a script bug).
    uint faults;

    @disable this(this);

    bool active() const @nogc nothrow pure @safe {
        return active_;
    }

    /// Program counter of the line or menu on screen (-1 when idle); changes when a new line shows.
    int nodeIndex() const @nogc nothrow pure @safe {
        return active_ ? shownAt_ : -1;
    }

    /// The line on screen; only valid while `active`.
    Line line() const return @nogc nothrow @trusted {
        assert(active_);
        if (say_ < 0)
            return Line(null, -1, null, textBuf[0 .. textLen]);
        const s = &prog.says[say_];
        return Line(s.label, s.speaker, s.mood, textBuf[0 .. textLen]);
    }

    /// The speaker of the line on screen, or null for narration.
    const(Speaker)* speaker() const return @nogc nothrow @trusted {
        if (!active_ || say_ < 0 || prog.says[say_].speaker < 0)
            return null;
        return &prog.speakers[prog.says[say_].speaker];
    }

    /// Choices whose condition held when they were shown.
    int choiceCount() const @nogc nothrow pure @safe {
        return active_ ? numVisible : 0;
    }

    ChoiceView choice(int i) const return @nogc nothrow @safe {
        assert(i >= 0 && i < numVisible);
        return ChoiceView(capBuf[i][0 .. capLen[i]]);
    }

    /// Runs `p` from `entry` until the first line (ending at once when there is none, or when
    /// `entry` is -1).
    void start(ref const StoryProgram p, int entry, ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        prog = &p;
        depth = 0;
        say_ = -1;
        textLen = 0;
        numVisible = 0;
        pc = entry;
        active_ = false;
        run(st, ev);
    }

    /// Closes the conversation where it stands.
    void stop() @nogc nothrow pure @safe {
        active_ = false;
        pc = -1;
        numVisible = 0;
    }

    /// Picks visible choice `i`; false (nothing happens) when it is out of range.
    bool choose(int i, ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        if (i < 0 || i >= choiceCount)
            return false;
        pc = prog.code[menuPc + 1 + visible[i]].c;
        numVisible = 0;
        run(st, ev);
        return true;
    }

    /// Continues past a line that offers no choices; false while choices are waiting.
    bool advance(ref StoryState st, ref StoryEvents ev) @nogc nothrow @safe {
        if (!active_ || numVisible > 0)
            return false;
        run(st, ev);
        return true;
    }

    private void finish() @nogc nothrow pure @safe {
        active_ = false;
        pc = -1;
        numVisible = 0;
    }

    /// Evaluates the menu at `at`; true when some choice is visible (then it waits), else `pc`
    /// moves past its options.
    private bool openMenu(int at, ref StoryState st) @nogc nothrow @trusted {
        const code = prog.code;
        immutable n = code[at].a;
        menuPc = at;
        numVisible = 0;
        foreach (k; 0 .. n) {
            const o = &code[at + 1 + k];
            if (o.b >= 0 && !truthy(evaluate(*prog, o.b, st)))
                continue;
            visible[numVisible] = cast(ubyte)k;
            capLen[numVisible] = cast(ushort)render(*prog, o.a, st, capBuf[numVisible][]).length;
            numVisible++;
        }
        pc = at + 1 + n;
        return numVisible > 0;
    }

    private void run(ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        const code = prog.code;
        int steps = 0;
        while (true) {
            if (pc < 0 || pc >= code.length)
                return finish();
            if (++steps > maxSteps) {
                faults++;
                return finish();
            }
            const ins = code[pc];
            final switch (ins.op) {
            case Op.say:
                say_ = ins.a;
                textLen = cast(uint)render(*prog, prog.says[say_].text, st, textBuf[]).length;
                shownAt_ = pc;
                active_ = true;
                pc++;
                if (pc < code.length && code[pc].op == Op.menu)
                    openMenu(pc, st);
                return;
            case Op.menu:
                if (openMenu(pc, st)) {
                    shownAt_ = menuPc;
                    active_ = true;
                    return;
                }
                break;
            case Op.option:
                pc++;
                break;
            case Op.jump:
                pc = ins.a;
                break;
            case Op.jumpIfNot:
                pc = truthy(evaluate(*prog, ins.a, st)) ? pc + 1 : ins.b;
                break;
            case Op.call:
                if (depth == maxCallDepth) {
                    faults++;
                    return finish();
                }
                calls[depth++] = pc + 1;
                pc = ins.a;
                break;
            case Op.ret:
                if (depth == 0)
                    return finish();
                pc = calls[--depth];
                break;
            case Op.assign:
                doAssign(*prog, cast(AssignOp)ins.sub, ins.a, ins.b, st);
                maybeCollect(st);
                pc++;
                break;
            case Op.event: {
                    StoryEvent e;
                    e.kind = StoryEventKind.custom;
                    e.id = cast(short)ins.a;
                    if (ins.b >= 0)
                        e.num = toNumber(evaluate(*prog, ins.b, st));
                    ev.push(e);
                    pc++;
                    break;
                }
            case Op.store:
                doStore(*prog, ins, st);
                maybeCollect(st);
                pc++;
                break;
            case Op.exec:
                evaluate(*prog, ins.a, st);
                maybeCollect(st);
                pc++;
                break;
            case Op.present: {
                    StoryEvent e;
                    e.kind = StoryEventKind.present;
                    e.present = cast(PresentKind)ins.sub;
                    e.a = prog.str(ins.a);
                    e.b = prog.str(ins.b);
                    ev.push(e);
                    pc++;
                    break;
                }
            }
        }
    }

    /// Statement boundary: nothing lives on an expression stack, so garbage may go.
    private static void maybeCollect(ref StoryState st) @nogc nothrow @safe {
        if (st.heapUsed > collectAt || st.collectionsCreated > 1024)
            st.collect();
    }
}

/// Index of the first trigger of `kind` for `target` whose condition holds, or -1. When one
/// fires, a `once` trigger is spent and `entry` is the code to start a StoryRunner at.
int trigger(ref const StoryProgram p, TriggerKind kind, const(char)[] target, ref StoryState st, out int entry) @nogc nothrow @safe {
    entry = -1;
    foreach (i, ref t; p.triggers) {
        if (t.on != kind || (t.target.length > 0 && t.target != target))
            continue;
        if (t.onceVar >= 0 && st.flag(t.onceVar))
            continue;
        if (t.cond >= 0 && !truthy(evaluate(p, t.cond, st)))
            continue;
        if (t.onceVar >= 0)
            st.setValue(t.onceVar, Value.boolean(true));
        entry = t.entry;
        return cast(int)i;
    }
    return -1;
}

/// Sets every declared starting value (`var x = 3`, record field defaults, `data` tables, which
/// are then frozen); call after `StoryState.reset` for a new playthrough.
void initialize(ref const StoryProgram p, ref StoryState st) @nogc nothrow @trusted {
    if (p.initEntry < 0)
        return;
    StoryRunner r;
    StoryEvents ev;
    r.start(p, p.initEntry, st, ev);
    assert(!r.active);
    foreach (slot; p.dataSlots)
        st.freeze(st.value(slot));
}

version (unittest) {
    import core.file : FileBytes;
    import story.compile;

    private immutable sampleMain = `import "people.story"

var coins = 40
var greeting = "Hello"

on start once -> intro
on talk elder if not met_elder -> elder_hi
on talk elder:
    elder: Back again, {greeting}?
on enter gate if not gate_open:
    clear seen_gate
    set seen_gate

label intro:
    Morning mist lifts off the terraces.
    : the drums sound {1 + 2} times.

label elder_hi:
    elder (worried): Ah, you came. You have {coins} coins.
    set met_elder
    elder.bond.trust += 5
  .ask:
    elder: Will you hold the west road?
    * I will hold it.
        set gate_open
        event gate_open 3
        -> .bless
    * What is out there?  if not asked_west
        set asked_west
        -> .ask
    * "Trust is {elder.bond.trust}" if elder.bond.disposition > 50
        call aside
        -> .ask
  .bless:
    if elder.bond.trust >= 55 and coins > 10:
        elder (happy): Go well, {elder.name}'s champion.
    elif coins > 0:
        elder: Go.
    else:
        elder: Hm.
    greeting = greeting + ", hero"

label aside:
    coins -= 15
    show elder happy
`;

    private immutable samplePeople = `type Bond:
    affection = 50 in 0..100
    respect = 50 in 0..100
    trust = 50 in 0..100
    disposition => (affection + respect + trust) / 3

character elder "Bà Lan":
    sprite 1
    home plaza wander 2
    bond: Bond
`;

    private struct MemFiles {
        const(char)[] loader(const(char)[] path, ref FileBytes) @nogc nothrow {
            if (path == "story/main.story")
                return sampleMain;
            if (path == "story/people.story")
                return samplePeople;
            return null;
        }
    }

    private void dumpDiagnostics(ref const StoryProgram p) @nogc nothrow @trusted {
        import core.stdc.stdio : printf;

        foreach (ref d; p.diagnostics)
            printf("  %.*s:%u:%u: %.*s\n", cast(int)d.file.length, d.file.ptr, d.line, d.col,
                    cast(int)d.message.length, d.message.ptr);
    }
}

@nogc nothrow unittest {
    MemFiles fs;
    StoryProgram p;
    StoryState st;
    immutable err = compileStory(p, st, "story/main.story", &fs.loader);
    if (err != StoryError.none)
        dumpDiagnostics(p);
    assert(err == StoryError.none);
    assert(p.speakers.length == 1 && p.speakers[0].name == "Bà Lan" && p.speakers[0].sprite == 1);
    assert(p.npcs.length == 1 && p.npcs[0].home == "plaza" && p.npcs[0].wander == 2);

    initialize(p, st);
    assert(st.named("coins") == 40 && st.named("elder.bond.trust") == 50);

    StoryRunner r;
    StoryEvents ev;
    int entry;
    assert(trigger(p, TriggerKind.start, null, st, entry) == 0);
    r.start(p, entry, st, ev);
    assert(r.active && r.speaker is null && r.line.text == "Morning mist lifts off the terraces.");
    assert(r.line.id == "intro" && r.advance(st, ev) && r.line.text == "the drums sound 3 times.");
    assert(r.advance(st, ev) && !r.active);
    assert(trigger(p, TriggerKind.start, null, st, entry) == -1);

    assert(trigger(p, TriggerKind.talk, "elder", st, entry) == 1);
    r.start(p, entry, st, ev);
    assert(r.line.text == "Ah, you came. You have 40 coins." && r.line.expr == "worried");
    assert(r.speaker.id == "elder" && r.choiceCount == 0);
    assert(r.advance(st, ev) && r.line.id == "elder_hi.ask" && r.choiceCount == 3);
    assert(st.named("elder.bond.trust") == 55 && st.flag(st.find("met_elder")));
    assert(r.choice(2).text == "Trust is 55");
    // A call and a local jump back; the menu re-renders.
    assert(r.choose(2, st, ev) && st.named("coins") == 25 && r.choiceCount == 3);
    assert(ev.length == 1 && ev.items[0].kind == StoryEventKind.present && ev.items[0].a == "elder"
            && ev.items[0].b == "happy");
    assert(r.choose(1, st, ev) && r.choiceCount == 2);
    assert(r.choose(0, st, ev) && ev.has(p.findEvent("gate_open")) && ev.items[1].num == 3);
    assert(r.line.text == "Go well, Bà Lan's champion." && r.line.expr == "happy");
    assert(r.advance(st, ev) && !r.active);
    assert(st.text(st.value(st.find("greeting"))) == "Hello, hero");

    // The second talk trigger takes over; the inline enter trigger runs without a line.
    assert(trigger(p, TriggerKind.talk, "elder", st, entry) == 2);
    r.start(p, entry, st, ev);
    assert(r.line.text == "Back again, Hello, hero?");
    assert(trigger(p, TriggerKind.enter, "gate", st, entry) == -1);
}

@nogc nothrow unittest {
    // Bounds clamp, derived fields read through, determinism of the state hash.
    MemFiles fs;
    StoryProgram p;
    StoryState a, b;
    assert(compileStory(p, a, "story/main.story", &fs.loader) == StoryError.none);
    StoryProgram q;
    assert(compileStory(q, b, "story/main.story", &fs.loader) == StoryError.none);
    initialize(p, a);
    initialize(q, b);
    a.set(a.find("elder.bond.trust"), 500);
    assert(a.named("elder.bond.trust") == 100);
    b.set(b.find("elder.bond.trust"), 100);
    assert(a.hash() == b.hash());
}

@nogc nothrow unittest {
    // Errors carry file:line:col and do not stop at the first.
    const(char)[] bad(const(char)[] path, ref FileBytes) @nogc nothrow {
        return "label a:\n    sett x\n    nobody: hi\n    -> nowhere\n    x = elder.bond\n";
    }

    StoryProgram p;
    StoryState st;
    assert(compileStory(p, st, "bad.story", &bad) == StoryError.syntax);
    int errs = 0;
    foreach (ref d; p.diagnostics)
        errs += d.severity == Severity.error;
    assert(errs == 3);
    char[256] buf;
    assert(p.firstError(buf[])[0 .. 14] == "bad.story:2:10");

    const(char)[] missing(const(char)[] path, ref FileBytes) @nogc nothrow {
        return path == "m.story" ? `import "gone.story"` : null;
    }

    assert(compileStory(p, st, "m.story", &missing) == StoryError.notFound);
}

@nogc nothrow unittest {
    // A runaway loop is cut off, not hung.
    const(char)[] loop(const(char)[] path, ref FileBytes) @nogc nothrow {
        return "on start -> spin\nlabel spin:\n    x += 1\n    -> spin\n";
    }

    StoryProgram p;
    StoryState st;
    assert(compileStory(p, st, "l.story", &loop) == StoryError.none);
    StoryRunner r;
    StoryEvents ev;
    int entry;
    trigger(p, TriggerKind.start, null, st, entry);
    r.start(p, entry, st, ev);
    assert(!r.active && r.faults == 1);
}

@nogc nothrow unittest {
    // Lists, maps and for loops (ported from the old interpreter's collections test).
    immutable text = `
on start -> collections
label collections:
    citizens = [{"name": "Ada", "wounded": true, "health": {"food": 5}}, {name: "Bo", wounded: false, health: {food: 8}}]
    food = 10
    for citizen in citizens:
        if citizen.wounded:
            food -= 2
            citizen.health.food -= 1
        Checking {citizen.name} ({citizen.health["food"]})
    total = 0
    for i in range(3):
        for j in [1, 2]:
            total += i + j
    stats = {"z": 2, "a": 1}
    order = ""
    for key in stats:
        order += key
    for unused in []:
        total = -100
    alias = citizens[0]
    alias.health["food"] += 3
    append(citizens, {"name": "Cy"})
    citizens[-1].name = "Cyd"
    remove(stats, "z")
    All done: {len(citizens)} citizens, {citizens[-1].name}, {stats}, {has(stats, "a")}, {keys({"q": 1})}
`;
    StoryProgram p;
    StoryState st;
    immutable err = compileText(p, st, text);
    if (err != StoryError.none)
        dumpDiagnostics(p);
    assert(err == StoryError.none);
    StoryRunner r;
    StoryEvents ev;
    int entry;
    trigger(p, TriggerKind.start, null, st, entry);
    r.start(p, entry, st, ev);
    assert(r.line.text == "Checking Ada (4)");
    r.advance(st, ev);
    assert(r.line.text == "Checking Bo (8)");
    r.advance(st, ev);
    assert(r.line.text == "All done: 3 citizens, Cyd, {a: 1}, true, [q]");
    assert(st.named("food") == 8 && st.named("total") == 15);
    assert(st.text(st.value(st.find("order"))) == "za");
    const ada = st.at(st.value(st.find("citizens")), Value.number(0));
    assert(toNumber(st.at(st.at(ada, Value.constText("health")), Value.constText("food"))) == 7);
    // Garbage collections are reclaimed; live ones survive with their contents.
    immutable h = st.hash();
    st.collect();
    assert(st.hash() == h);
}

@nogc nothrow unittest {
    // `data` tables over several lines, `def` functions with locals, symbols, host functions.
    static Value twice(scope const(Value)[] args, ref StoryState st, void* ctx) @nogc nothrow {
        return Value.number(toNumber(args[0]) * 2 + (ctx ? *cast(int*)ctx : 0));
    }

    static immutable HostFn[] hosts = [HostFn("twice", 1, 1, &twice)];
    immutable text = `
def grow(base, steps):
    t = {name: base.name, cost: base.cost}
    for i in range(steps):
        t.cost = floor(t.cost * 130 / 100)
    return t

def label_of(t):
    if t.kind == :arrow:
        return "bow"
    return "other"

data towers = [
    {name: "Arrow", kind: :arrow, cost: 50},   # comments inside are fine
    {name: "Cannon",
     kind: :cannon, cost: 80},
]
data big = grow(towers[1], 2)
var picked = :none

on start -> go
label go:
    picked = towers[0].kind
    t = grow(towers[0], 1)
    Costs {t.cost} then {big.cost}, {label_of(towers[0])}/{label_of(towers[1])}, {picked}, {twice(4)}.
    if picked == :arrow and picked != :cannon and str(picked) == "arrow":
        ok = towers[1][:cost]
    towers[0].cost = 1
`;
    StoryProgram p;
    StoryState st;
    immutable err = compileText(p, st, text, hosts);
    if (err != StoryError.none)
        dumpDiagnostics(p);
    assert(err == StoryError.none);
    assert(p.functions.length == 2 && p.dataSlots.length == 2);
    initialize(p, st);
    // The data table is frozen; grow's locals were cleared after the call.
    const towers = st.value(st.find("towers"));
    assert(st.frozen(towers) && st.count(towers) == 2 && st.value(st.find("grow@t")).isNil);
    assert(st.get(st.find("big")) == 0 && toNumber(st.at(st.value(st.find("big")), Value.constText("cost"))) == 135);
    int extra = 1;
    p.hostContext = &extra;
    StoryRunner r;
    StoryEvents ev;
    int entry;
    trigger(p, TriggerKind.start, null, st, entry);
    r.start(p, entry, st, ev);
    assert(r.line.text == "Costs 65 then 135, bow/other, arrow, 9.");
    r.advance(st, ev);
    assert(!r.active && st.named("ok") == 80);
    // Writes into frozen data are refused.
    assert(toNumber(st.at(st.items(towers)[0], Value.constText("cost"))) == 50);
}

@nogc nothrow unittest {
    // Function and data misuse is reported.
    static void expectError(const(char)[] text, const(char)[] what) @nogc nothrow {
        StoryProgram p;
        StoryState st;
        assert(compileText(p, st, text) != StoryError.none);
        foreach (ref d; p.diagnostics) {
            const m = d.message;
            foreach (k; 0 .. m.length + 1)
                if (k + what.length <= m.length && m[k .. k + what.length] == what)
                    return;
        }
        dumpDiagnostics(p);
        assert(0);
    }

    expectError("def f(x):\n    return g(x)\ndef g(x):\n    return f(x)\n", "recursive");
    expectError("def f(x):\n    elder: hi\n", "not allowed inside a function");
    expectError("def f(x):\n    -> f\n", "not allowed inside a function");
    expectError("label a:\n    return 3\n", "only a function");
    expectError("data d = 1\nlabel a:\n    d = 2\n", "read-only");
    expectError("def f(x):\n    return x\nlabel a:\n    y = f(1, 2)\n", "takes 1 arguments");
    expectError("def len(x):\n    return x\n", "built-in");
    expectError("def f(a, a):\n    return a\n", "named twice");
}

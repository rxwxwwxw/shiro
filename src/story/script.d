// Tiny condition / effect language for story data, compiled once at load into flat records.
//
//   conditions:  met_elder & !gate_open & gold_bonus >= 50     (ops: == != >= <= > <)
//   effects:     set met_elder | set gold_bonus 30 | clear gate_open | add gold_bonus -10 | event gate
//
// Model layer: no SDL; parsing is cold, evaluation is @nogc nothrow and allocation-free.
module story.script;

import story.state;

enum CondOp : ubyte {
    truthy,
    falsy,
    eq,
    ne,
    ge,
    le,
    gt,
    lt
}

struct Cond {
    CondOp op;
    short var;
    int value;
}

enum EffectOp : ubyte {
    /// var = value (1 when the effect gives no number).
    set,
    clear,
    add,
    /// Raises a named story event for the controller (the id is an event id, not a variable).
    event
}

struct Effect {
    EffectOp op;
    short id;
    int value;
}

/// Story events raised by effects during one step; the controller drains them.
struct StoryEvents {
    enum int capacity = 16;
    short[capacity] ids;
    int length;

    void push(short id) @nogc nothrow pure @safe {
        if (length < capacity)
            ids[length++] = id;
    }

    void clear() @nogc nothrow pure @safe {
        length = 0;
    }

    bool has(short id) const @nogc nothrow pure @safe {
        foreach (i; 0 .. length)
            if (ids[i] == id)
                return true;
        return false;
    }
}

/// Interns event names for `parseEffect` (the story database owns the event table).
alias EventInterner = int delegate(const(char)[] name) @nogc nothrow;

private bool isNameChar(char c) @nogc nothrow pure @safe {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private void skipSpaces(const(char)[] s, ref size_t i) @nogc nothrow pure @safe {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
        i++;
}

private const(char)[] readName(const(char)[] s, ref size_t i) @nogc nothrow pure @safe {
    immutable start = i;
    while (i < s.length && isNameChar(s[i]))
        i++;
    return s[start .. i];
}

private bool readInt(const(char)[] s, ref size_t i, out int v) @nogc nothrow pure @safe {
    bool neg;
    if (i < s.length && (s[i] == '-' || s[i] == '+'))
        neg = s[i++] == '-';
    immutable start = i;
    long acc = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') {
        acc = acc * 10 + (s[i++] - '0');
        if (acc > int.max)
            return false;
    }
    v = cast(int)(neg ? -acc : acc);
    return i > start;
}

/// Compiles `text` into `dst`; returns the number of terms (0 for empty text: always true) or -1
/// on a syntax error, an un-internable name or too many terms.
ptrdiff_t parseCondition(const(char)[] text, ref StoryState st, Cond[] dst) @nogc nothrow @safe {
    size_t i = 0, n = 0;
    skipSpaces(text, i);
    if (i == text.length)
        return 0;
    while (true) {
        skipSpaces(text, i);
        bool negate;
        if (i < text.length && text[i] == '!') {
            negate = true;
            i++;
            skipSpaces(text, i);
        }
        const name = readName(text, i);
        immutable id = st.intern(name);
        if (id < 0 || n == dst.length)
            return -1;
        Cond c = Cond(negate ? CondOp.falsy : CondOp.truthy, cast(short)id, 0);
        skipSpaces(text, i);
        if (!negate && i < text.length && text[i] != '&') {
            const two = i + 1 < text.length ? text[i .. i + 2] : text[i .. i + 1];
            if (two == "==" || two == "!=" || two == ">=" || two == "<=") {
                c.op = two == "==" ? CondOp.eq : (two == "!=" ? CondOp.ne : (two == ">=" ? CondOp.ge : CondOp.le));
                i += 2;
            } else if (text[i] == '>' || text[i] == '<') {
                c.op = text[i] == '>' ? CondOp.gt : CondOp.lt;
                i++;
            } else
                return -1;
            skipSpaces(text, i);
            if (!readInt(text, i, c.value))
                return -1;
            skipSpaces(text, i);
        }
        dst[n++] = c;
        if (i == text.length)
            return n;
        if (text[i] != '&')
            return -1;
        i++;
    }
}

/// True when every term holds (an empty list always holds).
bool evaluate(const(Cond)[] cs, ref const StoryState st) @nogc nothrow @safe {
    foreach (c; cs) {
        immutable v = st.get(c.var);
        bool ok;
        final switch (c.op) {
        case CondOp.truthy:
            ok = v != 0;
            break;
        case CondOp.falsy:
            ok = v == 0;
            break;
        case CondOp.eq:
            ok = v == c.value;
            break;
        case CondOp.ne:
            ok = v != c.value;
            break;
        case CondOp.ge:
            ok = v >= c.value;
            break;
        case CondOp.le:
            ok = v <= c.value;
            break;
        case CondOp.gt:
            ok = v > c.value;
            break;
        case CondOp.lt:
            ok = v < c.value;
            break;
        }
        if (!ok)
            return false;
    }
    return true;
}

/// Compiles one effect statement; false on a syntax error or an un-internable name.
bool parseEffect(const(char)[] text, ref StoryState st, scope EventInterner events, out Effect e) @nogc nothrow @trusted {
    size_t i = 0;
    skipSpaces(text, i);
    const verb = readName(text, i);
    skipSpaces(text, i);
    const name = readName(text, i);
    skipSpaces(text, i);
    int value = 1;
    bool haveValue;
    if (i < text.length) {
        if (!readInt(text, i, value))
            return false;
        haveValue = true;
        skipSpaces(text, i);
    }
    if (i != text.length || name.length == 0)
        return false;
    if (verb == "event") {
        immutable id = events is null ? -1 : events(name);
        if (id < 0 || haveValue)
            return false;
        e = Effect(EffectOp.event, cast(short)id, 0);
        return true;
    }
    EffectOp op;
    if (verb == "set")
        op = EffectOp.set;
    else if (verb == "clear" && !haveValue)
        op = EffectOp.clear;
    else if (verb == "add" && haveValue)
        op = EffectOp.add;
    else
        return false;
    immutable id = st.intern(name);
    if (id < 0)
        return false;
    e = Effect(op, cast(short)id, op == EffectOp.clear ? 0 : value);
    return true;
}

void apply(ref const Effect e, ref StoryState st, ref StoryEvents ev) @nogc nothrow @safe {
    final switch (e.op) {
    case EffectOp.set:
        st.set(e.id, e.value);
        break;
    case EffectOp.clear:
        st.set(e.id, 0);
        break;
    case EffectOp.add:
        st.add(e.id, e.value);
        break;
    case EffectOp.event:
        ev.push(e.id);
        break;
    }
}

void apply(const(Effect)[] es, ref StoryState st, ref StoryEvents ev) @nogc nothrow @safe {
    foreach (ref e; es)
        apply(e, st, ev);
}

@nogc nothrow @safe unittest {
    StoryState st;
    Cond[8] cs;
    assert(parseCondition("", st, cs[]) == 0 && parseCondition("   ", st, cs[]) == 0);
    immutable n = parseCondition("met_elder & !gate_open&gold >= 50 & runs<3", st, cs[]);
    assert(n == 4);
    assert(cs[0].op == CondOp.truthy && cs[1].op == CondOp.falsy && cs[2].op == CondOp.ge
            && cs[2].value == 50 && cs[3].op == CondOp.lt && cs[3].value == 3);
    assert(!evaluate(cs[0 .. n], st));
    st.set(st.find("met_elder"), 1);
    st.set(st.find("gold"), 50);
    assert(evaluate(cs[0 .. n], st));
    st.set(st.find("gate_open"), 1);
    assert(!evaluate(cs[0 .. n], st));
    assert(evaluate(cs[0 .. 0], st));

    Cond[2] small;
    assert(parseCondition("a & b & c", st, small[]) == -1);
    assert(parseCondition("a &", st, cs[]) == -1);
    assert(parseCondition("a >= ", st, cs[]) == -1);
    assert(parseCondition("a ~ 3", st, cs[]) == -1);
    assert(parseCondition("!a == 3", st, cs[]) == -1);
    assert(parseCondition("x == -2 & y != 0", st, cs[]) == 2 && cs[0].value == -2 && cs[1].op == CondOp.ne);
}

@nogc nothrow unittest {
    StoryState st;
    int intern(const(char)[] name) @nogc nothrow {
        return name == "gate" ? 0 : (name == "td" ? 1 : -1);
    }

    Effect e;
    StoryEvents ev;
    assert(parseEffect("set met_elder", st, &intern, e) && e.op == EffectOp.set && e.value == 1);
    apply(e, st, ev);
    assert(st.named("met_elder") == 1);
    assert(parseEffect(" add gold -15 ", st, &intern, e) && e.value == -15);
    apply(e, st, ev);
    apply(e, st, ev);
    assert(st.named("gold") == -30);
    assert(parseEffect("set gold 7", st, &intern, e));
    apply(e, st, ev);
    assert(st.named("gold") == 7);
    assert(parseEffect("clear gold", st, &intern, e));
    apply(e, st, ev);
    assert(st.named("gold") == 0);
    assert(parseEffect("event td", st, &intern, e) && e.op == EffectOp.event && e.id == 1);
    apply(e, st, ev);
    assert(ev.length == 1 && ev.has(1) && !ev.has(0));

    assert(!parseEffect("event unknown", st, &intern, e));
    assert(!parseEffect("event gate 3", st, &intern, e));
    assert(!parseEffect("add gold", st, &intern, e));
    assert(!parseEffect("clear gold 2", st, &intern, e));
    assert(!parseEffect("explode gold", st, &intern, e));
    assert(!parseEffect("set", st, &intern, e));
    assert(!parseEffect("set a b", st, &intern, e));
}

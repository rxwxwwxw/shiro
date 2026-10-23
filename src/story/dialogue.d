// Story database (speakers, dialogue nodes with choices, triggers) compiled once from JSON, and
// the dialogue runner that walks it. The controller reads the file; this module only sees bytes.
//
//   {
//     "speakers": [{"id": "elder", "name": "Bà Lan", "portrait": "elder", "figure": "elder", "sprite": 1}],
//     "nodes": [{"id": "elder_hi", "speaker": "elder", "expr": "happy", "text": "...",
//                "effects": ["set met_elder"], "next": "elder_hi2",
//                "choices": [{"text": "...", "if": "!gate_open", "effects": ["add gold 10"], "next": "..."}]}],
//     "triggers": [{"on": "talk", "target": "elder", "if": "!met_elder", "node": "elder_hi", "once": true}]
//   }
//
// Model layer: no SDL. Loading allocates (cold path, malloc only); the runner is @nogc nothrow.
module story.dialogue;

import core.json;
import core.stdc.stdlib : free, malloc, realloc;
import story.events;
import story.script;
import story.state;

enum StoryError : ubyte {
    none,
    badJson,
    missingField,
    duplicateId,
    unknownNode,
    unknownSpeaker,
    badCondition,
    badEffect,
    badTrigger,
    tooMany,
    outOfMemory
}

/// Most choices a node shows at once (the UI maps them to keys 1..maxChoices).
enum int maxChoices = 6;
/// Most terms in one condition.
private enum int maxCondTerms = 8;

struct Speaker {
    const(char)[] id, name, portrait, figure;
    /// Row of the speaker's walk sheet in the villager sprite atlas, or -1.
    int sprite = -1;
}

struct Choice {
    const(char)[] text;
    uint condStart, condLen;
    uint effStart, effLen;
    int next = -1;
}

struct Node {
    const(char)[] id;
    int speaker = -1;
    const(char)[] expr, text;
    uint effStart, effLen;
    uint choiceStart, choiceLen;
    int next = -1;
}

/// Growable malloc'd array for the cold load path.
private struct Pool(T) {
    T* ptr;
    uint length, cap;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(ptr);
    }

    bool push(T v) @nogc nothrow @trusted {
        if (length == cap) {
            immutable n = cap ? cap * 2 : 16;
            auto p = cast(T*)realloc(ptr, n * T.sizeof);
            if (p is null)
                return false;
            ptr = p;
            cap = n;
        }
        ptr[length++] = v;
        return true;
    }

    inout(T)[] slice() inout return @nogc nothrow @trusted {
        return ptr is null ? null : ptr[0 .. length];
    }

    void clear() @nogc nothrow @safe {
        length = 0;
    }
}

struct DialogueDb {
    private Pool!Speaker speakers_;
    private Pool!Node nodes_;
    private Pool!Choice choices_;
    private Pool!Cond conds_;
    private Pool!Effect effects_;
    private Pool!Trigger triggers_;
    private Pool!(const(char)[]) events_;
    /// Owns every string the records point at (unescaped copies out of the source JSON).
    private char* arena;
    private size_t arenaLen, arenaCap;
    private char[96] errBuf;
    private size_t errLen;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(arena);
    }

    const(Speaker)[] speakers() const return @nogc nothrow @safe {
        return speakers_.slice;
    }

    const(Node)[] nodes() const return @nogc nothrow @safe {
        return nodes_.slice;
    }

    const(Choice)[] choices() const return @nogc nothrow @safe {
        return choices_.slice;
    }

    const(Cond)[] conds() const return @nogc nothrow @safe {
        return conds_.slice;
    }

    const(Effect)[] effects() const return @nogc nothrow @safe {
        return effects_.slice;
    }

    const(Trigger)[] triggers() const return @nogc nothrow @safe {
        return triggers_.slice;
    }

    const(char)[][] eventNames() const return @nogc nothrow @trusted {
        return cast(const(char)[][])events_.slice;
    }

    /// The id (and field) the last failed `load` stopped at.
    const(char)[] errorContext() const return @nogc nothrow @safe {
        return errBuf[0 .. errLen];
    }

    int findNode(const(char)[] id) const @nogc nothrow @safe {
        foreach (i, ref n; nodes_.slice)
            if (n.id == id)
                return cast(int)i;
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

    /// Effects-and-dialogue of the first matching trigger (see story.events); -1 when none fires.
    int trigger(TriggerKind kind, const(char)[] target, ref StoryState st, ref StoryEvents ev, out int node) const @nogc nothrow @safe {
        node = -1;
        immutable t = pickTrigger(triggers_.slice, conds_.slice, kind, target, st);
        if (t >= 0)
            node = fireTrigger(triggers_.slice[t], effects_.slice, st, ev);
        return t;
    }

    /// Compiles `text`, interning every flag and variable it names into `st`. On failure the
    /// database is left empty and `errorContext` names the offending record.
    StoryError load(const(char)[] text, ref StoryState st) @nogc nothrow @trusted {
        clearAll();
        immutable e = loadImpl(text, st);
        if (e != StoryError.none)
            clearAll();
        return e;
    }

    private void clearAll() @nogc nothrow @safe {
        speakers_.clear();
        nodes_.clear();
        choices_.clear();
        conds_.clear();
        effects_.clear();
        triggers_.clear();
        events_.clear();
    }

    private void setError(const(char)[] what, const(char)[] id) @nogc nothrow @safe {
        errLen = 0;
        foreach (part; [what, ": ", id])
            foreach (c; part)
                if (errLen < errBuf.length)
                    errBuf[errLen++] = c;
    }

    /// Copies string token `t` (unescaped) into the arena; null for a missing token.
    private bool copyString(ref const Json j, int t, out const(char)[] dst) @nogc nothrow @trusted {
        if (t < 0)
            return true;
        if (!j.isString(t))
            return false;
        immutable n = j.unescape(t, arena[arenaLen .. arenaCap]);
        if (n < 0)
            return false;
        dst = arena[arenaLen .. arenaLen + n];
        arenaLen += n;
        return true;
    }

    private int internEvent(const(char)[] name) @nogc nothrow @trusted {
        immutable f = findEvent(name);
        if (f >= 0)
            return f;
        if (name.length == 0 || events_.length >= short.max)
            return -1;
        // Event names point into the source text only until load returns, so copy them.
        if (arenaLen + name.length > arenaCap)
            return -1;
        arena[arenaLen .. arenaLen + name.length] = name[];
        events_.push(arena[arenaLen .. arenaLen + name.length]);
        arenaLen += name.length;
        return events_.length - 1;
    }

    private StoryError condition(ref const Json j, int t, ref StoryState st, out uint start, out uint len) @nogc nothrow @trusted {
        start = conds_.length;
        if (t < 0)
            return StoryError.none;
        Cond[maxCondTerms] buf;
        immutable n = j.isString(t) ? parseCondition(j.str(t), st, buf[]) : -1;
        if (n < 0)
            return StoryError.badCondition;
        foreach (ref c; buf[0 .. n])
            if (!conds_.push(c))
                return StoryError.outOfMemory;
        len = cast(uint)n;
        return StoryError.none;
    }

    private StoryError effectList(ref const Json j, int t, ref StoryState st, out uint start, out uint len) @nogc nothrow @trusted {
        start = effects_.length;
        if (t < 0)
            return StoryError.none;
        if (j.tok(t).kind != JsonKind.array)
            return StoryError.badEffect;
        foreach (i; 0 .. j.length(t)) {
            immutable e = j.at(t, i);
            Effect fx;
            if (!j.isString(e) || !parseEffect(j.str(e), st, &internEvent, fx))
                return StoryError.badEffect;
            if (!effects_.push(fx))
                return StoryError.outOfMemory;
        }
        len = cast(uint)j.length(t);
        return StoryError.none;
    }

    /// Node index for the optional "next" / "node" field `t`: -1 when absent, -2 when unknown.
    private int nodeRef(ref const Json j, int t) const @nogc nothrow @trusted {
        if (t < 0)
            return -1;
        if (!j.isString(t))
            return -2;
        immutable f = findNode(j.str(t));
        return f >= 0 ? f : -2;
    }

    private StoryError loadImpl(const(char)[] text, ref StoryState st) @nogc nothrow @trusted {
        errLen = 0;
        Json j;
        if (!j.parse(text) || j.tok(0).kind != JsonKind.object) {
            setError("json", "malformed");
            return StoryError.badJson;
        }
        // Unescaped strings never outgrow their quoted source, so the source length bounds the arena.
        free(arena);
        arenaCap = text.length;
        arenaLen = 0;
        arena = cast(char*)malloc(arenaCap ? arenaCap : 1);
        if (arena is null)
            return StoryError.outOfMemory;

        immutable sp = j.get(0, "speakers"), nd = j.get(0, "nodes"), tr = j.get(0, "triggers");
        if (nd < 0 || j.tok(nd).kind != JsonKind.array) {
            setError("missing", "nodes");
            return StoryError.missingField;
        }
        foreach (i; 0 .. j.length(sp)) {
            immutable o = j.at(sp, i);
            Speaker s;
            if (!copyString(j, j.get(o, "id"), s.id) || s.id.length == 0) {
                setError("speaker", "id");
                return StoryError.missingField;
            }
            if (findSpeaker(s.id) >= 0) {
                setError("duplicate speaker", s.id);
                return StoryError.duplicateId;
            }
            if (!copyString(j, j.get(o, "name"), s.name) || !copyString(j, j.get(o, "portrait"),
                    s.portrait) || !copyString(j, j.get(o, "figure"), s.figure)) {
                setError("speaker", s.id);
                return StoryError.missingField;
            }
            s.sprite = j.integer(j.get(o, "sprite"), -1);
            if (!speakers_.push(s))
                return StoryError.outOfMemory;
        }

        // Pass 1: node ids, so "next" may point forward.
        foreach (i; 0 .. j.length(nd)) {
            Node n;
            if (!copyString(j, j.get(j.at(nd, i), "id"), n.id) || n.id.length == 0) {
                setError("node", "id");
                return StoryError.missingField;
            }
            if (findNode(n.id) >= 0) {
                setError("duplicate node", n.id);
                return StoryError.duplicateId;
            }
            if (!nodes_.push(n))
                return StoryError.outOfMemory;
        }
        // Pass 2: the bodies.
        foreach (i; 0 .. j.length(nd)) {
            immutable o = j.at(nd, i);
            auto n = &nodes_.ptr[i];
            immutable spk = j.get(o, "speaker");
            if (spk >= 0) {
                n.speaker = j.isString(spk) ? findSpeaker(j.str(spk)) : -1;
                if (n.speaker < 0) {
                    setError("unknown speaker in", n.id);
                    return StoryError.unknownSpeaker;
                }
            }
            if (!copyString(j, j.get(o, "expr"), n.expr) || !copyString(j, j.get(o, "text"), n.text)) {
                setError("node text", n.id);
                return StoryError.missingField;
            }
            if (effectList(j, j.get(o, "effects"), st, n.effStart, n.effLen) != StoryError.none) {
                setError("node effects", n.id);
                return StoryError.badEffect;
            }
            n.next = nodeRef(j, j.get(o, "next"));
            if (n.next == -2) {
                setError("unknown next in", n.id);
                return StoryError.unknownNode;
            }
            immutable ch = j.get(o, "choices");
            n.choiceStart = choices_.length;
            if (j.length(ch) > maxChoices) {
                setError("too many choices", n.id);
                return StoryError.tooMany;
            }
            foreach (k; 0 .. j.length(ch)) {
                immutable co = j.at(ch, k);
                Choice c;
                if (!copyString(j, j.get(co, "text"), c.text) || c.text.length == 0) {
                    setError("choice text", n.id);
                    return StoryError.missingField;
                }
                if (condition(j, j.get(co, "if"), st, c.condStart, c.condLen) != StoryError.none) {
                    setError("choice condition", n.id);
                    return StoryError.badCondition;
                }
                if (effectList(j, j.get(co, "effects"), st, c.effStart, c.effLen) != StoryError.none) {
                    setError("choice effects", n.id);
                    return StoryError.badEffect;
                }
                c.next = nodeRef(j, j.get(co, "next"));
                if (c.next == -2) {
                    setError("unknown choice next in", n.id);
                    return StoryError.unknownNode;
                }
                if (!choices_.push(c))
                    return StoryError.outOfMemory;
            }
            n.choiceLen = j.length(ch);
        }

        foreach (i; 0 .. j.length(tr)) {
            immutable o = j.at(tr, i);
            Trigger t;
            const on = j.str(j.get(o, "on"));
            if (on == "start")
                t.on = TriggerKind.start;
            else if (on == "talk")
                t.on = TriggerKind.talk;
            else if (on == "enter")
                t.on = TriggerKind.enter;
            else if (on == "return")
                t.on = TriggerKind.returned;
            else {
                setError("trigger kind", on);
                return StoryError.badTrigger;
            }
            if (!copyString(j, j.get(o, "target"), t.target)) {
                setError("trigger target", on);
                return StoryError.badTrigger;
            }
            if ((t.on == TriggerKind.talk || t.on == TriggerKind.enter) && t.target.length == 0) {
                setError("trigger needs a target", on);
                return StoryError.badTrigger;
            }
            if (condition(j, j.get(o, "if"), st, t.condStart, t.condLen) != StoryError.none) {
                setError("trigger condition", t.target);
                return StoryError.badCondition;
            }
            if (effectList(j, j.get(o, "effects"), st, t.effStart, t.effLen) != StoryError.none) {
                setError("trigger effects", t.target);
                return StoryError.badEffect;
            }
            t.node = nodeRef(j, j.get(o, "node"));
            if (t.node == -2) {
                setError("unknown trigger node for", t.target);
                return StoryError.unknownNode;
            }
            if (j.boolean(j.get(o, "once"))) {
                // Spent-markers are ordinary variables, named after the trigger's position.
                char[12] nm = "_trig000";
                nm[5] = cast(char)('0' + i / 100 % 10);
                nm[6] = cast(char)('0' + i / 10 % 10);
                nm[7] = cast(char)('0' + i % 10);
                immutable v = i < 1000 ? st.intern(nm[0 .. 8]) : -1;
                if (v < 0) {
                    setError("too many story variables at trigger", t.target);
                    return StoryError.tooMany;
                }
                t.onceVar = cast(short)v;
            }
            if (!triggers_.push(t))
                return StoryError.outOfMemory;
        }
        return StoryError.none;
    }

    /// First node that no trigger, `next` or choice can lead to, or -1 when every node is reachable.
    int unreachableNode() const @nogc nothrow @trusted {
        immutable n = nodes_.length;
        if (n == 0)
            return -1;
        auto seen = cast(bool*)malloc(n);
        auto stack = cast(int*)malloc(n * int.sizeof);
        assert(seen && stack, "reachability allocation failed");
        scope (exit) {
            free(seen);
            free(stack);
        }
        seen[0 .. n] = false;
        uint top = 0;
        void visit(int i) {
            if (i >= 0 && !seen[i]) {
                seen[i] = true;
                stack[top++] = i;
            }
        }

        foreach (ref t; triggers_.slice)
            visit(t.node);
        while (top > 0) {
            const node = &nodes_.ptr[stack[--top]];
            visit(node.next);
            foreach (ref c; choices_.slice[node.choiceStart .. node.choiceStart + node.choiceLen])
                visit(c.next);
        }
        foreach (i; 0 .. n)
            if (!seen[i])
                return i;
        return -1;
    }
}

/// Walks one conversation: shows a node, filters its choices by condition, applies effects and
/// follows `next` links. Effects mutate the caller's StoryState and raise events into `ev`.
struct DialogueRunner {
    private const(DialogueDb)* db;
    private int node_ = -1;
    private ubyte[maxChoices] visible;
    private int numVisible;

    bool active() const @nogc nothrow pure @safe {
        return node_ >= 0;
    }

    int nodeIndex() const @nogc nothrow pure @safe {
        return node_;
    }

    /// The line on screen; only valid while `active`.
    ref const(Node) line() const return @nogc nothrow @trusted {
        assert(active);
        return db.nodes[node_];
    }

    /// The speaker of the line on screen, or null for narration.
    const(Speaker)* speaker() const return @nogc nothrow @trusted {
        if (!active || line.speaker < 0)
            return null;
        return &db.speakers[line.speaker];
    }

    /// Choices whose condition held when the line was shown.
    int choiceCount() const @nogc nothrow pure @safe {
        return active ? numVisible : 0;
    }

    ref const(Choice) choice(int i) const return @nogc nothrow @trusted {
        assert(i >= 0 && i < numVisible);
        return db.choices[line.choiceStart + visible[i]];
    }

    /// Opens node `n` of `d` (ending at once when `n` is -1).
    void start(ref const DialogueDb d, int n, ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        db = &d;
        enter(n, st, ev);
    }

    /// Closes the conversation without following any link.
    void stop() @nogc nothrow pure @safe {
        node_ = -1;
        numVisible = 0;
    }

    /// Picks visible choice `i`; false (nothing happens) when it is out of range.
    bool choose(int i, ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        if (i < 0 || i >= choiceCount)
            return false;
        const c = &choice(i);
        apply(db.effects[c.effStart .. c.effStart + c.effLen], st, ev);
        enter(c.next, st, ev);
        return true;
    }

    /// Continues past a line that offers no choices; false while choices are waiting.
    bool advance(ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        if (!active || numVisible > 0)
            return false;
        enter(line.next, st, ev);
        return true;
    }

    private void enter(int n, ref StoryState st, ref StoryEvents ev) @nogc nothrow @trusted {
        node_ = n;
        numVisible = 0;
        if (n < 0)
            return;
        const node = &db.nodes[n];
        apply(db.effects[node.effStart .. node.effStart + node.effLen], st, ev);
        foreach (k; 0 .. node.choiceLen) {
            const c = &db.choices[node.choiceStart + k];
            if (evaluate(db.conds[c.condStart .. c.condStart + c.condLen], st))
                visible[numVisible++] = cast(ubyte)k;
        }
    }
}

version (unittest) {
    private immutable sampleStory = `{
      "speakers": [
        {"id": "elder", "name": "Bà Lan", "portrait": "elder", "figure": "elder", "sprite": 1},
        {"id": "guard", "name": "Guard", "sprite": 5}
      ],
      "nodes": [
        {"id": "hi", "speaker": "elder", "expr": "happy", "text": "Welcome, child.\nSit.",
         "effects": ["set met_elder"], "next": "ask"},
        {"id": "ask", "speaker": "elder", "text": "Will you guard the west road?",
         "choices": [
           {"text": "I will.", "effects": ["set elder_blessing", "add gold_bonus 50", "event gate"], "next": "thanks"},
           {"text": "Tell me more.", "if": "!asked", "effects": ["set asked"], "next": "ask"},
           {"text": "Not yet."}
         ]},
        {"id": "thanks", "speaker": "elder", "expr": "happy", "text": "Go well."},
        {"id": "guard_no", "speaker": "guard", "text": "The elder has not sent you."},
        {"id": "orphan", "text": "Nobody reaches me."}
      ],
      "triggers": [
        {"on": "talk", "target": "elder", "if": "!met_elder", "node": "hi"},
        {"on": "talk", "target": "elder", "node": "ask"},
        {"on": "enter", "target": "gate", "if": "!elder_blessing", "node": "guard_no"},
        {"on": "start", "effects": ["add runs 1"], "once": true}
      ]
    }`;
}

@nogc nothrow unittest {
    StoryState st;
    DialogueDb db;
    assert(db.load(sampleStory, st) == StoryError.none);
    assert(db.speakers.length == 2 && db.nodes.length == 5 && db.triggers.length == 4);
    assert(db.speakers[0].name == "Bà Lan" && db.speakers[1].portrait.length == 0);
    assert(db.nodes[0].text == "Welcome, child.\nSit." && db.findEvent("gate") == 0);
    assert(db.unreachableNode() == db.findNode("orphan"));

    StoryEvents ev;
    int node;
    assert(db.trigger(TriggerKind.start, null, st, ev, node) == 3 && node == -1);
    assert(st.named("runs") == 1 && db.trigger(TriggerKind.start, null, st, ev, node) == -1);

    DialogueRunner r;
    assert(db.trigger(TriggerKind.talk, "elder", st, ev, node) == 0);
    r.start(db, node, st, ev);
    assert(r.active && r.speaker.id == "elder" && r.choiceCount == 0 && st.named("met_elder") == 1);
    assert(!r.choose(0, st, ev) && r.advance(st, ev));
    assert(r.line.id == "ask" && r.choiceCount == 3);
    // "Tell me more" loops back once, then hides itself.
    assert(r.choose(1, st, ev) && r.line.id == "ask" && r.choiceCount == 2);
    assert(r.choice(1).text == "Not yet." && !r.advance(st, ev));
    assert(r.choose(0, st, ev) && r.line.id == "thanks" && ev.has(cast(short)db.findEvent("gate")));
    assert(st.named("gold_bonus") == 50 && st.named("elder_blessing") == 1);
    assert(r.advance(st, ev) && !r.active && r.speaker is null);

    // Once blessed, the guard trigger no longer fires; the second elder trigger takes over.
    assert(db.trigger(TriggerKind.enter, "gate", st, ev, node) == -1);
    assert(db.trigger(TriggerKind.talk, "elder", st, ev, node) == 1 && node == db.findNode("ask"));
}

@nogc nothrow unittest {
    StoryState st;
    DialogueDb db;
    assert(db.load(`{"nodes": [{"id": "a", "next": "b"}]}`, st) == StoryError.unknownNode);
    assert(db.errorContext == "unknown next in: a" && db.nodes.length == 0);
    assert(db.load(`{"nodes": [{"id": "a"}, {"id": "a"}]}`, st) == StoryError.duplicateId);
    assert(db.load(`{"nodes": [{"id": "a", "speaker": "nobody"}]}`, st) == StoryError.unknownSpeaker);
    assert(db.load(`{"nodes": [{"id": "a", "effects": ["explode"]}]}`, st) == StoryError.badEffect);
    assert(db.load(`{"nodes": [{"id": "a", "choices": [{"text": "x", "if": "a >"}]}]}`, st) == StoryError.badCondition);
    assert(db.load(`{"nodes": [], "triggers": [{"on": "talk"}]}`, st) == StoryError.badTrigger);
    assert(db.load(`{"nodes": [], "triggers": [{"on": "dance", "target": "x"}]}`, st) == StoryError.badTrigger);
    assert(db.load(`{"speakers": []}`, st) == StoryError.missingField);
    assert(db.load(`{"nodes": [`, st) == StoryError.badJson);
    assert(db.load(`{"nodes": [{"id": "a"}]}`, st) == StoryError.none && db.unreachableNode() == 0);
    // Loading again replaces the old story rather than adding to it.
    assert(db.load(sampleStory, st) == StoryError.none && db.load(sampleStory, st) == StoryError.none);
    assert(db.nodes.length == 5 && db.speakers.length == 2);
}

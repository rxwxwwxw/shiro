/** Cold CTFE Thompson/subset compiler and allocation-free byte scanner.
    Callers must establish equivalence between PEG and regular-language semantics. */
module npegged.dfa;

import npegged.peg : CharSetMask, State, Status, ParseContext, CheckResult;
import npegged.records : RecordBuffer;

version (NPeggedScannerMetrics) import npegged.peg : ScannerEvent, ScannerReason;

nothrow:

enum RegularKind {
    bytes,
    sequence,
    choice,
    optional,
    repetition,
    endOfInput,
    /// O4: an output event on the path (`bytes.bits[0]`: 0 opens a leaf record, kind + 1 finishes it). Transparent to `compileDFA`.
    mark,
    /// X2: zero-width; the next byte must not be in `bytes` (the end of input passes). Marks where a maximal-munch token
    /// may stop: its extensions take precedence.
    guard
}

/// Children precede their parents; references and actions are deliberately absent.
struct RegularExpression {
    RegularKind kind;
    CharSetMask bytes;
    size_t[] children;
}

/// Compact constructors keep generated automaton graphs readable and stable under dfmt.
RegularExpression regularByte(ulong b0, ulong b1, ulong b2, ulong b3) @nogc pure nothrow @safe {
    return RegularExpression(RegularKind.bytes, CharSetMask([b0, b1, b2, b3]));
}

@nogc nothrow unittest {
    const node = regularByte(1, 2, 3, 4);
    assert(node.kind == RegularKind.bytes && node.bytes.bits == [1UL, 2UL, 3UL, 4UL]);
}

RegularExpression regularMark(ulong event) @nogc pure nothrow @safe {
    return RegularExpression(RegularKind.mark, CharSetMask([event, 0, 0, 0]));
}

RegularExpression regularGuard(ulong b0, ulong b1, ulong b2, ulong b3) @nogc pure nothrow @safe {
    return RegularExpression(RegularKind.guard, CharSetMask([b0, b1, b2, b3]));
}

RegularExpression regularNode(RegularKind kind, size_t[] children) @nogc pure nothrow @safe {
    return RegularExpression(kind, CharSetMask.init, children);
}

@nogc nothrow unittest {
    size_t[2] children = [0, 1];
    const node = regularNode(RegularKind.sequence, children[]);
    assert(node.children == children[] && node.kind == RegularKind.sequence);
}

struct Automaton {
    ubyte[256][] transitions;
    bool[] accepting;
    bool valid;
    bool requireEnd;
    /// Extra accepting states enabled only after the last input byte.
    bool[] eofAccepting;
}

private struct NfaState {
    size_t[] epsilon;
    size_t[] eofEpsilon;
    CharSetMask bytes;
    size_t target = size_t.max;
}

/// Bounded construction and determinization fall back without exhausting CTFE storage.
Automaton compileDFA(const(RegularExpression)[] expressions, size_t root, bool requireEnd = false,
        size_t stateLimit = ubyte.max, size_t nfaLimit = 4096) pure {
    Automaton result;
    if (root >= expressions.length || !stateLimit || stateLimit > ubyte.max || nfaLimit < 2)
        return result;
    foreach (expression; expressions)
        if (expression.kind == RegularKind.guard)
            return compileGuardedDFA(expressions, root, requireEnd, stateLimit, nfaLimit);
    const maxStates = expressions.length * 4 + 4 < nfaLimit + 2 ? expressions.length * 4 + 4 : nfaLimit + 2;
    auto stateBuf = new NfaState[maxStates];
    size_t stateCount;
    struct Fragment {
        size_t begin, end;
    }

    bool malformed;
    bool hasEnd;
    Fragment build(size_t index, size_t depth = 0) {
        if (stateCount > nfaLimit - 2 || stateCount + 2 > stateBuf.length || depth >= 128) {
            malformed = true;
            return Fragment.init;
        }
        alias states = stateBuf;
        auto node = expressions[index];
        // Output events are invisible to the plain automaton: a mark is an empty sequence.
        const kind = node.kind == RegularKind.mark ? RegularKind.sequence : node.kind;
        if (kind == RegularKind.sequence && node.children.length == 1) {
            if (node.children[0] >= index) {
                malformed = true;
                return Fragment.init;
            }
            return build(node.children[0], depth + 1);
        }
        const begin = stateCount++;
        const end = stateCount++;
        if (kind == RegularKind.bytes) {
            states[begin].bytes = node.bytes;
            states[begin].target = end;
        } else if (kind == RegularKind.endOfInput) {
            hasEnd = true;
            malformed = node.children.length != 0;
            states[begin].eofEpsilon ~= end;
        } else {
            size_t previous = begin;
            foreach (child; node.children) {
                if (child >= index) {
                    malformed = true;
                    return Fragment(begin, end);
                }
                const savedCount = stateCount;
                const part = build(child, depth + 1);
                if (malformed)
                    return Fragment(begin, end);
                if (kind == RegularKind.sequence) {
                    states[previous].epsilon ~= part.begin;
                    previous = part.end;
                } else if (kind == RegularKind.choice && part.begin == savedCount
                        && part.end == savedCount + 1 && stateCount == savedCount + 2
                        && states[part.begin].target == part.end && !states[part.begin].epsilon.length
                        && !states[part.begin].eofEpsilon.length) {
                    states[begin].bytes = states[begin].bytes | states[part.begin].bytes;
                    states[begin].target = end;
                    states[part.begin] = NfaState.init;
                    stateCount = savedCount;
                } else {
                    states[begin].epsilon ~= part.begin;
                    states[part.end].epsilon ~= end;
                    if (kind == RegularKind.repetition)
                        states[part.end].epsilon ~= part.begin;
                }
            }
            if (kind == RegularKind.sequence)
                states[previous].epsilon ~= end;
            else if (kind == RegularKind.optional || kind == RegularKind.repetition) {
                if (node.children.length != 1)
                    malformed = true;
                states[begin].epsilon ~= end;
            }
        }
        return Fragment(begin, end);
    }

    const fragment = build(root);
    if (malformed)
        return result;
    auto states = stateBuf[0 .. stateCount];
    auto pending = new size_t[states.length];
    bool[] closure(bool[] set, bool atEnd = false) {
        size_t tail;
        foreach (i, present; set)
            if (present)
                pending[tail++] = i;
        while (tail) {
            const current = pending[--tail];
            foreach (next; states[current].epsilon)
                if (!set[next]) {
                    set[next] = true;
                    pending[tail++] = next;
                }
            if (atEnd)
                foreach (next; states[current].eofEpsilon)
                    if (!set[next]) {
                        set[next] = true;
                        pending[tail++] = next;
                    }
        }
        return set;
    }

    auto initial = new bool[states.length];
    initial[fragment.begin] = true;
    bool[][] subsets = [closure(initial)];
    auto active = new size_t[states.length];
    for (size_t current; current < subsets.length; ++current) {
        ubyte[256] row = ubyte.max;
        size_t activeLen;
        CharSetMask remaining;
        foreach (i, present; subsets[current])
            if (present && states[i].target != size_t.max) {
                active[activeLen++] = i;
                remaining = remaining | states[i].bytes;
            }
        for (size_t byteValue; byteValue < 256 && !remaining.empty; ++byteValue) {
            if (!remaining.contains(cast(ubyte)byteValue))
                continue;
            CharSetMask same = remaining;
            auto next = new bool[states.length];
            foreach (k; 0 .. activeLen) {
                const i = active[k];
                if (states[i].bytes.contains(cast(ubyte)byteValue)) {
                    next[states[i].target] = true;
                    same = same & states[i].bytes;
                } else {
                    same = same & ~states[i].bytes;
                }
            }
            next = closure(next);
            size_t target;
            while (target < subsets.length && subsets[target] != next)
                ++target;
            if (target == subsets.length) {
                if (target == stateLimit)
                    return Automaton.init;
                subsets ~= next;
            }
            foreach (b; byteValue .. 256)
                if (same.contains(cast(ubyte)b))
                    row[b] = cast(ubyte)target;
            remaining = remaining & ~same;
        }
        result.transitions ~= row;
        result.accepting ~= subsets[current][fragment.end];
        if (hasEnd)
            result.eofAccepting ~= closure(subsets[current].dup, true)[fragment.end];
    }
    if (result.eofAccepting == result.accepting)
        result.eofAccepting = null;
    result.valid = true;
    result.requireEnd = requireEnd;
    return minimizeDFA(result);
}

unittest {
    CharSetMask digits, dot;
    digits.addRange('0', '9');
    dot.addChar('.');
    // [0-9]+ ('.' [0-9]+)?
    RegularExpression[] nodes = [
        RegularExpression(RegularKind.bytes, digits),
        RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
        RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1]),
        RegularExpression(RegularKind.bytes, dot),
        RegularExpression(RegularKind.sequence, CharSetMask.init, [3, 2]),
        RegularExpression(RegularKind.optional, CharSetMask.init, [4]),
        RegularExpression(RegularKind.sequence, CharSetMask.init, [2, 5])
    ];
    const table = compileDFA(nodes, 6);
    assert(table.valid);
    assert(scanDFA(table.transitions, table.accepting, "123.45!", 0) == 6);
    assert(scanDFA(table.transitions, table.accepting, "123.", 0) == 3);
    assert(scanDFA(table.transitions, table.accepting, "x", 0) == size_t.max);
    nodes ~= RegularExpression(RegularKind.choice, CharSetMask.init, [0, 3]);
    const choice = compileDFA(nodes, 7);
    assert(scanDFA(choice.transitions, choice.accepting, ".", 0) == 1);
    assert(!compileDFA(nodes, 100).valid);
    nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, [8]);
    assert(!compileDFA(nodes, 8).valid);
    nodes ~= RegularExpression(RegularKind.optional);
    assert(!compileDFA(nodes, 9).valid);
    assert(!compileDFA(nodes, 0, false, 1).valid);
    assert(!compileDFA(nodes, 0, false, 0).valid);
    assert(!compileDFA(nodes, 0, false, 256).valid);
    assert(!compileDFA(nodes, 0, false, 255, 1).valid);
    assert(!compileDFA(nodes, 1, false, 255, 2).valid);
    RegularExpression[] deeplyNested = [regularByte(1, 0, 0, 0)];
    foreach (size_t i; 1 .. 512)
        deeplyNested ~= regularNode(RegularKind.optional, [i - 1]);
    assert(!compileDFA(deeplyNested, deeplyNested.length - 1).valid);
    assert(!compileDFA([regularNode(RegularKind.endOfInput, [0])], 0).valid);
    auto anchored = compileDFA([
        RegularExpression(RegularKind.bytes, digits), regularNode(RegularKind.endOfInput, []),
        regularNode(RegularKind.sequence, [0, 1])
    ], 2);
    const afterDigit = anchored.transitions[0]['0'];
    assert(anchored.valid && !anchored.accepting[afterDigit] && anchored.eofAccepting[afterDigit]);
}

/// X2: `compileDFA` for expressions with `guard` nodes. A thread that crossed a guard may only consume bytes outside the
/// union of the masks it crossed; a state reached along several paths keeps the intersection of their masks. The
/// automaton accepts as the plain one would (the end of a scan never needs the next byte), so only transitions differ.
private Automaton compileGuardedDFA(const(RegularExpression)[] expressions, size_t root,
        bool requireEnd, size_t stateLimit, size_t nfaLimit) pure {
    Automaton result;
    static struct GuardedState {
        size_t[] epsilon, eofEpsilon;
        CharSetMask bytes, guard;
        size_t target = size_t.max;
        size_t guardTarget = size_t.max;
    }

    const maxStates = expressions.length * 4 + 4 < nfaLimit + 2 ? expressions.length * 4 + 4 : nfaLimit + 2;
    auto states = new GuardedState[maxStates];
    size_t stateCount;
    struct Fragment {
        size_t begin, end;
    }

    bool malformed, hasEnd;
    Fragment build(size_t index, size_t depth = 0) {
        if (stateCount > nfaLimit - 2 || stateCount + 2 > states.length || depth >= 128) {
            malformed = true;
            return Fragment.init;
        }
        auto node = expressions[index];
        const begin = stateCount++;
        const end = stateCount++;
        if (node.kind == RegularKind.bytes) {
            states[begin].bytes = node.bytes;
            states[begin].target = end;
        } else if (node.kind == RegularKind.guard || node.kind == RegularKind.mark) {
            if (node.kind == RegularKind.guard) {
                states[begin].guard = node.bytes;
                states[begin].guardTarget = end;
            } else
                states[begin].epsilon ~= end;
            malformed = node.children.length != 0;
        } else if (node.kind == RegularKind.endOfInput) {
            hasEnd = true;
            malformed = node.children.length != 0;
            states[begin].eofEpsilon ~= end;
        } else {
            size_t previous = begin;
            foreach (child; node.children) {
                if (child >= index) {
                    malformed = true;
                    return Fragment(begin, end);
                }
                const part = build(child, depth + 1);
                if (malformed)
                    return Fragment(begin, end);
                if (node.kind == RegularKind.sequence) {
                    states[previous].epsilon ~= part.begin;
                    previous = part.end;
                } else {
                    states[begin].epsilon ~= part.begin;
                    states[part.end].epsilon ~= end;
                    if (node.kind == RegularKind.repetition)
                        states[part.end].epsilon ~= part.begin;
                }
            }
            if (node.kind == RegularKind.sequence)
                states[previous].epsilon ~= end;
            else if (node.kind == RegularKind.optional || node.kind == RegularKind.repetition) {
                if (node.children.length != 1)
                    malformed = true;
                states[begin].epsilon ~= end;
            }
        }
        return Fragment(begin, end);
    }

    const fragment = build(root);
    if (malformed)
        return result;
    const count = stateCount;
    // A configuration holds, per NFA state, whether it is reached and the bytes it must not consume next.
    static struct Configuration {
        bool[] present;
        CharSetMask[] forbidden;
    }

    Configuration fresh() {
        return Configuration(new bool[count], new CharSetMask[count]);
    }

    Configuration closure(Configuration configuration, bool atEnd) {
        auto pending = new size_t[count * 4 + 4];
        size_t tail;
        foreach (i, present; configuration.present)
            if (present)
                pending[tail++] = i;
        void reach(size_t next, CharSetMask forbidden) {
            if (!configuration.present[next]) {
                configuration.present[next] = true;
                configuration.forbidden[next] = forbidden;
            } else {
                const merged = configuration.forbidden[next] & forbidden;
                if (merged == configuration.forbidden[next])
                    return;
                configuration.forbidden[next] = merged;
            }
            if (tail == pending.length)
                pending.length = pending.length * 2;
            pending[tail++] = next;
        }

        while (tail) {
            const current = pending[--tail];
            const forbidden = configuration.forbidden[current];
            foreach (next; states[current].epsilon)
                reach(next, forbidden);
            if (atEnd)
                foreach (next; states[current].eofEpsilon)
                    reach(next, forbidden);
            if (states[current].guardTarget != size_t.max)
                reach(states[current].guardTarget, forbidden | states[current].guard);
        }
        return configuration;
    }

    bool same(const Configuration a, const Configuration b) {
        foreach (i; 0 .. count)
            if (a.present[i] != b.present[i] || a.present[i] && a.forbidden[i] != b.forbidden[i])
                return false;
        return true;
    }

    auto initial = fresh();
    initial.present[fragment.begin] = true;
    Configuration[] subsets = [closure(initial, false)];
    for (size_t current; current < subsets.length; ++current) {
        ubyte[256] row = ubyte.max;
        bool[][] seenTargets;
        ubyte[] seenIds;
        foreach (byteValue; 0 .. 256) {
            auto reached = new bool[count];
            bool any;
            foreach (i; 0 .. count)
                if (subsets[current].present[i] && states[i].target != size_t.max
                        && states[i].bytes.contains(cast(ubyte)byteValue)
                        && !subsets[current].forbidden[i].contains(cast(ubyte)byteValue)) {
                    reached[states[i].target] = true;
                    any = true;
                }
            if (!any)
                continue;
            size_t known;
            while (known < seenTargets.length && seenTargets[known] != reached)
                ++known;
            if (known == seenTargets.length) {
                auto next = fresh();
                foreach (i; 0 .. count)
                    next.present[i] = reached[i];
                next = closure(next, false);
                size_t target;
                while (target < subsets.length && !same(subsets[target], next))
                    ++target;
                if (target == subsets.length) {
                    if (target == stateLimit)
                        return Automaton.init;
                    subsets ~= next;
                }
                seenTargets ~= reached;
                seenIds ~= cast(ubyte)target;
            }
            row[byteValue] = seenIds[known];
        }
        result.transitions ~= row;
        result.accepting ~= subsets[current].present[fragment.end];
        if (hasEnd)
            result.eofAccepting ~= closure(Configuration(subsets[current].present.dup,
                    subsets[current].forbidden.dup), true).present[fragment.end];
    }
    if (result.eofAccepting == result.accepting)
        result.eofAccepting = null;
    result.valid = true;
    result.requireEnd = requireEnd;
    return minimizeDFA(result);
}

@nogc nothrow unittest {
    // Guard semantics in a tiny maximal-munch token: `a` stops unless `b` follows, `ab` always stops.
    CharSetMask a, b;
    a.addChar('a');
    b.addChar('b');
    enum nodes = () {
        CharSetMask a,
        b;
        a.addChar('a');
        b.addChar('b');
        return [
            RegularExpression(RegularKind.bytes, a), // 0
            RegularExpression(RegularKind.bytes, b), // 1
            RegularExpression(RegularKind.guard, b), // 2: stop after `a` only if no `b` follows
            regularNode(RegularKind.sequence, [0, 1]), // 3: `ab`
            regularNode(RegularKind.sequence, [0, 2]), // 4: `a` guarded
            regularNode(RegularKind.choice, [3, 4]), // 5
            regularNode(RegularKind.repetition, [5]), // 6: (ab / a)*
        ];
    }();
    enum table = compileDFA(nodes, 6);
    static assert(table.valid);
    // `aab` is a, ab; `abab` is ab, ab. A guard never rejects what the plain automaton accepts at the end of input.
    assert(scanDFA!table("aab", 0) == 3 && scanDFA!table("abab", 0) == 4 && scanDFA!table("a", 0) == 1);
    assert(scanDFA!table("ac", 0) == 1 && scanDFA!table("", 0) == 0);
}

unittest {
    // X2(c): a guard inside a tagged region keeps the events of the path it takes. `a` stops unless `b` follows, so
    // `ab` fires its event after `b` and a lone `a` fires it after `a`.
    CharSetMask a, b;
    a.addChar('a');
    b.addChar('b');
    const nodes = [
        RegularExpression(RegularKind.bytes, a), // 0
        RegularExpression(RegularKind.bytes, b), // 1
        RegularExpression(RegularKind.guard, b), // 2
        regularMark(0), // 3 open
        regularMark(2), // 4 close, kind 1
        regularNode(RegularKind.sequence, [0, 1]), // 5 ab
        regularNode(RegularKind.sequence, [0, 2]), // 6 a guarded
        regularNode(RegularKind.choice, [5, 6]), // 7
        regularNode(RegularKind.sequence, [3, 7, 4]), // 8 token with its record
        regularNode(RegularKind.repetition, [8]), // 9
    ];
    const tagged = compileTaggedDFA(nodes, 9);
    assert(tagged.valid && tagged.base.valid && compileDFA(nodes, 9).valid);
    // A guard node with children is malformed for both constructions.
    assert(!compileTaggedDFA([RegularExpression(RegularKind.guard, b, [0])], 0).valid);
}

/// Refine equivalence classes until every byte transition agrees within a class.
Automaton minimizeDFA(Automaton input) pure {
    if (!input.valid)
        return input;
    // Keep explicit failed-prefix states: reaching one advances the diagnostic
    // offset, whereas a missing transition stops before consuming that byte.
    // Refinement preserves both acceptance and this observable scan behavior.
    auto classes = new size_t[input.transitions.length];
    const endAccepting = input.eofAccepting.length ? input.eofAccepting : input.accepting;
    foreach (i; 0 .. classes.length)
        classes[i] = (input.accepting[i] ? 1 : 0) + (endAccepting[i] ? 2 : 0);
    size_t[] representatives;
    while (true) {
        auto refined = new size_t[classes.length];
        representatives = null;
        foreach (i; 0 .. classes.length) {
            size_t group;
            foreach (candidate; representatives) {
                bool equivalent = input.accepting[i] == input.accepting[candidate]
                    && endAccepting[i] == endAccepting[candidate];
                foreach (c; 0 .. 256) {
                    const a = input.transitions[i][c], b = input.transitions[candidate][c];
                    if ((a == ubyte.max) != (b == ubyte.max) || (a != ubyte.max && b != ubyte.max
                            && classes[a] != classes[b])) {
                        equivalent = false;
                        break;
                    }
                }
                if (equivalent)
                    break;
                ++group;
            }
            if (group == representatives.length)
                representatives ~= i;
            refined[i] = group;
        }
        if (refined == classes)
            break;
        classes = refined;
    }
    Automaton result;
    result.transitions = new ubyte[256][representatives.length];
    result.accepting = new bool[representatives.length];
    if (input.eofAccepting.length)
        result.eofAccepting = new bool[representatives.length];
    foreach (idx, representative; representatives) {
        auto row = input.transitions[representative];
        foreach (ref target; row)
            if (target != ubyte.max)
                target = cast(ubyte)classes[target];
        result.transitions[idx] = row;
        result.accepting[idx] = input.accepting[representative];
        if (input.eofAccepting.length)
            result.eofAccepting[idx] = endAccepting[representative];
    }
    result.valid = true;
    result.requireEnd = input.requireEnd;
    return result;
}

unittest {
    Automaton input;
    ubyte[256] row = ubyte.max;
    input.transitions = [row, row, row];
    input.transitions[0]['a'] = 1;
    input.transitions[0]['b'] = 2;
    input.accepting = [false, true, true];
    input.valid = true;
    const minimized = minimizeDFA(input);
    assert(minimized.transitions.length == 2);
    assert(minimized.transitions[0]['a'] == minimized.transitions[0]['b']);
    assert(!minimizeDFA(Automaton.init).valid);

}

/// O4: a DFA whose transitions carry output events. Events run before the byte they are attached to is consumed,
/// at the offset of that byte, and `tail` events run when the state accepts. Event 0 remembers the offset, event
/// `k + 1` finishes a leaf record of kind `k` that began at the remembered offset.
struct TaggedAutomaton {
    Automaton base;
    /// Event list id per (state, byte); list 0 is empty.
    ubyte[256][] action;
    /// Event list run when a state accepts, and when it accepts at the end of input.
    ubyte[] tail, tailEof;
    uint[] events;
    size_t[] starts;
    bool valid;
}

/// Like `compileDFA`, but follows the `mark` events of the path PEG takes. Threads are ordered by priority (earlier
/// alternative, greedy repetition first). When threads that consume the same byte would fire different events, the
/// first one wins and the others are dropped, as in an ordered choice that has committed. The result declines
/// (`valid == false`) unless it scans exactly like the plain automaton of the same expressions: same transitions
/// defined, same accepting states, byte for byte.
TaggedAutomaton compileTaggedDFA(const(RegularExpression)[] expressions, size_t root,
        bool requireEnd = false, size_t stateLimit = ubyte.max, size_t nfaLimit = 4096) pure {
    TaggedAutomaton result;
    const plain = compileDFA(expressions, root, requireEnd, stateLimit, nfaLimit);
    if (!plain.valid)
        return result;
    static struct TaggedState {
        size_t[] epsilon, eofEpsilon;
        CharSetMask bytes, guard;
        size_t target = size_t.max;
        size_t markTarget = size_t.max;
        size_t guardTarget = size_t.max;
        uint mark;
    }

    // X2: `forbidden` holds the bytes a thread that crossed a guard may not consume next.
    static struct Thread {
        size_t state, sequence;
        CharSetMask forbidden;
    }

    const maxStates = expressions.length * 4 + 4 < nfaLimit + 2 ? expressions.length * 4 + 4 : nfaLimit + 2;
    auto states = new TaggedState[maxStates];
    size_t stateCount;
    struct Fragment {
        size_t begin, end;
    }

    bool malformed, hasEnd;
    Fragment build(size_t index, size_t depth = 0) {
        if (stateCount > nfaLimit - 2 || stateCount + 2 > states.length || depth >= 128) {
            malformed = true;
            return Fragment.init;
        }
        // The plain automaton above validated the expressions (child order, arities), so only the limits can differ.
        auto node = expressions[index];
        const begin = stateCount++;
        const end = stateCount++;
        if (node.kind == RegularKind.bytes) {
            states[begin].bytes = node.bytes;
            states[begin].target = end;
        } else if (node.kind == RegularKind.mark) {
            states[begin].markTarget = end;
            states[begin].mark = cast(uint)node.bytes.bits[0];
            malformed = node.children.length != 0 || node.bytes.bits[0] > uint.max;
        } else if (node.kind == RegularKind.guard) {
            states[begin].guardTarget = end;
            states[begin].guard = node.bytes;
            malformed = node.children.length != 0;
        } else if (node.kind == RegularKind.endOfInput) {
            hasEnd = true;
            states[begin].eofEpsilon ~= end;
        } else {
            size_t previous = begin;
            foreach (child; node.children) {
                const part = build(child, depth + 1);
                if (malformed)
                    return Fragment(begin, end);
                if (node.kind == RegularKind.sequence) {
                    states[previous].epsilon ~= part.begin;
                    previous = part.end;
                } else {
                    // Edge order is priority: a repetition goes round again before it leaves.
                    states[begin].epsilon ~= part.begin;
                    if (node.kind == RegularKind.repetition)
                        states[part.end].epsilon ~= part.begin;
                    states[part.end].epsilon ~= end;
                }
            }
            if (node.kind == RegularKind.sequence)
                states[previous].epsilon ~= end;
            else if (node.kind == RegularKind.optional || node.kind == RegularKind.repetition)
                states[begin].epsilon ~= end;
        }
        return Fragment(begin, end);
    }

    const fragment = build(root);
    if (malformed)
        return result;
    const count = stateCount;
    // Event sequences are interned; sequence 0 is empty.
    uint[][] sequences = [null];
    size_t intern(uint[] sequence) {
        foreach (i, existing; sequences)
            if (existing == sequence)
                return i;
        sequences ~= sequence;
        return sequences.length - 1;
    }

    // Threads reachable without consuming, in priority order (depth-first, first edge first); the first path to a
    // state decides the events it carries.
    Thread[] closure(Thread[] starts, bool atEnd) {
        Thread[] ordered;
        auto seen = new bool[count];
        Thread[] stack;
        foreach_reverse (start; starts)
            stack ~= start;
        while (stack.length) {
            const current = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            if (seen[current.state])
                continue;
            seen[current.state] = true;
            ordered ~= current;
            const node = states[current.state];
            if (node.guardTarget != size_t.max)
                stack ~= Thread(node.guardTarget, current.sequence, current.forbidden | node.guard);
            if (node.markTarget != size_t.max)
                stack ~= Thread(node.markTarget, intern(sequences[current.sequence] ~ node.mark), current.forbidden);
            if (atEnd)
                foreach_reverse (next; node.eofEpsilon)
                    stack ~= Thread(next, current.sequence, current.forbidden);
            foreach_reverse (next; node.epsilon)
                stack ~= Thread(next, current.sequence, current.forbidden);
        }
        return ordered;
    }

    size_t[] eventSequences = [0]; // action list id -> sequence id
    size_t listOf(size_t sequence) {
        foreach (i, existing; eventSequences)
            if (existing == sequence)
                return i;
        eventSequences ~= sequence;
        return eventSequences.length - 1;
    }

    Thread[][] subsets = [closure([Thread(fragment.begin, 0)], false)];
    for (size_t current; current < subsets.length; ++current) {
        ubyte[256] row = ubyte.max;
        ubyte[256] actions = 0;
        // Consumers that agree with the first one on the events to fire stay; the others are dropped (their futures
        // are checked against the plain automaton below). Equal consumer sets share a successor.
        size_t[][] keptSets;
        size_t[] keptTargets;
        foreach (byteValue; 0 .. 256) {
            size_t[] kept;
            size_t winnerSequence = size_t.max;
            foreach (k, thread; subsets[current])
                if (states[thread.state].target != size_t.max
                        && states[thread.state].bytes.contains(cast(ubyte)byteValue)
                        && !thread.forbidden.contains(cast(ubyte)byteValue)) {
                    if (winnerSequence == size_t.max)
                        winnerSequence = thread.sequence;
                    if (thread.sequence == winnerSequence)
                        kept ~= k;
                }
            if (!kept.length)
                continue;
            size_t known;
            while (known < keptSets.length && keptSets[known] != kept)
                ++known;
            if (known == keptSets.length) {
                Thread[] starts;
                foreach (k; kept)
                    starts ~= Thread(states[subsets[current][k].state].target, 0);
                auto next = closure(starts, false);
                size_t target;
                while (target < subsets.length && subsets[target] != next)
                    ++target;
                if (target == subsets.length) {
                    if (target == stateLimit)
                        return TaggedAutomaton.init;
                    subsets ~= next;
                }
                keptSets ~= kept;
                keptTargets ~= target;
            }
            const list = listOf(winnerSequence);
            if (list >= ubyte.max)
                return TaggedAutomaton.init;
            row[byteValue] = cast(ubyte)keptTargets[known];
            actions[byteValue] = cast(ubyte)list;
        }
        result.base.transitions ~= row;
        result.action ~= actions;
        size_t accepts = size_t.max;
        foreach (thread; subsets[current])
            if (thread.state == fragment.end) {
                accepts = thread.sequence;
                break;
            }
        result.base.accepting ~= accepts != size_t.max;
        const acceptList = accepts != size_t.max ? listOf(accepts) : 0;
        if (acceptList >= ubyte.max)
            return TaggedAutomaton.init;
        result.tail ~= cast(ubyte)acceptList;
        if (hasEnd) {
            size_t eofAccepts = size_t.max;
            foreach (thread; closure(subsets[current], true))
                if (thread.state == fragment.end) {
                    eofAccepts = thread.sequence;
                    break;
                }
            result.base.eofAccepting ~= eofAccepts != size_t.max;
            const eofList = eofAccepts != size_t.max ? listOf(eofAccepts) : 0;
            if (eofList >= ubyte.max)
                return TaggedAutomaton.init;
            result.tailEof ~= cast(ubyte)eofList;
        }
    }
    foreach (sequence; eventSequences) {
        result.starts ~= result.events.length;
        result.events ~= sequences[sequence];
    }
    result.starts ~= result.events.length;
    result.base.valid = true;
    result.base.requireEnd = requireEnd;

    // The scanner must behave exactly like the plain one: walk both from the start and compare byte by byte.
    bool eofOf(const Automaton automaton, size_t state) {
        return automaton.eofAccepting.length ? automaton.eofAccepting[state] : automaton.accepting[state];
    }

    auto visited = new bool[result.base.transitions.length * plain.transitions.length];
    size_t[2][] work = [[0, 0]];
    visited[0] = true;
    while (work.length) {
        const pair = work[$ - 1];
        work = work[0 .. $ - 1];
        const tagged = pair[0], reference = pair[1];
        if (result.base.accepting[tagged] != plain.accepting[reference] || eofOf(result.base,
                tagged) != eofOf(plain, reference))
            return TaggedAutomaton.init;
        foreach (byteValue; 0 .. 256) {
            const a = result.base.transitions[tagged][byteValue], b = plain.transitions[reference][byteValue];
            if ((a == ubyte.max) != (b == ubyte.max))
                return TaggedAutomaton.init;
            if (a == ubyte.max)
                continue;
            const index = a * plain.transitions.length + b;
            if (!visited[index]) {
                visited[index] = true;
                work ~= [cast(size_t)a, cast(size_t)b];
            }
        }
    }
    result.valid = true;
    return result;
}

/// Return the last accepting offset, or size_t.max when no prefix matched.
size_t scanDFA(scope const(ubyte[256])[] transitions, scope const(bool)[] accepting, scope string input, size_t pos) @nogc pure nothrow @safe {
    size_t examined;
    return scanDFA(transitions, accepting, input, pos, examined);
}

@nogc nothrow unittest {
    ubyte[256][1] transitions;
    transitions[0][] = ubyte.max;
    bool[1] accepting = [true];
    assert(scanDFA(transitions[], accepting[], "suffix", 0) == 0);
}

/// The furthest examined prefix preserves recognition diagnostics after rollback.
size_t scanDFA(scope const(ubyte[256])[] transitions, scope const(bool)[] accepting, scope string input,
        size_t pos, out size_t examined) @nogc pure nothrow @safe {
    examined = pos;
    if (!transitions.length || transitions.length != accepting.length || pos > input.length)
        return size_t.max;
    ubyte state;
    size_t end = accepting[0] ? pos : size_t.max;
    while (pos < input.length) {
        const next = transitions[state][cast(ubyte)input[pos]];
        if (next == ubyte.max)
            break;
        assert(next < transitions.length);
        state = next;
        ++pos;
        examined = pos;
        if (accepting[state])
            end = pos;
    }
    return end;
}

@nogc nothrow unittest {
    enum makeTable = () {
        CharSetMask mask;
        mask.addRange('a', 'z');
        return compileDFA([RegularExpression(RegularKind.bytes, mask)], 0);
    };
    enum table = makeTable();
    static assert(table.valid);
    assert(scanDFA(table.transitions, table.accepting, "az", 0) == 1);
    assert(scanDFA(table.transitions, table.accepting, "az", 1) == 2);
    assert(scanDFA(table.transitions, table.accepting, "", 1) == size_t.max);
    assert(scanDFA(null, null, "", 0) == size_t.max);
}

private struct DfaStorage(alias Table) {
    static if (__traits(hasMember, Table, "automaton"))
        enum compiled = Table.automaton;
    else
        enum compiled = Table;
    static immutable loops = () {
        CharSetMask[compiled.transitions.length] masks;
        foreach (state, row; compiled.transitions)
            foreach (c; 0 .. 256)
                if (row[c] == state)
                    masks[state].addChar(cast(ubyte)c);
        return masks;
    }();
    static immutable automaton = compiled;
    version (NPeggedDFAEdgeCoverage) unittest {
        import tests.dfa_edges : exercise;

        static if (compiled.valid)
            assert(exercise!Table() > 0);
        else
            assert(exercise!Table() == 0);
    }
}

/// Largest DFA lowered to straight-line state code; bigger tables use the generic loop.
private enum codeScannerStateLimit = 48;

private string unsignedText(size_t value) pure nothrow @safe {
    char[20] digits;
    size_t count;
    do {
        digits[count++] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    string result;
    while (count)
        result ~= digits[--count];
    return result;
}

@safe pure nothrow unittest {
    assert(unsignedText(0) == "0" && unsignedText(7) == "7" && unsignedText(1204) == "1204");
}

private string hexText(ulong value) pure nothrow @safe {
    string result;
    foreach_reverse (nibble; 0 .. 16)
        result ~= "0123456789abcdef"[(value >> (nibble * 4)) & 15];
    return result;
}

@safe pure nothrow unittest {
    assert(hexText(0) == "0000000000000000" && hexText(0x1f2a) == "0000000000001f2a");
}

/// `case` labels (ranges for consecutive bytes) of every byte `state` sends to `target`.
private string emitRuns(const Automaton automaton, size_t state, ubyte target) pure nothrow @safe {
    string labels;
    size_t c;
    while (c < 256) {
        if (automaton.transitions[state][c] != target) {
            ++c;
            continue;
        }
        size_t last = c;
        while (last + 1 < 256 && automaton.transitions[state][last + 1] == target)
            ++last;
        labels ~= "case " ~ unsignedText(c) ~ ":" ~ (last > c ? " .. case " ~ unsignedText(last) ~ ":" : "") ~ "\n";
        c = last + 1;
    }
    return labels;
}

@safe pure nothrow unittest {
    Automaton table;
    table.transitions.length = 1;
    foreach (ref target; table.transitions[0])
        target = ubyte.max;
    assert(emitRuns(table, 0, 0).length == 0);
    table.transitions[0][0] = 0;
    table.transitions[0][1] = 0;
    table.transitions[0][255] = 0;
    assert(emitRuns(table, 0, 0) == "case 0: .. case 1:\ncase 255:\n");
}

/// CTFE source for a scanner that keeps the DFA state in the program counter.
/// Each state label performs exactly the arrival bookkeeping of the table loop:
/// accepting/EOF-accepting ends, the examined frontier, then one byte dispatch.
/// Expects `input`, `pos`, `end`, `examined` and `lastEofEnd` in scope.
private string codeScannerSource(const Automaton automaton, const TaggedAutomaton tags = TaggedAutomaton.init) pure nothrow @safe {
    const tagged = tags.valid;
    string code = "const size_t scanLength = input.length;\n";
    const hasEof = automaton.eofAccepting.length != 0;
    // A byte that loops back to its state and fires no event can be skipped without dispatch.
    bool loops(size_t state, size_t c) {
        return automaton.transitions[state][c] == state && (!tagged || !tags.action[state][c]);
    }

    // Bookkeeping when the state accepts: a tagged scan also notes how many records exist, where the open one began and
    // which tail events complete the accepted path.
    string accepted(size_t state, bool atEof) {
        string text = "end = pos;";
        if (tagged)
            text ~= " acceptLength = records.length; acceptReg = reg; acceptList = " ~ unsignedText(atEof
                    && tags.tailEof.length ? tags.tailEof[state] : tags.tail[state]) ~ ";";
        return text;
    }

    foreach (state; 0 .. automaton.transitions.length) {
        const name = unsignedText(state);
        code ~= "dfaState" ~ name ~ ":\n";
        // Self-loop bytes run in a tight loop; arrival bookkeeping then happens once,
        // exactly as the table loop's hoisted self-loop does.
        ulong[4] loopBits;
        foreach (c; 0 .. 256)
            if (loops(state, c))
                loopBits[c >> 6] |= 1UL << (c & 63);
        size_t runStart = 256, runEnd, loopRuns;
        foreach (c; 0 .. 256)
            if (loops(state, c)) {
                if (runStart == 256)
                    runStart = c;
                runEnd = c;
                if (c == 0 || !loops(state, c - 1))
                    ++loopRuns;
            }
        if (loopRuns == 1) {
            // One contiguous byte range: a single unsigned compare.
            code ~= "while (pos < scanLength && cast(ubyte)(cast(ubyte)input[pos] - " ~ unsignedText(
                    runStart) ~ ") <= " ~ unsignedText(runEnd - runStart) ~ ") ++pos;\n";
        } else if (loopRuns) {
            string literal;
            foreach (word; loopBits)
                literal ~= (literal.length ? ", 0x" : "0x") ~ hexText(word) ~ "UL";
            code ~= "{ enum ulong[4] loopBits = [" ~ literal ~ "]; while (pos < scanLength) { const ubyte c = "
                ~ "cast(ubyte)input[pos]; if (!((loopBits[c >> 6] >> (c & 63)) & 1)) break; ++pos; } }\n";
        }
        if (automaton.accepting[state])
            code ~= accepted(state, false) ~ "\n";
        const eof = hasEof && automaton.eofAccepting[state];
        if (eof)
            code ~= "lastEofEnd = pos;\n";
        code ~= "examined = pos;\n";
        code ~= "if (pos == scanLength) {" ~ (eof ? " " ~ accepted(state, true) : "") ~ " goto dfaFinish; }\n";
        code ~= "switch (cast(ubyte)input[pos]) {\n";
        if (tagged) {
            // One case group per (successor, events) pair.
            ubyte[] doneTargets, doneLists;
            foreach (c; 0 .. 256) {
                const target = automaton.transitions[state][c];
                const list = tags.action[state][c];
                if (target == ubyte.max || loops(state, c))
                    continue;
                bool seen;
                foreach (i, t; doneTargets)
                    seen = seen || (t == target && doneLists[i] == list);
                if (seen)
                    continue;
                doneTargets ~= target;
                doneLists ~= list;
                size_t at;
                while (at < 256) {
                    if (automaton.transitions[state][at] != target || tags.action[state][at] != list || loops(state, at)) {
                        ++at;
                        continue;
                    }
                    size_t last = at;
                    while (last + 1 < 256 && automaton.transitions[state][last + 1] == target
                            && tags.action[state][last + 1] == list && !loops(state, last + 1))
                        ++last;
                    code ~= "case " ~ unsignedText(at) ~ ":" ~ (last > at
                            ? " .. case " ~ unsignedText(last) ~ ":" : "") ~ "\n";
                    at = last + 1;
                }
                foreach (event; tags.events[tags.starts[list] .. tags.starts[list + 1]])
                    code ~= event == 0 ? "reg = pos;\n" : "records.putLeaf(" ~ unsignedText(event - 1)
                        ~ "U, reg, pos);\n";
                code ~= "++pos; goto dfaState" ~ unsignedText(target) ~ ";\n";
            }
        } else {
            foreach (target; 0 .. automaton.transitions.length) {
                if (target == state)
                    continue;
                const runs = emitRuns(automaton, state, cast(ubyte)target);
                if (runs.length)
                    code ~= runs ~ "++pos; goto dfaState" ~ unsignedText(target) ~ ";\n";
            }
        }
        code ~= "default: goto dfaFinish;\n}\n";
    }
    code ~= "dfaFinish:;\n";
    return code;
}

@safe pure nothrow unittest {
    Automaton table;
    table.transitions.length = 1;
    table.accepting = [true];
    table.eofAccepting = [true];
    foreach (ref target; table.transitions[0])
        target = ubyte.max;
    auto withoutLoops = codeScannerSource(table);
    assert(withoutLoops.length && withoutLoops != codeScannerSource(Automaton.init));
    table.transitions[0][0] = 0;
    table.transitions[0][1] = 0;
    auto rangeLoop = codeScannerSource(table);
    assert(rangeLoop != withoutLoops);
    table.transitions[0][255] = 0;
    auto maskLoop = codeScannerSource(table);
    assert(maskLoop != rangeLoop);
    table.accepting[0] = false;
    table.eofAccepting = null;
    assert(codeScannerSource(table) != maskLoop);
    table.transitions.length = 2;
    foreach (ref target; table.transitions[1])
        target = ubyte.max;
    table.transitions[0]['b'] = 1;
    table.accepting ~= true;
    assert(codeScannerSource(table).length > maskLoop.length);
}

/// Hoist a state's self-loop byte class out of its inner scanner loop.
/// This preserves DFA semantics while removing a dependent table read per byte.
pragma(inline, true) size_t scanDFA(alias Table)(scope string input, size_t pos,
        out size_t examined, out size_t lastEofEnd) @nogc pure nothrow @safe {
    alias compiled = DfaStorage!Table.compiled;
    return scanDFAWith!(Table, compiled.transitions.length <= codeScannerStateLimit)(input, pos, examined, lastEofEnd);
}

/// `Code` selects the straight-line state scanner over the table loop; both are equivalent.
pragma(inline, true) size_t scanDFAWith(alias Table, bool Code)(scope string input, size_t pos,
        out size_t examined, out size_t lastEofEnd) @nogc pure nothrow @safe {
    alias storage = DfaStorage!Table;
    alias compiled = storage.compiled;
    alias loops = storage.loops;
    alias automaton = storage.automaton;
    examined = pos;
    lastEofEnd = size_t.max;
    static if (!compiled.valid)
        return size_t.max;
    else {
        if (pos > input.length)
            return size_t.max;
        size_t end = size_t.max;
        static if (Code) {
            mixin(codeScannerSource(compiled));
            lastEofEnd = automaton.eofAccepting.length ? lastEofEnd : end;
            return automaton.requireEnd && end != input.length ? size_t.max : end;
        } else {
            ubyte state;
            end = automaton.accepting[0] ? pos : size_t.max;
            if (automaton.eofAccepting.length && automaton.eofAccepting[0])
                lastEofEnd = pos;
            while (pos < input.length) {
                const mask = loops[state];
                while (pos < input.length && mask.contains(cast(ubyte)input[pos]))
                    ++pos;
                examined = pos;
                if (automaton.accepting[state])
                    end = pos;
                if (automaton.eofAccepting.length && automaton.eofAccepting[state])
                    lastEofEnd = pos;
                if (pos == input.length)
                    break;
                const next = automaton.transitions[state][cast(ubyte)input[pos]];
                if (next == ubyte.max)
                    break;
                state = next;
                ++pos;
                examined = pos;
                if (automaton.accepting[state])
                    end = pos;
                if (automaton.eofAccepting.length && automaton.eofAccepting[state])
                    lastEofEnd = pos;
            }
            if (pos == input.length && automaton.eofAccepting.length && automaton.eofAccepting[state]) {
                end = pos;
                lastEofEnd = pos;
            }
            lastEofEnd = automaton.eofAccepting.length ? lastEofEnd : end;
            return automaton.requireEnd && end != input.length ? size_t.max : end;
        }
    }
}

@nogc nothrow unittest {
    // The state-code scanner must match the table loop on every observable output.
    static void same(alias table)(string input) {
        foreach (start; 0 .. input.length + 1) {
            size_t examinedCode, examinedTable, eofCode, eofTable;
            const code = scanDFAWith!(table, true)(input, start, examinedCode, eofCode);
            const loop = scanDFAWith!(table, false)(input, start, examinedTable, eofTable);
            assert(code == loop && examinedCode == examinedTable && eofCode == eofTable);
        }
    }

    enum digits = () {
        CharSetMask d;
        d.addRange('0', '9');
        return compileDFA([
            RegularExpression(RegularKind.bytes, d),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
        ], 2);
    }();
    enum anchoredDigits = () {
        CharSetMask d;
        d.addRange('0', '9');
        return compileDFA([
            RegularExpression(RegularKind.bytes, d),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.endOfInput, CharSetMask.init),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [1, 2])
        ], 3);
    }();
    enum quoted = () {
        CharSetMask q,
        s,
        other;
        q.addChar('"');
        s.addChar('\\');
        other.addRange(0, 255);
        CharSetMask plain;
        foreach (c; 0 .. 256)
            if (c != '"' && c != '\\')
                plain.addChar(cast(ubyte)c);
        return compileDFA([
            RegularExpression(RegularKind.bytes, q), // 0
            RegularExpression(RegularKind.bytes, s), // 1
            RegularExpression(RegularKind.bytes, other), // 2
            RegularExpression(RegularKind.sequence,
                    CharSetMask.init, [1, 2]), // 3 escape
            RegularExpression(RegularKind.bytes, plain), // 4
            RegularExpression(RegularKind.choice,
                    CharSetMask.init, [3, 4]), // 5
            RegularExpression(RegularKind.repetition, CharSetMask.init,
                    [5]), // 6
            RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 6, 0]) // 7
        ], 7);
    }();
    static foreach (table; [digits, anchoredDigits, quoted]) {
        {
            enum t = table;
            static immutable string[] inputs = [
                "", "1", "123", "123x", "x", "\"\"", "\"a\"", "\"a\\\"b\"", "\"a\\", "\"abc",
                "\"a\\\"", "\"\\\\\"x", "\"\\n\\t\"", "12\"3"
            ];
            foreach (input; inputs)
                same!t(input);
        }
    }
    // A table past the state limit still takes the loop path in the public entry point.
    static assert(codeScannerStateLimit < ubyte.max);
}

size_t scanDFA(alias Table)(scope string input, size_t pos, out size_t examined) @nogc pure nothrow @safe {
    size_t lastEofEnd;
    return scanDFA!Table(input, pos, examined, lastEofEnd);
}

@nogc nothrow unittest {
    enum mask = CharSetMask.fromChars('a');
    enum table = compileDFA([regularByte(mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3])], 0);
    size_t examined;
    assert(scanDFA!table("ax", 0, examined) == 1 && examined == 1);
}

@nogc nothrow unittest {
    enum end = compileDFA([regularNode(RegularKind.endOfInput, [])], 0);
    assert(scanDFA!end("", 0) == 0 && scanDFA!end("x", 0) == size_t.max);
    assert(scanDFA!end("x", 1) == 1);
    enum mask = CharSetMask.fromChars('a');
    enum anchored = compileDFA([
            regularByte(mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3]),
            regularNode(RegularKind.endOfInput, []), regularNode(RegularKind.sequence, [0, 1])
    ], 2);
    assert(scanDFA!anchored("a", 0) == 1 && scanDFA!anchored("ax", 0) == size_t.max);
    enum impossible = compileDFA([
            regularNode(RegularKind.endOfInput, []),
            regularByte(mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3]),
            regularNode(RegularKind.sequence, [0, 1])
    ], 2);
    assert(scanDFA!impossible("a", 0) == size_t.max);
}

/// Alias form keeps the table and compressed byte classes in compile-time storage.
size_t scanDFA(alias Table)(scope string input, size_t pos) @nogc pure nothrow @safe {
    size_t examined;
    return scanDFA!Table(input, pos, examined);
}

@nogc nothrow unittest {
    enum table = () {
        CharSetMask a,
        b;
        a.addChar('a');
        b.addChar('b');
        return compileDFA([
            RegularExpression(RegularKind.bytes, a),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.bytes, b),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [1, 2])
        ], 3);
    }();
    foreach (input; ["", "a", "aaab", "aaab!", "b", "!", "abbb"])
        assert(scanDFA!table(input, 0) == scanDFA(table.transitions, table.accepting, input, 0));
    assert(scanDFA!table("", 1) == size_t.max);
    enum invalid = Automaton.init;
    assert(scanDFA!invalid("a", 0) == size_t.max);
}

/// Array-alias interface for ordinary byte DFAs; the table form also carries EOF facts.
size_t scanDFA(alias Transitions, alias Accepting)(scope string input, size_t pos) @nogc pure nothrow @safe {
    struct BoundTable {
        static immutable automaton = Automaton(Transitions, Accepting, true);
    }

    return scanDFA!BoundTable(input, pos);
}

@nogc nothrow unittest {
    enum mask = CharSetMask.fromChars('a');
    enum table = compileDFA([regularByte(mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3])], 0);
    assert(scanDFA!(table.transitions, table.accepting)("ax", 0) == 1);
    assert(scanDFA!(table.transitions, table.accepting)("x", 0) == size_t.max);
}

version (NPeggedScannerMetrics) template scannerName(alias Table) {
    static if (__traits(hasMember, Table, "diagnosticName"))
        enum scannerName = Table.diagnosticName;
    else
        enum scannerName = "<anonymous DFA>";
}

version (NPeggedScannerMetrics) @nogc nothrow unittest {
    struct Named {
        enum diagnosticName = "Example.Token/_dfa_Token";
    }

    static assert(scannerName!Named == "Example.Token/_dfa_Token");
    static assert(scannerName!Automaton == "<anonymous DFA>");
}

private struct TaggedStorage(alias Table) {
    static immutable tagged = Table.tagged;
    /// Bytes on which a state loops to itself without firing an event: the scan skips them without table reads.
    static immutable loops = () {
        CharSetMask[Table.tagged.base.transitions.length] masks;
        foreach (state, row; Table.tagged.base.transitions)
            foreach (c; 0 .. 256)
                if (row[c] == state && !Table.tagged.action[state][c])
                    masks[state].addChar(cast(ubyte)c);
        return masks;
    }();
}

private template hasValidTags(alias Table) {
    static if (__traits(hasMember, Table, "tagged"))
        enum hasValidTags = Table.tagged.valid;
    else
        enum hasValidTags = false;
}

/// Run the events of list `list` at offset `at`; `reg` is the remembered start of the open leaf record.
pragma(inline, true) private void runEvents(alias Tags)(size_t list, size_t at, ref size_t reg, ref RecordBuffer records) @nogc nothrow {
    foreach (event; Tags.events[Tags.starts[list] .. Tags.starts[list + 1]]) {
        if (event == 0)
            reg = at;
        else
            records.putLeaf(event - 1, reg, at);
    }
}

/// O4: `scanDFA` for a tagged table. Appends the leaf records of the accepted path to `records` and leaves them
/// untouched when nothing is accepted. Records the path wrote past the last accepting offset are rolled back and
/// the accepting state's tail events are run at that offset, so the result is the one a rule-by-rule walk of the
/// same (deterministic) region gives. The caller checks `records.status` for an exhausted arena.
pragma(inline, true) size_t scanTaggedRecords(alias Table)(scope string input, size_t pos,
        out size_t examined, out size_t lastEofEnd, ref RecordBuffer records) @nogc nothrow {
    static if (hasValidTags!Table)
        return scanTaggedRecordsWith!(Table,
                TaggedStorage!Table.tagged.base.transitions.length <= codeScannerStateLimit)(input,
                pos, examined, lastEofEnd, records);
    else
        return scanTaggedRecordsWith!(Table, false)(input, pos, examined, lastEofEnd, records);
}

/// `Code` selects the straight-line state scanner over the table loop; both are equivalent.
size_t scanTaggedRecordsWith(alias Table, bool Code)(scope string input, size_t pos,
        out size_t examined, out size_t lastEofEnd, ref RecordBuffer records) @nogc nothrow {
    examined = pos;
    lastEofEnd = size_t.max;
    static if (!hasValidTags!Table)
        return size_t.max;
    else {
        alias tags = TaggedStorage!Table.tagged;
        if (pos > input.length)
            return size_t.max;
        const base = records.length;
        const hasEof = tags.base.eofAccepting.length != 0;
        size_t reg = pos, end = size_t.max, acceptLength = base, acceptReg = pos, acceptList;
        static if (Code) {
            mixin(codeScannerSource(tags.base, tags));
        } else {
            ubyte state;
            if (tags.base.accepting[0]) {
                end = pos;
                acceptList = tags.tail[0];
            }
            if (hasEof && tags.base.eofAccepting[0])
                lastEofEnd = pos;
            while (pos < input.length) {
                const mask = TaggedStorage!Table.loops[state];
                while (pos < input.length && mask.contains(cast(ubyte)input[pos]))
                    ++pos;
                examined = pos;
                if (tags.base.accepting[state]) {
                    end = pos;
                    acceptLength = records.length;
                    acceptReg = reg;
                    acceptList = tags.tail[state];
                }
                if (hasEof && tags.base.eofAccepting[state])
                    lastEofEnd = pos;
                if (pos == input.length)
                    break;
                const c = cast(ubyte)input[pos];
                const next = tags.base.transitions[state][c];
                if (next == ubyte.max)
                    break;
                const list = tags.action[state][c];
                if (list)
                    runEvents!tags(list, pos, reg, records);
                state = next;
                ++pos;
                examined = pos;
                if (tags.base.accepting[state]) {
                    end = pos;
                    acceptLength = records.length;
                    acceptReg = reg;
                    acceptList = tags.tail[state];
                }
                if (hasEof && tags.base.eofAccepting[state])
                    lastEofEnd = pos;
            }
            if (pos == input.length && hasEof && tags.base.eofAccepting[state]) {
                end = pos;
                lastEofEnd = pos;
                acceptLength = records.length;
                acceptReg = reg;
                acceptList = tags.tailEof[state];
            }
        }
        lastEofEnd = hasEof ? lastEofEnd : end;
        if (end == size_t.max || tags.base.requireEnd && end != input.length) {
            records.rollback(base);
            return size_t.max;
        }
        records.rollback(acceptLength);
        runEvents!tags(acceptList, end, acceptReg, records);
        return end;
    }
}

private RegularExpression[] taggedFieldNodes() pure nothrow {
    CharSetMask letters, comma;
    letters.addRange('a', 'z');
    comma.addChar(',');
    return [
        RegularExpression(RegularKind.bytes, letters), // 0
        regularNode(RegularKind.repetition, [0]), // 1
        regularMark(0), // 2 open
        regularMark(6), // 3 close, kind 5
        regularNode(RegularKind.sequence, [2, 1, 3]), // 4 Field
        RegularExpression(RegularKind.bytes, comma), // 5
        regularNode(RegularKind.sequence, [5, 4]), // 6
        regularNode(RegularKind.repetition, [6]), // 7
        regularNode(RegularKind.sequence, [4, 7]) // 8
    ];
}

/// O4: `Field (',' Field)*` with `Field <- [a-z]*` a leaf record of kind 5, as a generated `_dfa_` struct would declare it.
private struct TaggedFields(bool End) {
    enum automaton = compileDFA(taggedFieldNodes(), 8, End);
    enum tagged = compileTaggedDFA(taggedFieldNodes(), 8, End);
    enum valid = automaton.valid;
    enum requireEnd = automaton.requireEnd;
}

@nogc nothrow unittest {
    import npegged.storage : Arena;
    import npegged.records : CompactNode;

    alias Plain = TaggedFields!false;
    static assert(Plain.tagged.valid && Plain.automaton.valid);
    static immutable inputs = ["", "a", "ab,c", "ab,c,,d", ",", ",,", "ab,c!x", "A", "a,B", "a,b,"];
    foreach (input; inputs) {
        Arena owner;
        RecordBuffer output;
        output.arena = &owner;
        size_t examined, lastEofEnd;
        const end = scanTaggedRecords!Plain(input, 0, examined, lastEofEnd, output);
        size_t plainExamined;
        // Same end and examined bytes as the plain automaton.
        assert(end == scanDFA!Plain(input, 0, plainExamined) && examined == plainExamined);
        // One record per field of the accepted prefix, in order, each spanning its letters.
        size_t fields = 1, begin;
        foreach (i; 0 .. end + 1) {
            if (i == end || input[i] == ',') {
                assert(output.nodes[fields - 1] == CompactNode(5, begin, i, size_t.max));
                begin = i + 1;
                if (i < end)
                    ++fields;
            }
        }
        if (end == size_t.max)
            assert(output.length == 0);
        else
            assert(output.length == fields);
    }
    // A table that requires the end of input accepts only whole inputs and leaves no record behind otherwise.
    alias Anchored = TaggedFields!true;
    foreach (input; ["a,b", "a,b!", "a,!", "", "X", "A"]) {
        Arena owner;
        RecordBuffer output;
        output.arena = &owner;
        size_t examined, lastEofEnd;
        const end = scanTaggedRecords!Anchored(input, 0, examined, lastEofEnd, output);
        assert(end == scanDFA!Anchored(input, 0));
        if (input == "a,b" || input == "") {
            assert(end == input.length && output.length == (input.length ? 2 : 1));
        } else
            assert(end == size_t.max && output.length == 0);
    }
    // A refused allocation leaves the status of the buffer failed; the caller rolls back.
    Arena exhausted;
    exhausted.limit = 0;
    RecordBuffer limited;
    limited.arena = &exhausted;
    size_t examined, lastEofEnd;
    scanTaggedRecords!Plain("a,b", 0, examined, lastEofEnd, limited);
    assert(limited.status != Status.ok && limited.length == 0);
    // Starting past the input, and a scan that suppresses its output.
    assert(scanTaggedRecords!Plain("a", 2, examined, lastEofEnd, limited) == size_t.max);
    Arena roomy;
    RecordBuffer quiet;
    quiet.arena = &roomy;
    quiet.suppressed = true;
    assert(scanTaggedRecords!Plain("a,b", 0, examined, lastEofEnd, quiet) == 3 && quiet.length == 0);
}

/// The straight-line tagged scanner and the table loop agree on the end, the frontier and the records written.
@nogc nothrow unittest {
    import npegged.storage : Arena;

    static void sameScanners(Table)(string input) @nogc nothrow {
        foreach (start; 0 .. input.length + 1) {
            Arena first, second;
            RecordBuffer codeOutput, loopOutput;
            codeOutput.arena = &first;
            loopOutput.arena = &second;
            size_t codeExamined, codeEof, loopExamined, loopEof;
            const code = scanTaggedRecordsWith!(Table, true)(input, start, codeExamined, codeEof, codeOutput);
            const loop = scanTaggedRecordsWith!(Table, false)(input, start, loopExamined, loopEof, loopOutput);
            assert(code == loop && codeExamined == loopExamined && codeEof == loopEof);
            assert(codeOutput.nodes == loopOutput.nodes);
        }
    }

    char[6] buffer;
    enum alphabet = "a,A ";
    foreach (length; 0 .. buffer.length + 1) {
        size_t combinations = 1;
        foreach (_; 0 .. length)
            combinations *= alphabet.length;
        foreach (code; 0 .. combinations) {
            size_t rest = code;
            foreach (i; 0 .. length) {
                buffer[i] = alphabet[rest % alphabet.length];
                rest /= alphabet.length;
            }
            sameScanners!(TaggedFields!false)(cast(string)buffer[0 .. length]);
            sameScanners!(TaggedFields!true)(cast(string)buffer[0 .. length]);
        }
    }
}

private RegularExpression[] anchoredNodes() pure nothrow {
    CharSetMask letters;
    letters.addRange('a', 'z');
    return [
        RegularExpression(RegularKind.bytes, letters), // 0
        regularNode(RegularKind.repetition, [0]), // 1
        regularMark(0), // 2 open
        regularMark(6), // 3 close, kind 5
        regularNode(RegularKind.endOfInput, []), // 4
        regularNode(RegularKind.sequence, [2, 1, 3, 4]), // 5 `open [a-z]* close eoi`
        RegularExpression(RegularKind.bytes,
                letters), // 6
        regularNode(RegularKind.choice, [0, 0, 0, 0, 0, 0, 0]), // 7 many alternatives of one byte
    ];
}

private struct TaggedAnchored {
    enum tagged = compileTaggedDFA(anchoredNodes(), 5);
    enum automaton = compileDFA(anchoredNodes(), 5);
    enum valid = automaton.valid;
    enum requireEnd = automaton.requireEnd;
}

/// A record that must end at the end of input has its events run by the EOF-accepting state, and the generators
/// that read the tables report the limits the plain compiler does not hit.
nothrow unittest {
    import npegged.storage : Arena;
    import npegged.records : CompactNode;

    static assert(TaggedAnchored.tagged.valid && TaggedAnchored.tagged.base.eofAccepting.length);
    foreach (input; ["", "ab", "ab!"]) {
        Arena owner;
        RecordBuffer output;
        output.arena = &owner;
        size_t examined, lastEofEnd;
        const end = scanTaggedRecords!TaggedAnchored(input, 0, examined, lastEofEnd, output);
        assert(end == scanDFA!TaggedAnchored(input, 0));
        if (input == "ab!")
            assert(end == size_t.max && output.length == 0);
        else
            assert(end == input.length && output.nodes == [
            CompactNode(5, 0, input.length, size_t.max)
        ]);
    }
    // A choice of single bytes merges into one plain state but needs a state per alternative here: a small NFA budget
    // is enough for the plain compiler and not for the tagged one.
    assert(compileDFA(anchoredNodes(), 7, false, 255, 12).valid
            && !compileTaggedDFA(anchoredNodes(), 7, false, 255, 12).valid);
    // The generated scanner reads the events and the accepted-path bookkeeping from the tables.
    const code = codeScannerSource(TaggedAnchored.tagged.base, TaggedAnchored.tagged);
    assert(code.length > codeScannerSource(TaggedAnchored.automaton).length);
    bool hasPut, hasAccept;
    foreach (i; 0 .. code.length - 10) {
        hasPut = hasPut || code[i .. i + 10] == "reg = pos;";
        hasAccept = hasAccept || code[i .. i + 12] == "acceptLength";
    }
    assert(hasPut && hasAccept);
}

private RegularExpression[] ambiguousNodes() pure nothrow {
    CharSetMask a;
    a.addChar('a');
    // (open 'a' close1) / (open 'a' close2): the first alternative wins.
    return [
        RegularExpression(RegularKind.bytes, a), // 0
        regularMark(0), // 1
        regularMark(2), // 2 close kind 1
        regularMark(3), // 3 close kind 2
        regularNode(RegularKind.sequence, [1, 0, 2]), // 4
        regularNode(RegularKind.sequence, [1, 0, 3]), // 5
        regularNode(RegularKind.choice, [4, 5]) // 6
    ];
}

private struct AmbiguousTable {
    enum tagged = compileTaggedDFA(ambiguousNodes(), 6);
}

/// Of two paths that consume the same byte the earlier one wins, and a table that would scan differently from the
/// plain automaton of the same expressions is declined.
nothrow unittest {
    import npegged.storage : Arena;
    import npegged.records : CompactNode;

    static assert(AmbiguousTable.tagged.valid);
    Arena owner;
    RecordBuffer output;
    output.arena = &owner;
    size_t examined, lastEofEnd;
    assert(scanTaggedRecords!AmbiguousTable("a", 0, examined, lastEofEnd, output) == 1);
    assert(output.nodes == [CompactNode(1, 0, 1, size_t.max)]);
    // `a close1 / open a b close2`: on `a` the first alternative wins and the second is dropped, so `ab`, which the plain
    // automaton accepts, would be rejected. Such a table is declined rather than scanning differently.
    CharSetMask a, b;
    a.addChar('a');
    b.addChar('b');
    const lookahead = [
        RegularExpression(RegularKind.bytes, a), // 0
        RegularExpression(RegularKind.bytes, b), // 1
        regularMark(0), // 2 open
        regularMark(2), // 3 close kind 1
        regularMark(3), // 4 close kind 2
        regularNode(RegularKind.sequence, [0, 3]), // 5 `a close1`
        regularNode(RegularKind.sequence, [2, 0, 1, 4]), // 6 `open a b close2`
        regularNode(RegularKind.choice, [5, 6]) // 7
    ];
    assert(compileDFA(lookahead, 7).valid && !compileTaggedDFA(lookahead, 7).valid);
    // The same event on both paths is no problem.
    const same = [
        RegularExpression(RegularKind.bytes, a), regularMark(0), regularMark(2),
        regularNode(RegularKind.sequence, [1, 0, 2]), regularNode(RegularKind.sequence, [1, 0, 2]),
        regularNode(RegularKind.choice, [3, 4])
    ];
    assert(compileTaggedDFA(same, 5).valid);
    assert(!compileTaggedDFA(same, 99).valid && !compileTaggedDFA(same, 5, false, 0).valid);
    assert(!compileTaggedDFA(same, 5, false, 256).valid && !compileTaggedDFA(same, 5, false, 255, 1).valid);
    assert(!compileTaggedDFA([regularNode(RegularKind.sequence, [7])], 0).valid);
    assert(!compileTaggedDFA([regularNode(RegularKind.optional, [])], 0).valid);
    assert(!compileTaggedDFA([regularNode(RegularKind.endOfInput, [0])], 0).valid);
    assert(!compileTaggedDFA([regularMark(1L << 33)], 0).valid);
}

/// Generic tree capture retains the original combinator.
/// A failed scan is replayed to produce the original failure structure.
/// `Records`: 0 none, 1 rules inside the region emit records (the region is walked rule by rule), 2 they emit
/// leaf records only and `Table.tagged` produces them (O4).
struct dfaToken(alias Original, alias Table, size_t ReferenceDepth = 0, int Records = 0) {
    private enum HasInnerRecords = Records != 0;
    private enum Tagged = Records == 2 && hasValidTags!Table;
    version (NPeggedScannerMetrics) private enum diagnosticName = scannerName!Table;
    static if (__traits(hasMember, Original, "scan")) {
        version (NPeggedScannerMetrics) {
            static State!(CT, Check).Node scan(bool Capture, bool CT, int Check = 0)(ref State!(CT,
                    Check) s, size_t pos) nothrow {
                ScannerEvent event;
                event.rule = diagnosticName;
                event.reason = ScannerReason.primitiveScan;
                event.eligible = (Check == 1 || Check == 2 && (!HasInnerRecords || Tagged)) && Table.valid;
                event.original = true;
                auto sink = s.context.scannerReport;
                auto result = Original.scan!Capture(s, pos);
                const frontier = result.end > result.failEnd ? result.end : result.failEnd;
                event.originalBytes = frontier > pos ? frontier - pos : 0;
                if (!__ctfe && sink !is null)
                    sink.record(event);
                return result;
            }
        } else
            alias scan = Original.scan;
    }
    static if (__traits(hasMember, Original, "byteScanner") && __traits(hasMember, Original,
            "byteMatches") && __traits(hasMember, Original, "byteSteps") && Original.byteScanner) {
        enum byteScanner = true;
        alias byteMatches = Original.byteMatches;
        alias byteSteps = Original.byteSteps;
    }
    /// Cursor entry (S4, S5). `steps`/`live` and `depth` are the caller's register-resident counters (`s.depth` may be stale). A scan the table settles
    /// consumes exactly the work units `opCall` charges and never touches `s.steps` or `s.status`; every other
    /// outcome syncs the shared state and replays through `opCall`, so end, failEnd, status and steps are
    /// identical to `s.steps = steps; opCall(s, pos); steps = s.steps; live = s.status == Status.ok`.
    pragma(inline, true) static bool cursor(bool CT, int Check = 0)(ref State!(CT, Check) s,
            size_t pos, ref size_t steps, ref bool live, const size_t depth, out size_t end, out size_t failEnd) nothrow {
        return cursorImpl!false(s, pos, steps, live, depth, end, failEnd);
    }

    /// `cursor` for `accept` mode: identical units and outcomes, but a settled failure is not recorded as a diagnostic.
    pragma(inline, true) static bool cursorAccept(bool CT, int Check = 0)(ref State!(CT, Check) s,
            size_t pos, ref size_t steps, ref bool live, const size_t depth, out size_t end, out size_t failEnd) nothrow {
        return cursorImpl!true(s, pos, steps, live, depth, end, failEnd);
    }

    pragma(inline, true) private static bool cursorImpl(bool Accept, bool CT, int Check)(ref State!(CT,
            Check) s, size_t pos, ref size_t steps, ref bool live, const size_t depth, out size_t end, out size_t failEnd) nothrow {
        version (NPeggedScannerMetrics) {
        } else static if ((Check == 1 || (Check == 2 && (!HasInnerRecords || Tagged))) && Table.valid) {
            const limit = s.context.stepLimit;
            if (live && steps < limit && pos <= s.input.length && (!ReferenceDepth
                    || s.context.trace is null && depth <= s.context.depthLimit
                    && ReferenceDepth <= s.context.depthLimit - depth)) {
                const remaining = limit - steps - 1;
                const available = s.input.length - pos;
                const stop = pos + (remaining < available ? remaining : available);
                size_t examined = pos;
                size_t lastEofEnd = size_t.max;
                static if (Check == 2 && Tagged) {
                    // Records are appended during the scan, so only a scan that sees the whole input is attempted.
                    const settled = stop == s.input.length;
                    const recordBase = s.output.length;
                    const scanned = settled ? scanTaggedRecords!Table(s.input, pos, examined, lastEofEnd, s.output)
                        : size_t.max;
                    s.syncOutput();
                    if (s.status != Status.ok) {
                        s.output.rollback(recordBase);
                        live = false;
                        steps += examined - pos + 1;
                        end = failEnd = examined;
                        return false;
                    }
                } else {
                    const scanned = scanDFA!Table(s.input[0 .. stop], pos, examined, lastEofEnd);
                    const settled = examined < stop || stop == s.input.length;
                }
                if (scanned != size_t.max && settled) {
                    steps += examined - pos + 1;
                    static if (!Accept)
                        if (examined > scanned)
                            s.recordFailure(s.node(pos, examined, false));
                    end = failEnd = scanned;
                    return true;
                }
                static if (Table.requireEnd) {
                    if (settled && lastEofEnd != size_t.max) {
                        steps += examined - pos + 1;
                        end = lastEofEnd;
                        failEnd = examined > lastEofEnd ? examined : lastEofEnd;
                        static if (!Accept) {
                            auto failed = s.node(pos, end, false);
                            failed.failEnd = failEnd;
                            s.recordFailure(failed);
                        }
                        return false;
                    }
                } else {
                    if (settled) {
                        steps += examined - pos + 1;
                        end = failEnd = examined;
                        static if (!Accept) {
                            auto failed = s.node(pos, examined, false);
                            failed.failEnd = examined;
                            s.recordFailure(failed);
                        }
                        return false;
                    }
                }
            }
        }
        s.steps = steps;
        s.depth = depth;
        const replay = opCall(s, pos);
        steps = s.steps;
        live = s.status == Status.ok;
        end = replay.end;
        failEnd = replay.failEnd;
        return replay.successful;
    }

    /// The cursor entry for bodies whose counters live in the shared state (`withSharedSteps`).
    pragma(inline, true) static bool cursorShared(bool CT, int Check = 0)(ref State!(CT, Check) s,
            size_t pos, const size_t depth, out size_t end, out size_t failEnd) nothrow {
        s.depth = depth;
        const result = opCall(s, pos);
        end = result.end;
        failEnd = result.failEnd;
        return result.successful;
    }

    pragma(inline, true) static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT,
            Check) s, size_t pos) nothrow {
        version (NPeggedScannerMetrics) {
            ScannerEvent event;
            event.rule = diagnosticName;
            auto sink = s.context.scannerReport;
            scope (exit)
                if (!__ctfe && sink !is null)
                    sink.record(event);
            static if (Check == 0)
                event.reason = ScannerReason.tree;
            else static if (Check == 2 && HasInnerRecords && !Tagged)
                event.reason = ScannerReason.innerRecords;
            else static if (!Table.valid)
                event.reason = ScannerReason.invalidTable;
        }
        static if ((Check == 1 || (Check == 2 && (!HasInnerRecords || Tagged))) && Table.valid) {
            version (NPeggedScannerMetrics)
                event.eligible = true;
            if (s.status == Status.ok && pos <= s.input.length && s.steps < s.context.stepLimit
                    && (!ReferenceDepth || s.context.trace is null) && (!ReferenceDepth
                        || s.depth <= s.context.depthLimit && ReferenceDepth <= s.context.depthLimit - s.depth)) {
                // Every examined byte consumes one work unit. Cap speculation
                // before scanning so a small budget cannot trigger an unbounded loop.
                const remaining = s.context.stepLimit - s.steps - 1;
                const available = s.input.length - pos;
                const limit = pos + (remaining < available ? remaining : available);
                size_t examined = pos;
                size_t lastEofEnd = size_t.max;
                static if (Check == 2 && Tagged) {
                    const whole = limit == s.input.length;
                    const recordBase = s.output.length;
                    const end = whole ? scanTaggedRecords!Table(s.input, pos, examined, lastEofEnd, s.output)
                        : size_t.max;
                    if (!whole)
                        examined = limit; // not settled: the original walk decides
                    s.syncOutput();
                    if (s.status != Status.ok) {
                        s.output.rollback(recordBase);
                        s.steps += examined - pos + 1;
                        auto exhausted = s.node(pos, examined, false);
                        exhausted.failEnd = examined;
                        return exhausted;
                    }
                } else
                    const end = scanDFA!Table(s.input[0 .. limit], pos, examined, lastEofEnd);
                version (NPeggedScannerMetrics) {
                    event.attempted = true;
                    event.scanAccepted = end != size_t.max;
                    event.examinedBytes = examined - pos;
                    event.reason = examined < limit || limit == s.input.length
                        ? ScannerReason.failureDiagnostic : ScannerReason.budgetEdge;
                }
                if (end != size_t.max && (examined < limit || limit == s.input.length)) {
                    version (NPeggedScannerMetrics) {
                        event.fastSuccess = true;
                        event.reason = ScannerReason.none;
                    }
                    s.steps += examined - pos + 1;
                    if (examined > end)
                        s.recordFailure(s.node(pos, examined, false));
                    return s.node(pos, end);
                } else static if (Check == 1 || (Check == 2 && (!HasInnerRecords || Tagged))) {
                    static if (Table.requireEnd) {
                        if (lastEofEnd != size_t.max && (examined < limit || limit == s.input.length)) {
                            version (NPeggedScannerMetrics) {
                                event.fastFailure = true;
                                event.reason = ScannerReason.none;
                            }
                            s.steps += examined - pos + 1;
                            auto result = s.node(pos, lastEofEnd, false);
                            result.failEnd = examined > lastEofEnd ? examined : lastEofEnd;
                            s.recordFailure(result);
                            return result;
                        }
                    } else {
                        if (examined < limit || limit == s.input.length) {
                            version (NPeggedScannerMetrics) {
                                event.fastFailure = true;
                                event.reason = ScannerReason.none;
                            }
                            s.steps += examined - pos + 1;
                            auto result = s.node(pos, examined, false);
                            result.failEnd = examined;
                            s.recordFailure(result);
                            return result;
                        }
                    }
                }
            } else version (NPeggedScannerMetrics) {
                if (s.status != Status.ok)
                    event.reason = ScannerReason.state;
                else if (pos > s.input.length)
                    event.reason = ScannerReason.position;
                else if (s.steps >= s.context.stepLimit)
                    event.reason = ScannerReason.steps;
                else if (ReferenceDepth && s.context.trace !is null)
                    event.reason = ScannerReason.trace;
                else
                    event.reason = ScannerReason.depth;
            }
        }
        version (NPeggedScannerMetrics) {
            event.original = true;
            auto result = Original(s, pos);
            const frontier = result.end > result.failEnd ? result.end : result.failEnd;
            event.originalBytes = frontier > pos ? frontier - pos : 0;
            event.replayedBytes = event.examinedBytes < event.originalBytes ? event.examinedBytes : event.originalBytes;
            return result;
        } else
            return Original(s, pos);
    }
}

/// O4: a tagged region in records mode takes the same decisions from `opCall` and the cursor entry, writes the same
/// records, and leaves them alone (falling back to the original walk) when the step budget does not show the whole input.
@nogc nothrow unittest {
    import npegged.peg : zeroOrMore, charRange;
    import npegged.storage : Arena;

    alias Fields = TaggedFields!false;
    alias token = dfaToken!(zeroOrMore!(charRange!('a', 'z')), Fields, 0, 2);
    static assert(token.Tagged);
    static immutable string[7] inputs = ["", "a", "a,b", "a,b,", "A", "ab,cd,,e", "a,b!"];
    static immutable size_t[8] limits = [0, 1, 2, 3, 5, 9, 64, size_t.max];
    foreach (limit; limits)
        foreach (input; inputs)
            foreach (start; 0 .. input.length + 1) {
                Arena first, second;
                RecordBuffer calledOutput, cursorOutput;
                calledOutput.arena = &first;
                cursorOutput.arena = &second;
                State!(false, 2) called, cursor;
                called.context.stepLimit = cursor.context.stepLimit = limit;
                called.input = cursor.input = input;
                called.attachRecords(calledOutput);
                cursor.attachRecords(cursorOutput);
                const expected = token(called, start);
                size_t steps, end, failEnd;
                bool live = true;
                const ok = token.cursor(cursor, start, steps, live, 0, end, failEnd);
                assert(ok == expected.successful && end == expected.end && failEnd == expected.failEnd);
                assert(steps == called.steps && live == (called.status == Status.ok));
                assert(calledOutput.nodes == cursorOutput.nodes);
            }
    // An exhausted record arena fails the parse with its status and leaves no record behind.
    Arena exhausted;
    exhausted.limit = 0;
    RecordBuffer output;
    output.arena = &exhausted;
    State!(false, 2) failing, failingCursor;
    failing.input = failingCursor.input = "a,b";
    failing.attachRecords(output);
    const refused = token(failing, 0);
    assert(!refused.successful && failing.status != Status.ok && output.length == 0);
    Arena another;
    another.limit = 0;
    RecordBuffer cursorBuffer;
    cursorBuffer.arena = &another;
    failingCursor.attachRecords(cursorBuffer);
    size_t steps, end, failEnd;
    bool live = true;
    assert(!token.cursor(failingCursor, 0, steps, live, 0, end, failEnd));
    assert(!live && failingCursor.status != Status.ok && cursorBuffer.length == 0);
}

/// S4: the cursor entry is `opCall` with the counters held by the caller, for every step limit.
@nogc nothrow unittest {
    import npegged.peg : oneOrMore, digit;

    enum Digits = () {
        CharSetMask mask;
        mask.addRange('0', '9');
        return compileDFA([
            RegularExpression(RegularKind.bytes, mask),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
        ], 2);
    }();
    struct DigitsTable {
        enum automaton = Digits;
        enum valid = Digits.valid;
        enum requireEnd = Digits.requireEnd;
        enum diagnosticName = "Unit.Digits/_dfa_Digits";
    }

    alias token = dfaToken!(oneOrMore!digit, DigitsTable);
    alias deep = dfaToken!(oneOrMore!digit, DigitsTable, 2, false);
    static immutable string[5] inputs = ["", "x", "7", "1234", "12x"];
    static void sweep(Token)() @nogc nothrow {
        foreach (limit; 0 .. 9)
            foreach (depthLimit; 0 .. 4)
                foreach (input; inputs)
                    foreach (start; 0 .. input.length + 1)
                        foreach (depth; 0 .. 5) {
                            ParseContext context;
                            context.stepLimit = limit;
                            context.depthLimit = depthLimit;
                            State!(false, 1) reference;
                            State!(false, 1) cursor;
                            reference.context = context;
                            cursor.context = context;
                            reference.input = cursor.input = input;
                            reference.depth = depth;
                            // The cursor's depth lives in the caller; its shared copy may be stale.
                            cursor.depth = 99;
                            size_t steps = 0;
                            bool live = true;
                            size_t end, failEnd;
                            const expected = Token(reference, start);
                            const ok = Token.cursor(cursor, start, steps, live, depth, end, failEnd);
                            assert(ok == expected.successful && end == expected.end && failEnd == expected.failEnd);
                            assert(steps == reference.steps && live == (reference.status == Status.ok));
                            assert(cursor.status == reference.status);
                        }
    }

    sweep!token();
    sweep!deep();
}

@nogc nothrow unittest {
    import npegged.peg : ParseContext, check, parse, oneOrMore, digit;

    enum table = () {
        CharSetMask mask;
        mask.addRange('0', '9');
        return compileDFA([
            RegularExpression(RegularKind.bytes, mask),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
        ], 2);
    }();
    alias token = dfaToken!(oneOrMore!digit, table);
    ParseContext context;
    auto limited = check!token(context, "123");
    assert(limited.successful && limited.end == 3);
    context.stepLimit = size_t.max;
    auto fast = check!token(context, "123x");
    assert(fast.successful && fast.end == 3 && fast.failEnd == 3);
    auto bad = check!token(context, "x");
    assert(!bad.successful && bad.failEnd == 0);
    auto tree = parse!token(context, "12");
    assert(tree.matches == ["1", "2"]);
}

@nogc nothrow unittest {
    import npegged.peg : ParseContext, check, zeroOrMore, option, and, literal, charClass;

    enum mask = CharSetMask.fromChars('a');
    enum table = compileDFA([
            regularByte(mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3]),
            regularByte(0, 0, 0, 0), regularNode(RegularKind.sequence, [0, 1]),
            regularNode(RegularKind.optional, [2]), regularNode(RegularKind.repetition, [3])
    ], 4);
    alias original = zeroOrMore!(option!(and!(literal!"a", charClass!(0, 0, 0, 0))));
    ParseContext context;
    auto baseline = check!original(context, "a!");
    auto compiled = check!(dfaToken!(original, table))(context, "a!");
    assert(baseline.successful && compiled.successful);
    assert(baseline.end == compiled.end && baseline.failEnd == compiled.failEnd);
}

@nogc nothrow unittest {
    import npegged.peg : Arena, ParseContext, State, Status, and, digit, eoi, literal, oneOrMore, or;
    import npegged.records : RecordBuffer;

    struct DigitsTable {
        enum automaton = () {
            CharSetMask mask;
            mask.addRange('0', '9');
            return compileDFA([
                RegularExpression(RegularKind.bytes, mask),
                RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
            ], 2);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Digits/_dfa_Digits";
    }

    struct AnchoredTable {
        enum automaton = () {
            CharSetMask mask;
            mask.addRange('0', '9');
            return compileDFA([
                RegularExpression(RegularKind.bytes, mask),
                RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
            ], 2, true);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Anchored/_dfa_Anchored";
    }

    struct PairTable {
        enum automaton = () {
            CharSetMask digits;
            digits.addRange('0', '9');
            const bang = CharSetMask.fromChars('!');
            return compileDFA([
                RegularExpression(RegularKind.bytes, digits),
                RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1]),
                RegularExpression(RegularKind.bytes, bang),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [2, 3])
            ], 4);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Pair/_dfa_Pair";
    }

    struct EscapeTable {
        enum automaton = () {
            CharSetMask slash = CharSetMask.fromChars('\\');
            CharSetMask esc = CharSetMask.fromChars('n', 't', '\\', '"');
            return compileDFA([
                RegularExpression(RegularKind.bytes, slash), RegularExpression(RegularKind.bytes,
                        esc), RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
            ], 2);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Escape/_dfa_Escape";
    }

    alias FastDigits = dfaToken!(oneOrMore!digit, DigitsTable, 2, false);
    alias InnerDigits = dfaToken!(oneOrMore!digit, DigitsTable, 2, true);
    alias AnchoredDigits = dfaToken!(and!(oneOrMore!digit, eoi), AnchoredTable, 0, false);
    alias PairDigits = dfaToken!(and!(oneOrMore!digit, literal!"!"), PairTable, 0, false);

    alias EscapeRule = and!(literal!"\\", or!(literal!"n", literal!"t", literal!"\\", literal!"\""));
    alias FastEscape = dfaToken!(EscapeRule, EscapeTable, 2, false);
    alias InnerEscape = dfaToken!(EscapeRule, EscapeTable, 2, true);

    alias AltA = and!(FastDigits, literal!"!");
    alias AltB = and!(FastDigits, literal!"?");
    alias ChoiceDigits = or!(AltA, AltB);

    Arena arena;
    RecordBuffer records;
    records.arena = &arena;
    State!(false, 2) s;
    s.arena = &arena;
    s.attachRecords(records);

    // 1. Terminal fast-failure on EOF: failEnd == 0, 0 records
    s.input = "";
    auto rEof = FastDigits(s, 0);
    assert(!rEof.successful && rEof.failEnd == 0);
    assert(records.length == 0);

    // 2. Terminal fast-failure on mismatch: failEnd == 0, 0 records
    s.input = "abc";
    auto rMismatch = FastDigits(s, 0);
    assert(!rMismatch.successful && rMismatch.failEnd == 0);
    assert(records.length == 0);

    // 3. Failed escape sequence: mismatching escape char, failEnd == 1, 0 records
    s.input = "\\x";
    auto rFailEsc = FastEscape(s, 0);
    assert(!rFailEsc.successful && rFailEsc.failEnd == 1);
    assert(records.length == 0);

    // 4. Truncated escape sequence at EOF: failEnd == 1, 0 records
    s.input = "\\";
    auto rTruncEsc = FastEscape(s, 0);
    assert(!rTruncEsc.successful && rTruncEsc.failEnd == 1);
    assert(records.length == 0);

    // 5. Successful escape sequence: end == 2
    s.input = "\\n";
    auto rSuccEsc = FastEscape(s, 0);
    assert(rSuccEsc.successful && rSuccEsc.end == 2);

    // 6. Truncated pair at EOF: failEnd == 3, 0 records
    s.input = "123";
    auto rTruncPair = PairDigits(s, 0);
    assert(!rTruncPair.successful && rTruncPair.failEnd == 3);
    assert(records.length == 0);

    // 7. Anchored token failing at EOF requirement: failEnd == 3, 0 records
    s.input = "123x";
    auto rAnchored = AnchoredDigits(s, 0);
    assert(!rAnchored.successful && rAnchored.failEnd == 3);
    assert(records.length == 0);

    // 8. Backtracking with choice: first alt fast-fails without corrupting state, second alt succeeds
    s.input = "123?";
    auto rChoice = ChoiceDigits(s, 0);
    assert(rChoice.successful && rChoice.end == 4);

    // 9. Token WITH inner records (InnerDigits): falls back to combinator execution on failure
    s.input = "abc";
    auto rInnerFail = InnerDigits(s, 0);
    assert(!rInnerFail.successful && rInnerFail.failEnd == 0);
    assert(records.length == 0);

    s.input = "123";
    auto rInnerSucc = InnerDigits(s, 0);
    assert(rInnerSucc.successful && rInnerSucc.end == 3);

    // 10. Step budget edge: limits halt scan safely
    s.input = "12345";
    s.context.stepLimit = 2;
    auto rBudget = FastDigits(s, 0);
    assert(!rBudget.successful);
    s.context.stepLimit = size_t.max;
}

version (NPeggedScannerMetrics) @nogc nothrow unittest {
    import npegged.peg : Arena, ParseContext, ScannerReason, ScannerReport, ScannerStats, State,
        Status, and, digit, eoi, literal, oneOrMore, or;
    import npegged.records : RecordBuffer;

    static void noopTrace(string, size_t, bool, void*) @nogc nothrow {
    }

    struct DigitsTable {
        enum automaton = () {
            CharSetMask mask;
            mask.addRange('0', '9');
            return compileDFA([
                RegularExpression(RegularKind.bytes, mask),
                RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
            ], 2);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Digits/_dfa_Digits";
    }

    struct AnchoredTable {
        enum automaton = () {
            CharSetMask mask;
            mask.addRange('0', '9');
            return compileDFA([
                RegularExpression(RegularKind.bytes, mask),
                RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
            ], 2, true);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Anchored/_dfa_Anchored";
    }

    struct PairTable {
        enum automaton = () {
            CharSetMask digits;
            digits.addRange('0', '9');
            const bang = CharSetMask.fromChars('!');
            return compileDFA([
                RegularExpression(RegularKind.bytes, digits),
                RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1]),
                RegularExpression(RegularKind.bytes, bang),
                RegularExpression(RegularKind.sequence, CharSetMask.init, [2, 3])
            ], 4);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Pair/_dfa_Pair";
    }

    struct EscapeTable {
        enum automaton = () {
            CharSetMask slash = CharSetMask.fromChars('\\');
            CharSetMask esc = CharSetMask.fromChars('n', 't', '\\', '"');
            return compileDFA([
                RegularExpression(RegularKind.bytes, slash), RegularExpression(RegularKind.bytes,
                        esc), RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
            ], 2);
        }();
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
        enum diagnosticName = "Unit.Escape/_dfa_Escape";
    }

    struct InvalidTable {
        enum automaton = Automaton.init;
        enum valid = false;
        enum requireEnd = false;
        enum diagnosticName = "Unit.Invalid/_dfa_Invalid";
    }

    alias FastToken = dfaToken!(oneOrMore!digit, DigitsTable, 2, false);
    alias InnerToken = dfaToken!(oneOrMore!digit, DigitsTable, 2, true);
    alias BadTableToken = dfaToken!(oneOrMore!digit, InvalidTable, 0, false);
    alias AnchoredToken = dfaToken!(and!(oneOrMore!digit, eoi), AnchoredTable, 0, false);
    alias PairToken = dfaToken!(and!(oneOrMore!digit, literal!"!"), PairTable, 0, false);

    alias EscapeRule = and!(literal!"\\", or!(literal!"n", literal!"t", literal!"\\", literal!"\""));
    alias FastEscape = dfaToken!(EscapeRule, EscapeTable, 2, false);
    alias InnerEscape = dfaToken!(EscapeRule, EscapeTable, 2, true);

    alias AltA = and!(FastToken, literal!"!");
    alias AltB = and!(FastToken, literal!"?");
    alias ChoiceToken = or!(AltA, AltB);

    ScannerStats[16] storage;
    ScannerReport report;
    report.rows = storage[];

    Arena arena;
    State!(false, 1) s1;
    s1.arena = &arena;
    s1.input = "123x";
    assert(FastToken.scan!false(s1, 0).successful);
    assert(FastToken(s1, 0).successful);

    s1.context.scannerReport = &report;
    assert(FastToken.scan!false(s1, 0).end == 3);
    assert(!FastToken.scan!false(s1, 3).successful);
    assert(report.total.reasons[ScannerReason.primitiveScan] == 2);
    assert(report.total.originalBytes == 3);

    State!(false, 0) s0;
    s0.arena = &arena;
    s0.input = "12";
    s0.context.scannerReport = &report;
    assert(FastToken(s0, 0).successful);
    assert(report.total.reasons[ScannerReason.tree] == 1);

    RecordBuffer records;
    records.arena = &arena;
    State!(false, 2) s2;
    s2.arena = &arena;
    s2.input = "12x";
    s2.context.scannerReport = &report;
    s2.attachRecords(records);
    assert(InnerToken(s2, 0).successful);
    assert(!PairToken(s2, 0).successful);
    assert(report.total.fastFailure == 1);
    assert(report.total.replays == 0);
    assert(!AnchoredToken(s2, 0).successful);
    assert(report.total.fastFailure == 2);
    assert(report.total.replays == 0);

    // EOF on fast terminal: fastFailure, 0 replays
    s2.input = "";
    auto rEof = FastToken(s2, 0);
    assert(!rEof.successful && rEof.failEnd == 0);
    assert(records.length == 0);
    assert(report.total.fastFailure == 3);
    assert(report.total.replays == 0);

    // Failed escape sequence: fastFailure, 0 replays, exact failEnd == 1
    s2.input = "\\x";
    auto rFailEsc = FastEscape(s2, 0);
    assert(!rFailEsc.successful && rFailEsc.failEnd == 1);
    assert(records.length == 0);
    assert(report.total.fastFailure == 4);
    assert(report.total.replays == 0);

    // Truncated escape sequence at EOF: fastFailure, 0 replays, exact failEnd == 1
    s2.input = "\\";
    auto rTruncEsc = FastEscape(s2, 0);
    assert(!rTruncEsc.successful && rTruncEsc.failEnd == 1);
    assert(records.length == 0);
    assert(report.total.fastFailure == 5);
    assert(report.total.replays == 0);

    // Successful escape sequence: fastSuccess
    s2.input = "\\n";
    auto rSuccEsc = FastEscape(s2, 0);
    assert(rSuccEsc.successful && rSuccEsc.end == 2);
    assert(report.total.fastSuccess == 1);

    // Backtracking with choice: first alt succeeds scanning prefix, then fails on literal, second alt succeeds without replay
    s2.input = "123?";
    auto rChoice = ChoiceToken(s2, 0);
    assert(rChoice.successful && rChoice.end == 4);
    assert(report.total.fastFailure == 5);
    assert(report.total.replays == 0);

    // Token WITH inner records (InnerToken): failed scan MUST fall back to combinator execution
    s2.input = "abc";
    const prevFastFailure = report.total.fastFailure;
    const prevReplays = report.total.replays;
    const prevInnerRecords = report.total.reasons[ScannerReason.innerRecords];
    auto rInnerFail = InnerToken(s2, 0);
    assert(!rInnerFail.successful && rInnerFail.failEnd == 0);
    assert(records.length == 0);
    assert(report.total.fastFailure == prevFastFailure);
    assert(report.total.replays == prevReplays);
    assert(report.total.reasons[ScannerReason.innerRecords] == prevInnerRecords + 1);

    assert(BadTableToken(s1, 0).successful);
    assert(report.total.reasons[ScannerReason.invalidTable] == 1);

    // Guard reason precedence: state > position > steps > trace > depth.
    s1 = State!(false, 1).init;
    s1.arena = &arena;
    s1.input = "12";
    s1.context.scannerReport = &report;
    s1.status = Status.resourceLimit;
    s1.steps = s1.context.stepLimit;
    s1.context.trace = &noopTrace;
    s1.depth = s1.context.depthLimit + 1;
    cast(void)FastToken(s1, 99);
    assert(report.total.reasons[ScannerReason.state] == 1);

    s1.status = Status.ok;
    cast(void)FastToken(s1, 99);
    assert(report.total.reasons[ScannerReason.position] == 1);

    s1.status = Status.ok;
    s1.steps = s1.context.stepLimit;
    cast(void)FastToken(s1, 0);
    assert(report.total.reasons[ScannerReason.steps] == 1);

    s1.steps = 0;
    s1.status = Status.ok;
    cast(void)FastToken(s1, 0);
    assert(report.total.reasons[ScannerReason.trace] == 1);

    s1.context.trace = null;
    s1.steps = 0;
    s1.status = Status.ok;
    cast(void)FastToken(s1, 0);
    assert(report.total.reasons[ScannerReason.depth] == 1);

    s1.depth = s1.context.depthLimit;
    s1.steps = 0;
    s1.status = Status.ok;
    cast(void)FastToken(s1, 0);
    assert(report.total.reasons[ScannerReason.depth] == 2);

    // Terminal fastSuccess, fastFailure (anchored/unanchored), failureDiagnostic, and budgetEdge.
    s1 = State!(false, 1).init;
    s1.arena = &arena;
    s1.context.scannerReport = &report;
    s1.input = "123";
    assert(FastToken(s1, 0).end == 3);
    s1.input = "123x";
    assert(FastToken(s1, 0).end == 3);
    s1.input = "x";
    assert(!FastToken(s1, 0).successful);
    s1.input = "12x";
    assert(!AnchoredToken(s1, 0).successful);
    s1.input = "x";
    assert(!AnchoredToken(s1, 0).successful);

    s1.input = "1234";
    s1.status = Status.ok;
    s1.steps = 0;
    s1.context.stepLimit = 3; // remaining = 2 < available = 4 -> budgetEdge
    cast(void)FastToken(s1, 0);
    s1.input = "12!";
    s1.status = Status.ok;
    s1.steps = 0;
    s1.context.stepLimit = 2; // remaining = 1 < available = 3 -> budgetEdge on rejected scan
    cast(void)PairToken(s1, 0);
    s1.input = "12";
    s1.status = Status.ok;
    s1.steps = 0;
    s1.context.stepLimit = 2;
    cast(void)AnchoredToken(s1, 0);
    assert(report.total.fastSuccess >= 2 && report.total.fastFailure >= 2);
    assert(report.total.reasons[ScannerReason.budgetEdge] >= 3);
    assert(!report.truncated);
    ulong sumCalls;
    foreach (row; report.rows[0 .. report.length])
        sumCalls += row.calls;
    assert(sumCalls == report.total.calls);
}

/// Whole-DFA entry with the exact rule/scanner budget. False requests exact replay.
/// The caller proves a non-memoized, reference-free rule and supplies a fresh result.
pragma(inline, true) bool tryDFAEntry(alias Original, alias Table)(ref ParseContext context,
        scope string input, ref CheckResult result) @nogc nothrow {
    version (NPeggedMetrics)
        return false;
    else version (NPeggedRuleMetrics)
        return false;
    else version (NPeggedScannerMetrics)
        return false;
    else version (NPeggedDependencyTrace)
        return false;
    else static if (!Table.valid)
        return false;
    else {
        // Entry savings target bounded tiny inputs. Keep throughput scanners on
        // the established path: the broad clone regressed long-input codegen.
        if (input.length > 8 || context.trace !is null || context.depthLimit == 0 || context.stepLimit < 2)
            return false;
        // One rule tick, then the scanner's examined-bytes-plus-one charge.
        const remaining = context.stepLimit - 2;
        const limit = remaining < input.length ? remaining : input.length;
        size_t examined, lastEofEnd;
        const end = scanDFA!Table(input[0 .. limit], 0, examined, lastEofEnd);
        result.arena.limit = context.memoryLimit;
        if (examined < limit || limit == input.length) {
            if (end != size_t.max) {
                result.status = Status.ok;
                result.successful = true;
                result.end = end;
                result.failEnd = examined > end ? examined : end;
                return true;
            }
            static if (!Table.requireEnd) {
                result.status = Status.mismatch;
                result.end = result.failEnd = examined;
                return true;
            } else if (lastEofEnd != size_t.max) {
                result.status = Status.mismatch;
                result.end = lastEofEnd;
                result.failEnd = examined > lastEofEnd ? examined : lastEofEnd;
                return true;
            }
        }
        // Match dfaToken's exact replay without scanning a second time.
        State!(false, 1) state;
        state.arena = &result.arena;
        state.input = input;
        state.context = context;
        state.steps = 1;
        state.depth = 1;
        auto node = state.finish(Original(state, 0));
        result.status = state.status != Status.ok ? state.status : node.successful ? Status.ok : Status.mismatch;
        result.successful = result.status == Status.ok;
        result.end = node.end;
        result.failEnd = node.failEnd;
        return true;
    }
}

@nogc nothrow unittest {
    import npegged.peg : oneOrMore, literal, and, eoi, check;

    enum plain = () {
        CharSetMask mask;
        mask.addChar('a');
        return compileDFA([
            RegularExpression(RegularKind.bytes, mask),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
        ], 2);
    }();
    enum anchored = () {
        CharSetMask mask;
        mask.addChar('a');
        return compileDFA([
            RegularExpression(RegularKind.bytes, mask),
            RegularExpression(RegularKind.repetition, CharSetMask.init, [0]),
            RegularExpression(RegularKind.sequence, CharSetMask.init, [0, 1])
        ], 2, true);
    }();
    static void verify(alias Original, alias Table)(string input) @nogc nothrow {
        static State!(false, 1).Node reference(ref State!(false, 1) state, size_t pos) @nogc nothrow {
            return state.rule!(dfaToken!(Original, Table), "Entry", false)(pos);
        }

        foreach (limit; 0 .. 16) {
            ParseContext context;
            context.stepLimit = limit;
            context.memoryLimit = 0;
            auto expected = check!reference(context, input);
            CheckResult actual;
            if (tryDFAEntry!(Original, Table)(context, input, actual)) {
                assert(actual.status == expected.status && actual.successful == expected.successful);
                assert(actual.end == expected.end && actual.failEnd == expected.failEnd);
                assert(actual.arena.allocationCalls == expected.arena.allocationCalls);
            } else {
                assert(actual.status == Status.invalidInput && !actual.successful);
                assert(actual.arena.allocationCalls == 0);
            }
        }
    }

    foreach (input; ["", "a", "aaa", "aaaaaaaa", "aaaaaaaaa", "!", "a!", "a\0", "\xFF"]) {
        verify!(oneOrMore!(literal!"a"), plain)(input);
        verify!(and!(oneOrMore!(literal!"a"), eoi), anchored)(input);
    }
    ParseContext context;
    CheckResult result;
    enum invalid = Automaton.init;
    assert(!tryDFAEntry!(literal!"a", invalid)(context, "a", result));
    context.depthLimit = 0;
    assert(!tryDFAEntry!(oneOrMore!(literal!"a"), plain)(context, "a", result));
    context.depthLimit = 1;
    context.trace = (string, size_t, bool, void*) @nogc nothrow{};
    assert(!tryDFAEntry!(oneOrMore!(literal!"a"), plain)(context, "a", result));
}

/** Branch coverage of *accepted* parses (G3). Coverage is attributed from a reference PEG derivation of inputs the
    real parser accepted, never from the branches the generator happened to propose.

    Targets: every alternative of every choice, `e?` taken / skipped, and `e*`/`e+` iteration buckets (0, 1, many).
    Targets in rules the start rule cannot reach are `unreachable`; targets whose subtree has constructs the matcher cannot
    evaluate (actions, unknown nodes, terminals without a byte description, left recursion) are `unknown`. Both are tracked
    separately and excluded from the covered/total ratio.
*/
module npegged.coverage;
import npegged.analysis;
import npegged.generator : CandidateGenerator;
import npegged.peg : CharSetMask;

nothrow:

enum TargetKind : ubyte {
    alternative,
    optionalTaken,
    optionalSkipped,
    repeatNone,
    repeatOne,
    repeatMany
}

struct Target {
    size_t node;
    TargetKind kind;
    size_t alternative; // for alternatives
    bool reachable = true;
    bool unknown;
    size_t hits;
}

struct Coverage {
nothrow:
    Target[] targets;
    /// Exact repetition counts observed in accepted derivations: repeatCounts[node][n] = occurrences of n iterations.
    ulong[][] repeatCounts;
    size_t attributed; // accepted samples the matcher could attribute
    size_t unattributed; // accepted samples the matcher could not follow (unknown nodes or disagreement)

    size_t coverable() const {
        size_t n;
        foreach (t; targets)
            n += t.reachable && !t.unknown;
        return n;
    }

    size_t covered() const {
        size_t n;
        foreach (t; targets)
            n += t.reachable && !t.unknown && t.hits != 0;
        return n;
    }

    /// Index of a target, or size_t.max.
    size_t find(size_t node, TargetKind kind, size_t alternative = 0) const {
        foreach (i, t; targets)
            if (t.node == node && t.kind == kind && t.alternative == alternative)
                return i;
        return size_t.max;
    }
}

nothrow unittest {
    Coverage empty;
    assert(empty.find(0, TargetKind.alternative) == size_t.max);
    assert(empty.covered() == 0 && empty.coverable() == 0);
}

private struct Event {
    size_t target;
    size_t node = size_t.max; // repetition node, for exact-count statistics
    size_t count;
}

struct Attributor {
nothrow:
    GrammarAnalysis* graph;
    Coverage* coverage;
    private string input;
    private Event[] events; // targets of the current derivation, rolled back on failure
    private bool unsupported;

    private size_t depthLimit = 400;

    this(ref GrammarAnalysis graph, ref Coverage coverage) {
        this.graph = &graph;
        this.coverage = &coverage;
    }

    private ptrdiff_t match(size_t index, size_t pos, size_t depth) {
        if (unsupported)
            return -1;
        if (depth > depthLimit) {
            unsupported = true; // left recursion or runaway recursion: not followed
            return -1;
        }
        auto node = graph.expressions[index];
        final switch (node.kind) {
        case ExpressionKind.unknown:
            unsupported = true;
            return -1;
        case ExpressionKind.terminal:
            string text;
            if (CandidateGenerator.literalBytes(node.source, text)) {
                if (pos + text.length <= input.length && input[pos .. pos + text.length] == text)
                    return cast(ptrdiff_t)(pos + text.length);
                return -1;
            }
            if (node.source == "eps")
                return cast(ptrdiff_t)pos;
            if (node.source == "eoi" || node.source == "endOfInput")
                return pos == input.length ? cast(ptrdiff_t)pos : -1;
            if (node.source == "fail")
                return -1;
            if (node.byteTerminal && node.byteWidth == 1 && node.known)
                return pos < input.length && node.alphabet.contains(input[pos]) ? cast(ptrdiff_t)(pos + 1) : -1;
            unsupported = true;
            return -1;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            if (rule == size_t.max) {
                unsupported = true;
                return -1;
            }
            return match(graph.roots[rule], pos, depth + 1);
        case ExpressionKind.sequence:
            ptrdiff_t at = pos;
            foreach (child; node.children) {
                at = match(child, at, depth + 1);
                if (at < 0)
                    return -1;
            }
            return at;
        case ExpressionKind.choice:
            foreach (i, child; node.children) {
                const mark = events.length;
                const end = match(child, pos, depth + 1);
                if (end >= 0) {
                    const target = coverage.find(index, TargetKind.alternative, i);
                    if (target != size_t.max)
                        events ~= Event(target);
                    return end;
                }
                events.length = mark;
            }
            return -1;
        case ExpressionKind.optional:
            const mark = events.length;
            const end = match(node.children[0], pos, depth + 1);
            const taken = end >= 0;
            if (!taken)
                events.length = mark;
            const target = coverage.find(index, taken ? TargetKind.optionalTaken : TargetKind.optionalSkipped);
            if (target != size_t.max)
                events ~= Event(target);
            return taken ? end : cast(ptrdiff_t)pos;
        case ExpressionKind.repetition:
            return repeatLoop(index, node.children[0], pos, depth, 0);
        case ExpressionKind.predicate:
            const mark = events.length;
            const hit = match(node.children[0], pos, depth + 1) >= 0;
            events.length = mark; // events inside a predicate are not part of the derivation
            const wanted = node.combinator == "posLookahead";
            return hit == wanted ? cast(ptrdiff_t)pos : -1;
        case ExpressionKind.wrapper:
            if (node.combinator == "oneOrMore")
                return repeatLoop(index,
                        node.children[0], pos, depth, 1);
            return node.children.length ? match(node.children[0], pos, depth + 1) : cast(ptrdiff_t)pos;
        }
    }

    private ptrdiff_t repeatLoop(size_t index, size_t body, size_t pos, size_t depth, size_t least) {
        size_t count;
        ptrdiff_t at = pos;
        while (true) {
            const mark = events.length;
            const end = match(body, at, depth + 1);
            if (end < 0 || end == at) {
                events.length = mark;
                break;
            }
            at = end;
            ++count;
        }
        if (count < least)
            return -1;
        const kind = count == 0 ? TargetKind.repeatNone : count == 1 ? TargetKind.repeatOne : TargetKind.repeatMany;
        const target = coverage.find(index, kind);
        events ~= Event(target, index, count);
        return at;
    }

    /// Attribute an accepted whole-input sample. Returns false when the matcher cannot follow it.
    bool record(size_t startRule, string text) {
        input = text;
        events = null;
        unsupported = false;
        const end = match(graph.roots[startRule], 0, 0);
        if (unsupported || end != cast(ptrdiff_t)text.length) {
            ++coverage.unattributed;
            return false;
        }
        foreach (event; events) {
            if (event.target != size_t.max)
                ++coverage.targets[event.target].hits;
            if (event.node != size_t.max) {
                auto histogram = &coverage.repeatCounts[event.node];
                const bucket = event.count < 4096 ? event.count : 4096;
                if (histogram.length <= bucket)
                    histogram.length = bucket + 1;
                ++(*histogram)[bucket];
            }
        }
        ++coverage.attributed;
        return true;
    }
}

nothrow unittest {
    alias K = ExpressionKind;
    static void optionalTerminal(Expression terminal, string input, bool expected) nothrow {
        GrammarAnalysis graph;
        graph.names = ["Root"];
        graph.expressions = [terminal, Expression(K.optional, [0])];
        graph.roots = [1];
        auto coverage = buildTargets(graph, 0);
        auto matcher = Attributor(graph, coverage);
        assert(matcher.record(0, input) == expected);
        assert(coverage.attributed == cast(size_t)expected);
    }

    foreach (source; ["eps", "eoi", "endOfInput", "fail"]) {
        auto terminal = lit("a");
        terminal.source = source;
        terminal.nullable = source == "fail" ? Nullable.no : Nullable.yes;
        optionalTerminal(terminal, "", true);
        optionalTerminal(terminal, "a", false);
    }
    auto byteClass = lit("a");
    byteClass.source = "byteClass";
    byteClass.byteTerminal = true;
    byteClass.byteWidth = 1;
    byteClass.alphabet.addChar('a');
    optionalTerminal(byteClass, "a", true);
    optionalTerminal(byteClass, "b", false);
    optionalTerminal(byteClass, "", true);
    byteClass.known = false;
    optionalTerminal(byteClass, "", false);
    byteClass.known = true;
    byteClass.byteWidth = 2;
    optionalTerminal(byteClass, "", false);
    byteClass.byteTerminal = false;
    optionalTerminal(byteClass, "", false);
    Expression unresolved;
    unresolved.kind = K.reference;
    unresolved.reference = "Missing";
    optionalTerminal(unresolved, "", false);
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root"];
    graph.expressions = [
        lit("a"), lit("b"), Expression(K.choice, [0, 1]), Expression(K.predicate, [2]),
        Expression(K.sequence, [3, 0])
    ];
    graph.expressions[3].combinator = "posLookahead";
    graph.roots = [4];
    auto coverage = buildTargets(graph, 0);
    auto matcher = Attributor(graph, coverage);
    assert(matcher.record(0, "a"));
    assert(!matcher.record(0, "b"));
    assert(coverage.covered() == 0); // Predicate probes do not count as consumed derivations.
    matcher.depthLimit = 0;
    assert(!matcher.record(0, "a"));
    assert(coverage.unattributed == 2);
    // A filtered target view still permits attribution; it has no counters to increment.
    graph.roots = [2];
    coverage = buildTargets(graph, 0);
    coverage.targets = null;
    matcher = Attributor(graph, coverage);
    assert(matcher.record(0, "b") && coverage.attributed == 1);
    graph.expressions = [lit("a"), Expression(K.optional, [0])];
    graph.roots = [1];
    coverage = buildTargets(graph, 0);
    coverage.targets = null;
    matcher = Attributor(graph, coverage);
    assert(matcher.record(0, "") && coverage.attributed == 1);
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root"];
    graph.expressions = [lit("a"), Expression(K.repetition, [0])];
    graph.roots = [1];
    auto coverage = buildTargets(graph, 0);
    coverage.targets = null;
    auto matcher = Attributor(graph, coverage);
    auto bytes = new char[4097];
    bytes[] = 'a';
    assert(matcher.record(0, cast(string)bytes));
    assert(coverage.repeatCounts[1].length == 4097 && coverage.repeatCounts[1][4096] == 1);
    graph.expressions[0].source = "eps";
    graph.expressions[0].nullable = Nullable.yes;
    coverage = buildTargets(graph, 0);
    matcher = Attributor(graph, coverage);
    assert(matcher.record(0, "") && coverage.repeatCounts[1][0] == 1);
    graph.expressions[1].kind = K.wrapper;
    graph.expressions[1].combinator = "oneOrMore";
    coverage = buildTargets(graph, 0);
    matcher = Attributor(graph, coverage);
    assert(!matcher.record(0, ""));
}

/// All targets of the grammar, with reachability from `startRule` and statically unknown subtrees marked.
Coverage buildTargets(ref GrammarAnalysis graph, size_t startRule) nothrow {
    Coverage coverage;
    const count = graph.expressions.length;
    coverage.repeatCounts = new ulong[][count];
    auto reachable = new bool[count];
    void reach(size_t index) nothrow {
        if (index >= count || reachable[index])
            return;
        reachable[index] = true;
        auto node = graph.expressions[index];
        if (node.kind == ExpressionKind.reference) {
            const rule = graph.referenceRule(node);
            if (rule != size_t.max)
                reach(graph.roots[rule]);
        }
        foreach (child; node.children)
            reach(child);
    }

    reach(graph.roots[startRule]);
    // A subtree is unknown when evaluating it may hit an unsupported construct.
    auto unknownMemo = new byte[count]; // 0 unvisited, 1 visiting, 2 known, 3 unknown
    bool unknownNode(size_t index) nothrow {
        if (unknownMemo[index] == 2)
            return false;
        if (unknownMemo[index] >= 3)
            return true;
        if (unknownMemo[index] == 1)
            return false; // recursion cycle: judged by the other nodes on it
        unknownMemo[index] = 1;
        auto node = graph.expressions[index];
        bool result;
        final switch (node.kind) {
        case ExpressionKind.unknown:
            result = true;
            break;
        case ExpressionKind.terminal:
            string text;
            result = !(CandidateGenerator.literalBytes(node.source, text) || node.source == "eps"
                    || node.source == "eoi" || node.source == "endOfInput" || node.source == "fail"
                    || (node.byteTerminal && node.byteWidth == 1 && node.known));
            break;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            result = rule == size_t.max || unknownNode(graph.roots[rule]);
            break;
        case ExpressionKind.sequence:
        case ExpressionKind.choice:
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
        case ExpressionKind.predicate:
        case ExpressionKind.wrapper:
            foreach (child; node.children)
                result = unknownNode(child) || result;
            break;
        }
        unknownMemo[index] = result ? 3 : 2;
        return result;
    }

    foreach (index, node; graph.expressions) {
        void add(TargetKind kind, size_t alternative = 0) nothrow {
            Target target;
            target.node = index;
            target.kind = kind;
            target.alternative = alternative;
            target.reachable = reachable[index];
            target.unknown = unknownNode(index);
            coverage.targets ~= target;
        }

        if (node.kind == ExpressionKind.choice)
            foreach (i; 0 .. node.children.length)
                add(TargetKind.alternative, i);
        else if (node.kind == ExpressionKind.optional) {
                    add(TargetKind.optionalTaken);
                    add(TargetKind.optionalSkipped);
                } else if (node.kind == ExpressionKind.repetition) {
                    add(TargetKind.repeatNone);
                    add(TargetKind.repeatOne);
                    add(TargetKind.repeatMany);
                } else if (node.kind == ExpressionKind.wrapper && node.combinator == "oneOrMore") {
                    add(TargetKind.repeatOne);
                    add(TargetKind.repeatMany);
                }
    }
    return coverage;
}

version (unittest) {
    private Expression lit(string text) {
        Expression e;
        e.kind = ExpressionKind.terminal;
        e.known = true;
        e.nullable = Nullable.no;
        e.source = "literal!(\"" ~ text ~ "\")";
        return e;
    }
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root", "Dead"];
    graph.expressions = [
        lit("a"), // 0
        lit("ab"), // 1
        Expression(K.choice, [0, 1]), // 2
        lit("c"), // 3
        Expression(K.sequence, [2, 3]), // 4: Root <- ('a' / 'ab') 'c'
        lit("z"), // 5
        lit("y"), // 6
        Expression(K.choice, [5, 6]), // 7: Dead (unreachable)
        Expression(K.optional, [3]), // 8
        Expression(K.unknown), // 9
        Expression(K.choice, [9, 3]), // 10 unknown subtree (also unreachable)
    ];
    graph.roots = [4, 7];
    graph.solve();
    auto coverage = buildTargets(graph, 0);
    auto attributor = Attributor(graph, coverage);
    // "ac" is accepted by the PEG; "abc" is not (the first alternative hides 'ab'): it cannot be attributed.
    assert(attributor.record(0, "ac"));
    assert(!attributor.record(0, "abc") && coverage.unattributed == 1 && coverage.attributed == 1);
    const first = coverage.find(2, TargetKind.alternative, 0), second = coverage.find(2, TargetKind.alternative, 1);
    assert(coverage.targets[first].hits == 1 && coverage.targets[second].hits == 0);
    // Unreachable and unknown targets are tracked separately and excluded from the ratio.
    const dead = coverage.find(7, TargetKind.alternative, 0);
    assert(!coverage.targets[dead].reachable);
    assert(coverage.coverable() == 2 && coverage.covered() == 1);
    size_t unknown;
    foreach (t; coverage.targets)
        unknown += t.unknown;
    assert(unknown == 2); // the two alternatives of the choice containing the unknown node
}

nothrow unittest {
    // Repetition buckets, optional taken/skipped, predicates, left-recursion guard.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root", "Left"];
    graph.expressions = [
        lit("a"), // 0
        Expression(K.repetition, [0]), // 1: 'a'*
        lit("b"), // 2
        Expression(K.optional, [2]), // 3: 'b'?
        Expression(K.predicate, [2]), // 4: !'b'
        Expression(K.sequence, [4, 1, 3]), // 5: !'b' 'a'* 'b'?
        Expression(K.reference, null, "Left"), // 6
        Expression(K.sequence, [6, 0]), // 7
        Expression(K.choice, [7, 0]), // 8: Left <- Left 'a' / 'a'
    ];
    graph.expressions[4].combinator = "negLookahead";
    graph.roots = [5, 8];
    graph.solve();
    auto coverage = buildTargets(graph, 0);
    auto attributor = Attributor(graph, coverage);
    assert(attributor.record(0, "") && attributor.record(0, "a") && attributor.record(0, "aab"));
    assert(!attributor.record(0, "b")); // the predicate rejects it, so it is not an accepted sample
    foreach (kind; [
        TargetKind.repeatNone, TargetKind.repeatOne, TargetKind.repeatMany,
        TargetKind.optionalTaken, TargetKind.optionalSkipped
    ])
        assert(coverage.targets[coverage.find(kind == TargetKind.optionalTaken
                || kind == TargetKind.optionalSkipped ? 3 : 1, kind)].hits >= 1);
    auto left = buildTargets(graph, 1);
    auto guarded = Attributor(graph, left);
    assert(!guarded.record(1, "aa") && left.unattributed == 1); // left recursion is not followed
}

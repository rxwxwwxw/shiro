/** Learning generation weights from representative inputs (G5).

    A corpus is replayed through the reference derivation (`Attributor`): for every accepted, attributable input it counts
    which alternative each choice took, whether each `e?` was taken, and exact repetition counts. The result is exported
    as a G4 policy text. This is a *marginal* model: every construct is modeled independently of its context, parent rule
    or neighbors, so it does not reproduce the joint distribution of real inputs (a rule reached from two contexts shares one
    statistic), and it inherits the sampling bias of the corpus. The model records provenance and counts what it ignored.
*/
module npegged.learning;
import npegged.analysis;
import npegged.coverage;

nothrow:

private string decimal(size_t value) nothrow {
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

/// Names a construct the way policies do: rule name, kind, and preorder ordinal within the rule body.
struct Binding {
    string rule;
    size_t node;
    ExpressionKind kind; // choice, optional or repetition (the latter also covers `e+`)
    size_t ordinal;
}

Binding[] bindings(ref GrammarAnalysis graph) nothrow {
    Binding[] result;
    foreach (rule, root; graph.roots) {
        size_t[3] counters; // choice, optional, repetition
        auto seen = new bool[graph.expressions.length];
        void walk(size_t at) nothrow {
            if (at >= graph.expressions.length || seen[at])
                return;
            seen[at] = true;
            auto node = graph.expressions[at];
            const rep = node.kind == ExpressionKind.repetition
                || (node.kind == ExpressionKind.wrapper && node.combinator == "oneOrMore");
            if (node.kind == ExpressionKind.choice)
                result ~= Binding(graph.names[rule], at, ExpressionKind.choice, counters[0]++);
            else if (node.kind == ExpressionKind.optional)
                result ~= Binding(graph.names[rule], at, ExpressionKind.optional, counters[1]++);
            else if (rep)
                result ~= Binding(graph.names[rule], at, ExpressionKind.repetition, counters[2]++);
            foreach (child; node.children)
                walk(child);
        }

        walk(root);
    }
    return result;
}

nothrow unittest {
    GrammarAnalysis graph;
    graph.names = ["Root", "Missing"];
    graph.expressions = [
        Expression(ExpressionKind.terminal), Expression(ExpressionKind.optional, [0]),
        Expression(ExpressionKind.sequence, [1, 1])
    ];
    graph.roots = [2, 100];
    const result = bindings(graph);
    assert(result.length == 1 && result[0].node == 1 && result[0].ordinal == 0);
}

struct Learner {
nothrow:
    GrammarAnalysis* graph;
    size_t startRule;
    Coverage coverage;
    size_t invalid, ignoredUnattributed;

    this(ref GrammarAnalysis graph, size_t startRule) {
        this.graph = &graph;
        this.startRule = startRule;
        coverage = buildTargets(graph, startRule);
    }

    size_t learned() const {
        return coverage.attributed;
    }

    /// `accepted`: the real parser accepted the whole input. Invalid input teaches nothing and is only counted.
    void observe(string text, bool accepted) {
        if (!accepted) {
            ++invalid;
            return;
        }
        auto attributor = Attributor(*graph, coverage);
        if (!attributor.record(startRule, text))
            ++ignoredUnattributed;
    }

    private size_t hits(size_t node, TargetKind kind, size_t alternative = 0) const {
        const target = coverage.find(node, kind, alternative);
        return target == size_t.max ? 0 : coverage.targets[target].hits;
    }

    /// Policy text (npegged.policy format). Alternatives and optionals get `smoothing` added to every count so
    /// nothing observed-rare becomes impossible; repetition histograms contain only observed counts.
    string policyText(size_t smoothing = 1) {
        string text = "# learned from " ~ decimal(
                learned()) ~ " accepted sample(s); ignored: " ~ decimal(invalid) ~ " invalid, " ~ decimal(
                ignoredUnattributed) ~ " unattributable. Marginal per-construct statistics.\n";
        foreach (binding; bindings(*graph)) {
            auto node = graph.expressions[binding.node];
            if (binding.kind == ExpressionKind.choice) {
                string line = "choice " ~ binding.rule ~ " " ~ decimal(binding.ordinal) ~ " weights";
                foreach (i; 0 .. node.children.length)
                    line ~= " " ~ decimal(hits(binding.node, TargetKind.alternative, i) + smoothing);
                text ~= line ~ "\n";
            } else if (binding.kind == ExpressionKind.optional) {
                const taken = hits(binding.node, TargetKind.optionalTaken) + smoothing;
                const skipped = hits(binding.node, TargetKind.optionalSkipped) + smoothing;
                const permille = taken * 1000 / (taken + skipped);
                text ~= "optional " ~ binding.rule ~ " " ~ decimal(binding.ordinal) ~ " probability " ~ (permille >= 1000
                        ? "1" : "0." ~ (permille < 100 ? "0" : "") ~ (permille < 10 ? "0" : "") ~ decimal(permille))
                    ~ "\n";
            } else if (coverage.repeatCounts[binding.node].length) {
                string line = "repeat " ~ binding.rule ~ " " ~ decimal(binding.ordinal) ~ " histogram";
                foreach (count, weight; coverage.repeatCounts[binding.node])
                    if (weight)
                        line ~= " " ~ decimal(count) ~ ":" ~ decimal(weight);
                text ~= line ~ "\n";
            }
        }
        return text;
    }

    /// Per-choice alternative shares in permille (observed, unsmoothed), flattened over `bindings` of kind choice.
    ulong[] choiceShares() {
        ulong[] shares;
        foreach (binding; bindings(*graph)) {
            if (binding.kind != ExpressionKind.choice)
                continue;
            const alternatives = graph.expressions[binding.node].children.length;
            ulong total;
            foreach (i; 0 .. alternatives)
                total += hits(binding.node, TargetKind.alternative, i);
            foreach (i; 0 .. alternatives)
                shares ~= total ? hits(binding.node, TargetKind.alternative, i) * 1000 / total : 0;
        }
        return shares;
    }
}

nothrow unittest {
    GrammarAnalysis graph;
    graph.names = ["Root"];
    Expression terminal;
    terminal.kind = ExpressionKind.terminal;
    terminal.source = "literal!(\"x\")";
    terminal.known = true;
    terminal.nullable = Nullable.no;
    graph.expressions = [terminal, Expression(ExpressionKind.optional, [0])];
    graph.roots = [1];
    graph.solve();
    foreach (skipped; [0, 19, 999]) {
        auto learner = Learner(graph, 0);
        learner.observe("x", true);
        foreach (_; 0 .. skipped)
            learner.observe("", true);
        assert(learner.hits(size_t.max, TargetKind.alternative) == 0);
        const expected = skipped == 0 ? "optional Root 0 probability 1\n" : skipped == 19
            ? "optional Root 0 probability 0.050\n" : "optional Root 0 probability 0.001\n";
        const text = learner.policyText(0);
        assert(text.length >= expected.length && text[$ - expected.length .. $] == expected);
    }
}

/// Mean absolute difference of two share vectors, in permille (total variation distance averaged over entries).
size_t shareDistance(const ulong[] a, const ulong[] b) @nogc nothrow {
    if (a.length != b.length || !a.length)
        return 1000;
    ulong sum;
    foreach (i; 0 .. a.length)
        sum += a[i] > b[i] ? a[i] - b[i] : b[i] - a[i];
    return cast(size_t)(sum / a.length);
}

@nogc nothrow unittest {
    const ulong[1] one = [1];
    assert(shareDistance(null, null) == 1000);
    assert(shareDistance(one[], null) == 1000);
}

/// Total variation distance (permille) between two length distributions bucketed by powers of two.
size_t lengthDistance(const string[] a, const string[] b) nothrow {
    if (!a.length || !b.length)
        return 1000;
    size_t[16] left, right;
    size_t bucket(size_t length) nothrow {
        size_t n;
        while (length > 0 && n < 15) {
            length >>= 1;
            ++n;
        }
        return n;
    }

    foreach (text; a)
        ++left[bucket(text.length)];
    foreach (text; b)
        ++right[bucket(text.length)];
    ulong sum;
    foreach (i; 0 .. 16) {
        const x = left[i] * 1000 / a.length, y = right[i] * 1000 / b.length;
        sum += x > y ? x - y : y - x;
    }
    return cast(size_t)(sum / 2);
}

nothrow unittest {
    string large = new immutable(char)[32768];
    string larger = new immutable(char)[65536];
    assert(lengthDistance(null, ["a"]) == 1000);
    assert(lengthDistance(["a"], null) == 1000);
    assert(lengthDistance([""], [large]) == 1000);
    assert(lengthDistance([large], [larger]) == 0);
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root"];
    Expression lit(string t) {
        Expression e;
        e.kind = K.terminal;
        e.known = true;
        e.nullable = Nullable.no;
        e.source = "literal!(\"" ~ t ~ "\")";
        return e;
    }

    graph.expressions = [
        lit("a"), lit("b"), Expression(K.choice, [0, 1]), // 2: 'a' / 'b'
        lit("x"), Expression(K.optional, [3]), // 4: 'x'?
        lit("y"), Expression(K.repetition, [5]), // 6: 'y'*
        Expression(K.sequence, [2, 4, 6]), // 7
    ];
    graph.roots = [7];
    graph.solve();
    auto learner = Learner(graph, 0);
    foreach (text; ["a", "ax", "ayy", "ayyy", "bx", "b"])
        learner.observe(text, true);
    learner.observe("zzz", false);
    learner.observe("a?", true); // accepted claim the matcher cannot follow
    assert(learner.learned() == 6 && learner.invalid == 1 && learner.ignoredUnattributed == 1);
    const policy = learner.policyText(0);
    // 'a' 4 times, 'b' 2; 'x' taken 2 of 6; y histogram: 0 x3 (a,b,bx... counted), 2 x1, 3 x1
    assert(policy[0 .. 9] == "# learned");
    assert(learner.choiceShares() == [666, 333]);
    // exact repetition counts are kept
    const histogram = learner.coverage.repeatCounts[6];
    assert(histogram[0] == 4 && histogram[2] == 1 && histogram[3] == 1);
    assert(shareDistance([666, 333], [500, 500]) == 166);
    assert(lengthDistance(["a", "bb"], ["a", "bb"]) == 0 && lengthDistance(["a"], ["aaaaaaaa"]) == 1000);
}

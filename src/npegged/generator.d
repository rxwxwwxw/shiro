/** Cold, seeded candidate generator for PEG grammars (G1). No parser is involved: a walk of the expression
    graph *proposes* strings. A proposal is NOT known to be accepted (ordered choice, greedy repetition and
    predicates make that undecidable by walking); G2 filters candidates through the real parser.

    PRNG: splitmix64 seeded from `GeneratorOptions.seed`; one 64-bit state, fully deterministic and portable.
    Streams are reproducible: the same grammar, start rule, options and seed give the same candidates.

    Repetition lengths are skewed on purpose: `e*` is empty with probability 1/4, otherwise 1 + a geometric tail
    (each extra repeat with probability 1/2) capped at `maxRepeat`; one repetition in 32 may instead reach up to
    4 * maxRepeat. `e?` is taken with probability 1/2. Choices are uniform (weights arrive with G4).

    Termination: past `softDepth` a choice takes its alternative with the smallest minimal output length, so any
    productive grammar finishes; `maxDepth` is a hard stop, as is `maxOutput` bytes. Hitting a budget or an
    unsupported construct yields a status, never an unmarked candidate.
*/
module npegged.generator;
import npegged.analysis;
import npegged.bites : BitesAnalysis;
import npegged.peg : CharSetMask;

nothrow:

enum GenStatus : ubyte {
    ok,
    unsupported, /// the walk met a construct it cannot propose input for
    budgetExceeded /// depth or output budget hit
}

struct GeneratorOptions {
    ulong seed = 1;
    size_t maxDepth = 48;
    size_t softDepth = 12;
    size_t maxOutput = 4096;
    size_t maxRepeat = 8;
}

struct Candidate {
    GenStatus status;
    string text;
    string reason; /// why generation failed, when it did
}

private ulong splitmix(ref ulong state) @nogc pure {
    state += 0x9E3779B97F4A7C15UL;
    ulong z = state;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    return z ^ (z >> 31);
}

@nogc pure nothrow unittest {
    ulong a = 1, b = 1, c = 2;
    assert(splitmix(a) == splitmix(b) && splitmix(a) == splitmix(b));
    ulong first = 1;
    assert(splitmix(first) == 0x910A2DEC89025CC1UL); // splitmix64 reference value for seed 1
    assert(splitmix(c) != splitmix(first));
}

private enum size_t infinite = size_t.max / 4;

struct CandidateGenerator {
nothrow:
    private GrammarAnalysis* graph;
    private GeneratorOptions options;
    private size_t startRule;
    private ulong state;
    private size_t[] minimal; // minimal output length per expression, `infinite` when none
    private bool failed;
    private string failure;
    private GenStatus failureStatus;
    private char[] output;
    /// Per-alternative weights (flattened by `altBase`) and per-repetition bias; defaults reproduce uniform G1 behavior.
    ulong[] altWeight;
    size_t[] altBase; // node -> offset into altWeight, size_t.max for non-choices
    ubyte[] repeatBias; // node -> 0 default, 1 empty/skip, 2 one/take, 3 many
    bool[] proposedAlt; // alternatives the *walk* chose (not necessarily accepted), same layout as altWeight
    /// Policy hooks (G4). Unset values keep the G1 behavior bit for bit.
    ulong[][] repeatHist; // node -> weight per repetition count (index = count); empty = default distribution
    ushort[] optionalPermille; // node -> probability of taking `e?` in 1/1000, 0xFFFF = default 1/2
    ulong attenuationPermille = 1000; // weight of a recursive alternative is scaled by (attenuation/1000)^depth
    bool[] altRecursive; // alternative can reach its own rule again; same layout as altWeight

    this(ref GrammarAnalysis graph, size_t startRule, GeneratorOptions options = GeneratorOptions.init) {
        this.graph = &graph;
        this.options = options;
        this.startRule = startRule;
        this.state = options.seed;
        computeMinimal();
        altBase = new size_t[graph.expressions.length];
        repeatBias = new ubyte[graph.expressions.length];
        size_t total;
        foreach (index, node; graph.expressions) {
            altBase[index] = size_t.max;
            if (node.kind == ExpressionKind.choice) {
                altBase[index] = total;
                total += node.children.length;
            }
        }
        altWeight = new ulong[total];
        altWeight[] = 1;
        proposedAlt = new bool[total];
        altRecursive = new bool[total];
        repeatHist = new ulong[][graph.expressions.length];
        optionalPermille = new ushort[graph.expressions.length];
        optionalPermille[] = 0xFFFF;
        markRecursiveAlternatives();
    }

    /// An alternative is recursive when following references from it can reach the rule that owns the choice.
    private void markRecursiveAlternatives() {
        const rules = graph.roots.length;
        auto reaches = new bool[][rules];
        foreach (rule; 0 .. rules) {
            reaches[rule] = new bool[rules];
            auto seen = new bool[graph.expressions.length];
            void visit(size_t index) nothrow {
                if (index >= graph.expressions.length || seen[index])
                    return;
                seen[index] = true;
                auto node = graph.expressions[index];
                if (node.kind == ExpressionKind.reference) {
                    const target = graph.referenceRule(node);
                    if (target != size_t.max && !reaches[rule][target]) {
                        reaches[rule][target] = true;
                        visit(graph.roots[target]);
                    }
                }
                foreach (child; node.children)
                    visit(child);
            }

            visit(graph.roots[rule]);
        }
        foreach (rule, root; graph.roots) {
            auto seen = new bool[graph.expressions.length];
            void own(size_t index) nothrow {
                if (index >= graph.expressions.length || seen[index])
                    return;
                seen[index] = true;
                auto node = graph.expressions[index];
                if (node.kind == ExpressionKind.choice)
                    foreach (alternative, child; node.children) {
                        auto inner = new bool[graph.expressions.length];
                        bool recursive;
                        void scan(size_t at) nothrow {
                            if (at >= graph.expressions.length || inner[at] || recursive)
                                return;
                            inner[at] = true;
                            auto n = graph.expressions[at];
                            if (n.kind == ExpressionKind.reference) {
                                const target = graph.referenceRule(n);
                                if (target != size_t.max && (target == rule || reaches[target][rule]))
                                    recursive = true;
                            }
                            foreach (c; n.children)
                                scan(c);
                        }

                        scan(child);
                        altRecursive[altBase[index] + alternative] = recursive;
                    }
                foreach (child; node.children)
                    own(child);
            }

            own(root);
        }
    }

    /// Weight 0 disables an alternative; if every alternative of a choice is disabled the walk reports a failure.
    void setWeight(size_t node, size_t alternative, ulong weight) {
        if (node < altBase.length && altBase[node] != size_t.max && alternative < graph
                .expressions[node].children.length)
            altWeight[altBase[node] + alternative] = weight;
    }

    void setRepeatBias(size_t node, ubyte bias) {
        if (node < repeatBias.length)
            repeatBias[node] = bias;
    }

    nothrow unittest {
        GrammarAnalysis graph;
        graph.expressions = [
            Expression(ExpressionKind.choice, [1, 2]), Expression(ExpressionKind.terminal),
            Expression(ExpressionKind.terminal)
        ];
        CandidateGenerator generator;
        generator.graph = &graph;
        generator.altBase = [0, size_t.max, size_t.max];
        generator.altWeight = [1, 1];
        generator.repeatBias = [0, 0, 0];
        generator.setWeight(3, 0, 99);
        generator.setWeight(1, 0, 99);
        generator.setWeight(0, 2, 99);
        assert(generator.altWeight == [1, 1]);
        generator.setWeight(0, 1, 7);
        assert(generator.altWeight == [1, 7]);
        generator.setRepeatBias(3, 3);
        generator.setRepeatBias(1, 2);
        assert(generator.repeatBias == [0, 2, 0]);
    }

    private ulong roll() {
        return splitmix(state);
    }

    private bool chance(ulong numerator, ulong denominator) {
        return roll() % denominator < numerator;
    }

    /// Smallest output length of every expression, by fixed point from "infinite".
    private void computeMinimal() {
        const count = graph.expressions.length;
        minimal = new size_t[count];
        minimal[] = infinite;
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (index; 0 .. count) {
                auto node = graph.expressions[index];
                size_t value = infinite;
                final switch (node.kind) {
                case ExpressionKind.unknown:
                    break;
                case ExpressionKind.terminal:
                    value = terminalLength(node);
                    break;
                case ExpressionKind.reference:
                    const rule = graph.referenceRule(node);
                    if (rule != size_t.max)
                        value = minimal[graph.roots[rule]];
                    break;
                case ExpressionKind.sequence:
                    value = 0;
                    foreach (child; node.children)
                        value = add(value, minimal[child]);
                    break;
                case ExpressionKind.choice:
                    foreach (child; node.children)
                        value = minimal[child] < value ? minimal[child] : value;
                    break;
                case ExpressionKind.optional:
                case ExpressionKind.repetition:
                case ExpressionKind.predicate:
                    value = 0;
                    break;
                case ExpressionKind.wrapper:
                    value = node.children.length ? minimal[node.children[0]] : infinite;
                    break;
                }
                if (value < minimal[index]) {
                    minimal[index] = value;
                    changed = true;
                }
            }
        }
    }

    private static size_t add(size_t a, size_t b) @nogc {
        return a >= infinite || b >= infinite ? infinite : a + b;
    }

    @nogc nothrow unittest {
        assert(add(3, 4) == 7);
        assert(add(infinite, 0) == infinite && add(0, infinite) == infinite);
    }

    /// Bytes a terminal produces, or `infinite` when this module cannot propose input for it.
    private size_t terminalLength(ref Expression node) {
        string text;
        if (literalBytes(node.source, text))
            return text.length;
        if (node.source == "eps" || node.source == "eoi" || node.source == "endOfInput")
            return 0;
        if (node.byteTerminal && node.byteWidth == 1 && node.known && !node.alphabet.empty)
            return 1;
        return infinite;
    }

    nothrow unittest {
        GrammarAnalysis graph;
        graph.names = ["Root"];
        graph.expressions = [Expression(ExpressionKind.terminal)];
        graph.roots = [0];
        foreach (source; ["eps", "eoi", "endOfInput"]) {
            graph.expressions[0].source = source;
            auto generator = CandidateGenerator(graph, 0);
            const candidate = generator.next();
            assert(candidate.status == GenStatus.ok && candidate.text.length == 0);
        }
        auto terminal = Expression(ExpressionKind.terminal);
        terminal.source = "charClass!(\"x\")";
        terminal.known = true;
        terminal.byteTerminal = true;
        terminal.byteWidth = 1;
        terminal.alphabet.addChar('x');
        graph.expressions[0] = terminal;
        auto generator = CandidateGenerator(graph, 0);
        assert(generator.next().text == "x");
        foreach (variant; 0 .. 3) {
            graph.expressions[0] = terminal;
            if (variant == 0)
                graph.expressions[0].known = false;
            else if (variant == 1)
                graph.expressions[0].byteWidth = 2;
            else
                graph.expressions[0].alphabet = CharSetMask.init;
            auto unsupported = CandidateGenerator(graph, 0);
            assert(unsupported.next().status == GenStatus.unsupported);
        }
    }

    /// Decode `literal!("...")` including the simple escapes; anything else is not supported.
    static bool literalBytes(string source, out string bytes) {
        enum head = "literal!(";
        if (source.length < head.length + 3 || source[0 .. head.length] != head)
            return false;
        size_t at = head.length;
        const quote = source[at++];
        if (quote != '"' && quote != '\'')
            return false;
        while (at < source.length && source[at] != quote) {
            if (source[at] != '\\') {
                bytes ~= source[at++];
                continue;
            }
            if (at + 1 >= source.length)
                return false;
            const escape = source[at + 1];
            at += 2;
            switch (escape) {
            case 'n':
                bytes ~= '\n';
                break;
            case 't':
                bytes ~= '\t';
                break;
            case 'r':
                bytes ~= '\r';
                break;
            case '0':
                bytes ~= '\0';
                break;
            case '\\':
            case '"':
            case '\'':
                bytes ~= escape;
                break;
            case 'x':
                if (at + 1 >= source.length)
                    return false;
                int value;
                foreach (digit; source[at .. at + 2]) {
                    const v = digit >= '0' && digit <= '9' ? digit - '0' : digit >= 'a' && digit <= 'f'
                        ? digit - 'a' + 10 : digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : -1;
                    if (v < 0)
                        return false;
                    value = value * 16 + v;
                }
                at += 2;
                bytes ~= cast(char)value;
                break;
            default:
                return false;
            }
        }
        return at + 2 == source.length && source[at + 1] == ')';
    }

    nothrow unittest {
        string bytes;
        assert(literalBytes(`literal!("")`, bytes) && bytes.length == 0);
        assert(literalBytes(`literal!('x')`, bytes) && bytes == "x");
        assert(literalBytes(`literal!("\n\t\r\0\\\"\'\x0a\xAF")`, bytes) && bytes == "\n\t\r\0\\\"'\n\xAF");
        foreach (source; [
            "", "not-a-literal-expression", `literal!(abc)`, `literal!("unterminated`,
            `literal!("\`, `literal!("\x`, `literal!("\x0`,
            `literal!("\xgg")`, `literal!("\x/0")`, `literal!("\z")`, `literal!("a"X`,
            `literal!("a")suffix`
        ])
            assert(!literalBytes(source, bytes));
    }

    /// Weight after recursion attenuation. With attenuation active every weight is scaled by 1000 so that a recursive
    /// alternative, multiplied by (attenuation/1000) per level of depth, keeps resolution; a positive weight never drops
    /// to zero (attenuation changes likelihood, never availability).
    private ulong effectiveWeight(size_t slot, size_t depth) {
        ulong weight = altWeight[slot];
        if (attenuationPermille >= 1000 || !weight)
            return weight;
        weight *= 1000;
        if (!altRecursive[slot])
            return weight;
        foreach (_; 0 .. depth) {
            weight = weight * attenuationPermille / 1000;
            if (weight == 0)
                return 1;
        }
        return weight ? weight : 1;
    }

    nothrow unittest {
        CandidateGenerator generator;
        generator.altWeight = [1, 0, 2];
        generator.altRecursive = [true, true, false];
        assert(generator.effectiveWeight(0, 4) == 1);
        generator.attenuationPermille = 1;
        assert(generator.effectiveWeight(1, 4) == 0);
        assert(generator.effectiveWeight(2, 4) == 2000);
        assert(generator.effectiveWeight(0, 0) == 1000);
        assert(generator.effectiveWeight(0, 100) == 1);
    }

    private void fail(GenStatus status, string reason) {
        if (!failed) {
            failed = true;
            failureStatus = status;
            failure = reason;
        }
    }

    nothrow unittest {
        CandidateGenerator generator;
        generator.fail(GenStatus.unsupported, "first");
        generator.fail(GenStatus.budgetExceeded, "second");
        assert(generator.failureStatus == GenStatus.unsupported && generator.failure == "first");
    }

    private void emit(string text) {
        if (output.length + text.length > options.maxOutput)
            fail(GenStatus.budgetExceeded, "output budget exceeded");
        else
            output ~= text;
    }

    private void walk(size_t index, size_t depth) {
        if (failed)
            return;
        if (depth > options.maxDepth) {
            fail(GenStatus.budgetExceeded, "recursion depth budget exceeded");
            return;
        }
        auto node = graph.expressions[index];
        final switch (node.kind) {
        case ExpressionKind.unknown:
            fail(GenStatus.unsupported,
                    "unknown or unsupported node (action, parameter, external)");
            return;
        case ExpressionKind.terminal:
            string text;
            if (literalBytes(node.source, text))
                emit(text);
            else if (node.source == "eps" || node.source == "eoi" || node.source == "endOfInput") {
            } else if (node.byteTerminal && node.byteWidth == 1 && node.known && !node.alphabet.empty) {
                size_t members;
                foreach (c; 0 .. 256)
                    members += node.alphabet.contains(cast(char)c);
                size_t pick = roll() % members;
                foreach (c; 0 .. 256)
                    if (node.alphabet.contains(cast(char)c)) {
                        if (pick == 0) {
                            emit([cast(char)c].idup);
                            break;
                        }
                        --pick;
                    }
            } else
                fail(GenStatus.unsupported, "terminal without a byte description: " ~ node.source);
            return;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            if (rule == size_t.max)
                fail(GenStatus.unsupported, "unresolved reference: " ~ node.reference);
            else
                walk(graph.roots[rule], depth + 1);
            return;
        case ExpressionKind.sequence:
            foreach (child; node.children)
                walk(child, depth);
            return;
        case ExpressionKind.choice:
            if (!node.children.length) {
                fail(GenStatus.unsupported, "empty choice never succeeds");
                return;
            }
            size_t chosen;
            if (depth >= options.softDepth) {
                // Terminate: take the cheapest alternative, ties broken by the stream.
                size_t best = infinite + 1, ties;
                foreach (i, child; node.children) {
                    if (minimal[child] < best) {
                        best = minimal[child];
                        chosen = i;
                        ties = 1;
                    } else if (minimal[child] == best && roll() % ++ties == 0)
                        chosen = i;
                }
            } else {
                const base = altBase[index];
                ulong total;
                foreach (i; 0 .. node.children.length)
                    total += effectiveWeight(base + i, depth);
                if (!total) {
                    fail(GenStatus.unsupported, "every alternative of a choice is disabled");
                    return;
                }
                ulong pick = roll() % total;
                foreach (i; 0 .. node.children.length) {
                    const weight = effectiveWeight(base + i, depth);
                    if (pick < weight) {
                        chosen = i;
                        break;
                    }
                    pick -= weight;
                }
            }
            proposedAlt[altBase[index] + chosen] = true;
            walk(node.children[chosen], depth + 1);
            return;
        case ExpressionKind.optional:
            if (depth < options.softDepth) {
                const bias = repeatBias[index];
                const permille = optionalPermille[index];
                const take = bias == 1 ? false : bias >= 2 ? true : permille != 0xFFFF
                    ? chance(permille, 1000) : chance(1, 2);
                if (take)
                    walk(node.children[0], depth + 1);
            }
            return;
        case ExpressionKind.repetition:
            repeat(node.children[0], 0, depth, repeatBias[index], index);
            return;
        case ExpressionKind.predicate:
            return; // zero-width: the oracle decides whether the surrounding sequence is accepted
        case ExpressionKind.wrapper:
            if (node.combinator == "oneOrMore")
                repeat(node.children[0], 1,
                        depth, repeatBias[index]);
            else if (node.children.length)
                walk(node.children[0], depth);
            return;
        }
    }

    private void repeat(size_t body, size_t least, size_t depth, ubyte bias = 0, size_t node = size_t.max) {
        size_t count = least;
        if (node != size_t.max && repeatHist[node].length && depth < options.softDepth) {
            // Policy histogram: weight per repetition count; counts below the minimum are clamped to it.
            ulong total;
            foreach (weight; repeatHist[node])
                total += weight;
            if (total) {
                ulong pick = roll() % total;
                foreach (length, weight; repeatHist[node]) {
                    if (pick < weight) {
                        count = length < least ? least : length;
                        break;
                    }
                    pick -= weight;
                }
            }
        } else if (depth < options.softDepth && bias != 0 && chance(3, 4)) {
            // Guided: aim at a specific bucket (empty / one / many), still respecting the minimum.
            count = bias == 1 ? least : bias == 2 ? (least > 1 ? least : 1) : (least > 3 ? least : 3);
        } else if (depth < options.softDepth) {
            const longRun = chance(1, 32);
            const cap = longRun ? options.maxRepeat * 4 : options.maxRepeat;
            if (least == 0) {
                if (!chance(1, 4)) {
                    count = 1;
                    while (count < cap && chance(1, 2))
                        ++count;
                }
            } else
                while (count < cap && chance(1, 2))
                    ++count;
        }
        size_t emptyRounds;
        foreach (i; 0 .. count) {
            const before = output.length;
            walk(body, depth + 1);
            if (output.length == before && ++emptyRounds >= 2)
                return; // a nullable body made no progress twice: stop looping
        }
    }

    /// Next candidate of the stream (always consumes randomness, also on failure).
    Candidate next() {
        failed = false;
        failure = null;
        output = null;
        walk(graph.roots[startRule], 0);
        Candidate result;
        result.status = failed ? failureStatus : GenStatus.ok;
        result.reason = failure;
        result.text = failed ? null : cast(string)output.idup;
        return result;
    }
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
    graph.names = ["Root", "R"];
    graph.expressions = [
        lit("ab"), // 0
        Expression(K.repetition, [0]), // 1
        Expression(K.sequence, [1, 0]), // 2: ('ab')* 'ab'
        Expression(K.reference, null, "R"), // 3
        lit("x"), // 4
        Expression(K.sequence, [4, 3]), // 5: 'x' R
        lit("y"), // 6
        Expression(K.choice, [5, 6]), // 7: R <- 'x' R / 'y'
        Expression(K.unknown), // 8
    ];
    graph.roots = [2, 7];
    graph.solve();
    // determinism and divergence
    auto one = CandidateGenerator(graph, 0);
    auto two = CandidateGenerator(graph, 0);
    GeneratorOptions other;
    other.seed = 99;
    auto three = CandidateGenerator(graph, 0, other);
    string[] a, b, c;
    foreach (i; 0 .. 40) {
        a ~= one.next().text;
        b ~= two.next().text;
        c ~= three.next().text;
    }
    assert(a == b && a != c);
    foreach (text; a)
        assert(text.length >= 2 && text.length % 2 == 0 && text[$ - 2 .. $] == "ab");
    // repetition lengths are skewed and include the minimal one
    bool sawShort, sawLong;
    foreach (text; a) {
        sawShort = sawShort || text.length == 2;
        sawLong = sawLong || text.length >= 8;
    }
    assert(sawShort && sawLong);
    // right recursion terminates and respects the budgets
    GeneratorOptions deep;
    deep.softDepth = 3;
    auto recursive = CandidateGenerator(graph, 1, deep);
    foreach (i; 0 .. 200) {
        auto candidate = recursive.next();
        assert(candidate.status == GenStatus.ok && candidate.text.length < 64);
        assert(candidate.text[$ - 1] == 'y');
    }
    // hard output stop reports a status, never a truncated candidate
    GeneratorOptions tiny;
    tiny.maxOutput = 1;
    auto bounded = CandidateGenerator(graph, 0, tiny);
    auto over = bounded.next();
    assert(over.status == GenStatus.budgetExceeded && over.text is null);
}

nothrow unittest {
    // Budgets and malformed graphs fail with a status instead of producing a candidate.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Dangling", "Empty", "Deep"];
    graph.expressions = [
        Expression(K.reference, null, "Missing"), // 0
        Expression(K.choice, null), // 1: no alternatives
        Expression(K.reference, null, "Deep"), // 2: Deep <- Deep
    ];
    graph.roots = [0, 1, 2];
    graph.solve();
    auto dangling = CandidateGenerator(graph, 0).next();
    assert(dangling.status == GenStatus.unsupported);
    auto empty = CandidateGenerator(graph, 1).next();
    assert(empty.status == GenStatus.unsupported);
    GeneratorOptions shallow;
    shallow.maxDepth = 3;
    auto deep = CandidateGenerator(graph, 2, shallow).next();
    assert(deep.status == GenStatus.budgetExceeded);
}

nothrow unittest {
    // minimal lengths, unsupported nodes, nullable loop termination, literal escapes
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Unknown", "Loop", "Escapes"];
    graph.expressions = [
        Expression(K.unknown), // 0
        Expression(K.terminal), // 1 placeholder (eps)
        Expression(K.optional, [1]), // 2
        Expression(K.repetition, [2]), // 3: (eps?)*  nullable body
        Expression(K.terminal), // 4: escapes
    ];
    graph.expressions[1].source = "eps";
    graph.expressions[1].known = true;
    graph.expressions[1].nullable = Nullable.yes;
    graph.expressions[4].source = "literal!(\"a\\n\\x41\\\\\")";
    graph.expressions[4].known = true;
    graph.roots = [0, 3, 4];
    graph.solve();
    auto unsupported = CandidateGenerator(graph, 0).next();
    assert(unsupported.status == GenStatus.unsupported && unsupported.reason.length);
    auto loop = CandidateGenerator(graph, 1);
    foreach (i; 0 .. 50)
        assert(loop.next().text.length == 0); // terminates, produces the empty string
    auto escapes = CandidateGenerator(graph, 2).next();
    assert(escapes.status == GenStatus.ok && escapes.text == "a\nA\\");
    string bytes;
    assert(!CandidateGenerator.literalBytes("literal!(\"\\u00e9\")", bytes));
    assert(CandidateGenerator.literalBytes("literal!(\"\xc3\xa9\")", bytes) && bytes == "\xc3\xa9");
}

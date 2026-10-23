/** Report-only BITES machinery (B2-B5). Consumes the expression graph; changes no generated code.

    SUCC(e): sound *lower* approximation of the inputs on which e succeeds.
    NULL(e): sound *upper* approximation of the inputs on which e may succeed consuming nothing.
    Unknown, unsupported, recursive or budget-exceeded cases degrade in the sound direction:
    SUCC -> empty, NULL -> universal. See docs/BITES.md for the contract and scope.
*/
module npegged.bites;
import npegged.analysis;
import npegged.language;
import npegged.peg : CharSetMask;

nothrow:

/// Terminal languages shared by every approximation.
private struct TerminalShape {
    bool exact; // SUCC is exactly `succ`
    InputLanguage succ;
    bool zeroWidth; // eps/eoi/empty literal: never bites
    InputLanguage nullable; // inputs where the terminal may succeed empty
    bool known;
}

struct BitesAnalysis {
nothrow:
    GrammarAnalysis* graph;
    Budget budget;
    /// Times a budget overflow or a recursive back edge forced a conservative answer.
    size_t degradations, cuts, unknowns;
    private InputLanguage[] succMemo, nullMemo, bitesMemo;
    private bool[] succDone, nullDone, succActive, nullActive, bitesDone, bitesActive;

    /// B7 study: sound regular extensions of SUCC (fixed-length sequences, negative lookahead).
    bool regularSucc;
    private InputLanguage[] maySuccMemo;
    private bool[] maySuccDone, maySuccActive;

    this(ref GrammarAnalysis graph, Budget budget = Budget.init, bool regularSucc = false) {
        this.graph = &graph;
        this.budget = budget;
        this.regularSucc = regularSucc;
        const count = graph.expressions.length;
        succMemo = new InputLanguage[count];
        nullMemo = new InputLanguage[count];
        succDone = new bool[count];
        nullDone = new bool[count];
        succActive = new bool[count];
        nullActive = new bool[count];
        bitesMemo = new InputLanguage[count];
        bitesDone = new bool[count];
        bitesActive = new bool[count];
        maySuccMemo = new InputLanguage[count];
        maySuccDone = new bool[count];
        maySuccActive = new bool[count];
    }

    /// Lower approximation: an overflowed language is replaced by the empty one.
    private InputLanguage lower(InputLanguage value) {
        degradations += value.overflow;
        return value.overflow ? InputLanguage.empty() : value;
    }

    /// Upper approximation: an overflowed language is replaced by the universal one.
    private InputLanguage upper(InputLanguage value) {
        degradations += value.overflow;
        return value.overflow ? InputLanguage.universal() : value;
    }

    static string plainLiteral(string source) {
        // Only escape-free literals are decoded; anything else falls back to FIRST bytes.
        enum head = "literal!(";
        if (source.length < head.length + 3 || source[0 .. head.length] != head)
            return null;
        size_t start = head.length;
        if (source[start] != '"' && source[start] != '\'')
            return null;
        const quote = source[start++];
        // A decoded empty literal is distinct from unsupported input (null).
        string text = source[start .. start];
        while (start < source.length && source[start] != quote) {
            if (source[start] == '\\')
                return null;
            text ~= source[start++];
        }
        return start + 2 == source.length && source[start + 1] == ')' ? text : null;
    }

    nothrow unittest {
        assert(plainLiteral(`literal!("")`) !is null && plainLiteral(`literal!("")`).length == 0);
        assert(plainLiteral(`literal!('ab')`) == "ab");
        foreach (source; [
            "", "not-a-literal-expression", `literal!(abc)`, `literal!("\n")`,
            `literal!("unterminated`, `literal!("a"X`, `literal!("a")suffix`
        ])
            assert(plainLiteral(source) is null);
    }

    private TerminalShape terminal(ref Expression node) {
        TerminalShape shape;
        shape.succ = InputLanguage.empty();
        shape.nullable = InputLanguage.universal();
        const source = node.source;
        if (source == "eps") {
            shape.known = shape.exact = shape.zeroWidth = true;
            shape.succ = InputLanguage.universal();
        } else if (source == "eoi" || source == "endOfInput") {
            shape.known = shape.exact = shape.zeroWidth = true;
            shape.succ = InputLanguage.endOfInput();
            shape.nullable = shape.succ;
        } else if (source == "fail") {
            shape.known = shape.exact = true;
            shape.nullable = InputLanguage.empty();
        } else if (auto text = plainLiteral(source)) {
            shape.known = true;
            if (text.length == 0) {
                shape.exact = shape.zeroWidth = true;
                shape.succ = InputLanguage.universal();
            } else {
                shape.exact = true;
                shape.succ = InputLanguage.prefix(text);
                shape.nullable = InputLanguage.empty();
            }
        } else if (node.known && node.byteTerminal && node.byteWidth == 1 && node.nullable == Nullable.no) {
            shape.known = shape.exact = true;
            shape.succ = InputLanguage.bytePrefix(node.alphabet);
            shape.nullable = InputLanguage.empty();
        } else if (node.known && node.nullable == Nullable.no) {
            // Consuming terminal we cannot describe exactly: SUCC stays empty, NULL is proven empty.
            shape.known = true;
            shape.nullable = InputLanguage.empty();
        }
        return shape;
    }

    /// Bytes consumed by `index` when it is an exact fixed-length terminal chain (literal / single-byte class).
    private bool fixedPattern(size_t index, ref CharSetMask[] pattern, size_t depth = 0) {
        if (index >= graph.expressions.length || depth > 8 || pattern.length > 64)
            return false;
        auto node = graph.expressions[index];
        if (node.kind == ExpressionKind.terminal) {
            auto shape = terminal(node);
            if (!shape.exact || shape.zeroWidth || !shape.known)
                return false;
            if (auto text = plainLiteral(node.source)) {
                foreach (c; text) {
                    CharSetMask one;
                    one.addChar(c);
                    pattern ~= one;
                }
                return text.length != 0;
            }
            if (node.byteTerminal && node.byteWidth == 1) {
                pattern ~= node.alphabet;
                return true;
            }
            return false;
        }
        if (node.kind == ExpressionKind.sequence && node.children.length) {
            foreach (child; node.children)
                if (!fixedPattern(child, pattern, depth + 1))
                    return false;
            return true;
        }
        if (node.kind == ExpressionKind.wrapper && node.combinator != "oneOrMore" && node.children.length)
            return fixedPattern(node.children[0], pattern, depth + 1);
        return false;
    }

    private bool zeroWidth(size_t index) {
        return index < graph.facts.length && graph.facts[index].neverAdvances
            && graph.expressions[index].kind != ExpressionKind.unknown;
    }

    /// Lower approximation of the success of e_i ... e_n, using only zero-width and fixed-length steps.
    private InputLanguage succSequence(const(size_t)[] c, size_t i) {
        if (i == c.length)
            return InputLanguage.universal();
        if (i + 1 == c.length)
            return succ(c[i]);
        if (zeroWidth(c[i]))
            return lower(succ(c[i]).intersect(succSequence(c, i + 1), budget));
        CharSetMask[] pattern;
        if (fixedPattern(c[i], pattern))
            return lower(InputLanguage.fixedThen(pattern, succSequence(c, i + 1), budget));
        return InputLanguage.empty(); // a step of unknown length: no lower bound
    }

    /// Upper approximation of the inputs on which `index` may succeed (the dual of `succ`).
    InputLanguage maySucc(size_t index) {
        if (index >= graph.expressions.length)
            return InputLanguage.universal();
        if (maySuccDone[index])
            return maySuccMemo[index];
        if (maySuccActive[index]) {
            ++cuts;
            return InputLanguage.universal();
        }
        maySuccActive[index] = true;
        scope (exit)
            maySuccActive[index] = false;
        auto node = graph.expressions[index];
        InputLanguage result = InputLanguage.universal();
        final switch (node.kind) {
        case ExpressionKind.unknown:
            break;
        case ExpressionKind.terminal:
            auto shape = terminal(node);
            if (shape.exact && shape.known && !shape.zeroWidth)
                result = shape.succ;
            else if (shape.exact && shape.known) // eps / eoi / fail
                result = node.source == "fail" ? InputLanguage.empty() : shape.succ;
            else if (shape.known && !node.first.empty)
                result = InputLanguage.bytePrefix(node.first);
            break;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            if (rule != size_t.max)
                result = maySucc(graph.roots[rule]);
            break;
        case ExpressionKind.sequence:
            result = maySuccSequence(node.children, 0);
            break;
        case ExpressionKind.choice:
            result = InputLanguage.empty();
            foreach (child; node.children)
                result = upper(result.unionWith(maySucc(child), budget));
            break;
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
            break; // always succeeds
        case ExpressionKind.predicate:
            if (node.combinator == "negLookahead"
                    || node.combinator == "predictiveNot")
                result = upper(succ(node.children[0]).complement());
            else
                result = maySucc(node.children[0]);
            break;
        case ExpressionKind.wrapper:
            result = maySucc(node.children[0]);
            break;
        }
        maySuccDone[index] = true;
        maySuccMemo[index] = result;
        return result;
    }

    private InputLanguage maySuccSequence(const(size_t)[] c, size_t i) {
        if (i == c.length)
            return InputLanguage.universal();
        if (zeroWidth(c[i]))
            return upper(maySucc(c[i]).intersect(maySuccSequence(c, i + 1), budget));
        CharSetMask[] pattern;
        if (i + 1 < c.length && fixedPattern(c[i], pattern))
            return upper(InputLanguage.fixedThen(pattern, maySuccSequence(c, i + 1), budget));
        return maySucc(c[i]); // necessary condition only: the first step must succeed
    }

    /// Lower approximation of the inputs on which `index` succeeds.
    InputLanguage succ(size_t index) {
        if (index >= graph.expressions.length)
            return InputLanguage.empty();
        if (succDone[index])
            return succMemo[index];
        if (succActive[index]) {
            ++cuts;
            return InputLanguage.empty(); // recursion: sound bottom
        }
        succActive[index] = true;
        scope (exit)
            succActive[index] = false;
        auto node = graph.expressions[index];
        InputLanguage result = InputLanguage.empty();
        final switch (node.kind) {
        case ExpressionKind.unknown:
            break;
        case ExpressionKind.terminal:
            result = terminal(node).succ;
            break;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            if (rule != size_t.max)
                result = succ(graph.roots[rule]);
            break;
        case ExpressionKind.sequence:
            if (!node.children.length)
                result = InputLanguage.universal();
            else if (node.children.length == 1)
                result = succ(node.children[0]);
            else if (regularSucc)
                result = succSequence(node.children, 0);
            break; // otherwise the paper's SUCC(other) = empty
        case ExpressionKind.choice:
            foreach (child; node.children)
                result = lower(result.unionWith(succ(child), budget));
            break;
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
            result = InputLanguage.universal(); // e? and e* succeed on every input
            break;
        case ExpressionKind.predicate:
            // &e succeeds wherever e does; !e has no lower approximation here.
            if (node.combinator == "posLookahead")
                result = succ(node.children[0]);
            else if (regularSucc && (node.combinator == "negLookahead" || node.combinator == "predictiveNot"))
                result = lower(maySucc(node.children[0]).complement()); // fails wherever e cannot succeed
            break;
        case ExpressionKind.wrapper:
            // oneOrMore e succeeds where e succeeds; other wrappers are transparent.
            result = succ(node.children[0]);
            break;
        }
        succDone[index] = true;
        succMemo[index] = result;
        return result;
    }

    /// Upper approximation of the inputs on which `index` may succeed without consuming input.
    InputLanguage nul(size_t index) {
        if (index >= graph.expressions.length)
            return InputLanguage.universal();
        if (nullDone[index])
            return nullMemo[index];
        if (nullActive[index]) {
            ++cuts;
            return InputLanguage.universal(); // recursion: sound top
        }
        nullActive[index] = true;
        scope (exit)
            nullActive[index] = false;
        auto node = graph.expressions[index];
        InputLanguage result = InputLanguage.universal();
        // Facts can prove non-nullability regardless of the structure below.
        const proven = index < graph.facts.length && graph.facts[index].known
            && graph.facts[index].nullable == Nullable.no;
        if (proven) {
            result = InputLanguage.empty();
        } else
            final switch (node.kind) {
        case ExpressionKind.unknown:
            break;
        case ExpressionKind.terminal:
            result = terminal(node).nullable;
            break;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            if (rule != size_t.max)
                result = nul(graph.roots[rule]);
            break;
        case ExpressionKind.sequence:
            foreach (child; node.children)
                result = upper(result.intersect(nul(child), budget));
            break;
        case ExpressionKind.choice:
            result = InputLanguage.empty();
            foreach (child; node.children)
                result = upper(result.unionWith(nul(child), budget));
            break;
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
            break; // Σ*
        case ExpressionKind.predicate:
            if (node.combinator == "negLookahead"
                    || node.combinator == "predictiveNot")
                result = upper(succ(node.children[0]).complement());
            break; // &e: Σ* (an upper bound on where e succeeds is not available)
        case ExpressionKind.wrapper:
            result = nul(node.children[0]);
            break;
        }
        nullDone[index] = true;
        nullMemo[index] = result;
        return result;
    }

    /// Upper approximation of the inputs on which `index` may consume input outside a predicate.
    /// Lookahead has no bite; its NULL restriction constrains what follows it in a sequence.
    InputLanguage bites(size_t index) {
        if (index >= graph.expressions.length)
            return InputLanguage.universal();
        if (bitesDone[index])
            return bitesMemo[index];
        if (bitesActive[index]) {
            ++cuts;
            return InputLanguage.universal(); // recursion: sound top
        }
        bitesActive[index] = true;
        scope (exit)
            bitesActive[index] = false;
        auto node = graph.expressions[index];
        InputLanguage result = InputLanguage.universal();
        final switch (node.kind) {
        case ExpressionKind.unknown:
            ++unknowns;
            break;
        case ExpressionKind.terminal:
            auto shape = terminal(node);
            if (shape.zeroWidth)
                result = InputLanguage.empty();
            else if (shape.exact && shape.known)
                result = shape.succ; // L(t) Σ* for a consuming terminal
            else if (shape.known && !node.first.empty)
                result = InputLanguage.bytePrefix(node.first);
            break;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(node);
            if (rule != size_t.max)
                result = bites(graph.roots[rule]);
            else
                ++unknowns;
            break;
        case ExpressionKind.sequence:
            result = InputLanguage.empty();
            InputLanguage prefixNull = InputLanguage.universal();
            foreach (child; node.children) {
                result = upper(result.unionWith(upper(prefixNull.intersect(bites(child), budget)), budget));
                prefixNull = upper(prefixNull.intersect(nul(child), budget));
                if (prefixNull.emptiness() == Proof.provenEmpty)
                    break; // nothing after a non-nullable prefix can bite
            }
            break;
        case ExpressionKind.choice:
            result = InputLanguage.empty();
            foreach (child; node.children)
                result = upper(result.unionWith(bites(child), budget));
            break;
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
        case ExpressionKind.wrapper:
            result = bites(node.children[0]);
            break;
        case ExpressionKind.predicate:
            result = InputLanguage.empty();
            break;
        }
        bitesDone[index] = true;
        bitesMemo[index] = result;
        return result;
    }
}

nothrow unittest {
    // Small acyclic PEGs exercise approximation overflow in both directions.
    // Check proofs against the independent PEG interpreter, not another analysis.
    alias K = ExpressionKind;
    foreach (seed; 1 .. 13) {
        GrammarAnalysis graph;
        graph.names = ["Root"];
        graph.expressions = [
            lit("a"), lit("ab"), plain("eps", Nullable.yes), plain("eoi", Nullable.yes),
            plain("fail", Nullable.no), letters()
        ];
        uint random = seed;
        foreach (index; 6 .. 18) {
            random = random * 1664525u + 1013904223u;
            const left = random % index;
            random = random * 1664525u + 1013904223u;
            const right = random % index;
            switch ((random >> 16) % 7) {
            case 0:
                graph.expressions ~= composite(K.sequence, "and", [left, right]);
                break;
            case 1:
                graph.expressions ~= composite(K.choice, "or", [left, right]);
                break;
            case 2:
                graph.expressions ~= composite(K.optional, "option", [left]);
                break;
            case 3:
                graph.expressions ~= composite(K.repetition, "zeroOrMore", [left]);
                break;
            case 4:
                graph.expressions ~= composite(K.predicate, "negLookahead", [left]);
                break;
            case 5:
                graph.expressions ~= composite(K.predicate, "posLookahead", [left]);
                break;
            default:
                graph.expressions ~= composite(K.wrapper, "defined", [left]);
                break;
            }
        }
        graph.roots = [graph.expressions.length - 1];
        graph.solve();
        foreach (maximum; [0UL, 1, 4, 16])
            foreach (regular; [false, true]) {
                auto analysis = BitesAnalysis(graph, Budget(maximum), regular);
                foreach (index; 0 .. graph.expressions.length) {
                    auto succeeds = analysis.succ(index);
                    auto possible = analysis.maySucc(index);
                    auto empty = analysis.nul(index);
                    auto bites = analysis.bites(index);
                    foreach (input; sampleInputs(2)) {
                        bool bitten;
                        const end = matchNode(graph, index, input, 0, &bitten);
                        if (succeeds.contains(input))
                            assert(end >= 0);
                        if (end >= 0)
                            assert(possible.contains(input));
                        if (end == 0)
                            assert(empty.contains(input));
                        if (bitten)
                            assert(bites.contains(input));
                    }
                }
                if (!regular && (maximum == 0 || maximum == 4)) {
                    auto next = NextBites(graph, analysis, Budget(maximum), maximum == 0 ? 0 : 8);
                    const premises = checkPremises(graph, analysis, next);
                    const sites = commitSites(premises);
                    if (!next.trusted || !next.converged) {
                        foreach (check; premises)
                            assert(!check.wellFormed);
                        foreach (site; sites)
                            assert(!site.candidate);
                    }
                    assert(next.nextBites(size_t.max, Outcome.succ).contains("anything"));
                    assert(next.nextBites(size_t.max, Outcome.fail).contains("anything"));
                    // Conservative diagnostics must never silently become an emitted cut.
                    const diagnostics = unifiedDiagnostics(graph, Budget(maximum));
                    foreach (item; diagnostics)
                        if (item.cutCandidate)
                            assert(item.theorem.length != 0);
                    assert(renderUnified(diagnostics, false).length || !diagnostics.length);
                    assert(renderUnified(diagnostics, true).length != 0);
                }
            }
    }
}

nothrow unittest {
    GrammarAnalysis graph;
    graph.names = ["Root"];
    auto recursive = composite(ExpressionKind.reference, "", []);
    recursive.reference = "Root";
    graph.expressions = [recursive];
    graph.roots = [0];
    auto cycle = BitesAnalysis(graph, Budget.init, true);
    assert(cycle.succ(0).emptiness() == Proof.provenEmpty);
    assert(cycle.nul(0).contains("anything"));
    assert(cycle.bites(0).contains("anything"));
    assert(cycle.maySucc(0).contains("anything"));
    assert(cycle.cuts >= 4);
    assert(cycle.succ(size_t.max).emptiness() == Proof.provenEmpty);
    assert(cycle.nul(size_t.max).contains("anything"));
    assert(cycle.bites(size_t.max).contains("anything"));
    assert(cycle.maySucc(size_t.max).contains("anything"));
    CharSetMask[] pattern;
    assert(!cycle.fixedPattern(size_t.max, pattern));
    graph.expressions[0].reference = "Missing";
    auto missing = BitesAnalysis(graph, Budget.init, true);
    assert(missing.succ(0).emptiness() == Proof.provenEmpty);
    assert(missing.nul(0).contains("anything"));
    assert(missing.bites(0).contains("anything"));
    assert(missing.maySucc(0).contains("anything"));
    graph.expressions = [
        lit("ab"), letters(), plain("endOfInput", Nullable.yes), plain("fail", Nullable.no),
        Expression.init, plain("opaque", Nullable.no)
    ];
    graph.expressions[5].first.addChar('a');
    auto terminals = BitesAnalysis(graph, Budget(1), true);
    foreach (index; 0 .. graph.expressions.length) {
        terminals.succ(index);
        terminals.nul(index);
        terminals.bites(index);
        terminals.maySucc(index);
    }
    assert(terminals.fixedPattern(0, pattern));
    assert(pattern.length == 2);
    assert(terminals.fixedPattern(1, pattern));
    assert(!terminals.fixedPattern(2, pattern));
    assert(!terminals.fixedPattern(3, pattern));
    assert(!terminals.fixedPattern(4, pattern));
    assert(!terminals.fixedPattern(5, pattern));
    assert(!terminals.fixedPattern(0, pattern, 9));
    pattern.length = 65;
    assert(!terminals.fixedPattern(0, pattern));
    InputLanguage overflow = InputLanguage.universal();
    overflow.overflow = true;
    assert(terminals.lower(overflow).emptiness() == Proof.provenEmpty);
    assert(terminals.upper(overflow).contains("anything"));
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root"];
    graph.expressions = [
        lit("ab"), classAB(), composite(K.sequence, "and", [0, 1]),
        composite(K.wrapper, "defined", [2]), Expression.init, composite(K.sequence, "and", [0,
            4]), composite(K.sequence, "and", []), composite(K.sequence, "and", [0]),
        composite(K.predicate, "predictiveNot", [0]), composite(K.wrapper, "oneOrMore", [0])
    ];
    graph.roots = [3];
    graph.solve();
    auto analysis = BitesAnalysis(graph, Budget.init, true);
    CharSetMask[] pattern;
    assert(analysis.fixedPattern(2, pattern) && pattern.length == 3);
    assert(pattern[0].contains('a') && pattern[1].contains('b'));
    assert(pattern[2].contains('a') && pattern[2].contains('b') && !pattern[2].contains('c'));
    pattern.length = 0;
    assert(analysis.fixedPattern(3, pattern) && pattern.length == 3);
    pattern.length = 0;
    assert(!analysis.fixedPattern(5, pattern));
    assert(!analysis.fixedPattern(6, pattern));
    assert(!analysis.fixedPattern(9, pattern));
    assert(analysis.succ(6).contains("anything"));
    assert(analysis.succ(7).contains("abc") && !analysis.succ(7).contains("a"));
    assert(analysis.succSequence([], 0).contains("anything"));
    assert(analysis.maySuccSequence([], 0).contains("anything"));
    assert(analysis.succ(8).contains("a") && !analysis.succ(8).contains("ab"));
    assert(analysis.nul(8).contains("a") && !analysis.nul(8).contains("ab"));
    assert(analysis.maySucc(8).contains("a") && !analysis.maySucc(8).contains("ab"));
}

/// Add BITES disjointness diagnostics (B4) to the prefix-discrimination results, report-only.
/// Disjointness of upper approximations is a proof; an overlap is only "possible" and becomes "unknown"
/// when either alternative needed a budget cut, a recursive back edge or an unknown/unresolved node.
/// Proposition 5 (no hiding) is claimed only for proven-disjoint pairs of provably nonnullable alternatives.
void annotateBites(ref GrammarAnalysis graph, ref ChoiceDiscrimination[] choices,
        Budget budget = Budget.init, bool regularSucc = false) nothrow {
    foreach (ref choice; choices) {
        if (choice.expressionIndex >= graph.expressions.length)
            continue;
        const children = graph.expressions[choice.expressionIndex].children;
        InputLanguage[] languages;
        bool[] exact, nonnullable;
        foreach (child; children) {
            auto analysis = BitesAnalysis(graph, budget, regularSucc);
            languages ~= analysis.bites(child);
            exact ~= analysis.degradations == 0 && analysis.cuts == 0 && analysis.unknowns == 0;
            nonnullable ~= child < graph.facts.length && graph.facts[child].known
                && graph.facts[child].nullable == Nullable.no;
        }
        bool allDisjoint = choice.pairs.length != 0, allNoHiding = choice.pairs.length != 0;
        foreach (ref pair; choice.pairs) {
            if (pair.firstIndex >= languages.length || pair.secondIndex >= languages.length) {
                allDisjoint = allNoHiding = false;
                continue;
            }
            const overlap = languages[pair.firstIndex].intersect(languages[pair.secondIndex], budget);
            const proof = overlap.emptiness();
            if (proof == Proof.provenEmpty) {
                pair.bites = "proven-disjoint";
                pair.bitesImprovesFirst = pair.firstFirstConflict;
                pair.noHidingProven = nonnullable[pair.firstIndex] && nonnullable[pair.secondIndex];
            } else {
                string witness;
                overlap.shortestWitness(witness);
                pair.bitesWitness = witness;
                pair.bites = proof == Proof.provenNonempty && exact[pair.firstIndex]
                    && exact[pair.secondIndex] ? "possible-overlap" : "unknown";
                allDisjoint = false;
            }
            allNoHiding = allNoHiding && pair.noHidingProven;
        }
        choice.bitesAllDisjoint = allDisjoint;
        choice.noHidingProven = allNoHiding;
    }
}

nothrow unittest {
    GrammarAnalysis graph;
    graph.names = ["Root"];
    graph.expressions = [lit("a"), lit("b"), composite(ExpressionKind.choice, "or", [0, 1])];
    graph.roots = [2];
    graph.solve();
    ChoiceDiscrimination invalid;
    invalid.expressionIndex = size_t.max;
    ChoiceDiscrimination choice;
    choice.expressionIndex = 2;
    choice.bitesAllDisjoint = choice.noHidingProven = true;
    choice.pairs = [BranchDiscrimination(0, size_t.max), BranchDiscrimination(size_t.max, 1)];
    ChoiceDiscrimination[] reports = [invalid, choice];
    annotateBites(graph, reports);
    foreach (report; reports)
        assert(!report.bitesAllDisjoint && !report.noHidingProven);
    char[200] source;
    source[] = 'x';
    graph.expressions[2].source = source[].idup;
    const diagnostics = unifiedDiagnostics(graph);
    assert(diagnostics.length == 1);
    assert(diagnostics[0].source == source[0 .. 160] ~ "...");
}

/// Outcome of an expression: the paper's R = {succ, fail}.
enum Outcome : size_t {
    succ,
    fail
}

/// NEXTBITES(e, r) (B5): upper approximation of the inputs, seen from the position where `e` terminated,
/// on which the parser may bite after `e` returns with result r. Built from the paper's Last* x Next
/// (Redziejowski 2011, Appendix A.5-A.6) using only monotone "may" properties (nullable, may-advance,
/// may-fail), so every approximation is a superset. For a conservative graph (unknown nodes, unresolved
/// references: hidden call sites) or when iteration does not converge, every result is universal.
struct NextBites {
nothrow:
    GrammarAnalysis* graph;
    BitesAnalysis* bites;
    Budget budget;
    bool converged, trusted;
    InputLanguage[2][] value;
    private size_t[2][][] parents; // [node] -> (parent, unused) pairs
    private size_t[][] referencing; // [rule] -> reference nodes calling it

    this(ref GrammarAnalysis graph, ref BitesAnalysis bites, Budget budget = Budget.init, size_t maxIterations = 32) {
        this.graph = &graph;
        this.bites = &bites;
        this.budget = budget;
        const count = graph.expressions.length;
        value = new InputLanguage[2][count];
        foreach (ref pair; value) {
            pair[0] = InputLanguage.empty();
            pair[1] = InputLanguage.empty();
        }
        parents = new size_t[2][][count];
        referencing = new size_t[][graph.roots.length];
        foreach (index, node; graph.expressions) {
            foreach (child; node.children)
                if (child < count)
                    parents[child] ~= [index, 0];
            if (node.kind == ExpressionKind.reference) {
                auto copy = node;
                const rule = graph.referenceRule(copy);
                if (rule < referencing.length)
                    referencing[rule] ~= index;
            }
        }
        trusted = !graph.conservative;
        if (!trusted) {
            topAll();
            return;
        }
        solve(maxIterations);
    }

    private void topAll() {
        foreach (ref pair; value) {
            pair[0] = InputLanguage.universal();
            pair[1] = InputLanguage.universal();
        }
    }

    private bool mayNul(size_t i) const {
        return i >= graph.facts.length || graph.facts[i].nullable != Nullable.no;
    }

    private bool mayAdv(size_t i) const {
        return i >= graph.facts.length || !graph.facts[i].neverAdvances;
    }

    private bool mayFail(size_t i) const {
        return i >= graph.facts.length || !graph.facts[i].neverFails;
    }

    private bool maySucceed(size_t i) const {
        return mayAdv(i) || mayNul(i);
    }

    private InputLanguage joined(InputLanguage a, InputLanguage b) {
        auto r = a.unionWith(b, budget);
        return r.overflow ? InputLanguage.universal() : r;
    }

    private bool same(const InputLanguage a, const InputLanguage b) {
        return a.intersect(b.complement(), budget).emptiness() == Proof.provenEmpty
            && b.intersect(a.complement(), budget).emptiness() == Proof.provenEmpty;
    }

    /// One monotone step: union of everything that can bite after (n, r), from the current parent values.
    private InputLanguage contribution(size_t n, Outcome r) {
        InputLanguage total = InputLanguage.empty();
        void add(InputLanguage language) {
            total = joined(total, language);
        }

        // A rule's body returns to every call site with the same result.
        foreach (rule, root; graph.roots)
            if (root == n)
                foreach (site; referencing[rule])
                    add(value[site][r]);
        foreach (link; parents[n]) {
            const parent = link[0];
            auto node = graph.expressions[parent];
            size_t at = size_t.max;
            foreach (position, child; node.children)
                if (child == n)
                    at = position;
            if (at == size_t.max)
                continue;
            final switch (node.kind) {
            case ExpressionKind.unknown:
            case ExpressionKind.terminal:
            case ExpressionKind.reference:
                break;
            case ExpressionKind.wrapper:
                if (node.combinator == "oneOrMore") { // e e*
                    if (r == Outcome.succ) {
                        if (maySucceed(n))
                            add(value[parent][Outcome.succ]);
                        if (mayAdv(n))
                            add(bites.bites(n)); // the loop calls e again
                    } else if (mayFail(n)) {
                        add(value[parent][Outcome.succ]); // a later iteration failed: the loop ends
                        add(value[parent][Outcome.fail]); // the first call failed
                    }
                } else
                    add(value[parent][r]); // transparent wrapper
                break;
            case ExpressionKind.optional:
                if (r == Outcome.succ
                        ? maySucceed(n) : mayFail(n))
                    add(value[parent][Outcome.succ]);
                break;
            case ExpressionKind.repetition:
                if (r == Outcome.succ) {
                    if (mayAdv(n))
                        add(bites.bites(n)); // e is called again
                } else if (mayFail(n))
                    add(value[parent][Outcome.succ]);
                break;
            case ExpressionKind.predicate:
                const negative = node.combinator == "negLookahead"
                    || node.combinator == "predictiveNot";
                if (negative) {
                    if (r == Outcome.succ ? mayNul(n) : mayFail(n))
                        add(value[parent][r == Outcome.succ ? Outcome.fail : Outcome.succ]);
                } else if (r == Outcome.succ ? mayNul(n) : mayFail(n))
                    add(value[parent][r]);
                break;
            case ExpressionKind.sequence:
                sequenceContext(node.children, at, r, parent, &add);
                break;
            case ExpressionKind.choice:
                choiceContext(node.children, at, r, parent, &add);
                break;
            }
        }
        return total;
    }

    private void sequenceContext(const(size_t)[] c, size_t i, Outcome r, size_t parent,
            void delegate(InputLanguage) nothrow add) {
        bool prefixSucceeds = true, prefixNull = true; // all earlier (and e_i for succ) can succeed / be empty
        foreach (j; 0 .. i) {
            prefixSucceeds = prefixSucceeds && maySucceed(c[j]);
            prefixNull = prefixNull && mayNul(c[j]);
        }
        if (r == Outcome.fail) {
            if (mayFail(c[i]) && prefixNull)
                add(value[parent][Outcome.fail]);
            return;
        }
        const upToSucceeds = prefixSucceeds && maySucceed(c[i]);
        const upToNull = prefixNull && mayNul(c[i]);
        bool suffixNull = true;
        foreach (j; i + 1 .. c.length)
            suffixNull = suffixNull && mayNul(c[j]);
        if (upToSucceeds && suffixNull)
            add(value[parent][Outcome.succ]);
        if (upToNull) {
            // a later element fails after the earlier ones succeeded
            bool before = true;
            foreach (j; i + 1 .. c.length) {
                if (before && mayFail(c[j]))
                    add(value[parent][Outcome.fail]);
                before = before && maySucceed(c[j]);
            }
        }
        if (upToSucceeds) {
            // the next element that can advance, reached through elements that can be empty
            auto passed = InputLanguage.universal();
            foreach (j; i + 1 .. c.length) {
                if (mayAdv(c[j])) {
                    auto reach = passed.intersect(bites.bites(c[j]), budget);
                    add(reach.overflow ? InputLanguage.universal() : reach);
                }
                if (!mayNul(c[j]))
                    break;
                auto narrowed = passed.intersect(bites.nul(c[j]), budget);
                passed = narrowed.overflow ? InputLanguage.universal() : narrowed;
            }
        }
    }

    private void choiceContext(const(size_t)[] c, size_t i, Outcome r, size_t parent,
            void delegate(InputLanguage) nothrow add) {
        bool earlierFail = true;
        foreach (j; 0 .. i)
            earlierFail = earlierFail && mayFail(c[j]);
        if (r == Outcome.succ) {
            if (earlierFail && maySucceed(c[i]))
                add(value[parent][Outcome.succ]);
            return;
        }
        if (!mayFail(c[i]))
            return;
        // after e_i failed: a later alternative may succeed empty (choice succeeds at p), may bite,
        // or every alternative fails (the choice fails at p)
        bool failedSoFar = earlierFail;
        foreach (j; i + 1 .. c.length) {
            if (failedSoFar && mayNul(c[j]))
                add(value[parent][Outcome.succ]);
            if (failedSoFar && mayAdv(c[j]))
                add(bites.bites(c[j]));
            failedSoFar = failedSoFar && mayFail(c[j]);
        }
        if (failedSoFar)
            add(value[parent][Outcome.fail]);
    }

    private void solve(size_t maxIterations) {
        converged = false;
        foreach (iteration; 0 .. maxIterations) {
            bool changed;
            foreach (n; 0 .. graph.expressions.length)
                foreach (outcome; [Outcome.succ, Outcome.fail]) {
                    auto next = contribution(n, outcome);
                    if (!same(next, value[n][outcome])) {
                        value[n][outcome] = next;
                        changed = true;
                    }
                }
            if (!changed) {
                converged = true;
                return;
            }
        }
        topAll(); // not converged: sound top
    }

    InputLanguage nextBites(size_t index, Outcome r) {
        return index < value.length ? value[index][r] : InputLanguage.universal();
    }
}

/// Premise checks of Redziejowski's Propositions 10-13 for one choice or star expression.
/// A true flag means the premises are proven under the approximations above; false means "not proven".
struct PremiseCheck {
    size_t expressionIndex;
    string kind; // "choice" or "star"
    string ruleName;
    bool wellFormed; // trusted graph, no left recursion, fixed point converged
    bool disjoint; // choice: every BITES pair provably disjoint
    bool prop10, prop11; // choice: no hiding (nullable case) / cut safety after a bite
    bool allNonnullable; // choice: every alternative provably nonnullable (Proposition 6 setting)
    bool cond4, cond5, cond6, cond7, cond8; // the paper's numbered conditions, as proven here
    bool actionFree; // owning rule is known and action-free
    bool prop12, prop13; // star: no hiding / no success after e failed on a bite
    InputLanguage nextSucc, nextFail;
}

PremiseCheck[] checkPremises(ref GrammarAnalysis graph, ref BitesAnalysis bites, ref NextBites next) nothrow {
    PremiseCheck[] checks;
    bool leftRecursion;
    foreach (flag; graph.leftRecursive)
        leftRecursion = leftRecursion || flag;
    const wellFormed = next.trusted && next.converged && !leftRecursion;
    const effects = graph.ruleEffects();
    size_t owner(size_t target) nothrow {
        foreach (rule, root; graph.roots) {
            auto seen = new bool[graph.expressions.length];
            bool reaches(size_t index) nothrow {
                if (index == target)
                    return true;
                if (seen[index])
                    return false;
                seen[index] = true;
                foreach (child; graph.expressions[index].children)
                    if (reaches(child))
                        return true;
                return false;
            }

            if (reaches(root))
                return rule;
        }
        return size_t.max;
    }

    bool empty(InputLanguage a, InputLanguage b) nothrow {
        return a.intersect(b, next.budget).emptiness() == Proof.provenEmpty;
    }

    foreach (index, node; graph.expressions) {
        if (node.kind != ExpressionKind.choice && !(node.kind == ExpressionKind.repetition && node.children.length))
            continue;
        PremiseCheck check;
        check.expressionIndex = index;
        const rule = owner(index);
        check.ruleName = rule < graph.names.length ? graph.names[rule] : "";
        check.actionFree = rule < effects.length && effects[rule].known && !effects[rule].actionful;
        check.wellFormed = wellFormed;
        check.nextSucc = next.nextBites(index, Outcome.succ);
        check.nextFail = next.nextBites(index, Outcome.fail);
        const children = node.children;
        if (node.kind == ExpressionKind.repetition) {
            check.kind = "star";
            const 
            body = children[0];
            const nonnullable = body < graph.facts.length && graph.facts[body].nullable == Nullable.no;
            check.cond8 = empty(bites.bites(body), check.nextSucc);
            check.allNonnullable = nonnullable;
            check.prop12 = check.prop13 = wellFormed && nonnullable && check.cond8;
            checks ~= check;
            continue;
        }
        check.kind = "choice";
        check.disjoint = children.length > 1;
        foreach (i; 0 .. children.length)
            foreach (j; i + 1 .. children.length)
                check.disjoint = check.disjoint && empty(bites.bites(children[i]), bites.bites(children[j]));
        const last = children.length ? children[$ - 1] : size_t.max;
        bool cond4 = true, cond5 = true, cond6 = true, cond7 = true;
        const lastNullable = last >= graph.facts.length || graph.facts[last].nullable != Nullable.no;
        const choiceNullable = index >= graph.facts.length || graph.facts[index].nullable != Nullable.no;
        const choiceFails = index >= graph.facts.length || !graph.facts[index].neverFails;
        foreach (i, child; children) {
            const early = i + 1 < children.length;
            if (early && !(child < graph.facts.length && graph.facts[child].nullable == Nullable.no))
                cond4 = false;
            const hitsSucc = !empty(bites.bites(child), check.nextSucc);
            if (early && lastNullable && hitsSucc)
                cond5 = false;
            if (early && choiceNullable && hitsSucc)
                cond6 = false;
            if (choiceFails && !empty(bites.bites(child), check.nextFail))
                cond7 = false;
        }
        check.allNonnullable = children.length != 0;
        foreach (child; children)
            check.allNonnullable = check.allNonnullable && child < graph.facts.length
                && graph.facts[child].nullable == Nullable.no;
        check.cond4 = cond4;
        check.cond5 = cond5;
        check.cond6 = cond6;
        check.cond7 = cond7;
        check.prop10 = wellFormed && check.disjoint && cond4 && cond5;
        check.prop11 = wellFormed && check.disjoint && cond6 && cond7;
        checks ~= check;
    }
    return checks;
}

/// Deterministic report-only JSON: NEXTBITES per choice/star plus the proposition premises.
string renderNextBites(ref GrammarAnalysis graph, Budget budget = Budget.init) nothrow {
    auto bites = BitesAnalysis(graph, budget);
    auto next = NextBites(graph, bites, budget);
    const checks = checkPremises(graph, bites, next);
    string flag(bool value) nothrow {
        return value ? "true" : "false";
    }

    string result = "{\"scope\":\"Propositions 10-13 premises over conservative NEXTBITES; false means not proven\","
        ~ "\"trusted\":" ~ flag(next.trusted) ~ ",\"converged\":" ~ flag(next.converged) ~ ",\"items\":[";
    foreach (i, check; checks) {
        result ~= (i ? "," : "") ~ "{\"expressionIndex\":" ~ decimal(check.expressionIndex) ~ ",\"rule\":" ~ quoteWitness(
                check.ruleName) ~ ",\"kind\":\"" ~ check.kind ~ "\",\"wellFormed\":" ~ flag(
                check.wellFormed) ~ ",\"nextBitesSucc\":" ~ languageJson(
                check.nextSucc) ~ ",\"nextBitesFail\":" ~ languageJson(check.nextFail);
        if (check.kind == "choice")
            result ~= ",\"disjoint\":" ~ flag(check.disjoint) ~ ",\"prop10\":" ~ flag(
                    check.prop10) ~ ",\"prop11\":" ~ flag(check.prop11);
        else
            result ~= ",\"prop12\":" ~ flag(check.prop12) ~ ",\"prop13\":" ~ flag(check.prop13);
        result ~= "}";
    }
    return result ~ "]}";
}

/// A place where parsing could stop retrying (a "cut"), with the theorem that would justify it.
/// Report-only: no parser code is generated or changed by this analysis.
struct CommitSite {
    size_t expressionIndex;
    string ruleName, kind; // "choice" or "star"
    string theorem; // "Proposition 6", "Proposition 11", "Proposition 13" or "" when none applies
    bool candidate;
    string[] premises; // each "name=true|false"
    string[] blockers; // why no theorem applies
}

CommitSite[] commitSites(const PremiseCheck[] checks) nothrow {
    CommitSite[] sites;
    foreach (check; checks) {
        CommitSite site;
        site.expressionIndex = check.expressionIndex;
        site.ruleName = check.ruleName;
        site.kind = check.kind;
        string premise(string name, bool value) nothrow {
            return name ~ (value ? "=true" : "=false");
        }

        site.premises ~= premise("wellFormed", check.wellFormed);
        site.premises ~= premise("actionFree", check.actionFree);
        if (!check.wellFormed)
            site.blockers ~= "not well-formed: unknown/unresolved nodes, left recursion, or no convergence";
        if (!check.actionFree)
            site.blockers ~= "owning rule is actionful or its effects are unknown";
        if (check.kind == "choice") {
            site.premises ~= premise("disjoint", check.disjoint);
            site.premises ~= premise("allNonnullable", check.allNonnullable);
            site.premises ~= premise("condition6", check.cond6);
            site.premises ~= premise("condition7", check.cond7);
            if (!check.disjoint)
                site.blockers ~= "alternatives are not proven BITES-disjoint";
            if (check.disjoint && check.allNonnullable && check.wellFormed && check.actionFree)
                site.theorem = "Proposition 6"; // cut after an alternative failed having consumed a terminal
            else if (check.prop11 && check.actionFree) {
                site.theorem = "Proposition 11";
                if (!check.allNonnullable)
                    site.premises ~= "nullableCase=true";
            } else {
                if (!check.allNonnullable)
                    site.blockers ~= "an alternative may be nullable and conditions (6)/(7) are not both proven";
                if (check.disjoint && !check.cond6)
                    site.blockers ~= "condition (6) not proven: a bitten input may continue after the choice succeeds";
                if (check.disjoint && !check.cond7)
                    site.blockers ~= "condition (7) not proven: a bitten input may continue after the choice fails";
            }
        } else {
            site.premises ~= premise("bodyNonnullable", check.allNonnullable);
            site.premises ~= premise("condition8", check.cond8);
            if (check.prop13 && check.actionFree)
                site.theorem = "Proposition 13"; // after e failed on a bitten input, nothing after E can succeed
            else {
                if (!check.allNonnullable)
                    site.blockers ~= "repeated body may be nullable";
                if (!check.cond8)
                    site.blockers ~= "condition (8) not proven: BITES(e) meets NEXTBITES(E, succ)";
            }
        }
        site.candidate = site.theorem.length != 0;
        sites ~= site;
    }
    return sites;
}

/// Deterministic report-only JSON. `emitted` is always false: sites are candidates, and a cut would also
/// have to preserve failure positions, diagnostics, records and resource limits (not checked here).
string renderCommitSites(ref GrammarAnalysis graph, Budget budget = Budget.init) nothrow {
    auto bites = BitesAnalysis(graph, budget);
    auto next = NextBites(graph, bites, budget);
    const sites = commitSites(checkPremises(graph, bites, next));
    string list(const string[] values) nothrow {
        string text = "[";
        foreach (i, value; values)
            text ~= (i ? "," : "") ~ quoteWitness(value);
        return text ~ "]";
    }

    string result = "{\"scope\":\"candidate commit sites only; no cut is emitted\",\"sites\":[";
    foreach (i, site; sites)
        result ~= (i ? "," : "") ~ "{\"expressionIndex\":" ~ decimal(site.expressionIndex) ~ ",\"rule\":"
            ~ quoteWitness(site.ruleName) ~ ",\"kind\":\"" ~ site.kind ~ "\",\"candidate\":" ~ (site.candidate
                    ? "true" : "false") ~ ",\"theorem\":" ~ quoteWitness(site.theorem) ~ ",\"premises\":" ~ list(
                    site.premises) ~ ",\"blockers\":" ~ list(site.blockers) ~ ",\"emitted\":false}";
    return result ~ "]}";
}

private string flagText(bool value) nothrow {
    return value ? "true" : "false";
}

private string[] splitBlockers(const string[] values) nothrow {
    return values.dup;
}

private string joinJson(const string[] values) nothrow {
    string text = "[";
    foreach (i, value; values)
        text ~= (i ? "," : "") ~ quoteWitness(value);
    return text ~ "]";
}

/// One unified diagnostic per choice or star expression (B8). Source locations are the owning rule plus the
/// expression's source text and graph index; the grammar graph carries no byte offsets.
struct UnifiedDiagnostic {
    string ruleName, kind, source;
    size_t expressionIndex;
    string first; // "disjoint", "overlap" or "n/a" (star: FIRST(body) vs FOLLOW)
    bool firstFollowConflict, followKnown;
    string bitesStatus; // "proven-disjoint", "possible-overlap", "unknown" or "n/a"
    string theorem; // governing proposition, "" when none
    string hiding; // lint: "definite", "none-proven", "possible" or "unknown"
    string hidingReason;
    string backend; // optimization: recommended code path
    bool cutCandidate; // optimization candidate only; the generator never emits cuts
    string[] blockers;
}

/// Lint (language hiding) and optimization (backend, cut) views are kept separate: the lint never implies a
/// transformation is safe, and a candidate is not an emitted optimization.
UnifiedDiagnostic[] unifiedDiagnostics(ref GrammarAnalysis graph, Budget budget = Budget.init, bool regularSucc = false) nothrow {
    auto choices = graph.analyzeAllPrefixDiscriminations();
    annotateBites(graph, choices, budget, regularSucc);
    auto bites = BitesAnalysis(graph, budget, regularSucc);
    auto next = NextBites(graph, bites, budget);
    const checks = checkPremises(graph, bites, next);
    const sites = commitSites(checks);
    const follow = followSets(graph);
    UnifiedDiagnostic[] result;
    foreach (i, check; checks) {
        UnifiedDiagnostic item;
        item.expressionIndex = check.expressionIndex;
        item.ruleName = check.ruleName;
        item.kind = check.kind;
        string text = graph.expressions[check.expressionIndex].source;
        item.source = text.length > 160 ? text[0 .. 160] ~ "..." : text;
        item.blockers = splitBlockers(sites[i].blockers);
        item.theorem = sites[i].theorem;
        item.cutCandidate = sites[i].candidate;
        size_t ruleIndex = size_t.max;
        foreach (r, name; graph.names)
            if (name == check.ruleName)
                ruleIndex = r;
        const ownerFollow = ruleIndex < follow.known.length && follow.known[ruleIndex];
        if (check.kind == "choice") {
            const choice = {
                foreach (ref candidate; choices)
                    if (candidate.expressionIndex == check.expressionIndex)
                        return candidate;
                return ChoiceDiscrimination.init;
            }();
            item.followKnown = choice.followKnown;
            item.firstFollowConflict = choice.firstFollowConflict;
            item.first = choice.pairs.length && !choice.hasOverlap ? "disjoint" : "overlap";
            bool anyDefinite, anyUnknown, anyPossible, allProven = choice.pairs.length != 0;
            foreach (pair; choice.pairs) {
                anyDefinite = anyDefinite || pair.definite;
                anyUnknown = anyUnknown || pair.bites == "unknown";
                anyPossible = anyPossible || pair.bites == "possible-overlap";
                allProven = allProven && pair.bites == "proven-disjoint";
            }
            item.bitesStatus = allProven ? "proven-disjoint" : anyUnknown ? "unknown" : anyPossible
                ? "possible-overlap" : "unknown";
            if (anyDefinite) {
                item.hiding = "definite";
                item.hidingReason = "an earlier alternative is an unguarded proper prefix of a later one";
            } else if (choice.noHidingProven) {
                item.hiding = "none-proven";
                item.hidingReason = "Proposition 5: disjoint BITES, nonnullable alternatives";
            } else if (check.prop10) {
                item.hiding = "none-proven";
                item.hidingReason = "Proposition 10: nullable-choice conditions (4) and (5)";
            } else if (!check.wellFormed || anyUnknown) {
                item.hiding = "unknown";
                item.hidingReason = "grammar not well-formed for the analysis, or an alternative has unknown parts";
            } else {
                item.hiding = "possible";
                item.hidingReason = "BITES of alternatives overlap or nullable continuation is not proven safe";
            }
            if (item.first == "disjoint")
                item.backend = "predictiveChoice (emitted today)";
            else if (item.cutCandidate)
                item.backend = "cut candidate after first bite (not emitted)";
            else {
                bool tiny = choice.pairs.length != 0;
                foreach (child; graph.expressions[check.expressionIndex].children) {
                    const text2 = BitesAnalysis.plainLiteral(graph.expressions[child].source);
                    tiny = tiny && graph.expressions[child].source.length > 0 && text2.length >= 1 && text2.length <= 2;
                }
                item.backend = tiny ? "literalChoice2 (opt-in NPeggedFirst2)" : "ordered choice";
            }
        } else {
            item.first = "n/a";
            item.followKnown = ownerFollow;
            const 
            body = graph.expressions[check.expressionIndex].children[0];
            if (ownerFollow && body < graph.facts.length)
                foreach (w; 0 .. 4)
                    if (graph.facts[body].first.bits[w] & follow.follow[ruleIndex].bits[w])
                        item.firstFollowConflict = true;
            item.bitesStatus = "n/a";
            if (check.prop12) {
                item.hiding = "none-proven";
                item.hidingReason = "Proposition 12: BITES(e) and NEXTBITES(E, succ) are disjoint";
            } else if (!check.wellFormed) {
                item.hiding = "unknown";
                item.hidingReason = "grammar not well-formed for the analysis";
            } else {
                item.hiding = "possible";
                item.hidingReason = "the repeated body may bite what follows the repetition";
            }
            item.backend = "repetition loop";
        }
        if (!item.cutCandidate && !item.blockers.length)
            item.blockers ~= "no commit theorem applies";
        item.blockers ~= "cuts are never emitted by the generator (report-only)";
        result ~= item;
    }
    return result;
}

string renderUnified(const UnifiedDiagnostic[] items, bool json) nothrow {
    if (!json) {
        string text;
        foreach (item; items) {
            text ~= item.kind ~ " in rule \"" ~ item.ruleName ~ "\" (node " ~ decimal(
                    item.expressionIndex) ~ "): " ~ item.source ~ "\n  lint: hiding=" ~ item.hiding ~ " ("
                ~ item.hidingReason ~ ")\n  first=" ~ item.first ~ " first/follow=" ~ (!item.followKnown
                        ? "unknown" : item.firstFollowConflict ? "conflict" : "clear") ~ " bites="
                ~ item.bitesStatus ~ " theorem=" ~ (item.theorem.length ? item.theorem
                        : "none") ~ "\n  optimization: backend=" ~ item.backend ~ " cutCandidate=" ~ flagText(
                        item.cutCandidate);
            foreach (blocker; item.blockers)
                text ~= "\n    - " ~ blocker;
            text ~= "\n";
        }
        return text;
    }
    string result = "{\"scope\":\"lint and optimization candidates are separate; no cut is emitted\",\"items\":[";
    foreach (i, item; items)
        result ~= (i ? "," : "") ~ "{\"rule\":" ~ quoteWitness(item.ruleName) ~ ",\"expressionIndex\":" ~ decimal(
                item.expressionIndex) ~ ",\"kind\":\"" ~ item.kind ~ "\",\"source\":" ~ quoteWitness(
                item.source) ~ ",\"first\":\"" ~ item.first ~ "\",\"followKnown\":" ~ flagText(
                item.followKnown) ~ ",\"firstFollowConflict\":" ~ flagText(
                item.firstFollowConflict) ~ ",\"bites\":\"" ~ item.bitesStatus ~ "\",\"theorem\":"
            ~ quoteWitness(item.theorem) ~ ",\"lint\":{\"hiding\":\"" ~ item.hiding ~ "\",\"reason\":" ~ quoteWitness(
                    item.hidingReason) ~ "},\"optimization\":{\"backend\":" ~ quoteWitness(
                    item.backend) ~ ",\"cutCandidate\":" ~ flagText(item.cutCandidate)
            ~ ",\"cutEmitted\":false," ~ "\"blockers\":" ~ joinJson(item.blockers) ~ "}}";
    return result ~ "]}";
}

/// How a language relates to the extremes, for reports.
string languageStatus(const InputLanguage value) nothrow {
    if (value.emptiness() == Proof.provenEmpty)
        return "empty";
    if (value.complement().emptiness() == Proof.provenEmpty)
        return "universal";
    return "restricted";
}

private string quoteWitness(string text) nothrow {
    string result = "\"";
    foreach (c; text) {
        if (c == '"' || c == '\\') {
            result ~= '\\';
            result ~= c;
        } else if (c >= 0x20 && c < 0x7f)
            result ~= c;
        else {
            enum digits = "0123456789abcdef";
            result ~= "\\u00";
            result ~= digits[(cast(ubyte)c) >> 4];
            result ~= digits[(cast(ubyte)c) & 15];
        }
    }
    return result ~ "\"";
}

nothrow unittest {
    assert(quoteWitness("") == "\"\"");
    assert(quoteWitness("a\"\\\x00\x1f\x7f\xff") == "\"a\\\"\\\\\\u0000\\u001f\\u007f\\u00ff\"");
}

private string languageJson(const InputLanguage value) nothrow {
    string witness;
    const present = value.shortestWitness(witness);
    return "{\"status\":\"" ~ languageStatus(value) ~ "\",\"states\":" ~ decimal(value.states()) ~ (present
            ? ",\"witness\":" ~ quoteWitness(witness) : "") ~ "}";
}

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

/// Deterministic report-only serialization: per rule SUCC, NULL and BITES with proof scope.
/// `exact` is false when a budget or a recursive back edge forced a conservative answer for that rule.
string renderBites(ref GrammarAnalysis graph, Budget budget = Budget.init, bool regularSucc = false) nothrow {
    string result = "{\"scope\":\"pure byte-level expressions; actions, parameters and recursion degrade conservatively\"," ~ "\"budgetStates\":" ~ decimal(
            budget.maxStates) ~ ",\"rules\":[";
    foreach (rule, root; graph.roots) {
        auto analysis = BitesAnalysis(graph, budget, regularSucc);
        const succ = analysis.succ(root), nul = analysis.nul(root), bites = analysis.bites(root);
        const exact = analysis.degradations == 0 && analysis.cuts == 0;
        result ~= (rule ? "," : "") ~ "{\"rule\":" ~ quoteWitness(rule < graph.names.length
                ? graph.names[rule] : "") ~ ",\"exact\":" ~ (exact ? "true" : "false") ~ ",\"succ\":" ~ languageJson(
                succ) ~ ",\"null\":" ~ languageJson(nul) ~ ",\"bites\":" ~ languageJson(bites) ~ "}";
    }
    return result ~ "]}";
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Plain", "Guarded"];
    graph.expressions = [
        lit("abc"), letters(), composite(K.repetition, "zeroOrMore", [1]),
        composite(K.sequence, "and", [0, 2]), composite(K.predicate, "negLookahead", [0]),
        composite(K.sequence, "and", [4, 2])
    ];
    graph.roots = [3, 5];
    graph.solve();
    const report = renderBites(graph);
    assert(report == renderBites(graph)); // deterministic
    assert(containsText(report, "\"rule\":\"Plain\",\"exact\":true"));
    assert(containsText(report, "\"bites\":{\"status\":\"restricted\""));
    assert(containsText(report, "\"witness\":\"abc\""));
    // recursion marks the rule inexact
    GrammarAnalysis loop;
    loop.names = ["L"];
    loop.expressions = [
        composite(K.reference, "", []), lit("a"), composite(K.sequence, "and", [0, 1]),
        plain("eps", Nullable.yes), composite(K.choice, "or", [2, 3])
    ];
    loop.expressions[0].reference = "L";
    loop.roots = [4];
    loop.solve();
    assert(containsText(renderBites(loop), "\"exact\":false"));
}

private bool containsText(string input, string needle) nothrow {
    if (needle.length > input.length)
        return false;
    foreach (i; 0 .. input.length - needle.length + 1)
        if (input[i .. i + needle.length] == needle)
            return true;
    return false;
}

nothrow unittest {
    assert(containsText("", ""));
    assert(!containsText("", "x"));
    assert(containsText("abc", "bc"));
    assert(!containsText("abc", "z"));
}

version (unittest) {
    private struct Fixture {
        GrammarAnalysis graph;
        Expression[] nodes;
    }

    private Expression lit(string text) {
        Expression e;
        e.kind = ExpressionKind.terminal;
        e.known = true;
        e.nullable = Nullable.no;
        e.source = "literal!(\"" ~ text ~ "\")";
        e.first.addChar(text[0]);
        return e;
    }

    private Expression plain(string source, Nullable nullable) {
        Expression e;
        e.kind = ExpressionKind.terminal;
        e.known = true;
        e.nullable = nullable;
        e.source = source;
        return e;
    }

    private Expression composite(ExpressionKind kind, string combinator, size_t[] children) {
        Expression e;
        e.kind = kind;
        e.combinator = combinator;
        e.children = children;
        return e;
    }
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root"];
    graph.expressions = [
        lit("abc"), // 0
        plain("eps", Nullable.yes), // 1
        plain("eoi", Nullable.yes), // 2
        composite(K.choice, "or", [0, 1]), // 3: 'abc' / eps
        composite(K.predicate, "negLookahead", [0]), // 4: !'abc'
        composite(K.predicate, "posLookahead", [0]), // 5: &'abc'
        composite(K.optional, "option", [0]), // 6
        composite(K.repetition, "zeroOrMore", [0]), // 7
        composite(K.sequence, "and", [4, 0]), // 8: !'abc' 'abc'
        Expression(K.unknown), // 9
        composite(K.sequence, "and", [6, 1]), // 10: 'abc'? eps (nullable sequence)
        composite(K.choice, "or", [0, 9]), // 11: unknown arm
        plain("fail", Nullable.no), // 12
    ];
    graph.roots = [3];
    graph.solve();
    auto bites = BitesAnalysis(graph);
    // terminal prefix
    assert(bites.succ(0).contains("abcd") && !bites.succ(0).contains("ab") && !bites.succ(0).contains(""));
    assert(bites.nul(0).emptiness() == Proof.provenEmpty);
    // ordered choice union; eps arm makes it succeed on everything and be nullable everywhere
    assert(bites.succ(3).contains("") && bites.succ(3).contains("zzz"));
    assert(bites.nul(3).contains("") && bites.nul(3).contains("abc"));
    // eps / eoi
    assert(bites.succ(1).contains("q") && bites.nul(1).contains("q"));
    assert(bites.succ(2).contains("") && !bites.succ(2).contains("a"));
    assert(bites.nul(2).contains("") && !bites.nul(2).contains("a"));
    // !'abc': nullable exactly where 'abc' certainly does not succeed
    assert(bites.nul(4).contains("abd") && bites.nul(4).contains("") && !bites.nul(4).contains("abcd"));
    assert(bites.succ(4).emptiness() == Proof.provenEmpty); // no lower approximation
    // &'abc': succeeds where 'abc' does; nullable bound stays universal
    assert(bites.succ(5).contains("abcz") && !bites.succ(5).contains("abd"));
    assert(bites.nul(5).contains("zzz"));
    // optional/star succeed everywhere and may be empty
    assert(bites.succ(6).contains("x") && bites.nul(6).contains("x"));
    assert(bites.succ(7).contains("") && bites.nul(7).contains("abc"));
    // sequence: proven nonnullable via facts -> NULL empty; SUCC is the paper's conservative empty
    assert(bites.nul(8).emptiness() == Proof.provenEmpty && bites.succ(8).emptiness() == Proof.provenEmpty);
    // nullable sequence: intersection of NULLs (universal ∩ universal)
    assert(bites.nul(10).contains("abc") && bites.nul(10).contains(""));
    // unknown node: SUCC bottom, NULL top; a choice with an unknown arm keeps the known arm's SUCC
    assert(bites.succ(9).emptiness() == Proof.provenEmpty && bites.nul(9).contains("anything"));
    assert(bites.succ(11).contains("abc") && bites.nul(11).contains("zzz"));
    // fail never succeeds
    assert(bites.succ(12).emptiness() == Proof.provenEmpty && bites.nul(12).emptiness() == Proof.provenEmpty);
}

nothrow unittest {
    // Recursion degrades soundly: A <- A 'a' / eps is cut to bottom (SUCC) and top (NULL) at the back edge.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["A"];
    graph.expressions = [
        composite(K.reference, "", []), // 0 -> A
        lit("a"), // 1
        composite(K.sequence, "and", [0, 1]), // 2
        plain("eps", Nullable.yes), // 3
        composite(K.choice, "or", [2, 3]), // 4
    ];
    graph.expressions[0].reference = "A";
    graph.roots = [4];
    graph.solve();
    auto bites = BitesAnalysis(graph);
    assert(bites.succ(4).contains("zz")); // eps arm
    assert(bites.nul(4).contains("a") && bites.nul(4).contains(""));
    // Budget exceeded -> NULL becomes universal (never empty), SUCC becomes empty
    GrammarAnalysis heavy;
    heavy.names = ["R"];
    heavy.expressions = [
        lit("aaaaaaaaaaaaaaaa"), composite(K.predicate, "negLookahead", [0]),
        composite(K.predicate, "negLookahead", [0]), composite(K.sequence, "and", [1, 2])
    ];
    heavy.roots = [3];
    heavy.solve();
    Budget tiny;
    tiny.maxStates = 4;
    auto limited = BitesAnalysis(heavy, tiny);
    assert(limited.nul(3).contains("aaaa")); // universal fallback, not empty
    assert(limited.nul(3).emptiness() != Proof.provenEmpty);
}

version (unittest) {
    /// Reference PEG matcher over the expression graph (test oracle): end offset or -1.
    private ptrdiff_t matchNode(ref GrammarAnalysis graph, size_t index, string input, size_t pos,
            bool* bit = null, bool probe = false) nothrow {
        auto node = graph.expressions[index];
        final switch (node.kind) {
        case ExpressionKind.unknown:
            return -1;
        case ExpressionKind.terminal:
            if (node.source == "eps")
                return pos;
            if (node.source == "eoi")
                return pos == input.length ? cast(ptrdiff_t)pos : -1;
            if (node.source == "fail")
                return -1;
            if (node.byteTerminal && node.byteWidth == 1) {
                if (pos < input.length && node.alphabet.contains(input[pos])) {
                    if (bit !is null && !probe)
                        *bit = true;
                    return cast(ptrdiff_t)(pos + 1);
                }
                return -1;
            }
            const text = BitesAnalysis.plainLiteral(node.source);
            if (pos + text.length <= input.length && input[pos .. pos + text.length] == text) {
                if (bit !is null && !probe && text.length)
                    *bit = true; // a terminal consumed input outside a predicate: a bite
                return cast(ptrdiff_t)(pos + text.length);
            }
            return -1;
        case ExpressionKind.reference:
            return matchNode(graph,
                    graph.roots[graph.referenceRule(node)], input, pos, bit, probe);
        case ExpressionKind.sequence:
            ptrdiff_t at = pos;
            foreach (child; node.children) {
                at = matchNode(graph, child, input, at, bit, probe);
                if (at < 0)
                    return -1;
            }
            return at;
        case ExpressionKind.choice:
            foreach (child; node.children) {
                const end = matchNode(graph, child, input, pos, bit, probe);
                if (end >= 0)
                    return end;
            }
            return -1;
        case ExpressionKind.optional:
            const end = matchNode(graph, node.children[0], input, pos, bit, probe);
            return end >= 0 ? end : cast(ptrdiff_t)pos;
        case ExpressionKind.repetition:
            ptrdiff_t at = pos;
            while (true) {
                const end = matchNode(graph, node.children[0], input, at, bit, probe);
                if (end < 0 || end == at)
                    return at;
                at = end;
            }
        case ExpressionKind.predicate:
            const hit = matchNode(graph, node.children[0], input, pos, bit, true) >= 0;
            const wanted = node.combinator == "posLookahead";
            return hit == wanted ? cast(ptrdiff_t)pos : -1;
        case ExpressionKind.wrapper:
            return matchNode(graph, node.children[0], input, pos, bit, probe);
        }
    }

    /// Every string over {a,b,c,1} up to `maxLength`.
    private string[] sampleInputs(size_t maxLength) nothrow {
        string[] all = [""];
        size_t from;
        foreach (length; 0 .. maxLength) {
            const to = all.length;
            foreach (i; from .. to)
                foreach (c; "abc1")
                    all ~= all[i] ~ c;
            from = to;
        }
        return all;
    }
}

nothrow unittest {
    // Sampling supplements the proofs: SUCC never contains a failing input, NULL never misses an empty success.
    alias K = ExpressionKind;
    static void check(ref GrammarAnalysis graph, size_t[] indices) nothrow {
        auto bites = BitesAnalysis(graph);
        foreach (input; sampleInputs(4)) {
            foreach (index; indices) {
                const end = matchNode(graph, index, input, 0);
                if (bites.succ(index).contains(input))
                    assert(end >= 0, "SUCC claimed success on a failing input");
                if (end == 0)
                    assert(bites.nul(index).contains(input), "NULL missed an empty success");
                bool bit;
                matchNode(graph, index, input, 0, &bit);
                if (bit)
                    assert(bites.bites(index).contains(input), "BITES missed a bite");
            }
        }
    }

    GrammarAnalysis graph;
    graph.names = ["R"];
    graph.expressions = [
        lit("ab"), // 0
        lit("a"), // 1
        lit("c"), // 2
        plain("eps", Nullable.yes), // 3
        plain("eoi", Nullable.yes), // 4
        composite(K.choice, "or", [0, 1]), // 5: 'ab' / 'a'
        composite(K.predicate, "negLookahead", [0]), // 6: !'ab'
        composite(K.predicate, "posLookahead", [1]), // 7: &'a'
        composite(K.optional, "option", [2]), // 8: 'c'?
        composite(K.repetition, "zeroOrMore", [1]), // 9: 'a'*
        composite(K.sequence, "and", [6, 1]), // 10: !'ab' 'a'
        composite(K.sequence, "and", [7, 9, 4]), // 11: &'a' 'a'* eoi
        composite(K.choice, "or", [10, 8]), // 12: (!'ab' 'a') / 'c'?
        composite(K.sequence, "and", [8, 6]), // 13: 'c'? !'ab'
        composite(K.wrapper, "discard", [13]), // 14
        composite(K.predicate, "negLookahead", [6]), // 15: !!'ab'
        composite(K.sequence, "and", [15, 5]), // 16
        composite(K.choice, "or", [3, 2]), // 17: eps / 'c'
        composite(K.sequence, "and", [9, 8, 4]), // 18
    ];
    graph.roots = [5];
    graph.solve();
    check(graph, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]);
}

version (unittest) private Expression letters() {
    Expression e;
    e.kind = ExpressionKind.terminal;
    e.known = true;
    e.nullable = Nullable.no;
    e.byteTerminal = true;
    e.byteWidth = 1;
    e.source = "charRange!(97, 122)";
    e.alphabet.addRange('a', 'z');
    e.first = e.alphabet;
    return e;
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["R"];
    graph.expressions = [
        lit("abc"), // 0
        letters(), // 1
        composite(K.repetition, "zeroOrMore", [1]), // 2: letter*
        composite(K.sequence, "and", [0, 2]), // 3: "abc" letter*
        composite(K.predicate, "negLookahead", [0]), // 4: !"abc"
        composite(K.sequence, "and", [4, 2]), // 5: (!"abc") letter*
        composite(K.predicate, "negLookahead", [4]), // 6: !!"abc"
        composite(K.sequence, "and", [6, 6]), // 7: pure lookahead only
        composite(K.optional, "option", [0]), // 8: "abc"?
        composite(K.sequence, "and", [8, 1]), // 9: "abc"? letter (nullable prefix, consuming suffix)
        lit("x"), // 10
        composite(K.choice, "or", [0, 10]), // 11
        Expression(K.unknown), // 12
        composite(K.sequence, "and", [12, 1]), // 13: unknown prefix
        plain("eoi", Nullable.yes), // 14
        composite(K.sequence, "and", [14, 1]), // 15: eoi letter
        Expression(), // 16: a malformed-UTF-8 style single byte class below
    ];
    graph.expressions[16] = letters();
    graph.expressions[16].alphabet = CharSetMask.init;
    graph.expressions[16].alphabet.addRange(0x80, 0xff);
    graph.expressions[16].first = graph.expressions[16].alphabet;
    graph.roots = [3];
    graph.solve();
    auto bites = BitesAnalysis(graph);
    // BITES("abc" letter*) = "abc" Σ*
    const abcAny = InputLanguage.prefix("abc");
    foreach (probe; ["abc", "abcd", "abd", "", "x"])
        assert(bites.bites(3).contains(probe) == abcAny.contains(probe));
    // BITES((!"abc") letter*) = (Σ* \ "abc" Σ*) ∩ letter Σ*: FIRST bytes overlap, BITES are disjoint
    assert(bites.bites(5).contains("abd") && bites.bites(5).contains("x") && !bites.bites(5).contains("abcd"));
    assert(!bites.bites(5).contains("") && !bites.bites(5).contains("1"));
    assert(bites.bites(3).intersect(bites.bites(5)).emptiness() == Proof.provenEmpty);
    // pure lookahead has no bite
    assert(bites.bites(7).emptiness() == Proof.provenEmpty && bites.bites(4).emptiness() == Proof.provenEmpty);
    // nullable prefix then consuming suffix: prefix bites on "abc..." and letter bites on any letter start
    assert(bites.bites(9).contains("abcz") && bites.bites(9).contains("q") && !bites.bites(9).contains("1"));
    // union of choices, optional, repetition
    assert(bites.bites(11).contains("xyz") && bites.bites(11).contains("abc") && !bites.bites(11).contains("q"));
    assert(bites.bites(8).contains("abc") && bites.bites(2).contains("q"));
    // unknown prefix: the sequence cannot be restricted, so BITES is universal
    assert(bites.bites(13).contains("1") && bites.bites(12).contains(""));
    // EOF in prefix position: NULL(eoi) = {""} cannot be followed by a letter, so the sequence never bites
    assert(bites.bites(15).emptiness() == Proof.provenEmpty);
    // malformed UTF-8 byte class
    assert(bites.bites(16).contains("\xff") && bites.bites(16).contains("\x80z") && !bites.bites(16).contains("a"));
}

nothrow unittest {
    // Recursive rule degrades to universal at the back edge; parameterized/unresolved reference is top.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["A"];
    graph.expressions = [
        composite(K.reference, "", []), // 0 -> A
        lit("a"), // 1
        composite(K.sequence, "and", [1, 0]), // 2: 'a' A
        plain("eps", Nullable.yes), // 3
        composite(K.choice, "or", [2, 3]), // 4
        composite(K.reference, "", []), // 5 -> unresolved
    ];
    graph.expressions[0].reference = "A";
    graph.expressions[5].reference = "Missing";
    graph.roots = [4];
    graph.solve();
    auto bites = BitesAnalysis(graph);
    // The nonnullable 'a' prefix stops the walk before the back edge, so the answer is exact.
    assert(bites.bites(4).contains("a") && !bites.bites(4).contains("zz"));
    assert(bites.bites(5).contains("anything") && bites.bites(5).contains(""));
    // Left recursion reaches the back edge first: universal (sound top).
    GrammarAnalysis left;
    left.names = ["L"];
    left.expressions = [
        composite(K.reference, "", []), lit("a"), composite(K.sequence, "and", [0, 1]),
        plain("eps", Nullable.yes), composite(K.choice, "or", [2, 3])
    ];
    left.expressions[0].reference = "L";
    left.roots = [4];
    left.solve();
    auto topped = BitesAnalysis(left);
    assert(topped.bites(4).contains("zz") && topped.bites(4).contains(""));
}

nothrow unittest {
    // Failure continuation, nested rule calls, and the frame rule: (A / 'q') 'z' with A <- 'a' 'b'.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root", "A"];
    graph.expressions = [
        composite(K.reference, "", []), // 0 -> A
        lit("q"), // 1
        composite(K.choice, "or", [0, 1]), // 2
        lit("z"), // 3
        composite(K.sequence, "and", [2, 3]), // 4 Root
        lit("a"), // 5
        lit("b"), // 6
        composite(K.sequence, "and", [5, 6]), // 7 A
    ];
    graph.expressions[0].reference = "A";
    graph.roots = [4, 7];
    graph.solve();
    auto bites = BitesAnalysis(graph);
    auto next = NextBites(graph, bites);
    assert(next.trusted && next.converged);
    // A failed at p: the next alternative 'q' bites at p. Seen through the rule body and its first element.
    assert(next.nextBites(0, Outcome.fail).contains("q") && !next.nextBites(0, Outcome.fail).contains("z"));
    assert(next.nextBites(7, Outcome.fail).contains("q"));
    assert(next.nextBites(5, Outcome.fail).contains("q")); // 'a' is first: failing there is failing at A's start
    assert(next.nextBites(6, Outcome.fail).emptiness() == Proof.provenEmpty); // 'b' failed after consuming: backtrack
    // A succeeded: the choice succeeds, then 'z' bites.
    assert(next.nextBites(0, Outcome.succ).contains("z") && !next.nextBites(0, Outcome.succ).contains("q"));
    assert(next.nextBites(7, Outcome.succ).contains("z") && next.nextBites(6, Outcome.succ).contains("z"));
    assert(next.nextBites(4, Outcome.succ).emptiness() == Proof.provenEmpty); // the start rule: nothing follows
}

nothrow unittest {
    // Right recursion converges; left recursion and unknown nodes yield universal results and no proven premises.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["R"];
    graph.expressions = [
        lit("a"), // 0
        composite(K.reference, "", []), // 1 -> R
        composite(K.sequence, "and", [0, 1]), // 2: 'a' R
        lit("b"), // 3
        composite(K.choice, "or", [2, 3]), // 4
    ];
    graph.expressions[1].reference = "R";
    graph.roots = [4];
    graph.solve();
    auto bites = BitesAnalysis(graph);
    auto next = NextBites(graph, bites);
    assert(next.converged && next.nextBites(4, Outcome.succ).emptiness() == Proof.provenEmpty);
    assert(next.nextBites(1, Outcome.succ).emptiness() == Proof.provenEmpty);
    const ok = checkPremises(graph, bites, next);
    assert(ok.length == 1 && ok[0].wellFormed && ok[0].disjoint && ok[0].prop10 && ok[0].prop11);

    GrammarAnalysis left;
    left.names = ["L"];
    left.expressions = [
        composite(K.reference, "", []), lit("a"), composite(K.sequence, "and", [0, 1]), lit("b"),
        composite(K.choice, "or", [2, 3])
    ];
    left.expressions[0].reference = "L";
    left.roots = [4];
    left.solve();
    auto leftBites = BitesAnalysis(left);
    auto leftNext = NextBites(left, leftBites);
    const leftChecks = checkPremises(left, leftBites, leftNext);
    assert(leftChecks.length == 1 && !leftChecks[0].wellFormed && !leftChecks[0].prop10 && !leftChecks[0].prop11);

    GrammarAnalysis opaque;
    opaque.names = ["O"];
    opaque.expressions = [Expression(K.unknown), lit("a"), composite(K.choice, "or", [1, 0])];
    opaque.roots = [2];
    opaque.solve();
    auto opaqueBites = BitesAnalysis(opaque);
    auto opaqueNext = NextBites(opaque, opaqueBites);
    assert(!opaqueNext.trusted && opaqueNext.nextBites(1, Outcome.succ).contains("anything"));
    const opaqueChecks = checkPremises(opaque, opaqueBites, opaqueNext);
    assert(opaqueChecks.length == 1 && !opaqueChecks[0].prop10 && !opaqueChecks[0].prop11);
    // A tiny budget also degrades soundly: still no proven premise, never an empty NEXTBITES.
    Budget tiny;
    tiny.maxStates = 3;
    auto tinyBites = BitesAnalysis(graph, tiny);
    auto tinyNext = NextBites(graph, tinyBites, tiny);
    assert(tinyNext.nextBites(1, Outcome.succ).emptiness() != Proof.provenNonempty
            || tinyNext.nextBites(1, Outcome.succ).contains(""));
}

version (unittest) private Expression classAB() {
    auto e = letters();
    e.source = "charRange!(97, 98)";
    e.alphabet = CharSetMask.init;
    e.alphabet.addRange('a', 'b');
    e.first = e.alphabet;
    return e;
}

nothrow unittest {
    // B7: regular SUCC. Keyword K = 'ab' ![a-b]; guarded name G = !K [a-b]+; plus fixed chains and unknown steps.
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["R"];
    graph.expressions = [
        lit("ab"), // 0
        classAB(), // 1
        composite(K.predicate, "negLookahead", [1]), // 2: ![a-b]
        composite(K.sequence, "and", [0, 2]), // 3: keyword 'ab' ![a-b]
        composite(K.predicate, "negLookahead", [3]), // 4: !Keyword
        composite(K.wrapper, "oneOrMore", [1]), // 5: [a-b]+
        composite(K.sequence, "and", [4, 5]), // 6: !Keyword [a-b]+
        lit("a"), // 7
        lit("c"), // 8
        composite(K.sequence, "and", [7, 1, 8]), // 9: 'a' [a-b] 'c' (fixed chain)
        composite(K.optional, "option", [7]), // 10
        composite(K.sequence, "and", [10, 8]), // 11: 'a'? 'c' (unknown length first step)
        composite(K.predicate, "posLookahead", [0]), // 12: &'ab'
        composite(K.sequence, "and", [12, 0]), // 13: &'ab' 'ab'
        composite(K.predicate, "negLookahead", [9]), // 14: !('a' [a-b] 'c')
        composite(K.sequence, "and", [14, 7, 1]), // 15
    ];
    graph.roots = [6];
    graph.solve();
    auto plainSucc = BitesAnalysis(graph);
    auto regular = BitesAnalysis(graph, Budget.init, true);
    // original SUCC knows nothing about longer sequences; regular SUCC does
    assert(plainSucc.succ(3).emptiness() == Proof.provenEmpty && plainSucc.succ(9).emptiness() == Proof.provenEmpty);
    assert(regular.succ(3).contains("ab") && regular.succ(3).contains("ab1") && regular.succ(3).contains("ab c"));
    assert(!regular.succ(3).contains("aba") && !regular.succ(3).contains("a"));
    assert(regular.succ(9).contains("abc") && regular.succ(9).contains("aac1") && !regular.succ(9).contains("acc"));
    assert(regular.succ(11).emptiness() == Proof.provenEmpty); // unknown-length step: no lower bound
    assert(regular.succ(13).contains("abx") && !regular.succ(13).contains("a"));
    // !Keyword narrows NULL: nullable only where the keyword certainly fails
    assert(plainSucc.nul(4).contains("ab") && !regular.nul(4).contains("ab") && regular.nul(4).contains("aba"));
    // BITES of the guarded name excludes "ab" followed by a non-letter, but keeps "aba..."
    assert(regular.bites(6).contains("aba") && !regular.bites(6).contains("ab1") && !regular.bites(6).contains("ab"));
    assert(plainSucc.bites(6).contains("ab1")); // without regular SUCC the guard is vacuous
    // soundness by sampling: SUCC never claims a failing input; MAYSUCC never misses a success; NULL/BITES as before
    foreach (input; sampleInputs(4)) {
        foreach (index; [0UL, 3, 4, 6, 9, 11, 13, 14, 15]) {
            const end = matchNode(graph, index, input, 0);
            if (regular.succ(index).contains(input))
                assert(end >= 0, "regular SUCC claimed success on a failing input");
            if (end >= 0)
                assert(regular.maySucc(index).contains(input), "MAYSUCC missed a success");
            if (end == 0)
                assert(regular.nul(index).contains(input), "NULL missed an empty success");
            bool bit;
            matchNode(graph, index, input, 0, &bit);
            if (bit)
                assert(regular.bites(index).contains(input), "BITES missed a bite");
        }
    }
}

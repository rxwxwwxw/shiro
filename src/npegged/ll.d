/** Report-only PEG -> LL/CFG conversion contract (L1) and certified EBNF export (L2).

    PEG ordered choice and greedy repetition are not CFG alternation and repetition, so a rule region is
    classified by what can be *proven* about it. Nothing here generates or changes a parser.

    Classes (worst finding in the closed region wins, order: unknown > pegOnly > cfgCandidateUnproven >
    boundedLookaheadCandidate > certifiedLL1):
      certifiedLL1             every choice has pairwise FIRST-disjoint alternatives, a nullable alternative is last and
                               conflict-free against FOLLOW, every repetition/option is non-nullable and its BITES miss what
                               follows (NEXTBITES); no predicates, actions, recursion hazards or undescribable terminals.
      boundedLookaheadCandidate FIRST overlaps, but BITES proves the alternatives disjoint (needs k>1 or regular lookahead).
      cfgCandidateUnproven     a CFG reading exists but ordered choice / greedy repetition may hide language; no proof.
      pegOnly                  lookahead predicates, left recursion, or definite ordered-choice shadowing.
      unknown                  actions/effects, unknown or unresolved nodes, parameters, undescribable terminals.

    Assumptions behind `certifiedLL1`: the contract is the language of whole inputs (parsers must consume the input;
    callers add `eoi`); byte-oriented terminals; the sufficient LL(1) condition of Mascarenhas, Medeiros, Ierusalimschy
    (2014) plus the BITES/NEXTBITES premises of this repository for repetition. Empirical corpus checks are extra evidence.
*/
module npegged.ll;
import npegged.analysis;
import npegged.bites;
import npegged.language;
import npegged.peg : CharSetMask;

nothrow:

enum RegionClass : ubyte {
    certifiedLL1,
    boundedLookaheadCandidate,
    cfgCandidateUnproven,
    pegOnly,
    unknown
}

string className(RegionClass value) nothrow {
    final switch (value) {
    case RegionClass.certifiedLL1:
        return "certifiedLL1";
    case RegionClass.boundedLookaheadCandidate:
        return "boundedLookaheadCandidate";
    case RegionClass.cfgCandidateUnproven:
        return "CFGCandidateUnproven";
    case RegionClass.pegOnly:
        return "PEGOnly";
    case RegionClass.unknown:
        return "unknown";
    }
}

nothrow unittest {
    assert(className(RegionClass.certifiedLL1) == "certifiedLL1");
    assert(className(RegionClass.boundedLookaheadCandidate) == "boundedLookaheadCandidate");
    assert(className(RegionClass.cfgCandidateUnproven) == "CFGCandidateUnproven");
    assert(className(RegionClass.pegOnly) == "PEGOnly");
    assert(className(RegionClass.unknown) == "unknown");
}

/// One finding: the class it forces, a reason, and the graph node it was found at.
struct Finding {
    RegionClass forced;
    string reason;
    size_t expressionIndex = size_t.max;
}

struct RuleRegion {
    string rule;
    size_t ruleIndex;
    RegionClass local; // the rule's own body
    RegionClass region; // the rule plus every rule it can reach
    Finding[] findings; // local findings, including the witnesses of what blocked a better class
    string[] reachable; // rules in the closed region (excluding itself)
}

private RegionClass worse(RegionClass a, RegionClass b) nothrow {
    return a > b ? a : b;
}

/// Terminals the exporter and the proofs can describe exactly: escape-free literals, single-byte classes, eps, eoi.
bool describableTerminal(ref Expression node) nothrow {
    if (!node.known)
        return false;
    const source = node.source;
    if (source == "eps" || source == "eoi" || source == "endOfInput")
        return true;
    if (BitesAnalysis.plainLiteral(source).length)
        return true;
    return node.byteTerminal && node.byteWidth == 1 && node.nullable == Nullable.no;
}

nothrow unittest {
    Expression node;
    node.source = "eps";
    assert(!describableTerminal(node));
    node.known = true;
    foreach (source; ["eps", "eoi", "endOfInput", "literal!(\"a\")"]) {
        node.source = source;
        assert(describableTerminal(node));
    }
    node.source = "customTerminal";
    assert(!describableTerminal(node));
    node.byteTerminal = true;
    assert(!describableTerminal(node));
    node.byteWidth = 1;
    assert(!describableTerminal(node));
    node.nullable = Nullable.no;
    assert(describableTerminal(node));
    node.byteWidth = 2;
    assert(!describableTerminal(node));
}

RuleRegion[] classifyRegions(ref GrammarAnalysis graph, Budget budget = Budget.init) nothrow {
    auto choices = graph.analyzeAllPrefixDiscriminations();
    annotateBites(graph, choices, budget);
    auto bites = BitesAnalysis(graph, budget);
    auto next = NextBites(graph, bites, budget);
    const effects = graph.ruleEffects();
    RuleRegion[] regions;
    foreach (rule, root; graph.roots) {
        RuleRegion region;
        region.rule = rule < graph.names.length ? graph.names[rule] : "";
        region.ruleIndex = rule;
        region.local = RegionClass.certifiedLL1;
        void note(RegionClass forced, string reason, size_t node = size_t.max) nothrow {
            region.findings ~= Finding(forced, reason, node);
            region.local = worse(region.local, forced);
        }

        if (rule < effects.length && !(effects[rule].known && !effects[rule].actionful))
            note(RegionClass.unknown, "rule has actions or unknown effects");
        if (rule < graph.leftRecursive.length && graph.leftRecursive[rule])
            note(RegionClass.pegOnly, "left recursion: PEG semantics differ from a CFG reading");
        void classifyChoice(size_t index) nothrow {
            ChoiceDiscrimination found;
            foreach (ref candidate; choices)
                if (candidate.expressionIndex == index)
                    found = candidate;
            const children = graph.expressions[index].children;
            bool allFirstDisjoint = found.pairs.length != 0 || children.length < 2, anyDefinite, allBites = true;
            foreach (pair; found.pairs) {
                allFirstDisjoint = allFirstDisjoint && pair.kind == DiscriminationKind.disjointFirst;
                anyDefinite = anyDefinite || pair.definite;
                allBites = allBites && pair.bites == "proven-disjoint";
            }
            size_t nullableAlternatives;
            bool lastOnly = true;
            foreach (i, child; children) {
                const mayBeEmpty = child >= graph.facts.length || graph.facts[child].nullable != Nullable.no;
                if (mayBeEmpty) {
                    ++nullableAlternatives;
                    lastOnly = lastOnly && i + 1 == children.length;
                }
            }
            if (anyDefinite)
                note(RegionClass.pegOnly, "ordered-choice shadowing: an earlier alternative hides a later one", index);
            else if (nullableAlternatives && (!lastOnly || nullableAlternatives > 1))
                note(RegionClass.cfgCandidateUnproven,
                        "a nullable alternative is not the only, last alternative", index);
            else if (nullableAlternatives) {
                // Positional continuation (NEXTBITES), not rule-level FOLLOW: the choice may sit mid-rule.
                bool safe = next.trusted && next.converged;
                foreach (i, child; children)
                    if (i + 1 < children.length && bites.bites(child).intersect(next.nextBites(index,
                            Outcome.succ), budget).emptiness() != Proof.provenEmpty)
                        safe = false;
                if (!safe)
                    note(RegionClass.cfgCandidateUnproven,
                            "a nullable alternative may hide what follows the choice (NEXTBITES overlap or untrusted)",
                            index);
            } else if (!allFirstDisjoint && allBites)
                note(RegionClass.boundedLookaheadCandidate,
                        "FIRST overlap resolved only by BITES (needs bounded lookahead)", index);
            else if (!allFirstDisjoint)
                note(RegionClass.cfgCandidateUnproven,
                        "alternatives overlap and BITES does not prove them disjoint", index);
        }

        void classifyRepeat(size_t index, string what) nothrow {
            auto node = graph.expressions[index];
            const 
            body = node.children[0];
            const nonnullable = body < graph.facts.length && graph.facts[body].nullable == Nullable.no;
            if (!nonnullable) {
                note(RegionClass.pegOnly, what ~ " of a possibly nullable body (non-progress rules differ)", index);
                return;
            }
            auto hit = bites.bites(body).intersect(next.nextBites(index, Outcome.succ), budget);
            if (hit.emptiness() != Proof.provenEmpty)
                note(RegionClass.cfgCandidateUnproven, "greedy " ~ what ~ " may consume input that follows it", index);
        }

        auto seen = new bool[graph.expressions.length];
        void visit(size_t index) nothrow {
            if (index >= graph.expressions.length || seen[index])
                return;
            seen[index] = true;
            auto node = graph.expressions[index];
            final switch (node.kind) {
            case ExpressionKind.unknown:
                note(RegionClass.unknown, "unknown or unsupported node", index);
                return;
            case ExpressionKind.terminal:
                if (!describableTerminal(node))
                    note(RegionClass.unknown,
                            "terminal not describable by bytes: " ~ node.source, index);
                return;
            case ExpressionKind.reference:
                if (graph.referenceRule(node) == size_t.max)
                    note(RegionClass.unknown,
                            "unresolved or parameterized reference: " ~ node.reference, index);
                return; // callee findings belong to the callee's region
            case ExpressionKind.predicate:
                note(RegionClass.pegOnly,
                        "lookahead predicate has no CFG counterpart", index);
                break;
            case ExpressionKind.sequence:
            case ExpressionKind.wrapper:
                break;
            case ExpressionKind.choice:
                classifyChoice(index);
                break;
            case ExpressionKind.optional:
            case ExpressionKind.repetition:
                classifyRepeat(index,
                        node.kind == ExpressionKind.optional ? "option" : "repetition");
                break;
            }
            if (node.kind == ExpressionKind.wrapper && node.combinator == "oneOrMore")
                classifyRepeat(index, "one-or-more");
            foreach (child; node.children)
                visit(child);
        }

        visit(root);
        region.region = region.local;
        regions ~= region;
    }
    // Close each region over the rules it can reach.
    foreach (ref region; regions) {
        auto reached = new bool[regions.length];
        size_t[] stack = [region.ruleIndex];
        reached[region.ruleIndex] = true;
        while (stack.length) {
            const at = stack[$ - 1];
            stack.length -= 1;
            auto marks = new bool[graph.expressions.length];
            void walk(size_t index) nothrow {
                if (index >= graph.expressions.length || marks[index])
                    return;
                marks[index] = true;
                auto node = graph.expressions[index];
                if (node.kind == ExpressionKind.reference) {
                    const target = graph.referenceRule(node);
                    if (target != size_t.max && !reached[target]) {
                        reached[target] = true;
                        stack ~= target;
                    }
                }
                foreach (child; node.children)
                    walk(child);
            }

            walk(graph.roots[at]);
        }
        foreach (other; 0 .. regions.length)
            if (reached[other] && other != region.ruleIndex) {
                region.reachable ~= regions[other].rule;
                region.region = worse(region.region, regions[other].local);
            }
    }
    return regions;
}

private string quoted(string text) nothrow {
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
    assert(quoted("") == "\"\"");
    assert(quoted("a\"\\\x00\x1f\x7f\xff") == "\"a\\\"\\\\\\u0000\\u001f\\u007f\\u00ff\"");
}

private string number(size_t value) nothrow {
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

nothrow unittest {
    assert(number(0) == "0");
    assert(number(1204) == "1204");
    static if (size_t.sizeof == 8)
        assert(number(size_t.max) == "18446744073709551615");
    else
        assert(number(size_t.max) == "4294967295");
}

string renderRegions(const RuleRegion[] regions, bool json) nothrow {
    if (!json) {
        string text;
        foreach (region; regions) {
            text ~= "rule " ~ region.rule ~ ": " ~ className(region.region) ~ " (local " ~ className(
                    region.local) ~ ")\n";
            foreach (finding; region.findings)
                text ~= "  - " ~ className(finding.forced) ~ ": " ~ finding.reason ~ "\n";
            if (region.reachable.length) {
                text ~= "  reaches:";
                foreach (name; region.reachable)
                    text ~= " " ~ name;
                text ~= "\n";
            }
        }
        return text;
    }
    string result = "{\"scope\":\"conversion contract: sufficient conditions only; unknown never means convertible\",\"rules\":[";
    foreach (i, region; regions) {
        result ~= (i ? "," : "") ~ "{\"rule\":" ~ quoted(region.rule) ~ ",\"class\":\"" ~ className(
                region.region) ~ "\",\"local\":\"" ~ className(region.local) ~ "\",\"reaches\":[";
        foreach (k, name; region.reachable)
            result ~= (k ? "," : "") ~ quoted(name);
        result ~= "],\"findings\":[";
        foreach (k, finding; region.findings)
            result ~= (k ? "," : "") ~ "{\"class\":\"" ~ className(finding.forced) ~ "\",\"reason\":" ~ quoted(
                    finding.reason) ~ ",\"node\":" ~ (finding.expressionIndex == size_t.max
                    ? "null" : number(finding.expressionIndex)) ~ "}";
        result ~= "]}";
    }
    return result ~ "]}";
}

nothrow unittest {
    assert(renderRegions([], false) == "");
    auto empty = renderRegions([], true);
    assert(empty[$ - 3 .. $] == "[]}");
    RuleRegion first;
    first.rule = "A";
    first.local = RegionClass.certifiedLL1;
    first.region = RegionClass.unknown;
    first.reachable = ["B", "C"];
    first.findings = [
        Finding(RegionClass.unknown, "missing"), Finding(RegionClass.pegOnly, "predicate", 12)
    ];
    RuleRegion second;
    second.rule = "B";
    auto text = renderRegions([first, second], false);
    assert(text == "rule A: unknown (local certifiedLL1)\n  - unknown: missing\n  - PEGOnly: predicate\n  reaches: B C\nrule B: certifiedLL1 (local certifiedLL1)\n");
    auto json = renderRegions([first, second], true);
    assert(json == empty[0 .. $ - 2] ~ "{\"rule\":\"A\",\"class\":\"unknown\",\"local\":\"certifiedLL1\",\"reaches\":[\"B\",\"C\"],\"findings\":[{\"class\":\"unknown\",\"reason\":\"missing\",\"node\":null},{\"class\":\"PEGOnly\",\"reason\":\"predicate\",\"node\":12}]},{\"rule\":\"B\",\"class\":\"certifiedLL1\",\"local\":\"certifiedLL1\",\"reaches\":[],\"findings\":[]}]}");
}

// ---------------------------------------------------------------- L2: certified EBNF export

private string hex2(ubyte value) nothrow {
    enum digits = "0123456789abcdef";
    string result = "\\x";
    result ~= digits[value >> 4];
    result ~= digits[value & 15];
    return result;
}

private string ebnfLiteral(string text) nothrow {
    string result = "\"";
    foreach (c; text) {
        if (c == '"' || c == '\\') {
            result ~= '\\';
            result ~= c;
        } else if (c >= 0x20 && c < 0x7f)
            result ~= c;
        else
            result ~= hex2(cast(ubyte)c);
    }
    return result ~ "\"";
}

nothrow unittest {
    assert(ebnfLiteral("") == "\"\"");
    assert(ebnfLiteral("a\"\\\x00\x1f\x7f\xff") == "\"a\\\"\\\\\\x00\\x1f\\x7f\\xff\"");
}

private string ebnfClass(const CharSetMask mask) nothrow {
    string result = "[";
    size_t c;
    while (c < 256) {
        if (!mask.contains(cast(char)c)) {
            ++c;
            continue;
        }
        size_t last = c;
        while (last + 1 < 256 && mask.contains(cast(char)(last + 1)))
            ++last;
        result ~= hex2(cast(ubyte)c);
        if (last > c)
            result ~= "-" ~ hex2(cast(ubyte)last);
        c = last + 1;
    }
    return result ~ "]";
}

nothrow unittest {
    CharSetMask mask;
    assert(ebnfClass(mask) == "[]");
    mask.addChar('\0');
    mask.addChar('a');
    mask.addChar('b');
    mask.addChar(cast(char)255);
    assert(ebnfClass(mask) == "[\\x00\\x61-\\x62\\xff]");
}

/// EBNF for one expression of a certified region. `level`: 0 choice context, 1 sequence element, 2 postfix operand.
private string ebnfExpression(ref GrammarAnalysis graph, size_t index, int level) nothrow {
    auto node = graph.expressions[index];
    string group(string text, bool needed) nothrow {
        return needed ? "( " ~ text ~ " )" : text;
    }

    final switch (node.kind) {
    case ExpressionKind.unknown:
    case ExpressionKind.predicate:
        return "(* unexportable *)"; // unreachable for certified regions
    case ExpressionKind.terminal:
        if (node.source == "eps")
            return "eps";
        if (node.source == "eoi" || node.source == "endOfInput")
            return "EOF";
        if (auto text = BitesAnalysis.plainLiteral(node.source))
            return ebnfLiteral(text);
        return ebnfClass(node.alphabet);
    case ExpressionKind.reference:
        return node.reference;
    case ExpressionKind.wrapper:
        if (node.combinator == "oneOrMore")
            return ebnfExpression(graph, node.children[0], 2) ~ "+";
        return ebnfExpression(graph, node.children[0], level); // captures do not change the language
    case ExpressionKind.optional:
        return ebnfExpression(graph, node.children[0], 2) ~ "?";
    case ExpressionKind.repetition:
        return ebnfExpression(graph, node.children[0], 2) ~ "*";
    case ExpressionKind.sequence:
        if (!node.children.length)
            return "eps";
        string text;
        foreach (i, child; node.children)
            text ~= (i ? " " : "") ~ ebnfExpression(graph, child, 1);
        return group(text, level == 2);
    case ExpressionKind.choice:
        string text;
        foreach (i, child; node.children)
            text ~= (i ? " | " : "") ~ ebnfExpression(graph, child, 0);
        return group(text, level > 0);
    }
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.expressions = [
        Expression(K.unknown), Expression(K.predicate), Expression(K.terminal),
        Expression(K.reference), Expression(K.wrapper, [2]), Expression(K.optional, [2]),
        Expression(K.repetition, [2]), Expression(K.sequence), Expression(K.sequence, [2, 3]),
        Expression(K.choice, [2, 3])
    ];
    graph.expressions[2].source = "eps";
    graph.expressions[3].reference = "Leaf";
    assert(ebnfExpression(graph, 0, 0) == "(* unexportable *)");
    assert(ebnfExpression(graph, 1, 0) == "(* unexportable *)");
    assert(ebnfExpression(graph, 2, 0) == "eps");
    assert(ebnfExpression(graph, 3, 0) == "Leaf");
    assert(ebnfExpression(graph, 4, 0) == "eps");
    graph.expressions[4].combinator = "oneOrMore";
    assert(ebnfExpression(graph, 4, 0) == "eps+");
    assert(ebnfExpression(graph, 5, 0) == "eps?");
    assert(ebnfExpression(graph, 6, 0) == "eps*");
    assert(ebnfExpression(graph, 7, 0) == "eps");
    assert(ebnfExpression(graph, 8, 0) == "eps Leaf");
    assert(ebnfExpression(graph, 8, 2) == "( eps Leaf )");
    assert(ebnfExpression(graph, 9, 0) == "eps | Leaf");
    assert(ebnfExpression(graph, 9, 1) == "( eps | Leaf )");
    foreach (source; ["eoi", "endOfInput"]) {
        graph.expressions[2].source = source;
        assert(ebnfExpression(graph, 2, 0) == "EOF");
    }
    graph.expressions[2].source = "literal!(\"a\")";
    assert(ebnfExpression(graph, 2, 0) == "\"a\"");
    graph.expressions[2].source = "charRange!('a', 'b')";
    graph.expressions[2].alphabet.addChar('a');
    graph.expressions[2].alphabet.addChar('b');
    assert(ebnfExpression(graph, 2, 0) == "[\\x61-\\x62]");
}

/// Export converted rules as EBNF (text) or JSON with proof metadata. Only `certifiedLL1` regions are converted;
/// every other rule gets a separate `not-convertible` (PEG-specific or unproven) or `unknown` entry with its reasons.
string renderEbnf(ref GrammarAnalysis graph, bool json, Budget budget = Budget.init) nothrow {
    const regions = classifyRegions(graph, budget);
    string text = json ? "{\"scope\":\"certified LL(1) regions only; other rules are not converted\","
        ~ "\"contract\":\"language of whole inputs; EOF is end of input; byte terminals\",\"rules\":[" : "";
    foreach (i, region; regions) {
        const converted = region.region == RegionClass.certifiedLL1;
        const status = converted ? "converted" : region.region == RegionClass.unknown ? "unknown" : "not-convertible";
        string reasons;
        foreach (k, finding; region.findings)
            reasons ~= (k ? "; " : "") ~ finding.reason;
        string body = converted ? ebnfExpression(graph, graph.roots[region.ruleIndex], 0) : "";
        if (json) {
            text ~= (i ? "," : "") ~ "{\"rule\":" ~ quoted(region.rule) ~ ",\"ruleIndex\":" ~ number(
                    region.ruleIndex) ~ ",\"status\":\"" ~ status ~ "\",\"class\":\"" ~ className(region.region) ~ "\"";
            if (converted)
                text ~= ",\"ebnf\":" ~ quoted(body) ~ ",\"proof\":{\"class\":\"certifiedLL1\",\"closedRegion\":[";
            else
                text ~= ",\"reasons\":" ~ quoted(reasons) ~ ",\"proof\":{\"closedRegion\":[";
            foreach (k, name; region.reachable)
                text ~= (k ? "," : "") ~ quoted(name);
            text ~= "]}}";
        } else if (converted)
            text ~= region.rule ~ " ::= " ~ body ~ " ;\n";
        else
            text ~= "(* not converted: " ~ region.rule ~ " is " ~ className(region.region) ~ (reasons.length
                    ? ": " ~ reasons : "") ~ " *)\n";
    }
    return json ? text ~ "]}" : text;
}

nothrow unittest {
    // A closed conversion region must retain every reachable rule in its proof.
    alias K = ExpressionKind;
    Expression leaf;
    leaf.kind = K.terminal;
    leaf.source = "literal!(\"a\")";
    leaf.known = true;
    leaf.nullable = Nullable.no;
    leaf.first.addChar('a');
    GrammarAnalysis graph;
    graph.names = ["Root", "Mid", "Leaf"];
    graph.expressions = [
        leaf, Expression(K.reference), Expression(K.reference), Expression(K.sequence, [2, 2])
    ];
    graph.expressions[1].reference = "Leaf";
    graph.expressions[2].reference = "Mid";
    graph.expressions[3].combinator = "and";
    graph.roots = [3, 1, 0];
    graph.solve();
    assert(renderEbnf(graph, false) == "Root ::= Mid Mid ;\nMid ::= Leaf ;\nLeaf ::= \"a\" ;\n");
    const json = renderEbnf(graph, true);
    enum proof = "\"closedRegion\":[\"Mid\",\"Leaf\"]";
    bool found;
    foreach (i; 0 .. json.length - proof.length + 1)
        found = found || json[i .. i + proof.length] == proof;
    assert(found);
    assert(firstCertifiedRules(graph) == [true, true, true]);
}

// ---------------------------------------------------------------- cheap certifier for code generation (L3)

/// Rules whose closed region passes the classic positional LL(1) test using FIRST/FOLLOW bitsets only
/// (no language algebra, so it is cheap enough to run during compile-time evaluation). Sound but weaker than
/// `classifyRegions`: any certified rule here is `certifiedLL1`-eligible, never the other way round.
/// Conditions: no predicates, unknown nodes, unresolved references, left recursion or actions; every choice has
/// pairwise FIRST-disjoint, non-nullable alternatives; every `e?`, `e*`, `e+` has a non-nullable body whose FIRST
/// misses the bytes that can follow the construct (computed positionally, ending in the rule's FOLLOW).
bool[] firstCertifiedRules(ref GrammarAnalysis graph) nothrow {
    const follow = followSets(graph);
    const effects = graph.ruleEffects();
    auto local = new bool[graph.roots.length];
    foreach (rule, root; graph.roots) {
        bool ok = rule < effects.length && effects[rule].known && !effects[rule].actionful
            && !(rule < graph.leftRecursive.length && graph.leftRecursive[rule]);
        const known = rule < follow.known.length && follow.known[rule];
        CharSetMask top;
        top.bits[] = ulong.max;
        auto seen = new bool[graph.expressions.length];
        bool intersects(const CharSetMask a, const CharSetMask b) nothrow {
            foreach (w; 0 .. 4)
                if (a.bits[w] & b.bits[w])
                    return true;
            return false;
        }

        CharSetMask merged(const CharSetMask a, const CharSetMask b) nothrow {
            CharSetMask result;
            foreach (w; 0 .. 4)
                result.bits[w] = a.bits[w] | b.bits[w];
            return result;
        }

        bool nonnullable(size_t index) nothrow {
            return index < graph.facts.length && graph.facts[index].nullable == Nullable.no;
        }

        void walk(size_t index, CharSetMask cont) nothrow {
            if (!ok || index >= graph.expressions.length || seen[index])
                return;
            seen[index] = true;
            auto node = graph.expressions[index];
            if (index >= graph.facts.length || !graph.facts[index].known) {
                ok = false;
                return;
            }
            final switch (node.kind) {
            case ExpressionKind.unknown:
            case ExpressionKind.predicate:
                ok = false;
                return;
            case ExpressionKind.terminal:
                ok = ok && describableTerminal(node);
                return;
            case ExpressionKind.reference:
                ok = ok && graph.referenceRule(node) != size_t.max;
                return;
            case ExpressionKind.wrapper:
                if (node.combinator == "oneOrMore") {
                    const 
                    body = node.children[0];
                    ok = ok && nonnullable(body) && !intersects(graph.facts[body].first, cont);
                    walk(body, merged(graph.facts[body].first, cont));
                } else
                    walk(node.children[0], cont);
                return;
            case ExpressionKind.sequence:
                CharSetMask running = cont;
                foreach_reverse (child; node.children) {
                    walk(child, running);
                    if (child >= graph.facts.length) {
                        ok = false;
                        return;
                    }
                    running = graph.facts[child].nullable == Nullable.no ? graph.facts[child].first
                        : merged(graph.facts[child].first, running);
                }
                return;
            case ExpressionKind.choice:
                foreach (i, child; node.children) {
                    ok = ok && nonnullable(child);
                    foreach (other; node.children[i + 1 .. $])
                        ok = ok && other < graph.facts.length && child < graph.facts.length
                            && !intersects(graph.facts[child].first, graph.facts[other].first);
                    walk(child, cont);
                }
                return;
            case ExpressionKind.optional:
            case ExpressionKind.repetition:
                const 
                body = node.children[0];
                ok = ok && nonnullable(body) && body < graph.facts.length && !intersects(graph.facts[body].first, cont);
                walk(body, node.kind == ExpressionKind.repetition ? merged(graph.facts[body].first, cont) : cont);
                return;
            }
        }

        walk(root, known ? follow.follow[rule] : top);
        local[rule] = ok;
    }
    // Close over the rules each rule can reach.
    auto result = new bool[graph.roots.length];
    foreach (rule; 0 .. graph.roots.length) {
        auto reached = new bool[graph.roots.length];
        size_t[] stack = [rule];
        reached[rule] = true;
        bool all = true;
        while (stack.length) {
            const at = stack[$ - 1];
            stack.length -= 1;
            all = all && local[at];
            auto marks = new bool[graph.expressions.length];
            void follow2(size_t index) nothrow {
                if (index >= graph.expressions.length || marks[index])
                    return;
                marks[index] = true;
                auto node = graph.expressions[index];
                if (node.kind == ExpressionKind.reference) {
                    const target = graph.referenceRule(node);
                    if (target != size_t.max && !reached[target]) {
                        reached[target] = true;
                        stack ~= target;
                    }
                }
                foreach (child; node.children)
                    follow2(child);
            }

            follow2(graph.roots[at]);
        }
        result[rule] = all;
    }
    return result;
}

nothrow unittest {
    alias K = ExpressionKind;
    Expression a;
    a.kind = K.terminal;
    a.source = `literal!("a")`;
    a.known = true;
    a.nullable = Nullable.no;
    a.first.addChar('a');
    Expression b = a;
    b.source = `literal!("b")`;
    b.first = CharSetMask.init;
    b.first.addChar('b');
    GrammarAnalysis graph;
    graph.names = ["Root"];
    graph.expressions = [a, b, Expression(K.optional, [0]), Expression(K.sequence, [2, 1])];
    graph.expressions[3].combinator = "and";
    graph.roots = [3];
    foreach (kind; [K.optional, K.repetition, K.wrapper]) {
        graph.expressions[2].kind = kind;
        graph.expressions[2].combinator = kind == K.optional ? "option" : kind == K.repetition
            ? "zeroOrMore" : "oneOrMore";
        graph.expressions[0] = a;
        graph.solve();
        assert(firstCertifiedRules(graph) == [true]);
        graph.expressions[0].source = "eps";
        graph.expressions[0].nullable = Nullable.yes;
        graph.expressions[0].first = CharSetMask.init;
        graph.solve();
        assert(firstCertifiedRules(graph) == [false]);
        assert(classifyRegions(graph)[0].region == RegionClass.pegOnly);
    }
    graph.expressions[0] = a;
    graph.solve();
    graph.facts[0].known = false;
    assert(firstCertifiedRules(graph) == [false]);
}

nothrow unittest {
    // The cheap certifier must be a subset of the full classification on every fixture below.
    import npegged.language : Budget;

    alias K = ExpressionKind;
    CharSetMask a, b, c;
    a.addChar('a');
    b.addChar('b');
    c.addChar('c');
    Expression term(CharSetMask first, string text) {
        Expression e;
        e.kind = K.terminal;
        e.known = true;
        e.nullable = Nullable.no;
        e.source = "literal!(\"" ~ text ~ "\")";
        e.first = first;
        return e;
    }

    GrammarAnalysis graph;
    graph.names = ["Star", "Hide", "Pick", "Dup"];
    graph.expressions = [
        term(a, "a"), // 0
        Expression(K.repetition, [0]), // 1
        term(b, "b"), // 2
        Expression(K.sequence, [1, 2]), // 3  Star <- 'a'* 'b'
        Expression(K.repetition, [0]), // 4
        term(a, "a"), // 5
        Expression(K.sequence, [4, 5]), // 6  Hide <- 'a'* 'a'
        term(a, "a"), // 7
        term(c, "c"), // 8
        Expression(K.choice, [7, 8]), // 9  Pick <- 'a' / 'c'
        term(a, "a"), // 10
        term(a, "a"), // 11
        Expression(K.choice, [10, 11]), // 12 Dup <- 'a' / 'a'
    ];
    foreach (ref e; graph.expressions)
        if (e.kind != K.terminal) {
            e.combinator = e.kind == K.sequence ? "and" : e.kind == K.choice ? "or" : "zeroOrMore";
        }
    graph.roots = [3, 6, 9, 12];
    graph.solve();
    const cheap = firstCertifiedRules(graph);
    assert(cheap[0] && !cheap[1] && cheap[2] && !cheap[3]);
    const full = classifyRegions(graph);
    foreach (rule; 0 .. 4)
        if (cheap[rule])
            assert(full[rule].region == RegionClass.certifiedLL1);
}

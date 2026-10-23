/** Cold, conservative grammar graph analysis. No generated parser depends on GC. */
module npegged.analysis;
import npegged.peg : CharSetMask;

nothrow:

enum ExpressionKind {
    unknown,
    terminal,
    reference,
    sequence,
    choice,
    optional,
    repetition,
    predicate,
    wrapper
}

enum Nullable {
    unknown,
    no,
    yes
}

/// An expression graph uses indices so recursive rule references need no cyclic objects.
struct Expression {
    ExpressionKind kind;
    size_t[] children;
    string reference;
    CharSetMask first;
    Nullable nullable = Nullable.unknown;
    bool known;
    string source, combinator;
    string[] arguments;
    CharSetMask alphabet;
    bool byteTerminal;
    size_t byteWidth;
    /// The decoded bytes of a `literal!` terminal.
    string literalBytes;
    size_t rule = size_t.max;
}

struct FirstFacts {
    CharSetMask first;
    Nullable nullable = Nullable.unknown;
    bool known;
    bool eofOnly; // Any empty success requires end of input.
    /// One-sided proofs: false means "possibly", never "provably not".
    /// Both are least fixed points started from false, so recursion only loses precision.
    bool neverFails; // Every evaluation succeeds (ignoring resource limits).
    bool neverAdvances; // Every success consumes no input.
}

/// An ordered escape pair followed by an ordinary byte alternative.
struct EscapeLoop {
    size_t prefix, ordinary;
    bool known;
    bool doubled;
}

/// Report-only structural knowledge and conservative possibility of actions.
struct RuleEffect {
    bool known;
    bool actionful = true;
}

@nogc nothrow unittest {
    RuleEffect unknown;
    assert(!unknown.known && unknown.actionful);
}

/// Cold diagnostics for actual emitter choices. H02 refines effect evidence separately.
struct RuleEligibility {
    string name, rootExpression;
    bool known, actionful = true;
    bool leftRecursive, memoized, scalarEligible, directRecognition, directRecords;
    string[] scalarBlockers;
    string directFallback;
    bool selectorConfigured, recordSelected, recordLeaf, recordSubtree;
    uint recordKind = uint.max;
    /// Emitted code-generation facts (A3): what the generator actually produced for this rule.
    bool dfaScanner, predictiveDispatch;
    size_t scannerRegions;
    string strategy; // "direct-cursor", "dfa-scanner" or "combinator"
    /// W1: static bound on work units, "<a>*(n+1)" for an input of length n, or "unknown: <blocker>" (see npegged.work).
    string workBound = "unknown: not-computed";
}

@nogc nothrow unittest {
    RuleEligibility row;
    assert(row.recordKind == uint.max && !row.scalarEligible && !row.selectorConfigured);
}

/// Outcome of bounded literal-prefix discrimination between alternatives in ordered choice.
enum DiscriminationKind : ubyte {
    disjointFirst, // FIRST byte sets are disjoint; single-byte predictive dispatch suffices
    disjointTails, // FIRST bytes overlap; alternatives share a prefix and diverge on disjoint tail bytes
    shadowed, // Earlier alternative is an unguarded proper prefix or identical; later is shadowed
    guarded, // Earlier prefix alternative is guarded by EOF or a lookahead predicate
    unbounded // Overlap cannot be resolved by bounded literal prefix analysis
}

struct BranchDiscrimination {
    size_t firstIndex;
    size_t secondIndex;
    DiscriminationKind kind;
    size_t commonPrefixLength;
    string commonPrefix;
    ubyte discriminatingDepth;
    string detail;
    /// FIRST/FIRST (LL(1)) view: bytes both alternatives may start with. A conflict is only
    /// a potential hiding; `definite` is set only for proven literal-prefix shadowing.
    uint overlapBytes;
    bool firstFirstConflict;
    bool definite;
    /// BITES view (B4): "" (not analysed), "proven-disjoint", "possible-overlap" or "unknown".
    /// `possible-overlap` is an overlap of upper approximations, not proof of actual hiding.
    string bites;
    string bitesWitness; // shortest input in the intersection of the approximations, if any
    bool bitesImprovesFirst; // FIRST/FIRST conflict that BITES proves disjoint
    /// Proposition 5 premises hold (proven-disjoint, both alternatives provably nonnullable): no hiding.
    bool noHidingProven;
}

struct ChoiceDiscrimination {
    size_t expressionIndex;
    string ruleName;
    bool hasOverlap;
    BranchDiscrimination[] pairs;
    /// FIRST/FOLLOW: a nullable alternative whose continuation (FOLLOW of the owning rule) can start
    /// with a byte another alternative also starts with. Report-only; needs `followKnown`.
    size_t ruleIndex = size_t.max;
    bool followKnown;
    bool firstFollowConflict;
    bool bitesAllDisjoint; // every pair proven-disjoint
    bool noHidingProven; // every pair satisfies the Proposition 5 premises
}

@nogc nothrow unittest {
    BranchDiscrimination branch;
    assert(branch.kind == DiscriminationKind.disjointFirst && branch.commonPrefixLength == 0);
    ChoiceDiscrimination choice;
    assert(!choice.hasOverlap && choice.pairs.length == 0);
}

private int hexValue(char c) @nogc nothrow pure {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private string extractLiteralBytes(scope string text) nothrow {
    if (!text.length)
        return null;
    size_t qStart = 0;
    while (qStart < text.length && text[qStart] != '"' && text[qStart] != '\'')
        ++qStart;
    if (qStart >= text.length)
        return null;
    const quoteChar = text[qStart];
    size_t qEnd = qStart + 1;
    string result;
    while (qEnd < text.length && text[qEnd] != quoteChar) {
        if (text[qEnd] == '\\' && qEnd + 1 < text.length) {
            const next = text[qEnd + 1];
            if (next == 'n') {
                result ~= "\n";
                qEnd += 2;
            } else if (next == 'r') {
                result ~= "\r";
                qEnd += 2;
            } else if (next == 't') {
                result ~= "\t";
                qEnd += 2;
            } else if (next == '\\') {
                result ~= "\\";
                qEnd += 2;
            } else if (next == quoteChar) {
                result ~= quoteChar;
                qEnd += 2;
            } else if (next == '0') {
                result ~= "\0";
                qEnd += 2;
            } else if (next == 'x' && qEnd + 3 < text.length) {
                const int h1 = hexValue(text[qEnd + 2]);
                const int h2 = hexValue(text[qEnd + 3]);
                if (h1 >= 0 && h2 >= 0) {
                    result ~= cast(char)((h1 << 4) | h2);
                    qEnd += 4;
                } else {
                    result ~= text[qEnd .. qEnd + 2];
                    qEnd += 2;
                }
            } else {
                result ~= text[qEnd .. qEnd + 2];
                qEnd += 2;
            }
        } else {
            result ~= text[qEnd];
            ++qEnd;
        }
    }
    return result;
}

private string toDec(ulong value) pure nothrow {
    if (!value)
        return "0";
    char[20] buffer;
    size_t pos = buffer.length;
    while (value) {
        buffer[--pos] = cast(char)('0' + (value % 10));
        value /= 10;
    }
    return buffer[pos .. $].idup;
}

nothrow unittest {
    assert(toDec(0) == "0");
    assert(toDec(42) == "42");
    assert(toDec(123456) == "123456");

    assert(hexValue('0') == 0 && hexValue('9') == 9);
    assert(hexValue('a') == 10 && hexValue('f') == 15);
    assert(hexValue('A') == 10 && hexValue('F') == 15);
    assert(hexValue('z') == -1 && hexValue('!') == -1 && hexValue('@') == -1);

    assert(extractLiteralBytes("") is null);
    assert(extractLiteralBytes("no_quotes") is null);
    assert(extractLiteralBytes(`literal!("ab")`) == "ab");
    assert(extractLiteralBytes(`literal!('x')`) == "x");
    assert(extractLiteralBytes(`literal!("a\nb\x61")`) == "a\nba");
    assert(extractLiteralBytes(`"a\r\t\\\0\""`) == "a\r\t\\\0\"");
    assert(extractLiteralBytes(`"\x41\x42"`) == "AB");
    assert(extractLiteralBytes(`"\xgg"`) == "\\xgg");
    assert(extractLiteralBytes(`"\q"`) == "\\q");

    foreach (k; [
        DiscriminationKind.disjointFirst, DiscriminationKind.disjointTails,
        DiscriminationKind.shadowed, DiscriminationKind.guarded, DiscriminationKind.unbounded
    ])
        assert(discriminationKindName(k).length > 0);

    assert(jsonQuoted("hello\n\"\\world\x1f") == "\"hello\\u000a\\\"\\\\world\\u001f\"");

    ChoiceDiscrimination[] emptyList;
    assert(renderDiscrimination(emptyList, true) == "[]");
    assert(renderDiscrimination(emptyList, false) == "");

    ChoiceDiscrimination c1;
    c1.expressionIndex = 1;
    c1.ruleName = "Rule1";
    c1.hasOverlap = true;
    c1.pairs = [
        BranchDiscrimination(0, 1, DiscriminationKind.disjointTails, 1, "a", 2, "details"),
        BranchDiscrimination(0, 2, DiscriminationKind.shadowed, 0, "", 0, "shadow details")
    ];

    ChoiceDiscrimination c2;
    c2.expressionIndex = 2;
    c2.hasOverlap = false;
    c2.pairs = [BranchDiscrimination(0, 1, DiscriminationKind.disjointFirst, 0, "", 0, "disjoint")];

    ChoiceDiscrimination[] list = [c1, c2];
    auto json = renderDiscrimination(list, true);
    auto text = renderDiscrimination(list, false);
    assert(json.length > 0 && text.length > 0);
}

private string discriminationKindName(DiscriminationKind kind) pure nothrow {
    final switch (kind) {
    case DiscriminationKind.disjointFirst:
        return "disjointFirst";
    case DiscriminationKind.disjointTails:
        return "disjointTails";
    case DiscriminationKind.shadowed:
        return "shadowed";
    case DiscriminationKind.guarded:
        return "guarded";
    case DiscriminationKind.unbounded:
        return "unbounded";
    }
}

private string jsonQuoted(scope string value) pure nothrow {
    string result = "\"";
    enum hex = "0123456789abcdef";
    foreach (c; value) {
        if (c == '"' || c == '\\')
            result ~= "\\" ~ c;
        else if (cast(ubyte)c < 32)
            result ~= "\\u00" ~ hex[cast(ubyte)c >> 4] ~ hex[cast(ubyte)c & 15];
        else
            result ~= c;
    }
    return result ~ "\"";
}

string renderDiscrimination(scope const(ChoiceDiscrimination)[] discriminations, bool json = false) nothrow {
    if (json) {
        string res = "[";
        foreach (cIdx, ref choice; discriminations) {
            if (cIdx)
                res ~= ",";
            res ~= "{\"expressionIndex\":" ~ toDec(choice.expressionIndex) ~ ",\"ruleName\":" ~ jsonQuoted(
                    choice.ruleName) ~ ",\"hasOverlap\":" ~ (choice.hasOverlap ? "true" : "false") ~ ",\"pairs\":[";
            foreach (pIdx, ref p; choice.pairs) {
                if (pIdx)
                    res ~= ",";
                res ~= "{\"firstIndex\":" ~ toDec(p.firstIndex) ~ ",\"secondIndex\":" ~ toDec(
                        p.secondIndex) ~ ",\"kind\":\"" ~ discriminationKindName(
                        p.kind) ~ "\"" ~ ",\"commonPrefixLength\":" ~ toDec(
                        p.commonPrefixLength) ~ ",\"commonPrefix\":" ~ jsonQuoted(
                        p.commonPrefix) ~ ",\"discriminatingDepth\":" ~ toDec(
                        p.discriminatingDepth) ~ ",\"detail\":" ~ jsonQuoted(
                        p.detail) ~ ",\"overlapBytes\":" ~ toDec(
                        p.overlapBytes) ~ ",\"firstFirstConflict\":" ~ (p.firstFirstConflict
                        ? "true" : "false") ~ ",\"definite\":" ~ (p.definite ? "true" : "false") ~ ",\"bites\":" ~ jsonQuoted(
                        p.bites) ~ ",\"bitesWitness\":" ~ jsonQuoted(
                        p.bitesWitness) ~ ",\"bitesImprovesFirst\":" ~ (p.bitesImprovesFirst
                        ? "true" : "false") ~ ",\"noHidingProven\":" ~ (p.noHidingProven ? "true" : "false") ~ "}";
            }
            res ~= "],\"followKnown\":" ~ (choice.followKnown
                    ? "true" : "false") ~ ",\"firstFollowConflict\":" ~ (choice.firstFollowConflict
                    ? "true" : "false") ~ "}";
        }
        return res ~ "]";
    } else {
        string res;
        foreach (cIdx, ref choice; discriminations) {
            res ~= "Choice at node " ~ toDec(choice.expressionIndex);
            if (choice.ruleName.length)
                res ~= " (rule \"" ~ choice.ruleName ~ "\")";
            res ~= ": overlap=" ~ (choice.hasOverlap ? "yes" : "no") ~ ", first/follow=" ~ (!choice.followKnown
                    ? "unknown" : choice.firstFollowConflict ? "conflict" : "clear") ~ "\n";
            foreach (ref p; choice.pairs) {
                res ~= "  [" ~ toDec(p.firstIndex) ~ " vs " ~ toDec(p.secondIndex) ~ "] " ~ discriminationKindName(
                        p.kind);
                if (p.commonPrefixLength)
                    res ~= " (prefix \"" ~ p.commonPrefix ~ "\", depth " ~ toDec(p.discriminatingDepth) ~ ")";
                if (p.bites.length)
                    res ~= " {bites: " ~ p.bites ~ (p.bitesImprovesFirst
                            ? ", improves on FIRST" : "") ~ (p.noHidingProven ? ", no hiding (Prop. 5)" : "") ~ "}";
                res ~= " - " ~ p.detail ~ (p.firstFirstConflict ? " [first/first conflict, " ~ (p.definite
                        ? "definite shadowing" : "potential hiding") ~ "]" : "") ~ "\n";
            }
        }
        return res;
    }
}

/// FIRST is a conservative byte-set superset; unknown facts never enable dispatch.
/// Left edges include every call reachable before proven input consumption.
struct GrammarAnalysis {
nothrow:
    Expression[] expressions;
    private Expression[] _exprCap;
    string[] names;
    size_t[] roots;
    FirstFacts[] facts;
    private FirstFacts[] _factsCap;

    size_t appendExpression(Expression node) nothrow {
        const index = expressions.length;
        if (index >= _exprCap.length) {
            const cap = index < 32 ? 64 : index * 2;
            auto next = new Expression[cap];
            foreach (i; 0 .. index)
                next[i] = expressions[i];
            _exprCap = next;
        }
        _exprCap[index] = node;
        expressions = _exprCap[0 .. index + 1];
        return index;
    }

    void truncate(size_t count) @nogc nothrow {
        expressions = _exprCap[0 .. count];
        if (facts.length > count)
            facts = _factsCap[0 .. count];
    }

    nothrow unittest {
        GrammarAnalysis graph;
        const idx = graph.appendExpression(Expression(ExpressionKind.terminal));
        assert(idx == 0 && graph.expressions.length == 1);
        graph.truncate(0);
        assert(graph.expressions.length == 0);
    }

    size_t[][] leftEdges;
    bool[] leftRecursive;
    bool conservative;

    size_t referenceRule(ref Expression node) @nogc {
        if (node.rule == size_t.max - 1)
            return size_t.max;
        if (node.rule < names.length && names[node.rule] == node.reference)
            return node.rule;
        const r = ruleIndex(node.reference);
        node.rule = r == size_t.max ? size_t.max - 1 : r;
        return r;
    }

    @nogc nothrow unittest {
        string[1] names = ["First"];
        GrammarAnalysis graph;
        graph.names = names[];
        auto hit = Expression(ExpressionKind.reference, null, "First");
        assert(graph.referenceRule(hit) == 0 && graph.referenceRule(hit) == 0);
        auto miss = Expression(ExpressionKind.reference, null, "Missing");
        assert(graph.referenceRule(miss) == size_t.max && graph.referenceRule(miss) == size_t.max);
    }

    size_t ruleIndex(string name) @nogc {
        foreach (i, candidate; names)
            if (candidate == name)
                return i;
        return size_t.max;
    }

    @nogc nothrow unittest {
        string[2] names = ["First", "Second"];
        GrammarAnalysis graph;
        graph.names = names[];
        assert(graph.ruleIndex("First") == 0 && graph.ruleIndex("Second") == 1);
        assert(graph.ruleIndex("missing") == size_t.max);
    }

    /// Structural unknowns that force the existing grammar-wide conservative policy.
    string[] unknownEvidence() nothrow {
        string[] result;
        foreach (node; expressions)
            if (node.kind == ExpressionKind.unknown || node.kind == ExpressionKind.reference
                    && ruleIndex(node.reference) == size_t.max)
                result ~= node.source;
        return result;
    }

    nothrow unittest {
        GrammarAnalysis graph;
        graph.names = ["Known"];
        Expression known = Expression(ExpressionKind.reference, null, "Known");
        known.source = "Known";
        Expression opaque = Expression(ExpressionKind.reference, null, "External");
        opaque.source = "External";
        Expression action;
        action.source = "action!(literal!(\"a\"), effect)";
        graph.expressions = [known, opaque, action, Expression(ExpressionKind.terminal)];
        assert(graph.unknownEvidence() == ["External", action.source]);
        graph.expressions = null;
        assert(!graph.unknownEvidence().length);
    }

    /// Cold rule-local structural/effect facts. This does not modify solve() policy.
    /// Unknown calls may execute actions. Closed cycles use a monotone fixed point;
    /// structural knowledge is not a proof of termination or acyclicity.
    RuleEffect[] ruleEffects(scope const(bool)[] parameterized = null) nothrow {
        assert(names.length == roots.length);
        assert(!parameterized.length || parameterized.length == names.length);
        auto result = new RuleEffect[names.length];
        auto calls = new size_t[][names.length];
        auto seen = new size_t[expressions.length];
        size_t caller;
        void inspect(size_t index) nothrow {
            assert(index < expressions.length);
            if (seen[index] == caller + 1)
                return;
            seen[index] = caller + 1;
            auto node = expressions[index];
            if (node.kind == ExpressionKind.unknown) {
                result[caller].known = false;
                result[caller].actionful = true;
            } else if (node.kind == ExpressionKind.reference) {
                const callee = referenceRule(node);
                if (callee == size_t.max) {
                    result[caller].known = false;
                    result[caller].actionful = true;
                } else
                    calls[caller] ~= callee;
            } else {
                if (node.combinator == "action")
                    result[caller].actionful = true;
                foreach (child; node.children)
                    inspect(child);
            }
        }

        foreach (i, root; roots) {
            caller = i;
            const unknown = parameterized.length && parameterized[i];
            result[i] = RuleEffect(!unknown, unknown);
            inspect(root);
        }
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (i, edges; calls)
                foreach (callee; edges) {
                    const known = result[i].known && result[callee].known;
                    const actionful = result[i].actionful || result[callee].actionful;
                    if (known != result[i].known || actionful != result[i].actionful) {
                        result[i] = RuleEffect(known, actionful);
                        changed = true;
                    }
                }
        }
        return result;
    }

    nothrow unittest {
        GrammarAnalysis graph;
        assert(!graph.ruleEffects().length);
        graph.names = [
            "Pure", "Opaque", "Caller", "Action", "ActionCaller", "CycleA", "CycleB", "PureCycle"
        ];
        auto action = Expression(ExpressionKind.wrapper, [0]);
        action.combinator = "action";
        graph.expressions = [
            Expression(ExpressionKind.terminal),
            Expression(ExpressionKind.reference, null, "external"),
            Expression(ExpressionKind.reference, null, "Opaque"), action,
            Expression(ExpressionKind.reference, null, "Action"),
            Expression(ExpressionKind.reference, null, "CycleB"),
            Expression(ExpressionKind.reference, null, "CycleA"),
            Expression(ExpressionKind.sequence, [0, 2, 5]),
            Expression(ExpressionKind.reference, null, "PureCycle"),
            Expression(ExpressionKind.sequence, [0, 0]), Expression(ExpressionKind.unknown)
        ];
        graph.roots = [9, 1, 2, 3, 4, 7, 6, 8];
        auto effects = graph.ruleEffects();
        assert(effects[0].known && !effects[0].actionful);
        foreach (i; [1, 2, 5, 6])
            assert(!effects[i].known && effects[i].actionful);
        foreach (i; [3, 4])
            assert(effects[i].known && effects[i].actionful);
        assert(effects[7].known && !effects[7].actionful);
        bool[8] parameterized;
        parameterized[0] = parameterized[3] = true;
        auto guarded = graph.ruleEffects(parameterized[]);
        assert(!guarded[0].known && guarded[0].actionful);
        assert(!guarded[4].known && guarded[4].actionful);
        graph.expressions[7].children = [0, 4, 5];
        auto actionCycle = graph.ruleEffects();
        assert(actionCycle[5].known && actionCycle[5].actionful);
        assert(actionCycle[6].known && actionCycle[6].actionful);
        graph.roots[0] = 10;
        assert(!graph.ruleEffects()[0].known && graph.ruleEffects()[0].actionful);
        // Ordinary analysis flags and arrays are not changed by diagnostic facts.
        assert(!graph.conservative && !graph.leftRecursive.length);
        GrammarAnalysis reverse;
        reverse.names = ["First", "Second", "Unknown"];
        reverse.roots = [0, 1, 2];
        reverse.expressions = [
            Expression(ExpressionKind.reference, null, "Second"),
            Expression(ExpressionKind.reference, null, "Unknown"), Expression.init
        ];
        foreach (effect; reverse.ruleEffects())
            assert(!effect.known && effect.actionful);
    }

    private struct BranchPrefix {
        string literal;
        bool exact = true;
        bool guardedByEoi;
        bool hasPredicate;
        bool indeterminate;
    }

    private BranchPrefix inspectBranch(size_t index, size_t depth = 0) nothrow {
        if (depth >= 32 || index >= expressions.length) {
            BranchPrefix ind;
            ind.indeterminate = true;
            ind.exact = false;
            return ind;
        }
        const node = expressions[index];
        if (node.kind == ExpressionKind.unknown) {
            BranchPrefix ind;
            ind.indeterminate = true;
            ind.exact = false;
            return ind;
        }
        if (node.kind == ExpressionKind.reference) {
            const callee = referenceRule(cast(Expression)node);
            if (callee == size_t.max || (leftRecursive.length > callee && leftRecursive[callee])) {
                BranchPrefix ind;
                ind.indeterminate = true;
                ind.exact = false;
                return ind;
            }
            return inspectBranch(roots[callee], depth + 1);
        }
        if (node.kind == ExpressionKind.wrapper) {
            if (node.children.length)
                return inspectBranch(node.children[0], depth + 1);
            BranchPrefix ind;
            ind.indeterminate = true;
            ind.exact = false;
            return ind;
        }
        if (node.kind == ExpressionKind.predicate) {
            BranchPrefix pred;
            pred.hasPredicate = true;
            pred.exact = false;
            return pred;
        }
        if (node.kind == ExpressionKind.terminal) {
            if (node.source == "eps")
                return BranchPrefix("", true, false, false, false);
            if (node.source == "eoi" || node.source == "endOfInput")
                return BranchPrefix("", false, true, false, false);
            if (node.source == "doublequote")
                return BranchPrefix("\"", true, false, false, false);
            if (node.source == "quote")
                return BranchPrefix("'", true, false, false, false);
            if (node.source == "backslash")
                return BranchPrefix("\\", true, false, false, false);
            if (node.source == "slash")
                return BranchPrefix("/", true, false, false, false);
            if (node.source == "tab")
                return BranchPrefix("\t", true, false, false, false);
            if (node.source == "backquote")
                return BranchPrefix("`", true, false, false, false);
            if (node.source.length >= 7 && node.source[0 .. 7] == "literal") {
                const lit = extractLiteralBytes(node.source);
                return BranchPrefix(lit, true, false, false, false);
            }
            BranchPrefix ind;
            ind.indeterminate = true;
            ind.exact = false;
            return ind;
        }
        if (node.kind == ExpressionKind.sequence) {
            string prefixLit;
            bool exactAll = true;
            bool guardedEoi = false;
            bool hasPred = false;
            bool indet = false;
            foreach (child; node.children) {
                const cp = inspectBranch(child, depth + 1);
                if (cp.hasPredicate)
                    hasPred = true;
                if (cp.guardedByEoi)
                    guardedEoi = true;
                if (cp.indeterminate) {
                    if (!prefixLit.length)
                        indet = true;
                    exactAll = false;
                    break;
                }
                if (cp.literal.length) {
                    prefixLit ~= cp.literal;
                    if (!cp.exact) {
                        exactAll = false;
                        break;
                    }
                }
            }
            return BranchPrefix(prefixLit, exactAll && !hasPred && !guardedEoi, guardedEoi, hasPred, indet);
        }
        BranchPrefix ind;
        ind.indeterminate = true;
        ind.exact = false;
        return ind;
    }

    private BranchDiscrimination compareBranches(size_t firstChild, size_t secondChild, size_t i, size_t j) nothrow {
        BranchDiscrimination result;
        result.firstIndex = i;
        result.secondIndex = j;

        const bool firstHasFacts = firstChild < facts.length;
        const bool secondHasFacts = secondChild < facts.length;
        bool overlap = false;
        if (firstHasFacts && secondHasFacts) {
            overlap = facts[firstChild].first.intersects(facts[secondChild].first);
            if (!overlap && facts[firstChild].nullable == Nullable.yes && facts[secondChild].nullable == Nullable.yes)
                overlap = true;
        }

        if (!overlap) {
            result.kind = DiscriminationKind.disjointFirst;
            result.detail = "disjoint FIRST byte sets";
            return result;
        }

        const a = inspectBranch(firstChild);
        const b = inspectBranch(secondChild);

        size_t commonLen = 0;
        while (commonLen < a.literal.length && commonLen < b.literal.length
                && a.literal[commonLen] == b.literal[commonLen])
            ++commonLen;

        result.commonPrefixLength = commonLen;
        result.commonPrefix = a.literal[0 .. commonLen];

        if (commonLen < a.literal.length && commonLen < b.literal.length) {
            result.kind = DiscriminationKind.disjointTails;
            result.discriminatingDepth = cast(ubyte)(commonLen + 1);
            result.detail = "disjoint tails after prefix \"" ~ result.commonPrefix ~ "\" at depth " ~ toDec(
                    commonLen + 1) ~ " ('" ~ a.literal[commonLen] ~ "' vs '" ~ b.literal[commonLen] ~ "')";
            return result;
        }

        if (commonLen == a.literal.length && commonLen < b.literal.length) {
            if (a.guardedByEoi) {
                result.kind = DiscriminationKind.guarded;
                result.discriminatingDepth = cast(ubyte)(commonLen + 1);
                result.detail = "guarded: earlier alternative " ~ toDec(i) ~ " (\"" ~ a.literal
                    ~ "\") is guarded by eoi";
                return result;
            }
            if (a.hasPredicate) {
                result.kind = DiscriminationKind.guarded;
                result.discriminatingDepth = cast(ubyte)(commonLen + 1);
                result.detail = "guarded: earlier alternative " ~ toDec(
                        i) ~ " (\"" ~ a.literal ~ "\") has lookahead predicate";
                return result;
            }
            if (a.exact) {
                result.kind = DiscriminationKind.shadowed;
                result.discriminatingDepth = cast(ubyte)commonLen;
                result.detail = "shadowed: earlier alternative " ~ toDec(
                        i) ~ " (\"" ~ a.literal ~ "\") is unguarded prefix of alternative " ~ toDec(j);
                return result;
            }
            result.kind = DiscriminationKind.unbounded;
            result.detail = "unbounded: earlier alternative has non-literal tail";
            return result;
        }

        if (commonLen == a.literal.length && commonLen == b.literal.length && a.literal.length > 0) {
            if (a.guardedByEoi || a.hasPredicate) {
                result.kind = DiscriminationKind.guarded;
                result.detail = "guarded: earlier alternative " ~ toDec(i) ~ " has guard";
                return result;
            }
            if (a.exact && b.exact) {
                result.kind = DiscriminationKind.shadowed;
                result.discriminatingDepth = cast(ubyte)commonLen;
                result.detail = "shadowed: alternative " ~ toDec(j) ~ " is identical to earlier alternative " ~ toDec(i);
                return result;
            }
            result.kind = DiscriminationKind.unbounded;
            result.detail = "unbounded: identical prefix with non-literal tail";
            return result;
        }

        if (commonLen == b.literal.length && commonLen < a.literal.length) {
            result.kind = DiscriminationKind.disjointTails;
            result.discriminatingDepth = cast(ubyte)(commonLen + 1);
            result.detail = "disjoint tails: alternative " ~ toDec(
                    i) ~ " requires byte '" ~ a.literal[commonLen] ~ "' after prefix \"" ~ result.commonPrefix ~ "\"";
            return result;
        }

        result.kind = DiscriminationKind.unbounded;
        result.detail = "unbounded: non-literal or recursive overlap";
        return result;
    }

    ChoiceDiscrimination analyzePrefixDiscrimination(size_t exprIndex) nothrow {
        return analyzePrefixDiscrimination(exprIndex, followSets(this), true);
    }

    private size_t owningRule(size_t target) nothrow {
        foreach (r, root; roots) {
            auto seen = new bool[expressions.length];
            bool reaches(size_t index) nothrow {
                if (index == target)
                    return true;
                if (seen[index])
                    return false;
                seen[index] = true;
                foreach (child; expressions[index].children)
                    if (reaches(child))
                        return true;
                return false;
            }

            if (reaches(root))
                return r;
        }
        return size_t.max;
    }

    private ChoiceDiscrimination analyzePrefixDiscrimination(size_t exprIndex, const FollowResult follow,
            bool followValid) nothrow {
        import core.bitop : popcnt;

        ChoiceDiscrimination result;
        result.expressionIndex = exprIndex;
        if (exprIndex >= expressions.length)
            return result;
        const node = expressions[exprIndex];
        if (node.kind != ExpressionKind.choice)
            return result;

        result.ruleIndex = owningRule(exprIndex);
        if (result.ruleIndex < names.length)
            result.ruleName = names[result.ruleIndex];

        const branches = node.children;
        foreach (i; 0 .. branches.length) {
            foreach (j; i + 1 .. branches.length) {
                auto pair = compareBranches(branches[i], branches[j], i, j);
                if (pair.kind != DiscriminationKind.disjointFirst)
                    result.hasOverlap = true;
                if (branches[i] < facts.length && branches[j] < facts.length) {
                    foreach (w; 0 .. 4)
                        pair.overlapBytes += popcnt(facts[branches[i]].first.bits[w] & facts[branches[j]].first.bits[w]);
                    pair.firstFirstConflict = pair.overlapBytes != 0;
                }
                pair.definite = pair.kind == DiscriminationKind.shadowed;
                result.pairs ~= pair;
            }
        }
        // FIRST/FOLLOW: only meaningful when FOLLOW of the owning rule is trusted.
        if (followValid && result.ruleIndex < follow.known.length && follow.known[result.ruleIndex]) {
            result.followKnown = true;
            foreach (i, nullableBranch; branches) {
                if (nullableBranch >= facts.length || facts[nullableBranch].nullable == Nullable.no)
                    continue;
                foreach (j, other; branches) {
                    if (i == j || other >= facts.length)
                        continue;
                    foreach (w; 0 .. 4)
                        if (facts[other].first.bits[w] & follow.follow[result.ruleIndex].bits[w])
                            result.firstFollowConflict = true;
                }
            }
        }
        return result;
    }

    ChoiceDiscrimination[] analyzeAllPrefixDiscriminations() nothrow {
        ChoiceDiscrimination[] results;
        const follow = followSets(this);
        foreach (i, const ref expr; expressions) {
            if (expr.kind == ExpressionKind.choice)
                results ~= analyzePrefixDiscrimination(i, follow, true);
        }
        return results;
    }

    nothrow unittest {
        alias K = ExpressionKind;
        alias N = Nullable;
        CharSetMask a, b;
        a.addChar('a');
        b.addChar('b');

        // Test 1: "ab" / "ac"
        GrammarAnalysis g1;
        g1.names = ["Root"];
        g1.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ac\""),
            Expression(K.choice, [0, 1], null, CharSetMask.init, N.no, true, "or!(literal!\"ab\", literal!\"ac\")")
        ];
        g1.roots = [2];
        g1.solve();
        auto d1 = g1.analyzePrefixDiscrimination(2);
        assert(d1.hasOverlap);
        assert(d1.pairs.length == 1);
        assert(d1.pairs[0].kind == DiscriminationKind.disjointTails);
        assert(d1.pairs[0].commonPrefix == "a");
        assert(d1.pairs[0].commonPrefixLength == 1);
        assert(d1.pairs[0].discriminatingDepth == 2);

        // Test 2: "a" / "ab"
        GrammarAnalysis g2;
        g2.names = ["Root"];
        g2.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"a\""),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.choice, [0, 1], null, CharSetMask.init, N.no, true, "or!(literal!\"a\", literal!\"ab\")")
        ];
        g2.roots = [2];
        g2.solve();
        auto d2 = g2.analyzePrefixDiscrimination(2);
        assert(d2.hasOverlap);
        assert(d2.pairs.length == 1);
        assert(d2.pairs[0].kind == DiscriminationKind.shadowed);
        assert(d2.pairs[0].commonPrefix == "a");
        assert(d2.pairs[0].discriminatingDepth == 1);

        // Test 3: "a" eoi / "ab"
        GrammarAnalysis g3;
        g3.names = ["Root"];
        g3.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"a\""),
            Expression(K.terminal, null, null, CharSetMask.init, N.yes, true, "eoi"),
            Expression(K.sequence, [0, 1], null, CharSetMask.init, N.no, true,
                    "and!(literal!\"a\", eoi)"),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.choice, [2, 3], null, CharSetMask.init, N.no, true,
                    "or!(and!(literal!\"a\", eoi), literal!\"ab\")")
        ];
        g3.roots = [4];
        g3.solve();
        auto d3 = g3.analyzePrefixDiscrimination(4);
        assert(d3.hasOverlap);
        assert(d3.pairs.length == 1);
        assert(d3.pairs[0].kind == DiscriminationKind.guarded);
        assert(d3.pairs[0].commonPrefix == "a");

        // Test 4: &'ax' 'a' / 'ab'
        GrammarAnalysis g4;
        g4.names = ["Root"];
        g4.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ax\""),
            Expression(K.predicate, [0], null, CharSetMask.init, N.yes, true,
                    "posLookahead!(literal!\"ax\")"),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"a\""),
            Expression(K.sequence, [1, 2], null, CharSetMask.init, N.no, true,
                    "and!(posLookahead!(literal!\"ax\"), literal!\"a\")"),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.choice, [3, 4], null, CharSetMask.init, N.no, true,
                    "or!(and!(posLookahead!(literal!\"ax\"), literal!\"a\"), literal!\"ab\")")
        ];
        g4.roots = [5];
        g4.solve();
        auto d4 = g4.analyzePrefixDiscrimination(5);
        assert(d4.hasOverlap);
        assert(d4.pairs.length == 1);
        assert(d4.pairs[0].kind == DiscriminationKind.guarded);

        // Test 5: "a" / "b" (disjoint FIRST)
        GrammarAnalysis g5;
        g5.names = ["Root"];
        g5.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"a\""),
            Expression(K.terminal, null, null, b, N.no, true, "literal!\"b\""),
            Expression(K.choice, [0, 1], null, CharSetMask.init, N.no, true, "or!(literal!\"a\", literal!\"b\")")
        ];
        g5.roots = [2];
        g5.solve();
        auto d5 = g5.analyzePrefixDiscrimination(2);
        assert(!d5.hasOverlap);
        assert(d5.pairs.length == 1);
        assert(d5.pairs[0].kind == DiscriminationKind.disjointFirst);

        // Test 6: non-choice node, out-of-range index, and all discriminations
        assert(!g5.analyzePrefixDiscrimination(0).hasOverlap);
        assert(!g5.analyzePrefixDiscrimination(999).hasOverlap);
        assert(g5.analyzeAllPrefixDiscriminations().length == 1);

        // Test 7: "ab" / "ab" (identical -> shadowed)
        GrammarAnalysis g7;
        g7.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.choice, [0, 1], null, CharSetMask.init, N.no, true, "or!(literal!\"ab\", literal!\"ab\")")
        ];
        g7.solve();
        auto d7 = g7.analyzePrefixDiscrimination(2);
        assert(d7.pairs[0].kind == DiscriminationKind.shadowed);

        // Test 8: "ab" / "a" (longer first -> disjoint tails)
        GrammarAnalysis g8;
        g8.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"ab\""),
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"a\""),
            Expression(K.choice, [0, 1], null, CharSetMask.init, N.no, true, "or!(literal!\"ab\", literal!\"a\")")
        ];
        g8.solve();
        auto d8 = g8.analyzePrefixDiscrimination(2);
        assert(d8.pairs[0].kind == DiscriminationKind.disjointTails);

        // Test 9: special terminals: doublequote, quote, backslash, slash, tab, backquote, eps, eoi
        GrammarAnalysis g9;
        g9.expressions = [
            Expression(K.terminal, null, null, CharSetMask.fromChars('"'), N.no, true,
                    "doublequote"),
            Expression(K.terminal, null, null, CharSetMask.fromChars('\''), N.no, true, "quote"),
            Expression(K.terminal, null, null, CharSetMask.fromChars('\\'), N.no, true,
                    "backslash"),
            Expression(K.terminal, null, null, CharSetMask.fromChars('/'), N.no, true, "slash"),
            Expression(K.terminal, null, null, CharSetMask.fromChars('\t'), N.no, true, "tab"),
            Expression(K.terminal, null, null, CharSetMask.fromChars('`'), N.no, true,
                    "backquote"),
            Expression(K.terminal, null, null, CharSetMask.init, N.yes, true, "eps"),
            Expression(K.terminal, null, null, CharSetMask.init, N.yes, true, "endOfInput"),
            Expression(K.choice, [0, 1, 2, 3, 4, 5, 6, 7])
        ];
        g9.solve();
        auto d9 = g9.analyzePrefixDiscrimination(8);
        assert(d9.pairs.length == 28);

        // Test 10: references (valid, unknown, left-recursive), wrappers (with/without children), unknown nodes
        GrammarAnalysis g10;
        g10.names = ["Target", "Rec"];
        g10.roots = [0, 2];
        g10.expressions = [
            Expression(K.terminal, null, null, a, N.no, true, "literal!\"a\""), // 0
            Expression(K.reference,
                    null, "Target"), // 1 -> Target (valid)
            Expression(K.reference, null, "Rec"), // 2 -> Rec (recursive)
            Expression(K.reference, null, "Missing"), // 3 -> Missing
            Expression(K.wrapper, [0]), // 4 -> wrapper with child
            Expression(K.unknown), // 5 -> unknown node
            Expression(K.terminal, null, null, a, N.no, true, "any"), // 6 -> non-literal terminal
            Expression(K.sequence, [6,
                0]), // 7 -> sequence with indeterminate prefix
            Expression(K.sequence, [0, 6]), // 8 -> sequence with non-exact suffix
            Expression(K.choice, [1, 4, 3, 2, 5, 7, 8]) // 9
        ];
        g10.leftRecursive = [false, true];
        g10.solve();
        auto d10 = g10.analyzePrefixDiscrimination(9);
        assert(d10.pairs.length > 0);

        // Test 11: both nullable overlap, guarded identical, and unbounded non-literal overlap
        GrammarAnalysis g11;
        g11.expressions = [
            Expression(K.terminal, null, null, CharSetMask.init, N.yes, true, "eps"), // 0
            Expression(K.terminal,
                    null, null, CharSetMask.init, N.yes, true, "eps"), // 1
            Expression(K.sequence, [0,
                0]), // 2
            Expression(K.choice, [0, 1]), // 3
            Expression(K.choice, [2, 0]) // 4
        ];
        g11.solve();
        auto d11 = g11.analyzePrefixDiscrimination(3);
        assert(d11.hasOverlap);
    }

    /// Only closed, acyclic expressions with understood effects may be shared.
    bool shareable(size_t index) {
        bool[] visiting = new bool[names.length];
        bool inspect(size_t current) {
            auto node = expressions[current];
            if (node.kind == ExpressionKind.unknown)
                return false;
            if (node.kind == ExpressionKind.reference) {
                const rule = referenceRule(node);
                if (rule == size_t.max || visiting[rule])
                    return false;
                visiting[rule] = true;
                const result = inspect(roots[rule]);
                visiting[rule] = false;
                return result;
            }
            foreach (child; node.children)
                if (!inspect(child))
                    return false;
            return true;
        }

        return inspect(index);
    }

    unittest {
        GrammarAnalysis graph;
        graph.names = ["Token", "Cycle"];
        graph.expressions = [
            Expression(ExpressionKind.terminal), Expression(ExpressionKind.reference, null, "Token"),
            Expression(ExpressionKind.reference, null, "Cycle"),
            Expression(ExpressionKind.reference, null, "External"),
            Expression(ExpressionKind.unknown), Expression(ExpressionKind.sequence, [0, 1]),
            Expression(ExpressionKind.sequence, [0, 4])
        ];
        graph.roots = [0, 2];
        assert(graph.shareable(5));
        assert(!graph.shareable(2));
        assert(!graph.shareable(3));
        assert(!graph.shareable(6));
    }

    private CharSetMask continuation(size_t current) @nogc {
        auto expression = expressions[current];
        if (expression.kind == ExpressionKind.reference)
            return continuation(roots[referenceRule(expression)]);
        const escaped = escapeLoop(current);
        if (escaped.known)
            return expressions[escaped.prefix].first | expressions[escaped.ordinary].first;
        CharSetMask result;
        if (expression.kind == ExpressionKind.terminal)
            return result;
        if (expression.combinator == "zeroOrMore" || expression.combinator == "oneOrMore"
                || expression.combinator == "option")
            return facts[expression.children[0]].first | continuation(expression.children[0]);
        if (expression.kind == ExpressionKind.sequence) {
            for (size_t i = expression.children.length; i > 0; --i) {
                const child = expression.children[i - 1];
                result = result | continuation(child);
                if (i > 1) {
                    const paired = escapeLoop(expression.children[i - 2]);
                    if (paired.known && paired.doubled && expressions[child].byteWidth == 1
                            && expressions[child].first == expressions[paired.prefix].first)
                        result = result | expressions[child].first;
                }
                if (facts[child].nullable == Nullable.no)
                    break;
            }
            return result;
        }
        foreach (child; expression.children)
            result = result | continuation(child);
        return result;
    }

    @nogc nothrow unittest {
        Expression[4] nodes;
        FirstFacts[4] values;
        size_t[1] optional = [1];
        size_t[2] sequence = [0, 2];
        nodes[0].kind = nodes[1].kind = ExpressionKind.terminal;
        nodes[2].kind = ExpressionKind.optional;
        nodes[2].combinator = "option";
        nodes[2].children = optional[];
        nodes[3].kind = ExpressionKind.sequence;
        nodes[3].children = sequence[];
        values[0] = FirstFacts(CharSetMask.fromChars('a'), Nullable.no, true);
        values[1] = FirstFacts(CharSetMask.fromChars('b'), Nullable.no, true);
        values[2] = FirstFacts(values[1].first, Nullable.yes, true);
        GrammarAnalysis graph;
        graph.expressions = nodes[];
        graph.facts = values[];
        assert(graph.continuation(3) == CharSetMask.fromChars('b'));
        assert(graph.continuation(0).empty);

        Expression[10] nodes10;
        FirstFacts[10] values10;
        nodes10[0 .. 4] = nodes[];
        values10[0 .. 4] = values[];
        nodes10[4].kind = ExpressionKind.terminal;
        nodes10[4].byteTerminal = true;
        nodes10[4].byteWidth = 2;
        nodes10[4].first.addChar('"');
        nodes10[4].alphabet = nodes10[4].first;
        nodes10[5].kind = ExpressionKind.terminal;
        nodes10[5].byteTerminal = true;
        nodes10[5].byteWidth = 1;
        nodes10[5].first.addChar('x');
        size_t[2] escChoices = [4, 5];
        nodes10[6].combinator = "or";
        nodes10[6].children = escChoices[];
        size_t[1] escRepeated = [6];
        nodes10[7].combinator = "zeroOrMore";
        nodes10[7].children = escRepeated[];
        nodes10[8].kind = ExpressionKind.terminal;
        nodes10[8].byteTerminal = true;
        nodes10[8].byteWidth = 1;
        nodes10[8].first.addChar('"');
        size_t[2] escSeq = [7, 8];
        nodes10[9].kind = ExpressionKind.sequence;
        nodes10[9].children = escSeq[];
        values10[7] = FirstFacts(CharSetMask.fromChars('"', 'x'), Nullable.yes, true);
        values10[8] = FirstFacts(CharSetMask.fromChars('"'), Nullable.no, true);
        graph.expressions = nodes10[];
        graph.facts = values10[];
        assert(graph.continuation(9) == CharSetMask.fromChars('"'));

        Expression[16] nodes16;
        FirstFacts[16] values16;
        nodes16[0 .. 10] = nodes10[];
        values16[0 .. 10] = values10[];
        nodes16[10].kind = ExpressionKind.terminal;
        nodes16[10].byteTerminal = true;
        nodes16[10].byteWidth = 1;
        nodes16[10].first.addChar('\\');
        nodes16[11].kind = ExpressionKind.terminal;
        nodes16[11].source = "any";
        size_t[2] ordPair = [10, 11];
        nodes16[12].combinator = "and";
        nodes16[12].children = ordPair[];
        size_t[2] ordChoices = [12, 5];
        nodes16[13].combinator = "or";
        nodes16[13].children = ordChoices[];
        size_t[1] ordRep = [13];
        nodes16[14].combinator = "zeroOrMore";
        nodes16[14].children = ordRep[];
        size_t[2] ordSeq = [14, 8];
        nodes16[15].kind = ExpressionKind.sequence;
        nodes16[15].children = ordSeq[];
        values16[14] = FirstFacts(CharSetMask.fromChars('\\', 'x'), Nullable.yes, true);
        values16[15] = values10[8];
        graph.expressions = nodes16[];
        graph.facts = values16[];
        assert(graph.continuation(15).empty);

        nodes16[8].first = CharSetMask.fromChars('z');
        assert(graph.continuation(9).empty);
    }

    /// Conservative PEG/regular-language equivalence, beyond syntactic regularity.
    /// Nullable prefixes must not steal bytes from a following expression, and
    /// ordinary alternatives require disjoint FIRST sets with only a final nullable
    /// alternative; recognized escape loops preserve their earlier pair priority.
    /// X2(a): an ordered choice of literals that behaves as maximal munch. The set must be prefix-closed (every proper
    /// prefix of a literal is itself an alternative, so a walk never has to back up) and each literal must precede its
    /// proper prefixes (so the first alternative that matches is the longest). The walk can then be a deterministic trie
    /// with no lookahead, whatever follows the choice. `literals` receives the alternatives in order.
    bool maximalMunch(size_t index, ref string[] literals) {
        auto node = expressions[index];
        if (node.kind != ExpressionKind.choice || node.children.length < 2 || node.combinator != "or"
                && node.combinator != "predictiveChoice")
            return false;
        literals = null;
        foreach (child; node.children) {
            auto alternative = expressions[child];
            if (alternative.kind != ExpressionKind.terminal || alternative.source.length < 9
                    || alternative.source[0 .. 9] != "literal!(" || !alternative.literalBytes.length)
                return false;
            literals ~= alternative.literalBytes;
        }
        foreach (i, a; literals) {
            foreach (j, b; literals) {
                if (i == j)
                    continue;
                if (a == b)
                    return false;
                if (a.length < b.length && b[0 .. a.length] == a && j > i)
                    return false; // a prefix before its extension would win
            }
            // Prefix-closed: every proper prefix of `a` is an alternative.
            foreach (length; 1 .. a.length) {
                bool present;
                foreach (b; literals)
                    present = present || b == a[0 .. length];
                if (!present)
                    return false;
            }
        }
        return true;
    }

    unittest {
        static GrammarAnalysis make(string[] alternatives, string combinator = "or") {
            GrammarAnalysis graph;
            size_t[] children;
            foreach (i, literal; alternatives) {
                auto node = Expression(ExpressionKind.terminal, null, null, CharSetMask.init,
                        Nullable.no, true, "literal!(\"" ~ literal ~ "\")");
                node.byteTerminal = true;
                node.byteWidth = literal.length;
                node.literalBytes = literal;
                graph.expressions ~= node;
                children ~= i;
            }
            graph.expressions ~= Expression(ExpressionKind.choice, children, null, CharSetMask.init,
                    Nullable.unknown, false, null, combinator);
            return graph;
        }

        string[] literals;
        auto ok = make(["<<=", "<<", "<=", "<"]);
        assert(ok.maximalMunch(4, literals) && literals == ["<<=", "<<", "<=", "<"]);
        // Prefix-closed: `<<=` needs `<<`, which needs `<`.
        auto closed = make(["<<=", "<<", "<"]);
        assert(closed.maximalMunch(3, literals) && literals == ["<<=", "<<", "<"]);
        // A prefix listed before its extension would win: not maximal munch.
        assert(!make(["<", "<<", "<<="]).maximalMunch(3, literals));
        // Missing proper prefix (`<` for `<<`): a walk would have to back up.
        assert(!make(["<<", "="]).maximalMunch(2, literals));
        // Duplicate alternatives, a single alternative and other combinators are rejected.
        assert(!make(["<", "<"]).maximalMunch(2, literals));
        assert(!make(["<"]).maximalMunch(1, literals));
        assert(!make(["<<", "<"], "sequence").maximalMunch(2, literals));
        // A non-choice and a choice with a non-literal child are rejected.
        assert(!closed.maximalMunch(0, literals));
        auto mixed = make(["a", "b"]);
        mixed.expressions[1].literalBytes = null;
        assert(!mixed.maximalMunch(2, literals));
        mixed.expressions[1].source = "digit";
        mixed.expressions[1].literalBytes = "b";
        assert(!mixed.maximalMunch(2, literals));
    }

    bool regularLeaf(size_t index, bool anchored = false) {
        bool[] visiting = new bool[names.length];
        return regularLeaf(index, visiting, CharSetMask.init, anchored);
    }

    unittest {
        GrammarAnalysis graph;
        graph.names = ["Leaf", "Cycle"];
        graph.roots = [0, 2];
        graph.expressions = [
            Expression(ExpressionKind.terminal, null, null, CharSetMask.init, Nullable.no, true,
                    "digit", null, null, CharSetMask.init, true, 1),
            Expression(ExpressionKind.reference, null, "Leaf"),
            Expression(ExpressionKind.reference, null, "Cycle")
        ];
        assert(graph.regularLeaf(1));
        assert(!graph.regularLeaf(2));
    }

    private bool regularLeaf(size_t index, ref bool[] visiting, CharSetMask follow, bool anchored) {
        auto node = expressions[index];
        if (node.kind == ExpressionKind.reference) {
            const rule = referenceRule(node);
            if (rule == size_t.max || visiting[rule])
                return false;
            visiting[rule] = true;
            const result = regularLeaf(roots[rule], visiting, follow, anchored);
            visiting[rule] = false;
            return result;
        }
        if (node.kind == ExpressionKind.terminal)
            return node.byteTerminal || node.source == "eps";
        if (node.kind == ExpressionKind.unknown || node.kind == ExpressionKind.predicate)
            return false;
        if (escapeLoop(index).known)
            return true;
        if (node.combinator != "and" && node.combinator != "wrapAround" && node.combinator != "or"
                && node.combinator != "predictiveChoice" && node.combinator != "option" && node.combinator != "zeroOrMore"
                && node.combinator != "oneOrMore" && node.combinator != "fuse" && node.combinator != "discard"
                && node.combinator != "keep" && node.combinator != "drop" && node.combinator != "propagate"
                && node.combinator != "named" && node.combinator != "defined" && node.combinator != "branch")
            return false;
        CharSetMask following(size_t start) {
            CharSetMask result;
            foreach (next; node.children[start .. $]) {
                result = result | facts[next].first;
                if (facts[next].nullable == Nullable.no)
                    return result;
            }
            return result | follow;
        }

        foreach (i, child; node.children) {
            auto next = follow;
            if (node.combinator == "and" || node.combinator == "wrapAround")
                next = following(i + 1);
            else if (node.combinator == "zeroOrMore" || node.combinator == "oneOrMore")
                next = next | facts[child].first;
            if (!regularLeaf(child, visiting, next, anchored))
                return false;
        }
        if (node.combinator == "zeroOrMore" || node.combinator == "oneOrMore") {
            const child = node.children[0];
            if (continuation(child).intersects(facts[child].first)) {
                size_t current = child;
                while (true) {
                    auto expression = expressions[current];
                    if (expression.kind == ExpressionKind.reference) {
                        current = roots[referenceRule(expression)];
                        continue;
                    }
                    if (expression.children.length == 1 && (expression.kind == ExpressionKind.wrapper
                            || expression.combinator == "zeroOrMore"
                            || expression.combinator == "oneOrMore" || expression.combinator == "option")) {
                        current = expression.children[0];
                        continue;
                    }
                    break;
                }
                bool repeatable = expressions[current].byteTerminal && expressions[current].byteWidth == 1;
                auto body = expressions[current];
                if (!repeatable && body.kind == ExpressionKind.sequence && body.children.length >= 2) {
                    if (facts[body.children[0]].nullable == Nullable.no) {
                        bool safe = true;
                        foreach (tail; body.children[1 .. $]) {
                            if (facts[tail].first.intersects(facts[body.children[0]].first))
                                safe = false;
                        }
                        if (safe)
                            repeatable = true;
                    }
                }
                if (!repeatable && body.kind == ExpressionKind.choice) {
                    bool safe = true;
                    foreach (i, alt; body.children) {
                        if (facts[alt].nullable != Nullable.no)
                            safe = false;
                        foreach (j, other; body.children) {
                            if (i != j && continuation(alt).intersects(facts[other].first))
                                safe = false;
                        }
                    }
                    if (safe)
                        repeatable = true;
                }
                if (!repeatable)
                    return false;
            }
        }
        string[] munch;
        if ((node.combinator == "or" || node.combinator == "predictiveChoice") && maximalMunch(index, munch))
            return true;
        if (node.combinator == "or" || node.combinator == "predictiveChoice") {
            foreach (i, child; node.children) {
                if (!facts[child].known || facts[child].nullable == Nullable.unknown
                        || facts[child].nullable == Nullable.yes && i + 1 != node.children.length)
                    return false;
                foreach (other; node.children[i + 1 .. $])
                    if (facts[child].first.intersects(facts[other].first))
                        return false;
            }
        }
        if (node.combinator == "and" || node.combinator == "wrapAround") {
            bool variable(size_t current) {
                auto expression = expressions[current];
                if (expression.kind == ExpressionKind.reference)
                    return variable(roots[referenceRule(expression)]);
                if (expression.combinator == "option" || expression.combinator == "zeroOrMore"
                        || expression.combinator == "oneOrMore")
                    return true;
                foreach (child; expression.children)
                    if (variable(child))
                        return true;
                return false;
            }

            foreach (i, child; node.children) {
                if (!variable(child))
                    continue;
                const consumed = continuation(child);
                foreach (offset, next; node.children[i + 1 .. $]) {
                    auto suffix = expressions[next];
                    bool absorbedPrefix;
                    auto prefix = expressions[child];
                    if (prefix.combinator == "option" && prefix.children.length == 1
                            && expressions[prefix.children[0]].byteWidth == 1
                            && suffix.combinator == "zeroOrMore" && suffix.children.length == 1) {
                        CharSetMask bytes;
                        bool byteRun;
                        const escaped = escapeLoop(next);
                        if (escaped.known) {
                            byteRun = true;
                            foreach (word; 0 .. 4)
                                bytes.bits[word] = expressions[escaped.ordinary].first.bits[word] & ~expressions[escaped
                                    .prefix].first.bits[word];
                        } else if (expressions[suffix.children[0]].byteTerminal
                                && expressions[suffix.children[0]].byteWidth == 1) {
                            byteRun = true;
                            bytes = expressions[suffix.children[0]].first;
                        }
                        if (byteRun) {
                            absorbedPrefix = true;
                            foreach (word; 0 .. 4)
                                if (expressions[prefix.children[0]].first.bits[word] & ~bytes.bits[word])
                                    absorbedPrefix = false;
                        }
                    }
                    bool delimited;
                    const escaped = escapeLoop(child);
                    if (escaped.known && escaped.doubled && offset == 0 && anchored
                            && suffix.byteTerminal && suffix.byteWidth == 1
                            && suffix.first == expressions[escaped.prefix].first)
                        delimited = !following(i + 2).intersects(suffix.first);
                    else if (offset == 0 && suffix.byteTerminal && suffix.byteWidth == 1
                            && !facts[child].first.intersects(suffix.first)) {
                        if ((expressions[child].combinator == "zeroOrMore"
                                || expressions[child].combinator == "oneOrMore")
                                && expressions[child].children.length == 1) {
                            const childBody = expressions[child].children[0];
                            if (facts[childBody].nullable == Nullable.no)
                                delimited = !following(i + 2).intersects(suffix.first);
                        }
                    }
                    if (!facts[next].known || (consumed.intersects(facts[next].first) && !absorbedPrefix && !delimited))
                        return false;
                    if (facts[next].nullable == Nullable.no)
                        break;
                }
            }
        }
        return true;
    }

    unittest {
        CharSetMask a, b;
        a.addChar('a');
        b.addChar('b');
        GrammarAnalysis graph;
        graph.expressions = [
            Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true,
                    "charClass!(1, 0, 0, 0)", null, null, a, true, 1),
            Expression(ExpressionKind.terminal, null, null, b, Nullable.no, true,
                    "charClass!(2, 0, 0, 0)", null, null, b, true, 1),
            Expression(ExpressionKind.repetition, [0], null, CharSetMask.init, Nullable.unknown,
                    false, null, "zeroOrMore"),
            Expression(ExpressionKind.sequence, [2, 1], null, CharSetMask.init, Nullable.unknown,
                    false, null, "and"),
            Expression(ExpressionKind.sequence, [2, 0], null, CharSetMask.init, Nullable.unknown,
                    false, null, "and"),
            Expression(ExpressionKind.choice, [0, 1], null, CharSetMask.init, Nullable.unknown,
                    false, null, "or"),
            Expression(ExpressionKind.choice, [0, 0], null, CharSetMask.init, Nullable.unknown,
                    false, null, "or"), Expression(ExpressionKind.reference)
        ];
        graph.solve();
        assert(graph.regularLeaf(3));
        assert(!graph.regularLeaf(4));
        assert(graph.regularLeaf(5));
        assert(!graph.regularLeaf(6));
        assert(!graph.regularLeaf(7));

        Expression[5] absorbedNodes;
        absorbedNodes[0] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        absorbedNodes[0].byteTerminal = true;
        absorbedNodes[0].byteWidth = 1;
        absorbedNodes[1] = Expression(ExpressionKind.optional, [0], null, CharSetMask.init,
                Nullable.yes, true, null, "option");
        absorbedNodes[2] = Expression(ExpressionKind.repetition, [0], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        absorbedNodes[3] = Expression(ExpressionKind.sequence, [1, 2], null, CharSetMask.init,
                Nullable.unknown, false, null, "and");
        GrammarAnalysis agraph;
        agraph.expressions = absorbedNodes[];
        agraph.solve();
        assert(agraph.regularLeaf(3));

        absorbedNodes[4] = Expression(ExpressionKind.terminal, null, null, a | b, Nullable.no, true, "charClass");
        absorbedNodes[4].byteTerminal = true;
        absorbedNodes[4].byteWidth = 1;
        absorbedNodes[1].children = [4];
        agraph.solve();
        assert(!agraph.regularLeaf(3));

        Expression[6] escNodes;
        escNodes[0] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        escNodes[0].byteTerminal = true;
        escNodes[0].byteWidth = 2;
        escNodes[0].alphabet = a;
        escNodes[1] = Expression(ExpressionKind.terminal, null, null, b, Nullable.no, true, "literal!\"b\"");
        escNodes[1].byteTerminal = true;
        escNodes[1].byteWidth = 1;
        escNodes[2] = Expression(ExpressionKind.choice, [0, 1], null, CharSetMask.init,
                Nullable.unknown, false, null, "or");
        escNodes[3] = Expression(ExpressionKind.repetition, [2], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        escNodes[4] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        escNodes[4].byteTerminal = true;
        escNodes[4].byteWidth = 1;
        escNodes[5] = Expression(ExpressionKind.sequence, [3, 4], null, CharSetMask.init,
                Nullable.unknown, false, null, "and");
        GrammarAnalysis egraph;
        egraph.expressions = escNodes[];
        egraph.solve();
        assert(egraph.regularLeaf(5, true));
        assert(!egraph.regularLeaf(5, false));

        Expression[4] delNodes;
        delNodes[0] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        delNodes[0].byteTerminal = true;
        delNodes[0].byteWidth = 1;
        delNodes[1] = Expression(ExpressionKind.repetition, [0], null, CharSetMask.init,
                Nullable.no, true, null, "oneOrMore");
        delNodes[2] = Expression(ExpressionKind.terminal, null, null, b, Nullable.no, true, "literal!\"b\"");
        delNodes[2].byteTerminal = true;
        delNodes[2].byteWidth = 1;
        delNodes[3] = Expression(ExpressionKind.sequence, [1, 2], null, CharSetMask.init,
                Nullable.unknown, false, null, "and");
        GrammarAnalysis dgraph2;
        dgraph2.expressions = delNodes[];
        dgraph2.solve();
        assert(dgraph2.regularLeaf(3));
        delNodes[1].combinator = "zeroOrMore";
        dgraph2.solve();
        assert(dgraph2.regularLeaf(3));

        CharSetMask c;
        c.addChar('c');
        Expression[15] repNodes;
        repNodes[0] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        repNodes[0].byteTerminal = true;
        repNodes[0].byteWidth = 1;
        repNodes[1] = Expression(ExpressionKind.terminal, null, null, b, Nullable.no, true, "literal!\"b\"");
        repNodes[1].byteTerminal = true;
        repNodes[1].byteWidth = 1;
        repNodes[2] = Expression(ExpressionKind.optional, [1], null, CharSetMask.init,
                Nullable.yes, true, null, "option");
        repNodes[3] = Expression(ExpressionKind.sequence, [0, 2], null, CharSetMask.init,
                Nullable.no, true, null, "and");
        repNodes[4] = Expression(ExpressionKind.terminal, null, null, c, Nullable.no, true, "literal!\"c\"");
        repNodes[4].byteTerminal = true;
        repNodes[4].byteWidth = 1;
        repNodes[5] = Expression(ExpressionKind.sequence, [1, 4], null, CharSetMask.init,
                Nullable.no, true, null, "and");
        repNodes[6] = Expression(ExpressionKind.choice, [3, 5], null, CharSetMask.init, Nullable.no, true, null, "or");
        repNodes[7] = Expression(ExpressionKind.repetition, [6], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        GrammarAnalysis rgraph;
        rgraph.expressions = repNodes[];
        rgraph.solve();
        assert(!rgraph.regularLeaf(7));

        repNodes[8] = Expression(ExpressionKind.wrapper, [0], null, CharSetMask.init,
                Nullable.no, true, null, "named");
        repNodes[9] = Expression(ExpressionKind.reference, null, "A");
        repNodes[10] = Expression(ExpressionKind.repetition, [9], null, CharSetMask.init,
                Nullable.no, true, null, "oneOrMore");
        repNodes[11] = Expression(ExpressionKind.repetition, [10], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        rgraph.names = ["A", "Root"];
        rgraph.roots = [8, 11];
        rgraph.solve();
        assert(rgraph.regularLeaf(11));

        repNodes[12] = Expression(ExpressionKind.repetition, [0], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        repNodes[13] = Expression(ExpressionKind.repetition, [1], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        size_t[2] tailSeq = [1, 12];
        repNodes[14] = Expression(ExpressionKind.sequence, tailSeq[], null, CharSetMask.init,
                Nullable.no, true, null, "and");
        Expression[16] repNodes16;
        repNodes16[0 .. 15] = repNodes[];
        repNodes16[15] = Expression(ExpressionKind.repetition, [14], null, CharSetMask.init,
                Nullable.yes, true, null, "zeroOrMore");
        rgraph.expressions = repNodes16[];
        rgraph.roots = [8, 15];
        rgraph.solve();
        assert(rgraph.regularLeaf(15));

        size_t[2] nullablePrefix = [2, 12];
        repNodes16[14] = Expression(ExpressionKind.sequence, nullablePrefix[], null,
                CharSetMask.init, Nullable.yes, true, null, "and");
        rgraph.solve();
        assert(!rgraph.regularLeaf(15));

        size_t[2] overlapTail = [0, 12];
        repNodes16[14] = Expression(ExpressionKind.sequence, overlapTail[], null, CharSetMask.init,
                Nullable.no, true, null, "and");
        rgraph.solve();
        assert(!rgraph.regularLeaf(15));

        size_t[2] safeChoice = [0, 1];
        repNodes16[14] = Expression(ExpressionKind.choice, safeChoice[], null, CharSetMask.init,
                Nullable.no, true, null, "or");
        rgraph.solve();
        assert(rgraph.regularLeaf(15));

        size_t[2] nullChoice = [2, 1];
        repNodes16[14] = Expression(ExpressionKind.choice, nullChoice[], null, CharSetMask.init,
                Nullable.yes, true, null, "or");
        rgraph.solve();
        assert(!rgraph.regularLeaf(15));

        Expression[5] choiceNodes;
        choiceNodes[0] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        choiceNodes[0].byteTerminal = true;
        choiceNodes[0].byteWidth = 1;
        choiceNodes[1] = Expression(ExpressionKind.optional, [0], null, CharSetMask.init,
                Nullable.yes, true, null, "option");
        choiceNodes[2] = Expression(ExpressionKind.terminal, null, null, b, Nullable.no, true, "literal!\"b\"");
        choiceNodes[2].byteTerminal = true;
        choiceNodes[2].byteWidth = 1;
        choiceNodes[3] = Expression(ExpressionKind.choice, [1, 2], null, CharSetMask.init,
                Nullable.unknown, false, null, "or");
        choiceNodes[4] = Expression(ExpressionKind.choice, [2, 1], null, CharSetMask.init,
                Nullable.unknown, false, null, "or");
        GrammarAnalysis cgraph;
        cgraph.expressions = choiceNodes[];
        cgraph.solve();
        assert(!cgraph.regularLeaf(3));
        assert(cgraph.regularLeaf(4));

        Expression[3] wrapNodes;
        wrapNodes[0] = Expression(ExpressionKind.terminal, null, null, a, Nullable.no, true, "literal!\"a\"");
        wrapNodes[0].byteTerminal = true;
        wrapNodes[0].byteWidth = 1;
        wrapNodes[1] = Expression(ExpressionKind.terminal, null, null, b, Nullable.no, true, "literal!\"b\"");
        wrapNodes[1].byteTerminal = true;
        wrapNodes[1].byteWidth = 1;
        wrapNodes[2] = Expression(ExpressionKind.sequence, [0, 1], null, CharSetMask.init,
                Nullable.unknown, false, null, "wrapAround");
        GrammarAnalysis wgraph;
        wgraph.expressions = wrapNodes[];
        wgraph.solve();
        assert(wgraph.regularLeaf(2));
    }

    /// Pair priority can be encoded by removing escape prefixes from the ordinary
    /// class and retaining its single-byte fallback only at end of input.
    EscapeLoop escapeLoop(size_t index) @nogc {
        auto repeated = expressions[index];
        if ((repeated.combinator != "zeroOrMore" && repeated.combinator != "oneOrMore") || repeated.children.length != 1)
            return EscapeLoop.init;
        auto choice = expressions[repeated.children[0]];
        if ((choice.combinator != "or" && choice.combinator != "predictiveChoice") || choice.children.length != 2)
            return EscapeLoop.init;
        size_t pairIndex = choice.children[0], ordinaryIndex = choice.children[1];
        while (expressions[pairIndex].combinator == "branch" && expressions[pairIndex].children.length == 1)
            pairIndex = expressions[pairIndex].children[0];
        while (expressions[ordinaryIndex].combinator == "branch" && expressions[ordinaryIndex].children.length == 1)
            ordinaryIndex = expressions[ordinaryIndex].children[0];
        auto pair = expressions[pairIndex];
        size_t prefixIndex;
        bool doubled;
        if (pair.kind == ExpressionKind.terminal && pair.byteTerminal && pair.byteWidth == 2
                && pair.first == pair.alphabet) {
            prefixIndex = pairIndex;
            doubled = true;
        } else if (pair.combinator == "and" && pair.children.length == 2) {
            prefixIndex = pair.children[0];
            auto tail = expressions[pair.children[1]];
            if (tail.kind != ExpressionKind.terminal)
                return EscapeLoop.init;
            if (tail.source != "any") {
                if (!tail.byteTerminal || tail.byteWidth != 1 || tail.first != expressions[prefixIndex].first)
                    return EscapeLoop.init;
                doubled = true;
            }
            if (expressions[prefixIndex].kind != ExpressionKind.terminal
                    || !expressions[prefixIndex].byteTerminal || expressions[prefixIndex].byteWidth != 1)
                return EscapeLoop.init;
        } else
            return EscapeLoop.init;
        auto prefix = expressions[prefixIndex];
        if (doubled) {
            bool found;
            foreach (word; prefix.first.bits)
                if (word) {
                    if (found || (word & (word - 1)))
                        return EscapeLoop.init;
                    found = true;
                }
            if (!found)
                return EscapeLoop.init;
        }
        bool grouped;
        if (expressions[ordinaryIndex].combinator == "oneOrMore" && expressions[ordinaryIndex].children.length == 1) {
            grouped = true;
            ordinaryIndex = expressions[ordinaryIndex].children[0];
        }
        auto ordinary = expressions[ordinaryIndex];
        if (ordinary.kind != ExpressionKind.terminal || !ordinary.byteTerminal
                || ordinary.byteWidth != 1 || (grouped || doubled) && ordinary.first.intersects(prefix.first))
            return EscapeLoop.init;
        return EscapeLoop(prefixIndex, ordinaryIndex, true, doubled);
    }

    @nogc nothrow unittest {
        Expression[7] nodes;
        size_t[2] pair = [0, 1], choices = [2, 3];
        size_t[1] repeated = [4], grouped = [3];
        nodes[0].byteTerminal = nodes[3].byteTerminal = true;
        nodes[0].kind = nodes[1].kind = nodes[3].kind = ExpressionKind.terminal;
        nodes[0].byteWidth = nodes[3].byteWidth = 1;
        nodes[0].first.addChar('\\');
        nodes[1].source = "any";
        nodes[2].combinator = "and";
        nodes[2].children = pair[];
        nodes[3].first = CharSetMask.fromChars('x', '\\');
        nodes[4].combinator = "or";
        nodes[4].children = choices[];
        nodes[5].combinator = "zeroOrMore";
        nodes[5].children = repeated[];
        nodes[6].combinator = "oneOrMore";
        nodes[6].children = grouped[];
        GrammarAnalysis graph;
        graph.expressions = nodes[];
        assert(graph.escapeLoop(5) == EscapeLoop(0, 3, true));
        nodes[1].source = "external";
        assert(!graph.escapeLoop(5).known);
        nodes[1].source = "any";
        choices[1] = 6;
        assert(!graph.escapeLoop(5).known);
        nodes[3].first = CharSetMask.fromChars('x');
        assert(graph.escapeLoop(5).known);
        nodes[5].combinator = "oneOrMore";
        assert(graph.escapeLoop(5).known);
        nodes[4].combinator = "predictiveChoice";
        assert(graph.escapeLoop(5).known);
        nodes[4].combinator = "or";
        nodes[5].combinator = "option";
        assert(!graph.escapeLoop(5).known);

        Expression[16] dnodes;
        dnodes[0].kind = ExpressionKind.terminal;
        dnodes[0].byteTerminal = true;
        dnodes[0].byteWidth = 2;
        dnodes[0].first.addChar('"');
        dnodes[0].alphabet = dnodes[0].first;
        dnodes[1].kind = ExpressionKind.terminal;
        dnodes[1].byteTerminal = true;
        dnodes[1].byteWidth = 1;
        dnodes[1].first.addChar('x');
        size_t[2] dchoices = [0, 1];
        dnodes[2].combinator = "predictiveChoice";
        dnodes[2].children = dchoices[];
        size_t[1] drepeated = [2];
        dnodes[3].combinator = "zeroOrMore";
        dnodes[3].children = drepeated[];
        GrammarAnalysis dgraph;
        dgraph.expressions = dnodes[];
        assert(dgraph.escapeLoop(3) == EscapeLoop(0, 1, true, true));

        dnodes[4].kind = ExpressionKind.terminal;
        dnodes[4].byteTerminal = true;
        dnodes[4].byteWidth = 1;
        dnodes[4].first.addChar('"');
        size_t[2] dand = [4, 4];
        dnodes[5].combinator = "and";
        dnodes[5].children = dand[];
        dchoices[0] = 5;
        assert(dgraph.escapeLoop(3) == EscapeLoop(4, 1, true, true));

        size_t[1] bpair = [5], bord = [1];
        dnodes[6].combinator = "branch";
        dnodes[6].children = bpair[];
        dnodes[7].combinator = "branch";
        dnodes[7].children = bord[];
        dchoices[0] = 6;
        dchoices[1] = 7;
        assert(dgraph.escapeLoop(3) == EscapeLoop(4, 1, true, true));

        size_t[2] diffAnd = [4, 1];
        dnodes[8].combinator = "and";
        dnodes[8].children = diffAnd[];
        dchoices[0] = 8;
        dchoices[1] = 1;
        assert(!dgraph.escapeLoop(3).known);

        size_t[2] nonTermAnd = [4, 2];
        dnodes[9].combinator = "and";
        dnodes[9].children = nonTermAnd[];
        dchoices[0] = 9;
        assert(!dgraph.escapeLoop(3).known);

        dchoices[0] = 1;
        assert(!dgraph.escapeLoop(3).known);

        dnodes[10].kind = ExpressionKind.terminal;
        dnodes[10].byteTerminal = true;
        dnodes[10].byteWidth = 2;
        dnodes[10].first.addChar('"');
        dnodes[10].first.addChar('\'');
        dnodes[10].alphabet = dnodes[10].first;
        dchoices[0] = 10;
        assert(!dgraph.escapeLoop(3).known);

        dnodes[11].kind = ExpressionKind.terminal;
        dnodes[11].byteTerminal = true;
        dnodes[11].byteWidth = 2;
        dchoices[0] = 11;
        assert(!dgraph.escapeLoop(3).known);

        size_t[2] wideAnd = [0, 4];
        dnodes[12].combinator = "and";
        dnodes[12].children = wideAnd[];
        dchoices[0] = 12;
        assert(!dgraph.escapeLoop(3).known);

        dchoices[0] = 5;
        dchoices[1] = 4;
        assert(!dgraph.escapeLoop(3).known);

        dnodes[13].kind = ExpressionKind.wrapper;
        dchoices[1] = 13;
        assert(!dgraph.escapeLoop(3).known);
    }

    private FirstFacts evaluate(size_t index) {
        return evaluateNode(expressions[index]);
    }

    private FirstFacts evaluateNode(ref Expression expression) {
        FirstFacts result;
        final switch (expression.kind) {
        case ExpressionKind.unknown:
            return result;
        case ExpressionKind.terminal:
            result = FirstFacts(expression.first, expression.nullable,
                    expression.known, expression.source == "eoi" || expression.source == "endOfInput");
            result.neverAdvances = expression.known && expression.nullable == Nullable.yes;
            result.neverFails = result.neverAdvances && !result.eofOnly;
            return result;
        case ExpressionKind.reference:
            auto rule = referenceRule(expression);
            return rule == size_t.max ? result : facts[roots[rule]];
        case ExpressionKind.sequence:
            result.known = true;
            result.nullable = Nullable.yes;
            result.neverFails = result.neverAdvances = true;
            bool prefix = true;
            foreach (child; expression.children) {
                result.neverFails = result.neverFails && facts[child].neverFails;
                result.neverAdvances = result.neverAdvances && facts[child].neverAdvances;
                const cNull = facts[child].nullable;
                const cKnown = facts[child].known;
                result.eofOnly = result.eofOnly || facts[child].eofOnly;
                if (prefix) {
                    result.first.bits[0] |= facts[child].first.bits[0];
                    result.first.bits[1] |= facts[child].first.bits[1];
                    result.first.bits[2] |= facts[child].first.bits[2];
                    result.first.bits[3] |= facts[child].first.bits[3];
                    result.known = result.known && cKnown && cNull != Nullable.unknown;
                    prefix = cNull != Nullable.no;
                }
                if (cNull == Nullable.no)
                    result.nullable = Nullable.no;
                else if (cNull == Nullable.unknown && result.nullable != Nullable.no)
                    result.nullable = Nullable.unknown;
            }
            result.eofOnly = result.eofOnly && result.nullable == Nullable.yes;
            return result;
        case ExpressionKind.choice:
            result.known = true;
            result.nullable = Nullable.no;
            result.neverAdvances = true;
            bool onlyEnd = true;
            foreach (child; expression.children) {
                result.neverFails = result.neverFails || facts[child].neverFails;
                result.neverAdvances = result.neverAdvances && facts[child].neverAdvances;
                const cNull = facts[child].nullable;
                result.first.bits[0] |= facts[child].first.bits[0];
                result.first.bits[1] |= facts[child].first.bits[1];
                result.first.bits[2] |= facts[child].first.bits[2];
                result.first.bits[3] |= facts[child].first.bits[3];
                result.known = result.known && facts[child].known;
                if (cNull != Nullable.no && !facts[child].eofOnly)
                    onlyEnd = false;
                if (cNull == Nullable.yes)
                    result.nullable = Nullable.yes;
                else if (cNull == Nullable.unknown && result.nullable != Nullable.yes)
                    result.nullable = Nullable.unknown;
            }
            result.eofOnly = onlyEnd && result.nullable == Nullable.yes;
            return result;
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
            result = facts[expression.children[0]];
            result.nullable = Nullable.yes;
            result.eofOnly = false;
            result.neverFails = true; // `e?` and `e*` succeed on every input.
            return result;
        case ExpressionKind.predicate:
            result.nullable = Nullable.yes;
            // Unknown children can contain actions; skipping them changes effects.
            result.known = facts[expression.children[0]].known;
            result.neverAdvances = true; // Predicates restore the position.
            return result;
        case ExpressionKind.wrapper:
            return facts[expression.children[0]];
        }
    }

    /// Query-only expressions are appended bottom-up after the rule fixed point.
    FirstFacts appendFacts(size_t root) {
        const start = facts.length;
        const needed = expressions.length;
        if (needed > _factsCap.length) {
            const cap = needed < 32 ? 64 : needed * 2;
            auto next = new FirstFacts[cap];
            foreach (i; 0 .. start)
                next[i] = facts[i];
            _factsCap = next;
        }
        facts = _factsCap[0 .. needed];
        foreach (i; start .. needed)
            facts[i] = evaluate(i);
        return facts[root];
    }

    /// Rules an expression can call at the position it starts at (what left recursion follows).
    size_t[] leadingRules(size_t index) {
        size_t[] edges;
        leading(index, edges);
        return edges;
    }

    private void leading(size_t index, ref size_t[] edges) {
        auto expression = expressions[index];
        if (expression.kind == ExpressionKind.reference) {
            auto rule = referenceRule(expression);
            if (rule != size_t.max) {
                foreach (existing; edges)
                    if (existing == rule)
                        return;
                edges ~= rule;
            }
            return;
        }
        foreach (child; expression.children) {
            leading(child, edges);
            if (expression.kind == ExpressionKind.sequence && facts[child].nullable == Nullable.no)
                break;
        }
    }

    private bool selectedBelow(size_t index, const(uint)[] kinds, ref bool[] visiting) {
        auto expression = expressions[index];
        if (expression.kind == ExpressionKind.unknown)
            return true;
        if (expression.kind == ExpressionKind.predicate)
            return false;
        if (expression.kind == ExpressionKind.reference) {
            auto rule = referenceRule(expression);
            if (rule == size_t.max || kinds[rule] != uint.max)
                return true;
            if (visiting[rule])
                return false;
            visiting[rule] = true;
            auto selected = selectedBelow(roots[rule], kinds, visiting);
            visiting[rule] = false;
            return selected;
        }
        foreach (child; expression.children)
            if (selectedBelow(child, kinds, visiting))
                return true;
        return false;
    }

    /// Selected leaves can be emitted after success, avoiding speculative allocation.
    bool[] selectedLeaves(const(uint)[] kinds) {
        assert(kinds.length == names.length);
        auto result = new bool[names.length];
        foreach (i, kind; kinds) {
            if (kind == uint.max)
                continue;
            auto visiting = new bool[names.length];
            visiting[i] = true;
            result[i] = !selectedBelow(roots[i], kinds, visiting);
        }
        return result;
    }

    /// Returns true for rules that either have a kind tag or contain descendants with kinds.
    bool[] selectedSubtrees(const(uint)[] kinds) {
        assert(kinds.length == names.length);
        auto result = new bool[names.length];
        foreach (i, kind; kinds) {
            if (kind != uint.max)
                result[i] = true;
            else {
                auto visiting = new bool[names.length];
                visiting[i] = true;
                result[i] = selectedBelow(roots[i], kinds, visiting);
            }
        }
        return result;
    }

    // Tarjan SCC: ordinary recursion after a consumed terminal creates no left edge.
    private void visit(size_t rule, ref ptrdiff_t next, ref ptrdiff_t[] indices, ref ptrdiff_t[] low,
            ref bool[] active, ref size_t[] stack) {
        indices[rule] = low[rule] = next++;
        stack ~= rule;
        active[rule] = true;
        foreach (edge; leftEdges[rule]) {
            if (indices[edge] < 0) {
                visit(edge, next, indices, low, active, stack);
                if (low[edge] < low[rule])
                    low[rule] = low[edge];
            } else if (active[edge] && indices[edge] < low[rule])
                low[rule] = indices[edge];
        }
        if (low[rule] != indices[rule])
            return;
        size_t start = stack.length;
        do {
            --start;
            active[stack[start]] = false;
        }
        while (stack[start] != rule);
        bool cyclic = stack.length - start > 1;
        foreach (edge; leftEdges[rule])
            cyclic = cyclic || edge == rule;
        foreach (member; stack[start .. $])
            leftRecursive[member] = cyclic;
        stack.length = start;
    }

    void solve() {
        assert(names.length == roots.length);
        if (_exprCap.length < expressions.length)
            _exprCap = expressions;
        if (_factsCap.length < _exprCap.length)
            _factsCap = new FirstFacts[_exprCap.length];
        facts = _factsCap[0 .. expressions.length];
        conservative = false;
        foreach (i; 0 .. expressions.length) {
            if (expressions[i].kind == ExpressionKind.unknown)
                conservative = true;
            else if (expressions[i].kind == ExpressionKind.reference) {
                if (referenceRule(expressions[i]) == size_t.max)
                    conservative = true;
            }
        }
        auto dynamic = new bool[expressions.length];
        foreach (i; 0 .. expressions.length) {
            facts[i] = evaluate(i);
            if (expressions[i].kind == ExpressionKind.reference)
                dynamic[i] = true;
            else {
                foreach (child; expressions[i].children)
                    if (dynamic[child]) {
                        dynamic[i] = true;
                        break;
                    }
            }
        }
        size_t[] dynIndices;
        foreach (i, d; dynamic)
            if (d)
                dynIndices ~= i;
        auto changedAt = new uint[expressions.length];
        changedAt[] = 1;
        uint iter = 1;
        bool changed = true;
        while (changed) {
            changed = false;
            ++iter;
            foreach (i; dynIndices) {
                bool inputChanged;
                if (expressions[i].kind == ExpressionKind.reference) {
                    const rule = referenceRule(expressions[i]);
                    inputChanged = rule != size_t.max && changedAt[roots[rule]] >= iter - 1;
                } else {
                    foreach (child; expressions[i].children)
                        if (changedAt[child] >= iter - 1) {
                            inputChanged = true;
                            break;
                        }
                }
                if (!inputChanged)
                    continue;
                auto value = evaluate(i);
                if (value != facts[i]) {
                    facts[i] = value;
                    changedAt[i] = iter;
                    changed = true;
                }
            }
        }
        leftEdges = new size_t[][roots.length];
        foreach (i, root; roots)
            leading(root, leftEdges[i]);
        leftRecursive = new bool[roots.length];
        auto indices = new ptrdiff_t[roots.length];
        indices[] = -1;
        auto low = new ptrdiff_t[roots.length];
        auto active = new bool[roots.length];
        size_t[] stack;
        ptrdiff_t next;
        foreach (i; 0 .. roots.length)
            if (indices[i] < 0)
                visit(i, next, indices, low, active, stack);
    }
}

unittest {
    alias K = ExpressionKind;
    alias N = Nullable;
    CharSetMask a, b;
    a.addChar('a');
    b.addChar('b');
    GrammarAnalysis graph;
    graph.names = ["A", "B", "C", "D"];
    graph.expressions = [
        Expression(K.reference, null, "B"), // 0
        Expression(K.reference, null, "A"), // 1
        Expression(K.terminal, null, null, a, N.no, true), // 2
        Expression(K.terminal, null, null, b,
                N.no, true), // 3
        Expression(K.choice, [1, 2]), // 4: B <- A / 'a'
        Expression(K.sequence, [2, 0]), // 5: C <- 'a' B (ordinary recursion excluded)
        Expression(K.optional, [2]), // 6
        Expression(K.sequence, [6, 1]), // 7: D <- 'a'? A
        Expression(K.unknown), // 8
        Expression(K.repetition, [3]), // 9
        Expression(K.predicate, [0]), // 10
        Expression(K.wrapper, [9]), // 11
        Expression(K.sequence, [8, 3]), // 12 unknown prefix, proven nonnullable suffix
        Expression(K.reference, null, "external"), // 13
        Expression(K.sequence, [6, 3]), // 14 nullable prefix union
        Expression(K.sequence), // 15 empty sequence
        Expression(K.choice), // 16 empty choice
        Expression(K.choice, [8, 15]), // 17 nullable wins over unknown
        Expression(K.sequence, [8]), // 18 unknown nullability
    ];
    graph.roots = [0, 4, 5, 7];
    graph.solve();
    assert(graph.conservative);
    assert(graph.leftRecursive == [true, true, false, false]);
    assert(graph.leftEdges[3] == [0]);
    assert(graph.facts[14].known && graph.facts[14].nullable == N.no);
    assert(graph.facts[14].first.contains('a') && graph.facts[14].first.contains('b'));
    assert(!graph.facts[12].known && graph.facts[12].nullable == N.no);
    assert(graph.facts[11].nullable == N.yes);
    assert(graph.facts[10].nullable == N.yes && graph.facts[10].first.empty);
    assert(graph.facts[17].nullable == N.yes && !graph.facts[17].known);
    assert(graph.facts[18].nullable == N.unknown);
    assert(graph.ruleIndex("missing") == size_t.max);
    // Direct and predicate-hidden cycles; an edge to a completed SCC is harmless.
    graph.expressions ~= Expression(K.sequence, [10, 0]); // 19
    graph.roots = [19, 4, 5, 7];
    graph.solve();
    assert(graph.leftRecursive[0] && graph.leftRecursive[1]);
    graph.expressions ~= Expression(K.wrapper, [14]);
    assert(graph.appendFacts(graph.expressions.length - 1).first.contains('b'));
    GrammarAnalysis empty;
    empty.solve();
    assert(!empty.conservative && empty.leftRecursive.length == 0);
}

unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root", "Leaf", "Predicate", "Cycle"];
    graph.expressions = [
        Expression(K.reference, null, "Leaf"), Expression(K.terminal), Expression(K.predicate,
                [0]), Expression(K.sequence, [2, 1]), Expression(K.reference, null, "Cycle"),
        Expression(K.choice, [4, 1]), Expression(K.reference, null, "outside"), Expression(K.unknown)
    ];
    graph.roots = [0, 1, 3, 5];
    assert(graph.selectedLeaves([0U, 1U, 2U, uint.max]) == [false, true, true, false]);
    assert(graph.selectedSubtrees([0U, 1U, 2U, uint.max]) == [true, true, true, false]);
    assert(graph.selectedSubtrees([uint.max, 1U, uint.max, uint.max]) == [true, true, false, false]);
    assert(graph.selectedSubtrees([uint.max, uint.max, uint.max, uint.max]) == [
        false, false, false, false
    ]);
    graph.roots[0] = 4;
    assert(graph.selectedLeaves([0U, uint.max, uint.max, uint.max])[0]);
    assert(graph.selectedSubtrees([0U, uint.max, uint.max, uint.max])[0]);
    graph.roots[0] = 6;
    assert(!graph.selectedLeaves([0U, uint.max, uint.max, uint.max])[0]);
    assert(graph.selectedSubtrees([0U, uint.max, uint.max, uint.max])[0]);
    graph.roots[0] = 7;
    assert(!graph.selectedLeaves([0U, uint.max, uint.max, uint.max])[0]);
    assert(graph.selectedSubtrees([0U, uint.max, uint.max, uint.max])[0]);
}

unittest {
    alias K = ExpressionKind;
    alias N = Nullable;
    CharSetMask a;
    a.addChar('a');
    GrammarAnalysis graph;
    graph.names = ["Loop", "Safe", "Pick", "Chain"];
    graph.expressions = [
        Expression(K.reference, null, "Loop"), // 0
        Expression(K.terminal, null, null, a, N.no, true,
                "a"), // 1
        Expression(K.terminal, null, null, CharSetMask.init, N.yes, true, "eps"), // 2
        Expression(K.terminal,
                null, null, CharSetMask.init, N.yes, true, "eoi"), // 3
        Expression(K.sequence, [0, 1]), // 4: Loop <- Loop 'a'
        Expression(K.repetition, [1]), // 5: Safe <- 'a'*
        Expression(K.choice, [1, 2]), // 6: Pick <- 'a' / eps
        Expression(K.predicate, [1]), // 7
        Expression(K.sequence, [7, 5]), // 8: Chain <- &'a' 'a'*
        Expression(K.unknown), // 9
        Expression(K.optional, [9]), // 10
        Expression(K.choice, [1, 3]), // 11
        Expression(K.sequence), // 12
        Expression(K.choice), // 13
    ];
    graph.roots = [4, 5, 6, 8];
    graph.solve();
    assert(!graph.facts[1].neverFails && !graph.facts[1].neverAdvances);
    assert(graph.facts[2].neverFails && graph.facts[2].neverAdvances);
    assert(!graph.facts[3].neverFails && graph.facts[3].neverAdvances); // eoi may fail
    assert(!graph.facts[4].neverFails && !graph.facts[4].neverAdvances); // left recursion: pessimistic
    assert(graph.facts[5].neverFails && !graph.facts[5].neverAdvances);
    assert(graph.facts[6].neverFails && !graph.facts[6].neverAdvances); // eps arm rescues the choice
    assert(!graph.facts[7].neverFails && graph.facts[7].neverAdvances);
    assert(!graph.facts[8].neverFails && !graph.facts[8].neverAdvances);
    assert(graph.facts[10].neverFails && !graph.facts[10].neverAdvances); // unknown never proves "no advance"
    assert(!graph.facts[11].neverFails && !graph.facts[11].neverAdvances);
    assert(graph.facts[12].neverFails && graph.facts[12].neverAdvances); // empty sequence
    assert(!graph.facts[13].neverFails && graph.facts[13].neverAdvances); // empty choice always fails
}

/// Classical CFG-style FOLLOW for each rule, report-only (F2).
/// This is NOT NEXTBITES: PEG ordered choice and greedy repetition make FOLLOW an
/// over-approximation of continuations only for CFG-like, action-free, predicate-free regions.
struct FollowResult {
    CharSetMask[] follow; /// bytes that may follow the rule, per rule
    bool[] eof; /// end of input may follow
    bool[] known; /// false: ineligible neighbourhood, follow is top (all bytes and EOF)
}

private bool followEligible(ref GrammarAnalysis graph, size_t index, ref bool[] seen) nothrow {
    if (seen[index])
        return true;
    seen[index] = true;
    auto expression = graph.expressions[index];
    if (expression.kind == ExpressionKind.unknown || expression.kind == ExpressionKind.predicate)
        return false;
    if (expression.kind == ExpressionKind.reference && graph.referenceRule(expression) == size_t.max)
        return false;
    foreach (child; expression.children)
        if (!followEligible(graph, child, seen))
            return false;
    return true;
}

/// FOLLOW sets for rules of `graph`; rule 0 is the start rule and is followed by EOF.
FollowResult followSets(ref GrammarAnalysis graph) nothrow {
    FollowResult result;
    const rules = graph.roots.length;
    result.follow = new CharSetMask[rules];
    result.eof = new bool[rules];
    result.known = new bool[rules];
    if (!rules)
        return result;
    auto eligible = new bool[rules];
    foreach (r; 0 .. rules) {
        auto seen = new bool[graph.expressions.length];
        eligible[r] = followEligible(graph, graph.roots[r], seen);
    }
    bool changed = true;
    void add(size_t rule, CharSetMask mask, bool eof) nothrow {
        foreach (i; 0 .. 4) {
            const merged = result.follow[rule].bits[i] | mask.bits[i];
            if (merged != result.follow[rule].bits[i]) {
                result.follow[rule].bits[i] = merged;
                changed = true;
            }
        }
        if (eof && !result.eof[rule]) {
            result.eof[rule] = true;
            changed = true;
        }
    }

    void visit(size_t index, CharSetMask mask, bool eof) nothrow {
        auto expression = graph.expressions[index];
        final switch (expression.kind) {
        case ExpressionKind.unknown:
        case ExpressionKind.terminal:
        case ExpressionKind.predicate:
            return;
        case ExpressionKind.reference:
            const rule = graph.referenceRule(expression);
            if (rule != size_t.max)
                add(rule, mask, eof);
            return;
        case ExpressionKind.sequence:
            foreach_reverse (child; expression.children) {
                visit(child, mask, eof);
                const fact = graph.facts[child];
                foreach (i; 0 .. 4)
                    mask.bits[i] = (fact.nullable == Nullable.no ? 0 : mask.bits[i]) | fact.first.bits[i];
                if (fact.nullable == Nullable.no)
                    eof = false;
                if (fact.eofOnly)
                    eof = true;
            }
            return;
        case ExpressionKind.choice:
            foreach (child; expression.children)
                visit(child, mask, eof);
            return;
        case ExpressionKind.optional:
        case ExpressionKind.wrapper:
            visit(expression.children[0], mask, eof);
            return;
        case ExpressionKind.repetition:
            const first = graph.facts[expression.children[0]].first;
            foreach (i; 0 .. 4)
                mask.bits[i] |= first.bits[i];
            visit(expression.children[0], mask, eof);
            return;
        }
    }

    result.eof[0] = true;
    while (changed) {
        changed = false;
        foreach (r; 0 .. rules)
            if (eligible[r])
                visit(graph.roots[r], result.follow[r], result.eof[r]);
    }
    // A rule is trusted only if it and every rule that can reference it is eligible.
    foreach (r; 0 .. rules)
        result.known[r] = eligible[r];
    foreach (r; 0 .. rules)
        if (!eligible[r]) {
            bool[] seen = new bool[graph.expressions.length];
            void taint(size_t index) nothrow {
                if (seen[index])
                    return;
                seen[index] = true;
                auto expression = graph.expressions[index];
                if (expression.kind == ExpressionKind.reference) {
                    const target = graph.referenceRule(expression);
                    if (target != size_t.max)
                        result.known[target] = false;
                }
                foreach (child; expression.children)
                    taint(child);
            }

            taint(graph.roots[r]);
        }
    foreach (r; 0 .. rules)
        if (!result.known[r]) {
            result.follow[r].bits[] = ulong.max;
            result.eof[r] = true;
        }
    return result;
}

unittest {
    alias K = ExpressionKind;
    alias N = Nullable;
    CharSetMask a, b, c;
    a.addChar('a');
    b.addChar('b');
    c.addChar('c');
    GrammarAnalysis graph;
    // S <- A 'c' / B ; A <- 'a' B? ; B <- 'b' A?  (mutual recursion, nullable suffixes)
    graph.names = ["S", "A", "B", "P"];
    graph.expressions = [
        Expression(K.reference, null, "A"), // 0
        Expression(K.terminal, null, null, c, N.no, true), // 1
        Expression(K.sequence, [0, 1]), // 2
        Expression(K.reference, null, "B"), // 3
        Expression(K.choice, [2, 3]), // 4: S
        Expression(K.terminal, null, null, a, N.no, true), // 5
        Expression(K.optional, [3]), // 6
        Expression(K.sequence, [5, 6]), // 7: A
        Expression(K.terminal, null, null, b, N.no, true), // 8
        Expression(K.optional, [0]), // 9
        Expression(K.sequence, [8, 9]), // 10: B
        Expression(K.predicate, [1]), // 11
        Expression(K.sequence, [11, 5]), // 12: P (ineligible)
    ];
    graph.roots = [4, 7, 10, 12];
    graph.solve();
    const result = followSets(graph);
    assert(result.eof[0] && result.follow[0].empty);
    // A is followed by 'c' (in S); B (end of S, end of A) inherits both.
    assert(result.follow[1].contains('c') && !result.follow[1].contains('a'));
    assert(result.eof[1] && result.known[1]);
    assert(result.follow[2].contains('c') && result.eof[2]);
    assert(!result.follow[2].contains('a') && !result.follow[2].contains('b'));
    // Predicate rule is ineligible: top, and nothing it references is trusted.
    assert(!result.known[3] && result.eof[3] && result.follow[3].contains('z'));
    // Repetition makes the body its own follower; EOF only marks eoi-terminated tails.
    GrammarAnalysis loop;
    loop.names = ["R"];
    loop.expressions = [
        Expression(K.terminal, null, null, a, N.no, true), // 0
        Expression(K.repetition, [0]), // 1
        Expression(K.terminal, null, null, CharSetMask.init, N.yes,
                true, "eoi"), // 2
        Expression(K.sequence, [1, 2]), // 3
    ];
    loop.roots = [3];
    loop.solve();
    const only = followSets(loop);
    assert(only.eof[0] && only.known[0]);
    GrammarAnalysis none;
    assert(followSets(none).follow.length == 0);
}

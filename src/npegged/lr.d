/** Report-only canonical LR(1) analysis of the certified CFG subset (L5), plus the tables a recognizer can run (L6).

    Input: a rule whose closed region the L1 classifier calls `certifiedLL1` (so its CFG reading is trustworthy), or a hand-built
    `LrGrammar`. Terminals are the classes of a partition of the byte alphabet, so every terminal is a disjoint byte set.
    Output: states, ACTION/GOTO tables and every shift/reduce and reduce/reduce conflict. LR(1) freedom of a grammar is a
    property of its CFG reading; by itself it does NOT establish that the PEG means the same thing (docs/LL.md).
*/
module npegged.lr;
import npegged.analysis;
import npegged.bites : BitesAnalysis;
import npegged.ll : RegionClass, RuleRegion, describableTerminal;
import npegged.peg : CharSetMask;

nothrow:

/// A grammar symbol: a terminal (index of a byte class, `classCount` meaning end of input) or a nonterminal.
struct LrSymbol {
    bool terminal;
    uint id;
}

struct LrProduction {
    uint lhs;
    LrSymbol[] rhs;
}

struct LrGrammar {
    string[] names; // nonterminal names; nonterminal 0 is the augmented start S' -> start $
    LrProduction[] productions; // production 0 is S' -> start $
    CharSetMask[] classes; // disjoint terminal classes, in partition order
    ubyte[256] byteClass; // class index per byte (valid when `inClass[b]`)
    bool[256] inClass;
    string blocker; // non-empty: the grammar could not be built (nothing else is meaningful)

    @property uint endMarker() const nothrow {
        return cast(uint)classes.length;
    }
}

/// Table entry kinds.
enum LrAction : ubyte {
    error,
    shift,
    reduce,
    accept
}

struct LrCell {
    LrAction action;
    uint target; // state for shift, production for reduce
}

struct LrConflict {
    uint state;
    uint terminal;
    bool shiftReduce; // otherwise reduce/reduce
    uint first, second; // productions (reduce/reduce) or {shifted state marker, reduced production}
}

struct LrAutomaton {
    size_t states;
    bool truncated; // the state budget was exceeded: nothing else is a proof
    LrCell[] action; // [state * (classes + 1) + terminal]
    uint[] gotoTable; // [state * names + nonterminal], uint.max = none
    LrConflict[] conflicts;
    size_t terminalCount, nonterminalCount;

    LrCell cell(size_t state, size_t terminal) const nothrow {
        return action[state * terminalCount + terminal];
    }
}

private struct TermSet {
    ulong[5] bits; // up to 320 terminals (256 classes + end marker fit)

    bool has(uint t) const nothrow {
        return (bits[t >> 6] >> (t & 63)) & 1;
    }

    bool add(uint t) nothrow {
        const had = has(t);
        bits[t >> 6] |= 1UL << (t & 63);
        return !had;
    }

    bool unite(const TermSet other) nothrow {
        bool changed;
        foreach (i; 0 .. 5) {
            const merged = bits[i] | other.bits[i];
            changed = changed || merged != bits[i];
            bits[i] = merged;
        }
        return changed;
    }
}

private struct Item {
    uint production, dot, lookahead;
}

private bool lessItem(const Item a, const Item b) {
    if (a.production != b.production)
        return a.production < b.production;
    if (a.dot != b.dot)
        return a.dot < b.dot;
    return a.lookahead < b.lookahead;
}

private void sortItems(Item[] items) {
    // Insertion sort: item sets are small and the order must be deterministic.
    foreach (i; 1 .. items.length) {
        const value = items[i];
        size_t j = i;
        while (j > 0 && lessItem(value, items[j - 1])) {
            items[j] = items[j - 1];
            --j;
        }
        items[j] = value;
    }
}

private bool sameItems(const Item[] a, const Item[] b) {
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i])
            return false;
    return true;
}

// ---------------------------------------------------------------- building a grammar from a certified PEG region

/// Builds the CFG reading of rule `start` and every rule it reaches. Only `certifiedLL1` regions qualify.
/// The end marker is a terminal after every class; `eoi` in the grammar is that terminal, and a region without `eoi` gets
/// S' -> start (the automaton then accepts when `start` is complete and the lookahead is the end marker).
LrGrammar lrGrammarOf(ref GrammarAnalysis graph, size_t start, const RuleRegion[] regions) {
    LrGrammar grammar;
    if (start >= graph.roots.length || start >= regions.length || regions[start].region != RegionClass.certifiedLL1) {
        grammar.blocker = "region-not-certifiedLL1";
        return grammar;
    }
    // Pass 1: the byte sets of every terminal in the closed region.
    auto reached = new bool[graph.roots.length];
    size_t[] order = [start];
    reached[start] = true;
    CharSetMask[] sets;
    void collect(size_t index) {
        auto node = graph.expressions[index];
        if (node.kind == ExpressionKind.reference) {
            const target = graph.referenceRule(node);
            if (target != size_t.max && !reached[target]) {
                reached[target] = true;
                order ~= target;
            }
            return;
        }
        if (node.kind == ExpressionKind.terminal) {
            if (!describableTerminal(node)) {
                grammar.blocker = "undescribable-terminal";
                return;
            }
            const text = BitesAnalysis.plainLiteral(node.source);
            if (text.length) {
                foreach (c; text) {
                    CharSetMask one;
                    one.addChar(c);
                    sets ~= one;
                }
            } else if (node.byteTerminal && node.byteWidth == 1)
                sets ~= node.first;
            return;
        }
        foreach (child; node.children)
            collect(child);
    }

    for (size_t i; i < order.length; ++i) {
        collect(graph.roots[order[i]]);
        if (grammar.blocker.length)
            return grammar;
    }
    // The coarsest partition of the used bytes in which every set is a union of classes.
    ubyte[] representative;
    bool sameSignature(ubyte a, ubyte b) {
        foreach (set; sets)
            if (set.contains(a) != set.contains(b))
                return false;
        return true;
    }

    foreach (b; 0 .. 256) {
        bool used;
        foreach (set; sets)
            used = used || set.contains(cast(ubyte)b);
        if (!used)
            continue;
        size_t found = size_t.max;
        foreach (c, member; representative)
            if (sameSignature(member, cast(ubyte)b)) {
                found = c;
                break;
            }
        if (found == size_t.max) {
            found = representative.length;
            representative ~= cast(ubyte)b;
            grammar.classes ~= CharSetMask.init;
        }
        grammar.classes[found].addChar(cast(char)b);
        grammar.byteClass[b] = cast(ubyte)found;
        grammar.inClass[b] = true;
    }
    if (grammar.classes.length > 255) {
        grammar.blocker = "too-many-terminal-classes";
        return grammar;
    }
    // Pass 2: productions. Nonterminal 0 is S'; reached rules follow in discovery order; helpers are appended.
    grammar.names = ["S'"];
    auto ruleSymbol = new uint[graph.roots.length];
    foreach (r; order) {
        ruleSymbol[r] = cast(uint)grammar.names.length;
        grammar.names ~= graph.names[r];
    }
    LrProduction[] body_;
    size_t helper;
    uint fresh(string prefix) {
        const id = cast(uint)grammar.names.length;
        grammar.names ~= prefix ~ digits(helper++);
        return id;
    }

    LrSymbol[] symbols(size_t index) {
        auto node = graph.expressions[index];
        LrSymbol[] result;
        final switch (node.kind) {
        case ExpressionKind.unknown:
        case ExpressionKind.predicate:
            grammar.blocker = "predicate-or-unknown";
            return result;
        case ExpressionKind.reference:
            result ~= LrSymbol(false, ruleSymbol[graph.referenceRule(node)]);
            return result;
        case ExpressionKind.terminal:
            if (node.source == "eps")
                return result;
            if (node.source == "eoi" || node.source == "endOfInput") {
                result ~= LrSymbol(true, grammar.endMarker);
                return result;
            }
            const text = BitesAnalysis.plainLiteral(node.source);
            if (text.length) {
                foreach (c; text)
                    result ~= LrSymbol(true, grammar.byteClass[cast(ubyte)c]);
                return result;
            }
            uint[] covered;
            foreach (c; 0 .. grammar.classes.length)
                if (node.first.contains(representative[c]))
                    covered ~= cast(uint)c;
            if (covered.length == 1) {
                result ~= LrSymbol(true, covered[0]);
                return result;
            }
            const set = fresh("Class");
            foreach (c; covered)
                body_ ~= LrProduction(set, [LrSymbol(true, c)]);
            result ~= LrSymbol(false, set);
            return result;
        case ExpressionKind.wrapper:
            if (node.combinator == "oneOrMore") {
                auto inner = symbols(node.children[0]);
                const plus = fresh("Plus");
                body_ ~= LrProduction(plus, inner ~ [LrSymbol(false, plus)]);
                body_ ~= LrProduction(plus, inner.dup);
                result ~= LrSymbol(false, plus);
                return result;
            }
            return symbols(node.children[0]);
        case ExpressionKind.optional:
            auto inner = symbols(node.children[0]);
            const option = fresh("Opt");
            body_ ~= LrProduction(option, inner.dup);
            body_ ~= LrProduction(option, null);
            result ~= LrSymbol(false, option);
            return result;
        case ExpressionKind.repetition:
            auto again = symbols(node.children[0]);
            const loop = fresh("Star");
            body_ ~= LrProduction(loop, again ~ [LrSymbol(false, loop)]);
            body_ ~= LrProduction(loop, null);
            result ~= LrSymbol(false, loop);
            return result;
        case ExpressionKind.sequence:
            foreach (child; node.children)
                result ~= symbols(child);
            return result;
        case ExpressionKind.choice:
            const pick = fresh("Alt");
            foreach (child; node.children)
                body_ ~= LrProduction(pick, symbols(child));
            result ~= LrSymbol(false, pick);
            return result;
        }
    }

    foreach (r; order) {
        auto rhs = symbols(graph.roots[r]);
        if (grammar.blocker.length)
            return grammar;
        body_ ~= LrProduction(ruleSymbol[r], rhs);
    }
    grammar.productions = [LrProduction(0, [LrSymbol(false, ruleSymbol[start])])] ~ body_;
    return grammar;
}

private string digits(size_t value) {
    char[20] buffer;
    size_t at = buffer.length;
    do {
        buffer[--at] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    return buffer[at .. $].idup;
}

// ---------------------------------------------------------------- canonical LR(1)

/// Canonical LR(1) automaton with ACTION/GOTO tables and conflicts. `maxStates` bounds the construction; when it is hit the
/// result is `truncated` and carries no proof.
LrAutomaton buildLr(const LrGrammar grammar, size_t maxStates = 1024) {
    LrAutomaton automaton;
    const terminals = grammar.classes.length + 1; // the last terminal is the end marker
    const nonterminals = grammar.names.length;
    automaton.terminalCount = terminals;
    automaton.nonterminalCount = nonterminals;
    if (grammar.blocker.length || !grammar.productions.length) {
        automaton.truncated = true;
        return automaton;
    }
    // Nullable and FIRST for nonterminals, by fixed point.
    auto nullable = new bool[nonterminals];
    auto first = new TermSet[nonterminals];
    bool changed = true;
    while (changed) {
        changed = false;
        foreach (production; grammar.productions) {
            bool all = true;
            foreach (symbol; production.rhs) {
                if (symbol.terminal) {
                    changed = first[production.lhs].add(symbol.id) || changed;
                    all = false;
                    break;
                }
                changed = first[production.lhs].unite(first[symbol.id]) || changed;
                if (!nullable[symbol.id]) {
                    all = false;
                    break;
                }
            }
            if (all && !nullable[production.lhs]) {
                nullable[production.lhs] = true;
                changed = true;
            }
        }
    }
    // FIRST of the tail rhs[from..] followed by `lookahead`.
    TermSet firstOfTail(const LrSymbol[] rhs, size_t from, uint lookahead) {
        TermSet result;
        foreach (symbol; rhs[from .. $]) {
            if (symbol.terminal) {
                result.add(symbol.id);
                return result;
            }
            result.unite(first[symbol.id]);
            if (!nullable[symbol.id])
                return result;
        }
        result.add(lookahead);
        return result;
    }

    Item[] closure(Item[] kernel) {
        Item[] items = kernel.dup;
        for (size_t at; at < items.length; ++at) {
            const item = items[at];
            const rhs = grammar.productions[item.production].rhs;
            if (item.dot >= rhs.length || rhs[item.dot].terminal)
                continue;
            const lookaheads = firstOfTail(rhs, item.dot + 1, item.lookahead);
            foreach (index, production; grammar.productions) {
                if (production.lhs != rhs[item.dot].id)
                    continue;
                foreach (t; 0 .. cast(uint)terminals) {
                    if (!lookaheads.has(t))
                        continue;
                    const fresh = Item(cast(uint)index, 0, t);
                    bool known;
                    foreach (existing; items)
                        if (existing == fresh) {
                            known = true;
                            break;
                        }
                    if (!known)
                        items ~= fresh;
                }
            }
        }
        sortItems(items);
        return items;
    }

    Item[][] states = [closure([Item(0, 0, cast(uint)terminals - 1)])];
    // Transitions: shift[state][terminal], goto[state][nonterminal] -> target state, uint.max if none.
    uint[] shiftTarget;
    uint[] gotoTarget;
    for (size_t state; state < states.length; ++state) {
        shiftTarget.length = (state + 1) * terminals;
        gotoTarget.length = (state + 1) * nonterminals;
        shiftTarget[state * terminals .. (state + 1) * terminals] = uint.max;
        gotoTarget[state * nonterminals .. (state + 1) * nonterminals] = uint.max;
        // Group items by the symbol after the dot, in deterministic symbol order.
        foreach (symbolIndex; 0 .. terminals + nonterminals) {
            const isTerminal = symbolIndex < terminals;
            const id = cast(uint)(isTerminal ? symbolIndex : symbolIndex - terminals);
            Item[] moved;
            foreach (item; states[state]) {
                const rhs = grammar.productions[item.production].rhs;
                if (item.dot < rhs.length && rhs[item.dot].terminal == isTerminal && rhs[item.dot].id == id)
                    moved ~= Item(item.production, item.dot + 1, item.lookahead);
            }
            if (!moved.length)
                continue;
            auto target = closure(moved);
            size_t found = size_t.max;
            foreach (candidate, existing; states)
                if (sameItems(existing, target)) {
                    found = candidate;
                    break;
                }
            if (found == size_t.max) {
                if (states.length >= maxStates) {
                    automaton.truncated = true;
                    automaton.states = states.length;
                    return automaton;
                }
                found = states.length;
                states ~= target;
            }
            if (isTerminal)
                shiftTarget[state * terminals + id] = cast(uint)found;
            else
                gotoTarget[state * nonterminals + id] = cast(uint)found;
        }
    }
    automaton.states = states.length;
    shiftTarget.length = states.length * terminals;
    gotoTarget.length = states.length * nonterminals;
    automaton.action = new LrCell[states.length * terminals];
    automaton.gotoTable = gotoTarget;
    foreach (state; 0 .. states.length) {
        foreach (t; 0 .. terminals)
            if (shiftTarget[state * terminals + t] != uint.max)
                automaton.action[state * terminals + t] = LrCell(LrAction.shift, shiftTarget[state * terminals + t]);
        foreach (item; states[state]) {
            const production = grammar.productions[item.production];
            if (item.dot != production.rhs.length)
                continue;
            auto cell = &automaton.action[state * terminals + item.lookahead];
            const wanted = item.production == 0 ? LrCell(LrAction.accept, 0) : LrCell(LrAction.reduce, item.production);
            if (cell.action == LrAction.error)
                *cell = wanted;
            else if (*cell != wanted) {
                LrConflict conflict;
                conflict.state = cast(uint)state;
                conflict.terminal = item.lookahead;
                conflict.shiftReduce = cell.action == LrAction.shift;
                conflict.first = cell.target;
                conflict.second = item.production;
                automaton.conflicts ~= conflict;
            }
        }
    }
    return automaton;
}

// ---------------------------------------------------------------- recognizer over the tables (L6a)

/// Table-driven recognition of `input` (whole-input acceptance). Conflicting tables are refused (`ok` false).
struct LrVerdict {
    bool ok; // the tables were conflict-free and complete
    bool accepted;
}

LrVerdict lrAccepts(const LrGrammar grammar, const LrAutomaton automaton, scope const(char)[] input) {
    LrVerdict verdict;
    if (automaton.truncated || automaton.conflicts.length || grammar.blocker.length)
        return verdict;
    verdict.ok = true;
    auto stack = new uint[1];
    stack[0] = 0;
    size_t at;
    const end = cast(uint)grammar.classes.length;
    while (true) {
        uint terminal = end;
        if (at < input.length) {
            const b = cast(ubyte)input[at];
            if (!grammar.inClass[b])
                return verdict;
            terminal = grammar.byteClass[b];
        }
        const cell = automaton.cell(stack[$ - 1], terminal);
        final switch (cell.action) {
        case LrAction.error:
            return verdict;
        case LrAction.shift:
            stack ~= cell.target;
            if (terminal != end) // the end marker is a virtual symbol: shifting it (for `eoi`) consumes no byte
                ++at;
            break;
        case LrAction.reduce:
            const production = grammar.productions[cell.target];
            stack.length -= production.rhs.length;
            const next = automaton.gotoTable[stack[$ - 1] * automaton.nonterminalCount + production.lhs];
            if (next == uint.max)
                return verdict;
            stack ~= next;
            break;
        case LrAction.accept:
            verdict.accepted = at == input.length;
            return verdict;
        }
    }
}

// ---------------------------------------------------------------- reports

/// Machine- and human-readable summary of one automaton.
string renderLr(string rule, const LrGrammar grammar, const LrAutomaton automaton, bool json) {
    string number(size_t value) {
        return digits(value);
    }

    const verdict = grammar.blocker.length ? "unsupported" : automaton.truncated
        ? "state-budget-exceeded" : automaton.conflicts.length ? "conflicts" : "lr1";
    string conflicts;
    foreach (i, conflict; automaton.conflicts) {
        if (i == 16)
            break;
        conflicts ~= (i ? "," : "") ~ "{\"state\":" ~ number(conflict.state) ~ ",\"terminal\":" ~ number(
                conflict.terminal) ~ ",\"kind\":\"" ~ (conflict.shiftReduce
                ? "shift/reduce" : "reduce/reduce") ~ "\",\"productions\":[" ~ number(
                conflict.first) ~ "," ~ number(conflict.second) ~ "]}";
    }
    if (json)
        return "{\"rule\":\"" ~ rule ~ "\",\"verdict\":\"" ~ verdict ~ "\",\"blocker\":\"" ~ grammar.blocker
            ~ "\",\"terminals\":" ~ number(grammar.classes.length) ~ ",\"nonterminals\":" ~ number(
                    grammar.names.length) ~ ",\"productions\":" ~ number(grammar.productions.length) ~ ",\"states\":"
            ~ number(automaton.states) ~ ",\"conflicts\":" ~ number(
                    automaton.conflicts.length) ~ ",\"conflictDetails\":[" ~ conflicts ~ "]}";
    return "rule " ~ rule ~ ": " ~ verdict ~ " (" ~ number(grammar.productions.length)
        ~ " productions, " ~ number(automaton.states) ~ " states, " ~ number(
                automaton.conflicts.length) ~ " conflicts" ~ (grammar.blocker.length
                ? ", blocker " ~ grammar.blocker : "") ~ ")\n";
}

// ---------------------------------------------------------------- tests

/// Test helper: "S -> a S b | _" lines; uppercase letters are nonterminals, `_` is empty, other characters are terminals.
LrGrammar cfgOf(string text) {
    LrGrammar grammar;
    grammar.names = ["S'"];
    uint[26] nonterminal;
    nonterminal[] = uint.max;
    uint ensure(char letter) {
        if (nonterminal[letter - 'A'] == uint.max) {
            nonterminal[letter - 'A'] = cast(uint)grammar.names.length;
            grammar.names ~= [letter].idup;
        }
        return nonterminal[letter - 'A'];
    }

    char[] terminals;
    uint classOf(char c) {
        foreach (i, known; terminals)
            if (known == c)
                return cast(uint)i;
        terminals ~= c;
        CharSetMask one;
        one.addChar(c);
        grammar.classes ~= one;
        grammar.byteClass[cast(ubyte)c] = cast(ubyte)(terminals.length - 1);
        grammar.inClass[cast(ubyte)c] = true;
        return cast(uint)(terminals.length - 1);
    }

    LrProduction[] body_;
    uint lhs = uint.max, start = uint.max;
    foreach (line; split(text, '\n')) {
        size_t at;
        while (at < line.length && line[at] == ' ')
            ++at;
        if (at == line.length)
            continue;
        lhs = ensure(line[at]);
        if (start == uint.max)
            start = lhs;
        at += 1;
        while (at < line.length && (line[at] == ' ' || line[at] == '-' || line[at] == '>'))
            ++at;
        LrSymbol[] rhs;
        for (; at <= line.length; ++at) {
            if (at == line.length || line[at] == '|') {
                body_ ~= LrProduction(lhs, rhs);
                rhs = null;
                continue;
            }
            const c = line[at];
            if (c == ' ' || c == '_')
                continue;
            if (c >= 'A' && c <= 'Z')
                rhs ~= LrSymbol(false, ensure(c));
            else
                rhs ~= LrSymbol(true, classOf(c));
        }
    }
    grammar.productions = [LrProduction(0, [LrSymbol(false, start)])] ~ body_;
    return grammar;
}

private string[] split(string text, char separator) {
    string[] parts;
    size_t begin;
    foreach (i; 0 .. text.length + 1)
        if (i == text.length || text[i] == separator) {
            parts ~= text[begin .. i];
            begin = i + 1;
        }
    return parts;
}

nothrow unittest {
    // Conflict-free grammars: balanced brackets, nullable productions, left-recursive expressions (LR but not LL).
    foreach (text; [
        "S -> a S b | _", "S -> A B\nA -> _ | a\nB -> b",
        "E -> E + T | T\nT -> T * F | F\nF -> ( E ) | n"
    ]) {
        const grammar = cfgOf(text);
        const automaton = buildLr(grammar);
        assert(!automaton.truncated && !automaton.conflicts.length, text);
        assert(automaton.states > 2);
    }
    // Shift/reduce: the ambiguous expression grammar.
    {
        const automaton = buildLr(cfgOf("E -> E + E | n"));
        assert(automaton.conflicts.length && automaton.conflicts[0].shiftReduce);
    }
    // Reduce/reduce: two nonterminals derive the same terminal.
    {
        const automaton = buildLr(cfgOf("S -> A | B\nA -> x\nB -> x"));
        assert(automaton.conflicts.length && !automaton.conflicts[0].shiftReduce);
    }
    // The classic LR(1)-but-not-LALR(1) grammar is conflict-free for canonical LR(1).
    {
        const automaton = buildLr(cfgOf("S -> a E c | a F d | b F c | b E d\nE -> e\nF -> e"));
        assert(!automaton.truncated && !automaton.conflicts.length);
    }
    // A tiny state budget is reported, never read as a proof.
    {
        const automaton = buildLr(cfgOf("E -> E + T | T\nT -> T * F | F\nF -> ( E ) | n"), 3);
        assert(automaton.truncated);
        assert(!lrAccepts(cfgOf("S -> a"), automaton, "a").ok);
    }
}

nothrow unittest {
    // The table-driven recognizer agrees with the grammar it was built from on every short string.
    const expression = cfgOf("E -> E + T | T\nT -> T * F | F\nF -> ( E ) | n");
    const automaton = buildLr(expression);
    // Independent recursive-descent reference for the same language.
    struct Reference {
        string input;
        size_t at;
        bool primary() nothrow {
            if (at < input.length && input[at] == 'n') {
                ++at;
                return true;
            }
            if (at < input.length && input[at] == '(') {
                ++at;
                if (!sum() || at >= input.length || input[at] != ')')
                    return false;
                ++at;
                return true;
            }
            return false;
        }

        bool product() nothrow {
            if (!primary())
                return false;
            while (at < input.length && input[at] == '*') {
                ++at;
                if (!primary())
                    return false;
            }
            return true;
        }

        bool sum() nothrow {
            if (!product())
                return false;
            while (at < input.length && input[at] == '+') {
                ++at;
                if (!product())
                    return false;
            }
            return true;
        }
    }

    enum alphabet = "n+*()";
    char[7] buffer;
    size_t checked;
    foreach (length; 0 .. 8) {
        size_t combinations = 1;
        foreach (_; 0 .. length)
            combinations *= alphabet.length;
        foreach (code; 0 .. combinations) {
            size_t digit = code;
            foreach (i; 0 .. length) {
                buffer[i] = alphabet[digit % alphabet.length];
                digit /= alphabet.length;
            }
            Reference reference;
            reference.input = buffer[0 .. length].idup;
            const expected = reference.sum() && reference.at == length;
            const verdict = lrAccepts(expression, automaton, buffer[0 .. length]);
            assert(verdict.ok && verdict.accepted == expected, buffer[0 .. length].idup);
            ++checked;
        }
    }
    assert(checked > 19000);
    // Bytes outside every terminal class are rejected, not misread.
    assert(!lrAccepts(expression, automaton, "n?").accepted);
}

nothrow unittest {
    const grammar = cfgOf("S -> a S b | _");
    const automaton = buildLr(grammar);
    assert(renderLr("S", grammar, automaton, true)[0 .. 24] == "{\"rule\":\"S\",\"verdict\":\"l");
    assert(renderLr("S", grammar, automaton, false)[0 .. 12] == "rule S: lr1 ");
    const ambiguous = cfgOf("E -> E + E | n");
    const conflicted = buildLr(ambiguous);
    assert(renderLr("E", ambiguous, conflicted, true).length > 100);
    LrGrammar blocked;
    blocked.blocker = "predicate-or-unknown";
    assert(renderLr("P", blocked, buildLr(blocked), false)[0 .. 21] == "rule P: unsupported (");
}

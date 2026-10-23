/** External generation policies (G4): weights live outside the grammar syntax.

    Text format, one directive per line, `#` starts a comment:

        choice <Rule> <k> weights <w0> <w1> ...     k-th choice in Rule's body (preorder, references not followed)
        optional <Rule> <k> probability <0..1>      k-th `e?`; up to three decimals
        repeat <Rule> <k> histogram <n>:<w> ...     k-th `e*`/`e+`: relative weight of each repetition count n
        attenuation <0..1>                          recursive alternatives are scaled by attenuation^depth
        zero-weights allow|deny                     default allow

    Validation is strict: weights and counts are plain decimal integers; negative, NaN, infinite, decimal or malformed
    numbers are rejected with a message naming the line; probabilities need at most three decimals so nothing is rounded
    silently. A zero weight disables an alternative only when allowed and at least one alternative of that choice stays
    enabled. Output and depth budgets stay in `GeneratorOptions`.
*/
module npegged.policy;
import npegged.analysis;
import npegged.generator;

nothrow:

struct ChoicePolicy {
    string rule;
    size_t ordinal;
    ulong[] weights;
    size_t line;
}

struct OptionalPolicy {
    string rule;
    size_t ordinal;
    ushort permille;
    size_t line;
}

struct RepeatPolicy {
    string rule;
    size_t ordinal;
    ulong[] histogram; // index = count
    size_t line;
}

struct Policy {
    ChoicePolicy[] choices;
    OptionalPolicy[] optionals;
    RepeatPolicy[] repeats;
    ulong attenuationPermille = 1000;
    bool allowZero = true;
}

struct PolicyResult {
    bool ok;
    Policy policy;
    string[] errors;
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

/// Plain decimal integer, no sign, no separators.
private bool parseCount(string text, out ulong value) @nogc {
    if (!text.length || text.length > 15)
        return false;
    foreach (c; text) {
        if (c < '0' || c > '9')
            return false;
        value = value * 10 + (c - '0');
    }
    return true;
}

@nogc nothrow unittest {
    ulong value;
    assert(parseCount("0", value) && value == 0);
    assert(parseCount("999999999999999", value) && value == 999999999999999UL);
    foreach (text; ["", "1000000000000000", "-1", "1x"])
        assert(!parseCount(text, value));
}

/// Decimal in [0, 1] with at most three fraction digits, as thousandths.
private bool parseUnit(string text, out ulong thousandths) @nogc {
    if (!text.length)
        return false;
    size_t dot = text.length;
    foreach (i, c; text)
        if (c == '.')
            dot = i;
    ulong whole;
    if (!parseCount(text[0 .. dot], whole) || whole > 1)
        return false;
    ulong fraction;
    size_t digits;
    if (dot < text.length) {
        const part = text[dot + 1 .. $];
        if (!part.length || part.length > 3)
            return false;
        if (!parseCount(part, fraction))
            return false;
        digits = part.length;
    }
    foreach (_; digits .. 3)
        fraction *= 10;
    thousandths = whole * 1000 + fraction;
    return thousandths <= 1000;
}

@nogc nothrow unittest {
    ulong value;
    foreach (text; ["", ".1", "0.", "0.1234", "0.x", "2", "1.001"])
        assert(!parseUnit(text, value));
    assert(parseUnit("0", value) && value == 0);
    assert(parseUnit("1.000", value) && value == 1000);
    assert(parseUnit("0.5", value) && value == 500);
    assert(parseUnit("0.05", value) && value == 50);
    assert(parseUnit("0.005", value) && value == 5);
}

private string[] words(string line) {
    string[] result;
    size_t start = size_t.max;
    foreach (i, c; line) {
        const space = c == ' ' || c == '\t' || c == '\r';
        if (space && start != size_t.max) {
            result ~= line[start .. i];
            start = size_t.max;
        } else if (!space && start == size_t.max)
            start = i;
    }
    if (start != size_t.max)
        result ~= line[start .. $];
    return result;
}

nothrow unittest {
    assert(words(" \tRoot\r \t0 ") == ["Root", "0"]);
    assert(words(" \t\r").length == 0);
}

PolicyResult parsePolicy(string text) nothrow {
    PolicyResult result;
    size_t lineNumber;
    size_t begin;
    void fail(string message) nothrow {
        result.errors ~= "line " ~ decimal(lineNumber) ~ ": " ~ message;
    }

    foreach (end; 0 .. text.length + 1) {
        if (end != text.length && text[end] != '\n')
            continue;
        string line = text[begin .. end];
        begin = end + 1;
        ++lineNumber;
        foreach (i, c; line)
            if (c == '#') {
                line = line[0 .. i];
                break;
            }
        auto w = words(line);
        if (!w.length)
            continue;
        if (w[0] == "attenuation") {
            ulong value;
            if (w.length != 2 || !parseUnit(w[1], value) || value == 0)
                fail("attenuation needs one value in (0, 1] with at most three decimals");
            else
                result.policy.attenuationPermille = value;
        } else if (w[0] == "zero-weights") {
            if (w.length == 2 && (w[1] == "allow" || w[1] == "deny"))
                result.policy.allowZero = w[1] == "allow";
            else
                fail("zero-weights needs allow or deny");
        } else if (w[0] == "choice" || w[0] == "optional" || w[0] == "repeat") {
            ulong ordinal;
            if (w.length < 5 || !parseCount(w[2], ordinal)) {
                fail(w[0] ~ " needs: <Rule> <k> <keyword> <values>");
                continue;
            }
            if (w[0] == "choice") {
                ChoicePolicy item;
                item.rule = w[1];
                item.ordinal = ordinal;
                item.line = lineNumber;
                bool good = w[3] == "weights";
                foreach (token; w[4 .. $]) {
                    ulong weight;
                    if (!parseCount(token, weight)) {
                        fail("invalid weight '" ~ token ~ "' (plain non-negative integers only)");
                        good = false;
                        break;
                    }
                    item.weights ~= weight;
                }
                if (w[3] != "weights")
                    fail("choice expects the keyword 'weights'");
                if (good)
                    result.policy.choices ~= item;
            } else if (w[0] == "optional") {
                ulong value;
                if (w.length != 5 || w[3] != "probability" || !parseUnit(w[4], value))
                    fail("optional expects: probability <value in [0, 1], at most three decimals>");
                else
                    result.policy.optionals ~= OptionalPolicy(w[1], ordinal, cast(ushort)value, lineNumber);
            } else {
                RepeatPolicy item;
                item.rule = w[1];
                item.ordinal = ordinal;
                item.line = lineNumber;
                bool good = w[3] == "histogram";
                if (!good)
                    fail("repeat expects the keyword 'histogram'");
                foreach (token; w[4 .. $]) {
                    size_t colon = token.length;
                    foreach (i, c; token)
                        if (c == ':')
                            colon = i;
                    ulong count, weight;
                    if (colon == token.length || !parseCount(token[0 .. colon], count)
                            || !parseCount(token[colon + 1 .. $], weight) || count > 4096) {
                        fail("invalid histogram entry '" ~ token ~ "' (expected count:weight, count <= 4096)");
                        good = false;
                        break;
                    }
                    if (item.histogram.length <= count)
                        item.histogram.length = count + 1;
                    item.histogram[count] += weight;
                }
                if (good)
                    result.policy.repeats ~= item;
            }
        } else
            fail("unknown directive '" ~ w[0] ~ "'");
    }
    // Zero-weight rules (after parsing, so `zero-weights deny` may appear anywhere).
    foreach (item; result.policy.choices) {
        ulong sum;
        bool zero;
        foreach (weight; item.weights) {
            sum += weight;
            zero = zero || weight == 0;
        }
        lineNumber = item.line;
        if (zero && !result.policy.allowZero)
            fail("zero weight not permitted (zero-weights deny)");
        if (!sum)
            fail("at least one alternative must have a positive weight");
    }
    foreach (item; result.policy.repeats) {
        ulong sum;
        foreach (weight; item.histogram)
            sum += weight;
        lineNumber = item.line;
        if (!sum)
            fail("a histogram needs a positive total weight");
    }
    result.ok = result.errors.length == 0;
    return result;
}

nothrow unittest {
    foreach (text; [
        "attenuation", "attenuation 0", "attenuation 1 2", "zero-weights",
        "zero-weights maybe", "zero-weights allow extra",
        "choice R x weights 1", "optional R 0 probability 0.5 extra",
        "optional R 0 wrong 0.5",
        "optional R 0 probability 0.x",
        "repeat R 0 wrong 0:1", "repeat R 0 histogram :1", "repeat R 0 histogram 0:",
        "repeat R 0 histogram 4097:1"
    ]) {
        auto invalid = parsePolicy(text);
        assert(!invalid.ok && invalid.errors.length);
    }
    auto repeated = parsePolicy("repeat R 0 histogram 0:1 0:2");
    assert(repeated.ok && repeated.policy.repeats[0].histogram == [3]);
}

/// Bind the policy to a grammar's generator. Returns problems (unknown rule or ordinal, wrong weight count);
/// a policy with problems must not be used silently.
string[] applyPolicy(ref CandidateGenerator generator, ref GrammarAnalysis graph, const Policy policy) nothrow {
    string[] problems;
    // k-th construct of a kind in a rule's body, preorder, references not followed.
    size_t nth(string rule, size_t ordinal, ExpressionKind kind, bool oneOrMore) nothrow {
        const index = graph.ruleIndex(rule);
        if (index == size_t.max)
            return size_t.max;
        size_t found = size_t.max, seen;
        auto visited = new bool[graph.expressions.length];
        void walk(size_t at) nothrow {
            if (at >= graph.expressions.length || visited[at] || found != size_t.max)
                return;
            visited[at] = true;
            auto node = graph.expressions[at];
            const matches = node.kind == kind || (oneOrMore && node.kind == ExpressionKind.wrapper
                    && node.combinator == "oneOrMore");
            if (matches && seen++ == ordinal) {
                found = at;
                return;
            }
            foreach (child; node.children)
                walk(child);
        }

        walk(graph.roots[index]);
        return found;
    }

    foreach (item; policy.choices) {
        const node = nth(item.rule, item.ordinal, ExpressionKind.choice, false);
        if (node == size_t.max)
            problems ~= "line " ~ decimal(item.line) ~ ": no choice " ~ decimal(item.ordinal) ~ " in rule " ~ item.rule;
        else if (item.weights.length != graph.expressions[node].children.length)
            problems ~= "line " ~ decimal(item.line) ~ ": choice has " ~ decimal(
                    graph.expressions[node].children.length) ~ " alternatives but " ~ decimal(
                    item.weights.length) ~ " weights";
        else
            foreach (i, weight; item.weights)
                generator.setWeight(node, i, weight);
    }
    foreach (item; policy.optionals) {
        const node = nth(item.rule, item.ordinal, ExpressionKind.optional, false);
        if (node == size_t.max)
            problems ~= "line " ~ decimal(item.line) ~ ": no optional " ~ decimal(item.ordinal) ~ " in rule "
                ~ item.rule;
        else
            generator.optionalPermille[node] = item.permille;
    }
    foreach (item; policy.repeats) {
        const node = nth(item.rule, item.ordinal, ExpressionKind.repetition, true);
        if (node == size_t.max)
            problems ~= "line " ~ decimal(item.line) ~ ": no repetition " ~ decimal(
                    item.ordinal) ~ " in rule " ~ item.rule;
        else
            generator.repeatHist[node] = item.histogram.dup;
    }
    generator.attenuationPermille = policy.attenuationPermille;
    return problems;
}

nothrow unittest {
    alias K = ExpressionKind;
    GrammarAnalysis graph;
    graph.names = ["Root"];
    Expression terminal;
    terminal.kind = K.terminal;
    terminal.source = "literal!(\"a\")";
    terminal.known = true;
    terminal.nullable = Nullable.no;
    auto one = Expression(K.wrapper, [0]);
    one.combinator = "oneOrMore";
    auto keep = Expression(K.wrapper, [0]);
    keep.combinator = "keep";
    graph.expressions = [
        terminal, Expression(K.optional, [0]), Expression(K.repetition, [0]), one, keep,
        Expression(K.sequence, [1, 1, 2, 3, 4])
    ];
    graph.roots = [5];
    graph.solve();
    auto generator = CandidateGenerator(graph, 0);
    auto valid = parsePolicy("optional Root 0 probability 1\nrepeat Root 1 histogram 1:1");
    assert(valid.ok && applyPolicy(generator, graph, valid.policy).length == 0);
    auto missing = parsePolicy("optional Root 99 probability 1\nrepeat Root 99 histogram 1:1");
    assert(missing.ok && applyPolicy(generator, graph, missing.policy).length == 2);
    graph.roots[0] = graph.expressions.length;
    assert(applyPolicy(generator, graph, missing.policy).length == 2);
}

/// Observable policy metadata: the normalized policy as JSON, so a generated corpus records how it was made.
string policyMetadata(const Policy policy) nothrow {
    string quote(string value) nothrow {
        string result = "\"";
        foreach (c; value) {
            if (c == '"' || c == '\\')
                result ~= '\\';
            result ~= c;
        }
        return result ~ "\"";
    }

    string list(const ulong[] values) nothrow {
        string result = "[";
        foreach (i, value; values)
            result ~= (i ? "," : "") ~ decimal(value);
        return result ~ "]";
    }

    string json = "{\"attenuationPermille\":" ~ decimal(policy.attenuationPermille)
        ~ ",\"zeroWeights\":\"" ~ (policy.allowZero ? "allow" : "deny") ~ "\",\"choices\":[";
    foreach (i, item; policy.choices) {
        ulong sum;
        foreach (weight; item.weights)
            sum += weight;
        ulong[] shares;
        foreach (weight; item.weights)
            shares ~= sum ? weight * 1000 / sum : 0;
        json ~= (i ? "," : "") ~ "{\"rule\":" ~ quote(item.rule) ~ ",\"k\":" ~ decimal(
                item.ordinal) ~ ",\"weights\":" ~ list(item.weights) ~ ",\"sharePermille\":" ~ list(shares) ~ "}";
    }
    json ~= "],\"optionals\":[";
    foreach (i, item; policy.optionals)
        json ~= (i ? "," : "") ~ "{\"rule\":" ~ quote(item.rule) ~ ",\"k\":" ~ decimal(
                item.ordinal) ~ ",\"permille\":" ~ decimal(item.permille) ~ "}";
    json ~= "],\"repeats\":[";
    foreach (i, item; policy.repeats)
        json ~= (i ? "," : "") ~ "{\"rule\":" ~ quote(item.rule) ~ ",\"k\":" ~ decimal(
                item.ordinal) ~ ",\"histogram\":" ~ list(item.histogram) ~ "}";
    return json ~ "]}";
}

nothrow unittest {
    Policy policy;
    policy.allowZero = false;
    policy.choices = [ChoicePolicy("R\"\\", 0, [1, 1], 1), ChoicePolicy("Other", 1, [0, 0], 2)];
    policy.optionals = [OptionalPolicy("R", 0, 0, 3), OptionalPolicy("R", 1, 1000, 4)];
    policy.repeats = [RepeatPolicy("R", 0, [1], 5), RepeatPolicy("R", 1, [0, 2], 6)];
    assert(policyMetadata(policy) == `{"attenuationPermille":1000,"zeroWeights":"deny","choices":[{"rule":"R\"\\","k":0,"weights":[1,1],"sharePermille":[500,500]},{"rule":"Other","k":1,"weights":[0,0],"sharePermille":[0,0]}],"optionals":[{"rule":"R","k":0,"permille":0},{"rule":"R","k":1,"permille":1000}],"repeats":[{"rule":"R","k":0,"histogram":[1]},{"rule":"R","k":1,"histogram":[0,2]}]}`);
}

nothrow unittest {
    auto good = parsePolicy("# comment\nchoice Root 0 weights 5 0 2\noptional Root 0 probability 0.25\nrepeat Root 0 histogram 0:1 3:2 20:1\nattenuation 0.8\n");
    assert(good.ok && good.policy.choices[0].weights == [5, 0, 2]);
    assert(good.policy.optionals[0].permille == 250 && good.policy.attenuationPermille == 800);
    assert(good.policy.repeats[0].histogram.length == 21 && good.policy.repeats[0].histogram[3] == 2);
    foreach (bad; [
        "choice Root 0 weights -1 2", "choice Root 0 weights nan 1", "choice Root 0 weights 1.5 2",
        "choice Root 0 weights inf", "choice Root 0 weights 0 0", "optional Root 0 probability 1.5",
        "optional Root 0 probability -0.1", "optional Root 0 probability 0.1234",
        "optional Root 0 probability nan", "repeat Root 0 histogram 1",
        "repeat Root 0 histogram x:1", "repeat Root 0 histogram 0:0",
        "attenuation 0", "attenuation 2", "bogus Root", "zero-weights maybe", "choice Root 0 weights"
    ])
        assert(!parsePolicy(bad).ok);
    assert(!parsePolicy("zero-weights deny\nchoice Root 0 weights 1 0").ok);
    assert(parsePolicy("choice Root 0 weights 1 0\nzero-weights allow").ok);
    // metadata is deterministic and normalized
    const meta = policyMetadata(good.policy);
    assert(meta == policyMetadata(good.policy));
    assert(meta[0 .. 30] == "{\"attenuationPermille\":800,\"ze");
}

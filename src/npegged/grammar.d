/** Grammar frontend derived from Pegged's extended PEG syntax (Boost 1.0).
    Runtime code generation is a cold path using selective druntime GC. */
module npegged.grammar;
public import npegged.peg;
public import npegged.dfa;
import npegged.io;
public import npegged.analysis : RuleEligibility, DiscriminationKind, BranchDiscrimination,
    ChoiceDiscrimination, renderDiscrimination;
import npegged.bites : renderBites, annotateBites, renderNextBites, renderCommitSites,
    unifiedDiagnostics, renderUnified;
import npegged.language : Budget;
public import npegged.generator : CandidateGenerator, GeneratorOptions, GenStatus;
import npegged.coverage : Coverage, Attributor, buildTargets, TargetKind;
import npegged.policy : parsePolicy, applyPolicy, policyMetadata;
import npegged.learning : Learner, shareDistance, lengthDistance;
import npegged.fuzz : Mutator, Observation, observe, sameObservation, accepts, shrink, Mismatch,
    regressionLine, parseRegression, Regression;
import core.time : MonoTime;
import npegged.ll : classifyRegions, renderRegions, renderEbnf, RegionClass, firstCertifiedRules;
import npegged.work : WorkBound, workBounds, describe;
import npegged.lr : LrGrammar, LrAutomaton, lrGrammarOf, buildLr, renderLr;
import npegged.analysis : GrammarAnalysis, Expression, ExpressionKind, Nullable, FirstFacts, RuleEffect;

nothrow:

struct Diagnostic {
    size_t offset;
    string message;
}

enum Memoization {
    no,
    yes,
    selective
}

/// The direct backend lowers recognition control; other modes retain combinators.
enum ParserBackend {
    combinators,
    direct,
    /// `direct` plus FIRST-guarded loop exits inside rules whose closed region is certifiedLL1 (L3, opt-in).
    ll1
}

/// Serialization for an explicitly requested cold eligibility report.
enum EligibilityFormat {
    json,
    text
}

/// Grammar-wide evidence and actual code-generation decisions, not a purity promise.
struct EligibilityResult {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    string grammarName;
    ParserBackend backend;
    Memoization memoPolicy = Memoization.yes;
    bool conservative;
    string[] unknownEvidence, actionRules;
    RuleEligibility[] rules;
    string report;
}

@nogc nothrow unittest {
    EligibilityResult result;
    assert(result.status == Status.invalidInput && !result.report.length && !result.rules.length);
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

nothrow unittest {
    assert(jsonQuoted("a\"\\\n\0\t\x1f/é") == "\"a\\\"\\\\\\u000a\\u0000\\u0009\\u001f/é\"");
    assert(jsonQuoted("") == "\"\"");
}

private string jsonStrings(scope const(string)[] values) pure nothrow {
    string result = "[";
    foreach (i, value; values)
        result ~= (i ? "," : "") ~ jsonQuoted(value);
    return result ~ "]";
}

nothrow unittest {
    assert(jsonStrings(null) == "[]");
    assert(jsonStrings(["a", "b"]) == "[\"a\",\"b\"]");
}

private string booleanText(bool value) @nogc nothrow pure {
    return value ? "true" : "false";
}

@nogc nothrow unittest {
    assert(booleanText(true) == "true" && booleanText(false) == "false");
}

private string renderEligibility(scope const ref EligibilityResult value, EligibilityFormat format) nothrow {
    const json = format == EligibilityFormat.json;
    string result;
    string field(string name, string data) nothrow {
        return (json ? jsonQuoted(name) ~ ":" : name ~ "=") ~ data;
    }

    const separator = json ? "," : " ";
    result = (json ? "{" : "") ~ field("grammar", jsonQuoted(value.grammarName)) ~ separator ~ field("backend",
            jsonQuoted(value.backend == ParserBackend.direct
                ? "direct" : value.backend == ParserBackend.ll1 ? "ll1" : "combinators"))
        ~ separator ~ field("memoPolicy",
                jsonQuoted(value.memoPolicy == Memoization.no
                    ? "no" : value.memoPolicy == Memoization.yes ? "yes" : "selective"))
        ~ separator ~ field("conservative",
                booleanText(value.conservative)) ~ separator ~ field("unknownEvidence",
                jsonStrings(value.unknownEvidence)) ~ separator ~ field("actionRules",
                jsonStrings(value.actionRules)) ~ separator ~ field(
                "fallbackModes", "[\"trace\",\"CTFE\",\"full-tree\"]") ~ (json ? ",\"rules\":[" : "\n");
    foreach (i, row; value.rules) {
        if (json)
            result ~= i ? ",{" : "{";
        result ~= field("name", jsonQuoted(row.name)) ~ separator ~ field("rootExpression",
                jsonQuoted(row.rootExpression)) ~ separator ~ field("known",
                booleanText(row.known)) ~ separator ~ field("actionful", booleanText(row.actionful)) ~ separator ~ field(
                "leftRecursive", booleanText(row.leftRecursive)) ~ separator ~ field("memoized",
                booleanText(row.memoized)) ~ separator ~ field("scalarEligible",
                booleanText(row.scalarEligible)) ~ separator ~ field("scalarBlockers",
                jsonStrings(row.scalarBlockers)) ~ separator ~ field("directRecognition",
                booleanText(row.directRecognition)) ~ separator ~ field("directRecords",
                booleanText(row.directRecords)) ~ separator ~ field("directFallback",
                jsonQuoted(row.directFallback)) ~ separator ~ field("selectorConfigured",
                booleanText(row.selectorConfigured)) ~ separator ~ field("recordKind",
                number(row.recordKind)) ~ separator ~ field("recordSelected",
                booleanText(row.recordSelected)) ~ separator ~ field("recordLeaf",
                booleanText(row.recordLeaf)) ~ separator ~ field("recordSubtree",
                booleanText(row.recordSubtree)) ~ separator ~ field("dfaScanner",
                booleanText(row.dfaScanner)) ~ separator ~ field("predictiveDispatch",
                booleanText(row.predictiveDispatch)) ~ separator ~ field("scannerRegions",
                number(row.scannerRegions)) ~ separator ~ field("strategy",
                jsonQuoted(row.strategy)) ~ separator ~ field("workBound", jsonQuoted(row.workBound)) ~ (json
                ? "}" : "\n");
    }
    return result ~ (json ? "]}" : "");
}

nothrow unittest {
    EligibilityResult value;
    value.grammarName = "Quoted\n\"";
    auto json = renderEligibility(value, EligibilityFormat.json);
    assert(startsWith(json, "{\"grammar\":\"Quoted\\u000a\\\"\""));
    assert(json[$ - 3 .. $] == "[]}");
    assert(startsWith(renderEligibility(value, EligibilityFormat.text), "grammar="));
    value.memoPolicy = Memoization.no;
    value.backend = ParserBackend.direct;
    value.rules = [RuleEligibility.init, RuleEligibility.init];
    value.rules[0].name = "First";
    value.rules[1].name = "Second";
    value.rules[1].scalarBlockers = ["grammar-unknown", "full-memo"];
    assert(renderEligibility(value, EligibilityFormat.json).length > json.length);
    assert(renderEligibility(value, EligibilityFormat.text).length > json.length);
    value.memoPolicy = Memoization.selective;
    assert(renderEligibility(value, EligibilityFormat.json).length);
}

version (NPeggedPureIslands) private template islandAnonymousSelection(alias Selector) {
    enum islandAnonymousSelection = Selector("");
}

private string number(ulong value) pure nothrow {
    char[32] digits;
    size_t start = digits.length;
    do {
        digits[--start] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    return digits[start .. $].idup;
}

unittest {
    assert(number(0) == "0");
    assert(number(123) == "123");
}

private bool startsWith(scope string s, scope string prefix) @nogc nothrow pure @safe {
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

private string ulongHex(ulong value) pure nothrow {
    if (value == 0)
        return "0x0UL";
    char[22] buf;
    buf[0 .. 2] = "0x";
    enum hex = "0123456789abcdef";
    char[16] digits;
    size_t len;
    ulong v = value;
    while (v) {
        digits[len++] = hex[v & 0xF];
        v >>= 4;
    }
    size_t outLen = 2;
    while (len) {
        buf[outLen++] = digits[--len];
    }
    return (buf[0 .. outLen] ~ "UL").idup;
}

unittest {
    assert(ulongHex(0) == "0x0UL");
    assert(ulongHex(15) == "0xfUL");
    assert(ulongHex(256) == "0x100UL");
    assert(startsWith("hello world", "hello"));
    assert(!startsWith("hello", "world"));
}

private string quoted(string text) pure nothrow {
    string result = "\"";
    foreach (c; text) {
        switch (c) {
        case '\\':
            result ~= "\\\\";
            break;
        case '"':
            result ~= "\\\"";
            break;
        case '\n':
            result ~= "\\n";
            break;
        case '\r':
            result ~= "\\r";
            break;
        case '\t':
            result ~= "\\t";
            break;
        case '\0':
            result ~= "\\0";
            break;
        default:
            if (cast(ubyte)c < 32 || cast(ubyte)c >= 127) {
                enum hex = "0123456789ABCDEF";
                result ~= "\\x" ~ hex[(cast(ubyte)c) >> 4] ~ hex[(cast(ubyte)c) & 15];
            } else
                result ~= c;
            break;
        }
    }
    return result ~ "\"";
}

unittest {
    assert(quoted("a\n\"\\") == "\"a\\n\\\"\\\\\"");
}

/// Cold grammar frontend. Runtime generation selectively uses druntime GC; emitted parsers never do.
package struct Frontend {
    string input;
    size_t pos;
    Diagnostic error;
    bool spaced;
    struct Rule {
        string name, params, body;
    }

    Rule[] rules;
    string name, params;
    bool memoize = true;
    bool selective;
    ParserBackend backend;
    bool llGuards, llActive; // L3: FIRST-guarded loop exits in certified rules
    bool acceptActive; // C1: emitting the `accept` clone (no failure diagnostics; same work units and outcomes)
    size_t llRule;
    bool[] llCertified;
    bool llComputed;
    uint[] recordKinds;
    version (NPeggedPureIslands) private bool islandOmitAnonymous;
    bool[] recordLeaves;
    bool[] recordSubtrees;
    /// O4 test hook: regions whose rules emit leaf records are walked rule by rule instead of using a tagged table.
    bool walkRecordRegions;
    string[] parameterNames;
    private GrammarAnalysis analyzed;
    private bool hasAnalysis;
    private bool[] scalarRules;
    /// Rules the `accept` clone calls through a cursor: the scalar rules plus the iteratively lowered left-recursive ones (P8).
    private bool[] acceptRules;
    private IterativeForm[] iterativeForms;
    private EligibilityResult* eligibility;
    private string directDeclarations, directRule;
    void skip() nothrow {
        while (pos < input.length) {
            if (input[pos] == ' ' || input[pos] == '\t' || input[pos] == '\n' || input[pos] == '\r')
                ++pos;
            else if (input[pos] == '#') {
                while (pos < input.length && input[pos] != '\n')
                    ++pos;
            } else
                break;
        }
    }

    bool accept(char c) nothrow {
        skip();
        if (pos < input.length && input[pos] == c) {
            ++pos;
            return true;
        }
        return false;
    }

    void require(char c) nothrow {
        if (!accept(c))
            problem("Expected '" ~ c ~ "'");
    }

    void problem(string message) nothrow {
        if (!error.message.length)
            error = Diagnostic(pos, message);
    }

    string ident() nothrow {
        skip();
        size_t start = pos;
        if (pos >= input.length || !isInitial(input[pos]))
            return null;
        ++pos;
        while (pos < input.length && (isInitial(input[pos]) || (input[pos] >= '0' && input[pos] <= '9')))
            ++pos;
        return input[start .. pos];
    }

    static bool isInitial(char c) @nogc nothrow pure {
        return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
    }

    string parameters() nothrow {
        if (!accept('('))
            return null;
        string result = "(";
        do {
            auto id = ident();
            if (!id.length) {
                problem("Expected parameter name");
                break;
            }
            parameterNames ~= id;
            result ~= "alias " ~ id;
            if (accept('='))
                result ~= " = " ~ expression();
            if (!accept(','))
                break;
            result ~= ", ";
        }
        while (!error.message.length);
        require(')');
        return result ~ ")";
    }

    bool definitionAhead() nothrow {
        size_t saved = pos;
        auto id = ident();
        if (!id.length) {
            pos = saved;
            return false;
        }
        if (accept('(')) {
            size_t depth = 1;
            while (pos < input.length && depth) {
                auto c = input[pos++];
                if (c == '\'' || c == '"') {
                    auto delimiter = c;
                    while (pos < input.length && input[pos] != delimiter) {
                        if (input[pos++] == '\\' && pos < input.length)
                            ++pos;
                    }
                    if (pos < input.length)
                        ++pos;
                    continue;
                }
                if (c == '(')
                    ++depth;
                if (c == ')')
                    --depth;
            }
        }
        skip();
        bool result = pos < input.length && input[pos] == '<';
        pos = saved;
        return result;
    }

    nothrow unittest {
        foreach (text; [`R(T = ')') <- 'a'`, `R(T = "a\"(") <- 'a'`, `R(T = (X)) <- 'a'`]) {
            Frontend parser;
            parser.input = text;
            assert(parser.definitionAhead() && parser.pos == 0);
            assert(!parser.error.message.length);
        }
        foreach (text; ["", "9bad", `R(T = "unterminated`, `R(T = "trailing\`]) {
            Frontend parser;
            parser.input = text;
            assert(!parser.definitionAhead() && parser.pos == 0);
        }
    }

    string expression() nothrow {
        skip();
        char kind = 0;
        if (pos < input.length && (input[pos] == '/' || input[pos] == '|'))
            kind = input[pos++];
        string[] choices;
        choices ~= sequence();
        while (!error.message.length) {
            skip();
            if (pos >= input.length || (input[pos] != '/' && input[pos] != '|'))
                break;
            char next = input[pos++];
            if (kind && kind != next) {
                problem("Cannot mix / and | in one expression");
                break;
            }
            kind = next;
            choices ~= sequence();
        }
        if (choices.length == 1)
            return choices[0];
        string result = kind == '|' ? "longest_match!(" : "or!(";
        foreach (i, choice; choices)
            result ~= (i ? ", " : "") ~ choice;
        return result ~ ")";
    }

    string sequence() nothrow {
        string[] pieces;
        while (!error.message.length) {
            skip();
            if (pos >= input.length || input[pos] == ')' || input[pos] == ',' || input[pos] == '/'
                    || input[pos] == '|' || definitionAhead())
                break;
            auto before = pos;
            auto piece = prefix();
            if (pos == before) {
                problem("Expected parsing expression");
                break;
            }
            pieces ~= piece;
        }
        if (!pieces.length) {
            problem("Empty sequence");
            return "eps";
        }
        if (pieces.length == 1)
            return pieces[0];
        string result = "and!(";
        foreach (i, piece; pieces)
            result ~= (i ? ", " : "") ~ piece;
        return result ~ ")";
    }

    string prefix() nothrow {
        skip();
        string operators;
        while (pos < input.length && isPrefix(input[pos])) {
            operators ~= input[pos++];
            skip();
        }
        auto result = primary();
        while (!error.message.length) {
            if (accept('?'))
                result = "option!(" ~ result ~ ")";
            else if (accept('*'))
                result = "zeroOrMore!(" ~ result ~ ")";
            else if (accept('+'))
                result = "oneOrMore!(" ~ result ~ ")";
            else if (accept('{'))
                result = actions(result);
            else
                break;
        }
        foreach (c; operators)
            result = operation(c) ~ "!(" ~ result ~ ")";
        return result;
    }

    static bool isPrefix(char c) @nogc nothrow pure {
        return c == '&' || c == '!' || c == '~' || c == ':' || c == '^' || c == ';' || c == '%';
    }

    static string operation(char c) @nogc nothrow pure {
        switch (c) {
        case '&':
            return "posLookahead";
        case '!':
            return "negLookahead";
        case '~':
            return "fuse";
        case ':':
            return "discard";
        case '^':
            return "keep";
        case ';':
            return "drop";
        case '%':
            return "propagate";
        default:
            assert(false);
        }
    }

    string primary() nothrow {
        skip();
        string result;
        if (accept('(')) {
            result = expression();
            require(')');
        } else if (accept('.'))
            result = "any";
        else if (accept('[')) {
            bool allAscii = true;
            CharSetMask mask;
            size_t elementCount = 0;
            dchar singleFirst = 0, singleLast = 0;
            bool singleByteEscape = false;
            string[] nonAsciiRanges;
            while (pos < input.length && input[pos] != ']' && !error.message.length) {
                bool byteEscape = input[pos] == '\\' && pos + 1 < input.length
                    && (input[pos + 1] == 'x' || input[pos + 1] >= '0' && input[pos + 1] <= '7');
                auto first = character();
                if (pos < input.length && input[pos] == '-' && pos + 1 < input.length && input[pos + 1] != ']') {
                    ++pos;
                    auto last = character();
                    if (last < 256) {
                        mask.addRange(first, last);
                    } else {
                        allAscii = false;
                        nonAsciiRanges ~= "charRange!(" ~ number(first) ~ ", " ~ number(last) ~ ")";
                    }
                    singleFirst = first;
                    singleLast = last;
                    singleByteEscape = false;
                    ++elementCount;
                } else if (byteEscape) {
                    if (first < 256) {
                        mask.addChar(first);
                    } else {
                        allAscii = false;
                        nonAsciiRanges ~= "literal!(" ~ quoted([cast(char)first].idup) ~ ")";
                    }
                    singleFirst = first;
                    singleLast = first;
                    singleByteEscape = true;
                    ++elementCount;
                } else {
                    if (first < 256) {
                        mask.addChar(first);
                    } else {
                        allAscii = false;
                        nonAsciiRanges ~= "charRange!(" ~ number(first) ~ ", " ~ number(first) ~ ")";
                    }
                    singleFirst = first;
                    singleLast = first;
                    singleByteEscape = false;
                    ++elementCount;
                }
            }
            require(']');
            if (!elementCount)
                result = "fail";
            else if (elementCount == 1 && singleByteEscape) {
                result = "literal!(" ~ quoted([cast(char)singleFirst].idup) ~ ")";
            } else if (elementCount == 1 && allAscii) {
                result = "charRange!(" ~ number(singleFirst) ~ ", " ~ number(singleLast) ~ ")";
            } else if (allAscii) {
                result = "charClass!(" ~ ulongHex(mask.bits[0]) ~ ", " ~ ulongHex(
                        mask.bits[1]) ~ ", " ~ ulongHex(mask.bits[2]) ~ ", " ~ ulongHex(mask.bits[3]) ~ ")";
            } else {
                string[] allChoices;
                if (!mask.empty)
                    allChoices ~= "charClass!(" ~ ulongHex(mask.bits[0]) ~ ", " ~ ulongHex(
                            mask.bits[1]) ~ ", " ~ ulongHex(mask.bits[2]) ~ ", " ~ ulongHex(mask.bits[3]) ~ ")";
                allChoices ~= nonAsciiRanges;
                result = "or!(";
                foreach (i, c; allChoices)
                    result ~= (i ? ", " : "") ~ c;
                result ~= ")";
            }
        } else if (pos < input.length && (input[pos] == '\'' || input[pos] == '"')) {
            auto delimiter = input[pos++];
            string text;
            while (pos < input.length && input[pos] != delimiter && !error.message.length) {
                bool byteEscape = input[pos] == '\\' && pos + 1 < input.length
                    && (input[pos + 1] == 'x' || input[pos + 1] >= '0' && input[pos + 1] <= '7');
                auto scalar = character(true);
                text ~= byteEscape ? [cast(char)scalar].idup : encode(scalar);
            }
            if (pos == input.length)
                problem("Unterminated literal");
            else
                ++pos;
            bool insensitive = pos < input.length && input[pos] == 'i';
            if (insensitive)
                ++pos;
            result = (insensitive ? "caseInsensitiveLiteral!(" : "literal!(") ~ quoted(text) ~ ")";
        } else {
            result = ident();
            if (!result.length) {
                problem("Expected literal, range, group, or rule name");
                return "fail";
            }
            while (!error.message.length) {
                size_t beforeArguments = pos;
                if (pos < input.length && input[pos] == '(') {
                    ++pos;
                    result ~= "!(";
                    size_t count;
                    do {
                        result ~= (count++ ? ", " : "") ~ expression();
                    }
                    while (accept(','));
                    require(')');
                    result ~= ")";
                } else {
                    pos = beforeArguments;
                    // Qualified rule names cannot have whitespace around the dot.
                    size_t saved = pos;
                    if (pos + 1 < input.length && input[pos] == '.' && isInitial(input[pos + 1])) {
                        ++pos;
                        auto id = ident();
                        result ~= "." ~ id;
                    } else {
                        pos = saved;
                        break;
                    }
                }
            }
        }
        if (spaced)
            result = "wrapAround!(Spacing, " ~ result ~ ", Spacing)";
        return result;
    }

    dchar character(bool literalMode = false) nothrow {
        if (pos == input.length) {
            problem("Expected character");
            return 0;
        }
        if (input[pos] != '\\') {
            dchar value;
            if (!decode(input, pos, value))
                problem("Invalid UTF-8");
            return value;
        }
        ++pos;
        if (pos == input.length) {
            problem("Incomplete escape");
            return 0;
        }
        auto c = input[pos++];
        switch (c) {
        case 'n':
            return '\n';
        case 'r':
            return '\r';
        case 't':
            return '\t';
        case 'b':
            return '\b';
        case 'f':
            return '\f';
        case 'v':
            return '\v';
        case 'x':
        case 'u':
        case 'U': {
                uint value;
                uint count = c == 'x' ? 2 : c == 'u' ? 4 : 8;
                foreach (i; 0 .. count) {
                    if (pos == input.length) {
                        problem("Incomplete hex escape");
                        return 0;
                    }
                    auto digit = input[pos++];
                    uint n = digit >= '0' && digit <= '9' ? digit - '0' : digit >= 'a' && digit <= 'f'
                        ? digit - 'a' + 10 : digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : 16;
                    if (n == 16) {
                        problem("Invalid hex escape");
                        return 0;
                    }
                    value = value * 16 + n;
                }
                if (value > 0x10FFFF || value >= 0xD800 && value <= 0xDFFF)
                    problem("Invalid Unicode scalar");
                return cast(dchar)value;
            }
        default:
            if (c >= '0' && c <= '7') {
                uint value = c - '0';
                foreach (i; 0 .. (literalMode || c <= '2' ? 2 : 1)) {
                    if (pos == input.length || input[pos] < '0' || input[pos] > '7')
                        break;
                    value = value * 8 + input[pos++] - '0';
                }
                return cast(dchar)value;
            }
            return c;
        }
    }

    nothrow unittest {
        foreach (literalMode; [false, true]) {
            Frontend parser;
            parser.input = `\377`;
            assert(parser.character(literalMode) == (literalMode ? 255 : 31));
            assert(parser.pos == (literalMode ? 4 : 3));
            parser = Frontend.init;
            parser.input = `\277`;
            assert(parser.character(literalMode) == 191 && parser.pos == 4);
            parser = Frontend.init;
            parser.input = `\78`;
            assert(parser.character(literalMode) == 7 && parser.pos == 2);
        }
        foreach (text; ["", `\`, `\x0`, `\x0g`, `\uD800`, `\U00110000`]) {
            Frontend parser;
            parser.input = text;
            parser.character();
            assert(parser.error.message.length != 0);
        }
        Frontend parameters;
        parameters.input = "(T = ,)";
        parameters.parameters();
        assert(parameters.error.message.length != 0);
    }

    string actions(string result) nothrow {
        size_t start = pos, depth;
        char quote = 0;
        bool escaped;
        while (pos < input.length) {
            char c = input[pos++];
            if (!quote && c == '/' && pos < input.length) {
                if (input[pos] == '/') {
                    while (pos < input.length && input[pos] != '\n')
                        ++pos;
                    continue;
                }
                if (input[pos] == '*') {
                    ++pos;
                    while (pos + 1 < input.length && !(input[pos] == '*' && input[pos + 1] == '/'))
                        ++pos;
                    if (pos + 1 == input.length) {
                        problem("Unterminated action comment");
                        return result;
                    }
                    pos += 2;
                    continue;
                }
                if (input[pos] == '+') {
                    ++pos;
                    size_t nesting = 1;
                    while (pos + 1 < input.length && nesting) {
                        if (input[pos] == '/' && input[pos + 1] == '+') {
                            ++nesting;
                            pos += 2;
                        } else if (input[pos] == '+' && input[pos + 1] == '/') {
                            --nesting;
                            pos += 2;
                        } else
                            ++pos;
                    }
                    if (nesting) {
                        problem("Unterminated nested action comment");
                        return result;
                    }
                    continue;
                }
            }
            if (quote) {
                if (escaped)
                    escaped = false;
                else if (c == '\\' && quote != '`')
                    escaped = true;
                else if (c == quote)
                    quote = 0;
                continue;
            }
            if (c == '\'' || c == '"' || c == '`') {
                quote = c;
                continue;
            }
            if (c == '(' || c == '[' || c == '{')
                ++depth;
            else if ((c == ')' || c == ']' || c == '}') && depth)
                --depth;
            else if (!depth && (c == ',' || c == '}')) {
                auto expression = input[start .. pos - 1];
                result = "action!(" ~ result ~ ", " ~ expression ~ ")";
                if (c == '}')
                    return result;
                start = pos;
            }
        }
        problem("Unterminated semantic action");
        return result;
    }

    nothrow unittest {
        foreach (text; [
            `handler("a\"{", ')')}`, `handler(/* ignored */ /+ outer /+ inner +/ tail +/)}`,
            "handler(`\\{`)}"
        ]) {
            Frontend parser;
            parser.input = text;
            assert(parser.actions("body") == "action!(body, " ~ text[0 .. $ - 1] ~ ")");
            assert(parser.pos == text.length && !parser.error.message.length);
        }
        foreach (text; [
            "/*x", "/+ outer /+ inner +/", `handler("unterminated`, `handler("trailing\`
        ]) {
            Frontend parser;
            parser.input = text;
            parser.actions("body");
            assert(parser.error.message.length != 0);
        }
    }

    void read() nothrow {
        hasAnalysis = false;
        name = ident();
        params = parameters();
        require(':');
        if (!name.length)
            problem("Expected grammar name");
        while (!error.message.length) {
            skip();
            if (pos == input.length)
                break;
            auto ruleName = ident();
            auto ruleParams = parameters();
            require('<');
            char arrow = 0;
            string arrowActions;
            if (pos < input.length) {
                if (input[pos] == '-')
                    ++pos;
                else if (isPrefix(input[pos]) && input[pos] != '!' && input[pos] != '&')
                    arrow = input[pos++];
                else if (input[pos] == '{') {
                    ++pos;
                    arrowActions = actions("__BODY__");
                } else
                    arrow = ' ';
            }
            spaced = arrow == ' ';
            auto body = expression();
            spaced = false;
            if (arrow && arrow != ' ')
                body = operation(arrow) ~ "!(" ~ body ~ ")";
            if (arrowActions.length) {
                string replaced;
                for (size_t i; i < arrowActions.length;) {
                    if (i + 8 <= arrowActions.length && arrowActions[i .. i + 8] == "__BODY__") {
                        replaced ~= body;
                        i += 8;
                    } else
                        replaced ~= arrowActions[i++];
                }
                body = replaced;
            }
            rules ~= Rule(ruleName, ruleParams, body);
        }
        if (!rules.length)
            problem("Grammar needs at least one rule");
    }

    struct FirstSetResult {
        bool known;
        bool canBeEmpty;
        CharSetMask mask;
    }

    FirstSetResult primitiveFirstSet(string expr) const nothrow {
        FirstSetResult res;
        while (expr.length > 0 && expr[0] == ' ')
            expr = expr[1 .. $];
        while (expr.length > 0 && expr[$ - 1] == ' ')
            expr = expr[0 .. $ - 1];

        if (startsWith(expr, "literal!(") || startsWith(expr, "literal!\"")) {
            size_t qStart = 0;
            while (qStart < expr.length && expr[qStart] != '"')
                qStart++;
            if (qStart < expr.length) {
                size_t qEnd = qStart + 1;
                while (qEnd < expr.length && expr[qEnd] != '"') {
                    if (expr[qEnd] == '\\' && qEnd + 1 < expr.length)
                        qEnd += 2;
                    else
                        qEnd++;
                }
                string content = expr[qStart + 1 .. qEnd];
                if (content.length == 0) {
                    res.known = true;
                    res.canBeEmpty = true;
                    return res;
                }
                char c = content[0];
                if (c == '\\' && content.length > 1) {
                    char esc = content[1];
                    switch (esc) {
                    case 'n':
                        c = '\n';
                        break;
                    case 'r':
                        c = '\r';
                        break;
                    case 't':
                        c = '\t';
                        break;
                    case '0':
                        c = '\0';
                        break;
                    case '\\':
                        c = '\\';
                        break;
                    case '"':
                        c = '"';
                        break;
                    default:
                        c = esc;
                        break;
                    }
                }
                res.known = true;
                res.canBeEmpty = false;
                res.mask.addChar(c);
                return res;
            }
        }

        if (startsWith(expr, "charRange!(")) {
            string inner = expr[11 .. $];
            if (inner.length > 0 && inner[$ - 1] == ')')
                inner = inner[0 .. $ - 1];
            size_t comma = 0;
            while (comma < inner.length && inner[comma] != ',')
                comma++;
            if (comma < inner.length) {
                string sLow = inner[0 .. comma];
                string sHigh = inner[comma + 1 .. $];
                while (sLow.length > 0 && sLow[0] == ' ')
                    sLow = sLow[1 .. $];
                while (sHigh.length > 0 && sHigh[0] == ' ')
                    sHigh = sHigh[1 .. $];
                uint low = 0, high = 0;
                foreach (ch; sLow) {
                    if (ch >= '0' && ch <= '9')
                        low = low * 10 + (ch - '0');
                }
                foreach (ch; sHigh) {
                    if (ch >= '0' && ch <= '9')
                        high = high * 10 + (ch - '0');
                }
                if (high < 128 && low <= high) {
                    res.known = true;
                    res.canBeEmpty = false;
                    res.mask.addRange(low, high);
                    return res;
                }
            }
        }

        if (startsWith(expr, "charClass!(")) {
            string inner = expr[11 .. $];
            if (inner.length > 0 && inner[$ - 1] == ')')
                inner = inner[0 .. $ - 1];
            ulong[4] b;
            size_t idx = 0;
            size_t start = 0;
            for (size_t i = 0; i <= inner.length && idx < 4; ++i) {
                if (i == inner.length || inner[i] == ',') {
                    string part = inner[start .. i];
                    while (part.length > 0 && (part[0] == ' ' || part[0] == '\t'))
                        part = part[1 .. $];
                    while (part.length > 0 && (part[$ - 1] == 'U' || part[$ - 1] == 'L' || part[$ - 1] == ' '))
                        part = part[0 .. $ - 1];
                    ulong val = 0;
                    if (startsWith(part, "0x") || startsWith(part, "0X")) {
                        foreach (ch; part[2 .. $]) {
                            uint n = ch >= '0' && ch <= '9' ? ch - '0' : ch >= 'a' && ch <= 'f'
                                ? ch - 'a' + 10 : ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : 0;
                            val = (val << 4) | n;
                        }
                    } else {
                        foreach (ch; part) {
                            if (ch >= '0' && ch <= '9')
                                val = val * 10 + (ch - '0');
                        }
                    }
                    b[idx++] = val;
                    start = i + 1;
                }
            }
            if (idx == 4) {
                res.known = true;
                res.canBeEmpty = false;
                res.mask = CharSetMask(b);
                return res;
            }
        }

        if (expr == "digit") {
            res.known = true;
            res.mask.addRange('0', '9');
            return res;
        }
        if (expr == "alpha") {
            res.known = true;
            res.mask.addRange('a', 'z');
            return res;
        }
        if (expr == "Alpha") {
            res.known = true;
            res.mask.addRange('A', 'Z');
            return res;
        }
        if (expr == "hexDigit") {
            res.known = true;
            res.mask.addRange('0', '9');
            res.mask.addRange('a', 'f');
            res.mask.addRange('A', 'F');
            return res;
        }
        if (expr == "space") {
            res.known = true;
            res.mask.addChar(' ');
            res.mask.addChar('\t');
            res.mask.addChar('\v');
            return res;
        }
        if (expr == "blank") {
            res.known = true;
            res.mask.addChar(' ');
            res.mask.addChar('\t');
            res.mask.addChar('\v');
            res.mask.addChar('\r');
            res.mask.addChar('\n');
            return res;
        }
        if (expr == "ident" || expr == "identifier") {
            res.known = true;
            res.mask.addRange('a', 'z');
            res.mask.addRange('A', 'Z');
            res.mask.addChar('_');
            return res;
        }

        return res;
    }

    nothrow unittest {
        Frontend frontend;
        auto literal = frontend.primitiveFirstSet("  literal!(\"a\")  ");
        assert(literal.known && !literal.canBeEmpty && literal.mask.contains('a'));
        assert(frontend.primitiveFirstSet("literal!\"b\"").mask.contains('b'));
        auto range = frontend.primitiveFirstSet("charRange!( 97, 98 )");
        assert(range.known && range.mask.contains('a') && range.mask.contains('b'));
        assert(!range.mask.contains('c'));
        foreach (expression; [
            "charRange!(98,97)", "charRange!(128,129)", "charRange!(97)", "charClass!(1,2)",
            "literal!(123)", "unknownTerminal"
        ])
            assert(!frontend.primitiveFirstSet(expression).known);
        auto hex = frontend.primitiveFirstSet("charClass!( 0x1UL, 0X2UL, 0xaFUL, 0xAFUL )");
        assert(hex.known && hex.mask.bits == [1UL, 2UL, 175UL, 175UL]);
        auto decimal = frontend.primitiveFirstSet("charClass!( 1, 2, 3, 4 )");
        assert(decimal.known && decimal.mask.bits == [1UL, 2UL, 3UL, 4UL]);
    }

    private string decodedLiteral(string source) const nothrow {
        Frontend decoder;
        decoder.input = source;
        while (decoder.pos < source.length && source[decoder.pos] != '"')
            ++decoder.pos;
        if (decoder.pos == source.length)
            return null;
        ++decoder.pos;
        string bytes;
        while (decoder.pos < source.length && source[decoder.pos] != '"') {
            const byteEscape = source[decoder.pos] == '\\' && decoder.pos + 1 < source.length
                && source[decoder.pos + 1] == 'x';
            const scalar = decoder.character(true);
            bytes ~= byteEscape ? [cast(char)scalar].idup : encode(scalar);
        }
        return bytes;
    }

    nothrow unittest {
        Frontend frontend;
        assert(frontend.decodedLiteral(`literal!("a\n\x80é")`) == "a\n\x80é");
        assert(frontend.decodedLiteral("unknown") is null);
    }

    private size_t expressionNode(ref GrammarAnalysis graph, string text) const nothrow {
        while (text.length && (text[0] == ' ' || text[0] == '\t'))
            text = text[1 .. $];
        while (text.length && (text[$ - 1] == ' ' || text[$ - 1] == '\t'))
            text = text[0 .. $ - 1];
        Expression node;
        node.source = text;
        size_t marker;
        while (marker < text.length && text[marker] != '!')
            ++marker;
        bool parameter;
        if (marker == text.length)
            foreach (name; parameterNames)
                if (text == name)
                    parameter = true;
        size_t knownRule = size_t.max;
        if (marker == text.length && !parameter)
            knownRule = graph.ruleIndex(text);
        if (parameter)
            node.kind = ExpressionKind.unknown;
        else if (knownRule != size_t.max) {
            node.kind = ExpressionKind.reference;
            node.reference = text;
            node.rule = knownRule;
        } else if (marker == text.length && (text == "eps" || text == "eoi" || text == "endOfInput" || text == "fail")) {
            node.kind = ExpressionKind.terminal;
            node.known = true;
            node.nullable = text == "fail" ? Nullable.no : Nullable.yes;
        } else if (marker == text.length && text == "any") {
            node.kind = ExpressionKind.terminal;
            node.known = true;
            node.nullable = Nullable.no;
            node.first = CharSetMask([ulong.max, ulong.max, ulong.max, ulong.max]);
        } else {
            string combinator = text[0 .. marker];
            bool compound = marker + 2 < text.length && text[marker .. marker + 2] == "!(" && text[$ - 1] == ')';
            string[] args;
            if (compound)
                args = splitTemplateArgs(text[marker + 2 .. $ - 1]);
            node.arguments = args;
            bool children;
            if (compound && (combinator == "and" || combinator == "wrapAround")) {
                node.kind = ExpressionKind.sequence;
                children = true;
            } else if (compound && (combinator == "or" || combinator == "longest_match"
                    || combinator == "predictiveChoice")) {
                node.kind = ExpressionKind.choice;
                children = true;
            } else if (compound && args.length && (combinator == "option" || combinator == "zeroOrMore")) {
                node.kind = combinator == "option" ? ExpressionKind.optional : ExpressionKind.repetition;
                args.length = 1;
                children = true;
            } else if (compound && args.length && (combinator == "posLookahead"
                    || combinator == "negLookahead" || combinator == "predictiveNot")) {
                node.kind = ExpressionKind.predicate;
                args.length = 1;
                children = true;
            } else if (compound && args.length && (combinator == "discard" || combinator == "fuse"
                    || combinator == "keep" || combinator == "drop" || combinator == "propagate"
                    || combinator == "oneOrMore"
                    || combinator == "named" || combinator == "defined" || combinator == "branch"
                    || combinator == "dfaToken")) {
                node.kind = ExpressionKind.wrapper;
                args.length = 1;
                children = true;
            }
            if (children) {
                node.combinator = combinator;
                foreach (arg; args)
                    node.children ~= expressionNode(graph, arg);
            } else {
                auto primitive = primitiveFirstSet(text);
                if (primitive.known) {
                    node.kind = ExpressionKind.terminal;
                    node.first = primitive.mask;
                    node.known = true;
                    node.nullable = primitive.canBeEmpty ? Nullable.yes : Nullable.no;
                } else if (startsWith(text, "charRange!(") || startsWith(text, "charClass!(")
                        || startsWith(text, "caseInsensitiveLiteral!(")) {
                    // Unknown Unicode FIRST bytes must not imply unknown rule calls.
                    node.kind = ExpressionKind.terminal;
                    node.nullable = Nullable.no;
                } else if (text == "spacing" || text == "Spacing") {
                    node.kind = ExpressionKind.terminal;
                    node.nullable = Nullable.yes;
                    node.known = true;
                    node.first = primitiveFirstSet("blank").mask;
                } else if (text == "doublequote" || text == "backslash" || text == "quote"
                        || text == "slash" || text == "backquote" || text == "tab") {
                    node.kind = ExpressionKind.terminal;
                    node.nullable = Nullable.no;
                    node.known = true;
                    node.first.addChar(text == "doublequote" ? '"' : text == "backslash"
                            ? '\\' : text == "quote" ? '\'' : text == "slash" ? '/' : text == "tab" ? '\t' : '`');
                } else if (text == "endOfLine" || text == "eol") {
                    node.kind = ExpressionKind.terminal;
                    node.nullable = Nullable.no;
                    node.known = true;
                    node.first.addChar('\r');
                    node.first.addChar('\n');
                } else if (marker == text.length) {
                    node.kind = ExpressionKind.reference;
                    node.reference = text;
                }
            }
        }
        if (node.kind == ExpressionKind.terminal && startsWith(text, "literal!")) {
            node.byteTerminal = true;
            const bytes = decodedLiteral(text);
            node.literalBytes = bytes;
            node.byteWidth = bytes.length;
            node.first = CharSetMask.init;
            if (bytes.length)
                node.first.addChar(bytes[0]);
            foreach (c; bytes)
                node.alphabet.addChar(c);
        } else if (node.kind == ExpressionKind.terminal && node.known && node.nullable == Nullable.no
                && (text == "any" || text == "digit" || text == "alpha" || text == "Alpha"
                    || text == "hexDigit" || text == "space" || text == "blank" || text == "doublequote"
                    || text == "backslash" || text == "quote" || text == "slash" || text == "backquote"
                    || text == "tab" || startsWith(text, "charClass!(") || startsWith(text, "charRange!("))) {
            node.byteTerminal = true;
            node.byteWidth = 1;
            node.alphabet = node.first;
        }
        // A guarded byte is a common spelling of a complemented byte class.
        if (node.combinator == "and" && node.children.length == 2) {
            auto guard = graph.expressions[node.children[0]];
            auto consumedByte = graph.expressions[node.children[1]];
            if (guard.combinator == "negLookahead" && guard.children.length == 1
                    && consumedByte.kind == ExpressionKind.terminal && consumedByte.source == "any") {
                auto excluded = graph.expressions[guard.children[0]];
                bool byteChoice = false;
                CharSetMask excludedMask;
                if (excluded.byteTerminal && excluded.nullable == Nullable.no && excluded.byteWidth == 1) {
                    byteChoice = true;
                    excludedMask = excluded.first;
                } else if (excluded.kind == ExpressionKind.choice && excluded.children.length) {
                    byteChoice = true;
                    foreach (child; excluded.children) {
                        auto branch = graph.expressions[child];
                        if (!branch.byteTerminal || branch.nullable != Nullable.no || branch.byteWidth != 1) {
                            byteChoice = false;
                            break;
                        }
                        excludedMask = excludedMask | branch.first;
                    }
                }
                if (byteChoice) {
                    node.kind = ExpressionKind.terminal;
                    node.children = null;
                    node.arguments = null;
                    node.combinator = null;
                    node.byteTerminal = node.known = true;
                    node.byteWidth = 1;
                    node.nullable = Nullable.no;
                    foreach (i; 0 .. 4)
                        node.first.bits[i] = ~excludedMask.bits[i];
                    node.alphabet = node.first;
                    node.source = "charClass!(" ~ ulongHex(node.first.bits[0]) ~ ", " ~ ulongHex(
                            node.first.bits[1]) ~ ", " ~ ulongHex(node.first.bits[2]) ~ ", " ~ ulongHex(
                            node.first.bits[3]) ~ ")";
                }
            }
        }
        return graph.appendExpression(node);
    }

    private void prepareAnalysis() nothrow {
        analyzed = GrammarAnalysis.init;
        foreach (rule; rules)
            analyzed.names ~= rule.name;
        foreach (rule; rules)
            analyzed.roots ~= expressionNode(analyzed, rule.body);
        analyzed.solve();
        hasAnalysis = true;
    }

    FirstSetResult computeFirstSet(string expression) nothrow {
        if (!hasAnalysis)
            prepareAnalysis();
        const saved = analyzed.expressions.length;
        scope (exit)
            analyzed.truncate(saved);
        auto root = expressionNode(analyzed, expression);
        auto value = analyzed.appendFacts(root);
        return FirstSetResult(value.known && value.nullable != Nullable.unknown,
                value.nullable != Nullable.no, value.first);
    }

    static string[] splitTemplateArgs(string args) pure nothrow {
        string[] result;
        size_t depth, start;
        bool inQuote;
        for (size_t i; i < args.length; ++i) {
            const c = args[i];
            if (inQuote && c == '\\' && i + 1 < args.length) {
                ++i;
                continue;
            }
            if (c == '"')
                inQuote = !inQuote;
            else if (!inQuote) {
                if (c == '(')
                    ++depth;
                else if (c == ')' && depth)
                    --depth;
                else if (c == ',' && !depth) {
                    result ~= args[start .. i];
                    start = i + 1;
                }
            }
        }
        if (start < args.length)
            result ~= args[start .. $];
        return result;
    }

    private string dispatchChoice(string[] choices, FirstFacts[] values) nothrow {
        if (choices.length < 2 || choices.length > ubyte.max)
            return null;
        foreach (i, value; values)
            if (!value.known || value.nullable == Nullable.unknown || value.nullable == Nullable.yes
                    && i + 1 != values.length || value.first.empty && value.nullable != Nullable.yes)
                return null;
        foreach (i; 0 .. values.length)
            foreach (j; i + 1 .. values.length)
                if (values[i].first.intersects(values[j].first))
                    return null;
        string result = "predictiveChoice!(";
        foreach (i, choice; choices) {
            const mask = values[i].first;
            result ~= (i ? ", " : "") ~ "branch!(" ~ choice ~ ", " ~ ulongHex(
                    mask.bits[0]) ~ ", " ~ ulongHex(mask.bits[1]) ~ ", " ~ ulongHex(
                    mask.bits[2]) ~ ", " ~ ulongHex(mask.bits[3]) ~ (values[i].nullable == Nullable.yes
                    ? ", true" : "") ~ ")";
        }
        return result ~ ")";
    }

    string optimizeChoice(string[] choices) nothrow {
        if (!hasAnalysis)
            prepareAnalysis();
        auto query = analyzed;
        FirstFacts[] values;
        foreach (choice; choices) {
            auto root = expressionNode(query, choice);
            values ~= query.appendFacts(root);
        }
        auto plan = dispatchChoice(choices, values);
        if (firstTwoEnabled()) {
            if (plan is null)
                plan = firstTwoChoice(choices);
        }
        return plan;
    }

    /// The two-byte dispatch table (F4/P3) is used by the direct backend, whose cursors test it inline; the combinator
    /// backends keep the plain ordered choice unless `NPeggedFirst2` forces the table combinator.
    private bool firstTwoEnabled() const nothrow {
        version (NPeggedFirst2)
            return true;
        else
            return backend == ParserBackend.direct;
    }

    /// F4 (opt-in): ordered choice of 1-2 byte literals with overlapping FIRST bytes. Anything else,
    /// including empty literals, parameters or more than 16 distinct first bytes, returns null.
    string firstTwoChoice(string[] choices) nothrow {
        if (choices.length < 2 || choices.length >= ubyte.max)
            return null;
        bool[256] seen;
        size_t firsts, total, longest;
        string list;
        foreach (i, choice; choices) {
            if (!startsWith(choice, "literal!(") || choice[$ - 1] != ')')
                return null;
            const text = decodedLiteral(choice);
            if (text.length < 1 || text.length > 4)
                return null;
            if (!seen[cast(ubyte)text[0]]) {
                seen[cast(ubyte)text[0]] = true;
                ++firsts;
            }
            total += text.length;
            if (text.length > longest)
                longest = text.length;
            list ~= (i ? ", " : "") ~ quoted(text);
        }
        // L4: literals of 3-4 bytes need the trie walk; the two-byte table covers the rest.
        if (longest >= 3)
            return total <= literalTrieNodes ? "literalChoiceK!(" ~ list ~ ")" : null;
        return firsts <= 16 ? "literalChoice2!(" ~ list ~ ")" : null;
    }

    /// Trie nodes `literalChoiceK` may use (one ubyte id each).
    enum literalTrieNodes = 240;

    nothrow unittest {
        Frontend frontend;
        assert(frontend.firstTwoChoice([`literal!("ab")`, `literal!("ac")`]) == `literalChoice2!("ab", "ac")`);
        assert(!frontend.firstTwoChoice([]).length);
        assert(!frontend.firstTwoChoice([`literal!("a")`]).length);
        auto excessive = new string[ubyte.max];
        excessive[] = `literal!("a")`;
        assert(!frontend.firstTwoChoice(excessive).length);
        foreach (unsupported; ["identifier", `literal!("a"`, `literal!("")`, `literal!("abcde")`])
            assert(!frontend.firstTwoChoice([`literal!("a")`, unsupported]).length);
        // L4: 3-4 byte literals use the trie walk.
        assert(frontend.firstTwoChoice([`literal!("<<=")`, `literal!("<")`]) == `literalChoiceK!("<<=", "<")`);
        assert(frontend.firstTwoChoice([`literal!("....")`, `literal!("...")`,
                `literal!(".")`]) == `literalChoiceK!("....", "...", ".")`);
        string[] choices;
        foreach (c; "abcdefghijklmnopq")
            choices ~= "literal!(\"" ~ c ~ "\")";
        assert(!frontend.firstTwoChoice(choices).length);
        choices.length = 16;
        assert(frontend.firstTwoChoice(choices).length != 0);
    }

    private string emitExpression(ref GrammarAnalysis graph, size_t index) nothrow {
        auto node = graph.expressions[index];
        if (!node.children.length)
            return node.source;
        string[] args;
        foreach (i, argument; node.arguments)
            args ~= i < node.children.length ? emitExpression(graph, node.children[i]) : argument;
        if (node.combinator == "or") {
            string[] factored;
            bool changed;
            for (size_t start; start < node.children.length;) {
                const first = node.children[start];
                auto branch = graph.expressions[first];
                const prefix = branch.combinator == "and" && branch.children.length ? branch.children[0] : first;
                size_t end = start + 1;
                if (graph.shareable(prefix)) {
                    while (end < node.children.length) {
                        const candidate = node.children[end];
                        auto other = graph.expressions[candidate];
                        const head = other.combinator == "and" && other.children.length ? other.children[0] : candidate;
                        if (graph.expressions[head].source != graph.expressions[prefix].source)
                            break;
                        ++end;
                    }
                }
                if (end == start + 1) {
                    factored ~= args[start];
                } else {
                    string tails = "or!(";
                    foreach (i; start .. end) {
                        auto alternative = graph.expressions[node.children[i]];
                        string tail = "discard!(eps)";
                        if (alternative.combinator == "and" && alternative.children.length > 1) {
                            tail = "and!(";
                            foreach (j, child; alternative.children[1 .. $])
                                tail ~= (j ? ", " : "") ~ emitExpression(graph, child);
                            tail ~= ")";
                        }
                        tails ~= (i == start ? "" : ", ") ~ tail;
                    }
                    tails ~= ")";
                    factored ~= "and!(" ~ emitExpression(graph, prefix) ~ ", " ~ optimizeRule(tails) ~ ")";
                    changed = true;
                }
                start = end;
            }
            if (changed) {
                if (factored.length == 1)
                    return factored[0];
                string choice = "or!(";
                foreach (i, branch; factored)
                    choice ~= (i ? ", " : "") ~ branch;
                return optimizeRule(choice ~ ")");
            }
            FirstFacts[] values;
            foreach (child; node.children)
                values ~= graph.facts[child];
            auto predicted = dispatchChoice(args, values);
            if (firstTwoEnabled()) {
                if (!predicted.length)
                    predicted = firstTwoChoice(args);
            }
            if (predicted.length)
                return predicted;
        }
        string result = node.combinator ~ "!(";
        foreach (i, arg; args)
            result ~= (i ? ", " : "") ~ arg;
        return result ~ ")";
    }

    nothrow unittest {
        Frontend frontend;
        assert(frontend.optimizeRule(`or!(and!(literal!("a"), literal!("b")), and!(literal!("a"), literal!("c")))`) == `and!(literal!("a"), predictiveChoice!(branch!(and!(literal!("b")), 0x0UL, 0x400000000UL, 0x0UL, 0x0UL), branch!(and!(literal!("c")), 0x0UL, 0x800000000UL, 0x0UL, 0x0UL)))`);
        assert(startsWith(frontend.optimizeRule(`or!(and!(literal!("a"), literal!("b")), literal!("a"))`),
                `and!(literal!("a"), predictiveChoice!(`));
        const separated = `or!(and!(literal!("a"), literal!("b")), literal!("x"), literal!("a"))`;
        assert(frontend.optimizeRule(separated) == separated);
        const effectful = `or!(and!(external, literal!("b")), and!(external, literal!("c")))`;
        assert(frontend.optimizeRule(effectful) == effectful);
    }

    string optimizeRule(string expression) nothrow {
        if (!hasAnalysis)
            prepareAnalysis();
        const saved = analyzed.expressions.length;
        scope (exit)
            analyzed.truncate(saved);
        auto root = expressionNode(analyzed, expression);
        analyzed.appendFacts(root);
        return emitExpression(analyzed, root);
    }

    void configureRecords(alias Selector)() nothrow {
        static if (!is(Selector == void)) {
            static assert(__traits(compiles, { uint function(string) @nogc nothrow pure fn = &Selector; }),
                    "Compact selectors must be pure @nogc nothrow uint functions");
            foreach (rule; rules)
                recordKinds ~= Selector(name ~ "." ~ rule.name);
            version (NPeggedPureIslands)
                static if (__traits(compiles, islandAnonymousSelection!Selector))
                    islandOmitAnonymous = islandAnonymousSelection!Selector == uint.max;
        }
    }

    /// Emit a small regular-expression graph; determinization happens in CTFE.
    private string regularTable(ref GrammarAnalysis graph, size_t root, out size_t references) nothrow {
        bool hasRecords;
        return regularTable(graph, root, references, hasRecords);
    }

    private string regularTable(ref GrammarAnalysis graph, size_t root, out size_t references, out bool hasRecords) nothrow {
        bool tagged;
        string members;
        return regularTable(graph, root, references, hasRecords, tagged, members);
    }

    /// `tagged`: every record the region's rules emit is a compiled leaf, so the region can produce them itself (O4);
    /// `members` then holds the extra members of the generated `_dfa_` struct that build the tagged table.
    private string regularTable(ref GrammarAnalysis graph, size_t root, out size_t references,
            out bool hasRecords, out bool tagged, out string members) nothrow {
        references = 0;
        hasRecords = false;
        tagged = false;
        members = null;
        bool taggable = true;
        GrammarAnalysis* regular = &graph;
        GrammarAnalysis stripped;
        bool requireEnd;
        auto rootNode = graph.expressions[root];
        if (rootNode.combinator == "and" && rootNode.children.length) {
            const last = graph.expressions[rootNode.children[$ - 1]].source;
            if (last == "eoi" || last == "endOfInput") {
                Expression strippedNode = rootNode;
                strippedNode.children = rootNode.children[0 .. $ - 1].dup;
                root = graph.appendExpression(strippedNode);
                graph.appendFacts(root);
                requireEnd = true;
            }
        }
        if (!regular.regularLeaf(root, requireEnd))
            return null;
        RegularExpression[] nodes;
        size_t lower(size_t index, size_t depth = 0) {
            auto expression = regular.expressions[index];
            if (expression.kind == ExpressionKind.reference) {
                const targetRule = graph.referenceRule(expression);
                bool leaf;
                if (recordKinds.length == 0) {
                    hasRecords = true;
                    taggable = false;
                } else if (targetRule < recordKinds.length && (recordKinds[targetRule] != uint.max
                        || (targetRule < recordSubtrees.length && recordSubtrees[targetRule]))) {
                    hasRecords = true;
                    leaf = recordKinds[targetRule] != uint.max && targetRule < recordLeaves.length
                        && recordLeaves[targetRule];
                    taggable = taggable && leaf;
                }
                if (depth + 1 > references)
                    references = depth + 1;
                if (!leaf)
                    return lower(graph.roots[targetRule], depth + 1);
                // A compiled leaf: remember where it starts, and finish the record where its body ends.
                const open = nodes.length;
                nodes ~= RegularExpression(RegularKind.mark, CharSetMask([0, 0, 0, 0]));
                const 
                body = lower(graph.roots[targetRule], depth + 1);
                const close = nodes.length;
                nodes ~= RegularExpression(RegularKind.mark,
                        CharSetMask([cast(ulong)recordKinds[targetRule] + 1, 0, 0, 0]));
                nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, [
                    open, body, close
                ]);
                return nodes.length - 1;
            }
            const escaped = regular.escapeLoop(index);
            if (escaped.known) {
                size_t prefix;
                if (escaped.doubled) {
                    prefix = nodes.length;
                    nodes ~= RegularExpression(RegularKind.bytes, regular.expressions[escaped.prefix].first);
                } else
                    prefix = lower(escaped.prefix, depth);
                const any = nodes.length;
                nodes ~= RegularExpression(RegularKind.bytes, escaped.doubled
                        ? regular.expressions[escaped.prefix].first : CharSetMask([
                            ulong.max, ulong.max, ulong.max, ulong.max
                ]));
                const pair = nodes.length;
                nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, [prefix, any]);
                CharSetMask ordinary, fallback;
                foreach (i; 0 .. 4) {
                    const first = regular.expressions[escaped.prefix].first.bits[i];
                    const bytes = regular.expressions[escaped.ordinary].first.bits[i];
                    ordinary.bits[i] = bytes & ~first;
                    fallback.bits[i] = bytes & first;
                }
                const ordinaryByte = nodes.length;
                nodes ~= RegularExpression(RegularKind.bytes, ordinary);
                size_t[] alternatives = [pair, ordinaryByte];
                if (!fallback.empty) {
                    const lastByte = nodes.length;
                    nodes ~= RegularExpression(RegularKind.bytes, fallback);
                    const end = nodes.length;
                    nodes ~= RegularExpression(RegularKind.endOfInput);
                    const last = nodes.length;
                    nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, [
                        lastByte, end
                    ]);
                    alternatives ~= last;
                }
                const choice = nodes.length;
                nodes ~= RegularExpression(RegularKind.choice, CharSetMask.init, alternatives);
                const repeated = nodes.length;
                nodes ~= RegularExpression(RegularKind.repetition, CharSetMask.init, [choice]);
                if (expression.combinator == "oneOrMore") {
                    nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, [
                        choice, repeated
                    ]);
                    return nodes.length - 1;
                }
                return repeated;
            }
            string[] munch;
            if (regular.maximalMunch(index, munch)) {
                // X2: a maximal-munch token is a trie whose nodes may stop only when no extension follows.
                size_t trie(string prefix) {
                    size_t[] alternatives;
                    CharSetMask extensions;
                    bool[256] seen;
                    bool terminal;
                    foreach (literal; munch) {
                        if (literal == prefix)
                            terminal = true;
                        if (literal.length > prefix.length && literal[0 .. prefix.length] == prefix
                                && !seen[cast(ubyte)literal[prefix.length]]) {
                            const next = cast(ubyte)literal[prefix.length];
                            seen[next] = true;
                            extensions.addChar(next);
                            CharSetMask byteMask;
                            byteMask.addChar(next);
                            const byteNode = nodes.length;
                            nodes ~= RegularExpression(RegularKind.bytes, byteMask);
                            const rest = trie(prefix ~ cast(char)next);
                            nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, [
                                byteNode, rest
                            ]);
                            alternatives ~= nodes.length - 1;
                        }
                    }
                    if (terminal) {
                        if (extensions.empty)
                            nodes ~= RegularExpression(RegularKind.sequence, CharSetMask.init, null);
                        else
                            nodes ~= RegularExpression(RegularKind.guard, extensions);
                        alternatives ~= nodes.length - 1;
                    }
                    if (alternatives.length == 1)
                        return alternatives[0];
                    nodes ~= RegularExpression(RegularKind.choice, CharSetMask.init, alternatives);
                    return nodes.length - 1;
                }

                return trie("");
            }
            RegularExpression node;
            if (expression.kind == ExpressionKind.terminal) {
                if (startsWith(expression.source, "literal!")) {
                    node.kind = RegularKind.sequence;
                    foreach (c; decodedLiteral(expression.source)) {
                        CharSetMask mask;
                        mask.addChar(c);
                        node.children ~= nodes.length;
                        nodes ~= RegularExpression(RegularKind.bytes, mask);
                    }
                } else if (expression.source == "eps")
                    node.kind = RegularKind.sequence;
                else {
                    node.kind = RegularKind.bytes;
                    node.bytes = expression.first;
                }
            } else {
                foreach (child; expression.children)
                    node.children ~= lower(child, depth);
                if (expression.combinator == "or" || expression.combinator == "predictiveChoice")
                    node.kind = RegularKind.choice;
                else if (expression.combinator == "option")
                    node.kind = RegularKind.optional;
                else if (expression.combinator == "zeroOrMore")
                    node.kind = RegularKind.repetition;
                else if (expression.combinator == "oneOrMore") {
                    const child = node.children[0];
                    const repeated = nodes.length;
                    nodes ~= RegularExpression(RegularKind.repetition, CharSetMask.init, [child]);
                    node.children = [child, repeated];
                    node.kind = RegularKind.sequence;
                } else
                    node.kind = RegularKind.sequence;
            }
            nodes ~= node;
            return nodes.length - 1;
        }

        const index = lower(root);
        bool repeated, marked;
        foreach (node; nodes) {
            repeated = repeated || node.kind == RegularKind.repetition;
            marked = marked || node.kind == RegularKind.mark;
        }
        // Fixed terminals already use inlined literal/byte matching. A state
        // machine is useful here when it replaces a character-processing loop.
        if (!repeated)
            return null;
        string source = "[\n";
        foreach (i, node; nodes) {
            if (node.kind == RegularKind.bytes) {
                source ~= "regularByte(";
                foreach (j, bits; node.bytes.bits)
                    source ~= (j ? ", " : "") ~ ulongHex(bits);
                source ~= ")";
            } else if (node.kind == RegularKind.mark)
                source ~= "regularMark(" ~ number(cast(size_t)node.bytes.bits[0]) ~ ")";
            else if (node.kind == RegularKind.guard) {
                source ~= "regularGuard(";
                foreach (j, bits; node.bytes.bits)
                    source ~= (j ? ", " : "") ~ ulongHex(bits);
                source ~= ")";
            } else {
                const kind = ["bytes", "sequence", "choice", "optional", "repetition", "endOfInput"][node.kind];
                source ~= "regularNode(RegularKind." ~ kind ~ ", [";
                foreach (j, child; node.children)
                    source ~= (j ? ", " : "") ~ number(child);
                source ~= "])";
            }
            source ~= ", // node " ~ number(i) ~ "\n";
        }
        const flag = requireEnd ? "true" : "false";
        tagged = hasRecords && taggable && marked && !walkRecordRegions;
        if (tagged) {
            members = "enum nodes = " ~ source ~ "]; enum tagged = compileTaggedDFA(nodes, " ~ number(
                    index) ~ ", " ~ flag ~ "); ";
            return "compileDFA(nodes, " ~ number(index) ~ ", " ~ flag ~ ")";
        }
        return "compileDFA(" ~ source ~ "], " ~ number(index) ~ ", " ~ flag ~ ")";
    }

    nothrow unittest {
        Frontend frontend;
        frontend.input = `Regular: Token <- [0-9]+ Unsafe <- 'a'* 'a'
            Class <- '[' '^'? ('\\' . / (!']' .))* ']'
            PlainEscapes <- ('\\' . / 'a')*`;
        frontend.read();
        frontend.prepareAnalysis();
        size_t references;
        assert(startsWith(frontend.regularTable(frontend.analyzed, frontend.analyzed.roots[0],
                references), "compileDFA(["));
        assert(frontend.regularTable(frontend.analyzed, frontend.analyzed.roots[1], references) is null);
        assert(frontend.regularTable(frontend.analyzed, frontend.analyzed.roots[2], references).length);
        assert(frontend.regularTable(frontend.analyzed, frontend.analyzed.roots[3], references).length);
        assert(frontend.emit().length);
    }

    /// O4: a region whose rules emit only compiled leaf records gets a tagged table; anything else is walked.
    nothrow unittest {
        static uint leafField(string name) @nogc nothrow pure {
            return name == "T.Field" ? 5 : uint.max;
        }

        static uint nested(string name) @nogc nothrow pure {
            return name == "T.Field" ? 5 : name == "T.Inner" ? 6 : uint.max;
        }

        enum text = "T: Root <- Field (',' Field)* eoi Field <- Inner* Inner <- [a-z]";
        const tagged = grammar!(Memoization.selective, leafField, ParserBackend.direct)(text);
        assert(countOf(tagged, "struct _dfa_Root { enum nodes") == 1 && countOf(tagged, ", 2)") >= 1);
        assert(countOf(tagged, "static if ( _dfa_Root.tagged.valid)") >= 1);
        // The test hook and a grammar without a compile-time selector both keep walking the region.
        const walked = grammar!(Memoization.selective, leafField, ParserBackend.direct, false)(text);
        assert(countOf(walked, "compileTaggedDFA") == 0);
        assert(countOf(grammar!(Memoization.selective, void, ParserBackend.direct)(text), "compileTaggedDFA") == 0);
        // Field contains a selected rule, so it is no compiled leaf: only the region inside Field is tagged.
        const inner = grammar!(Memoization.selective, nested, ParserBackend.direct)(text);
        assert(countOf(inner, "struct _dfa_Root { enum nodes") == 0 && countOf(inner, "compileTaggedDFA") >= 1);
        // An unselected rule inside the region is transparent.
        enum transparent = "T: Root <- Field (Sep Field)* eoi Sep <- ',' Field <- [a-z]*";
        assert(countOf(grammar!(Memoization.selective, leafField,
                ParserBackend.direct)(transparent), "struct _dfa_Root { enum nodes") == 1);
    }

    version (NPeggedScannerMetrics) {
        private bool scannerWholeRegular(ref GrammarAnalysis graph, size_t root) nothrow {
            const saved = graph.expressions.length;
            scope (exit)
                graph.truncate(saved);
            auto node = graph.expressions[root];
            bool anchored;
            if (node.combinator == "and" && node.children.length) {
                const last = graph.expressions[node.children[$ - 1]].source;
                if (last == "eoi" || last == "endOfInput") {
                    node.children = node.children[0 .. $ - 1].dup;
                    root = graph.appendExpression(node);
                    graph.appendFacts(root);
                    anchored = true;
                }
            }
            return graph.regularLeaf(root, anchored);
        }

        nothrow unittest {
            Frontend frontend;
            GrammarAnalysis graph;
            foreach (text; [
                "literal!(\"a\")", "and!(oneOrMore!(literal!(\"a\")), eoi)",
                "and!(oneOrMore!(literal!(\"a\")), endOfInput)"
            ]) {
                auto root = frontend.expressionNode(graph, text);
                graph.appendFacts(root);
                assert(frontend.scannerWholeRegular(graph, root));
            }
            auto root = frontend.expressionNode(graph, "and!(zeroOrMore!(literal!(\"a\")), literal!(\"a\"))");
            graph.appendFacts(root);
            assert(!frontend.scannerWholeRegular(graph, root));
        }
    }

    /// Compile maximal eligible regions even when their enclosing rule is not regular.
    private string emitTokens(ref GrammarAnalysis graph, size_t index, string rule, ref size_t count,
            ref string declarations) nothrow {
        auto node = graph.expressions[index];
        if (node.combinator == "negLookahead" && node.children.length == 1 && !graph.conservative) {
            auto facts = graph.facts[node.children[0]];
            if (facts.known && (facts.nullable == Nullable.no || facts.eofOnly)) {
                string result = "predictiveNot!(" ~ emitTokens(graph, node.children[0], rule, count, declarations);
                foreach (bits; facts.first.bits)
                    result ~= ", " ~ ulongHex(bits);
                return result ~ ")";
            }
        }
        if (node.children.length && node.kind != ExpressionKind.reference && node.combinator != "branch") {
            size_t referenceDepth;
            bool hasRecords, tagged;
            string members;
            const table = regularTable(graph, index, referenceDepth, hasRecords, tagged, members);
            if (table.length) {
                const symbol = "_dfa_" ~ rule ~ (count ? "_" ~ number(count) : "");
                ++count;
                declarations ~= "struct " ~ symbol ~ " { " ~ members ~ "enum automaton = " ~ table
                    ~ "; enum valid = automaton.valid; enum requireEnd = automaton.requireEnd;";
                version (NPeggedScannerMetrics)
                    declarations ~= " enum diagnosticName = " ~ quoted(name ~ "." ~ rule ~ "/" ~ symbol) ~ ";";
                declarations ~= " }\n";
                return "dfaToken!(" ~ emitExpression(graph,
                        index) ~ ", " ~ symbol ~ ", " ~ number(referenceDepth) ~ ", " ~ (tagged
                        ? "2" : hasRecords ? "true" : "false") ~ ")";
            }
        }
        // Merge adjacent regular children before falling back to nonregular syntax.
        // A trailing comment/recursive rule must not split a lexical header into
        // several separate scanners. Each region independently proves PEG equivalence.
        if (node.combinator == "and" && node.children.length > 2) {
            string[] regions;
            for (size_t start; start < node.children.length;) {
                size_t selected = start + 1;
                string selectedTable;
                size_t selectedDepth;
                bool selectedRecords;
                foreach (end; start + 2 .. node.children.length + 1) {
                    if (end - start > 64)
                        break;
                    if (end == start + 2 && (!closedEmpty(graph, node.children[start])
                            || !graph.regularLeaf(node.children[start])))
                        break;
                    if (!closedEmpty(graph, node.children[end - 1]) || !graph.regularLeaf(node.children[end - 1]))
                        break;
                    Expression region;
                    region.kind = ExpressionKind.sequence;
                    region.combinator = "and";
                    region.children = node.children[start .. end].dup;
                    region.source = "and!(";
                    foreach (i, child; region.children) {
                        const text = graph.expressions[child].source;
                        region.arguments ~= text;
                        region.source ~= (i ? ", " : "") ~ text;
                    }
                    region.source ~= ")";
                    const savedRegion = graph.expressions.length;
                    const root = graph.appendExpression(region);
                    graph.appendFacts(root);
                    size_t referenceDepth;
                    bool hasRecords;
                    const table = regularTable(graph, root, referenceDepth, hasRecords);
                    graph.truncate(savedRegion);
                    // Closed terminal regions have identical scanning policies in
                    // recognition and record modes; named calls retain rule budgets.
                    if (!table.length || referenceDepth || hasRecords)
                        break;
                    selected = end;
                    selectedTable = table;
                    selectedDepth = referenceDepth;
                    selectedRecords = hasRecords;
                }
                if (selected == start + 1) {
                    regions ~= emitTokens(graph, node.children[start], rule, count, declarations);
                } else {
                    const symbol = "_dfa_" ~ rule ~ (count ? "_" ~ number(count) : "");
                    ++count;
                    declarations ~= "struct " ~ symbol ~ " { enum automaton = " ~ selectedTable
                        ~ "; enum valid = automaton.valid; enum requireEnd = automaton.requireEnd;";
                    version (NPeggedScannerMetrics)
                        declarations ~= " enum diagnosticName = " ~ quoted(name ~ "." ~ rule ~ "/" ~ symbol) ~ ";";
                    declarations ~= " }\n";
                    string original = "and!(";
                    foreach (i, child; node.children[start .. selected])
                        original ~= (i ? ", " : "") ~ emitExpression(graph, child);
                    regions ~= "dfaToken!(" ~ original ~ "), " ~ symbol ~ ", " ~ number(
                            selectedDepth) ~ ", " ~ (selectedRecords ? "true" : "false") ~ ")";
                }
                start = selected;
            }
            string result = "and!(";
            foreach (i, region; regions)
                result ~= (i ? ", " : "") ~ region;
            return result ~ ")";
        }
        if (!node.children.length)
            return node.source;
        string result = node.combinator ~ "!(";
        foreach (i, argument; node.arguments)
            result ~= (i ? ", " : "") ~ (i < node.children.length ? emitTokens(graph,
                    node.children[i], rule, count, declarations) : argument);
        return result ~ ")";
    }

    nothrow unittest {
        Frontend frontend;
        frontend.input = "Partial: Token <- 'a'* 'a'";
        frontend.read();
        frontend.prepareAnalysis();
        size_t count;
        string declarations;
        const string body = frontend.emitTokens(frontend.analyzed, frontend.analyzed.roots[0],
                "Token", count, declarations);
        assert(count == 1 && startsWith(body, "and!(dfaToken!("));
        assert(startsWith(declarations, "struct _dfa_Token { enum automaton = compileDFA(["));
    }

    /// Empty fast paths only compile closed expressions; opaque calls stay untouched.
    private bool closedEmpty(ref GrammarAnalysis graph, size_t index, size_t depth = 0) nothrow {
        auto node = graph.expressions[index];
        if (depth >= 64 || node.kind == ExpressionKind.reference || node.kind == ExpressionKind.unknown)
            return false;
        foreach (child; node.children)
            if (!closedEmpty(graph, child, depth + 1))
                return false;
        return true;
    }

    nothrow unittest {
        Frontend frontend;
        GrammarAnalysis graph;
        auto root = frontend.expressionNode(graph, "zeroOrMore!(literal!(\"a\"))");
        assert(frontend.closedEmpty(graph, root));
        assert(!frontend.closedEmpty(graph, root, 64));
        root = frontend.expressionNode(graph, "and!(literal!(\"a\"), externalParser)");
        assert(!frontend.closedEmpty(graph, root));
    }

    /// 0: unknown/possibly consumes, 1: zero-width success, 2: zero-width failure.
    /// Reachable predicates are deliberately unknown; they may inspect a suffix.
    private int zeroMatch(ref GrammarAnalysis graph, size_t index, int byteValue, size_t depth = 0) nothrow {
        if (depth >= 64)
            return 0;
        auto node = graph.expressions[index];
        const op = node.combinator;
        if (op == "and") {
            foreach (child; node.children) {
                const result = zeroMatch(graph, child, byteValue, depth + 1);
                if (result != 1)
                    return result;
            }
            return 1;
        }
        if (op == "or") {
            foreach (child; node.children) {
                const result = zeroMatch(graph, child, byteValue, depth + 1);
                if (result != 2)
                    return result;
            }
            return 2;
        }
        if (op == "predictiveChoice") {
            if (!node.children.length)
                return 2;
            foreach (branch; node.children)
                if (byteValue < 256 && graph.facts[branch].first.contains(cast(ubyte)byteValue))
                    return 0;
            const last = node.children[$ - 1];
            return graph.facts[last].nullable == Nullable.yes ? zeroMatch(graph, last, byteValue, depth + 1) : 2;
        }
        if (op == "zeroOrMore" || op == "option" || op == "oneOrMore") {
            const result = zeroMatch(graph, node.children[0], byteValue, depth + 1);
            return result == 2 && op != "oneOrMore" ? 1 : result;
        }
        if (op == "discard" || op == "fuse" || op == "keep" || op == "drop" || op == "propagate"
                || op == "named" || op == "defined" || op == "dfaToken" || op == "branch")
            return zeroMatch(graph, node.children[0], byteValue, depth + 1);
        if (node.kind != ExpressionKind.terminal)
            return 0;
        if (node.source == "eps" || startsWith(node.source, "literal!(") && node.byteWidth == 0)
            return 1;
        if (node.source == "eoi" || node.source == "endOfInput")
            return byteValue == 256 ? 1 : 2;
        if (node.source == "fail")
            return 2;
        if (node.byteTerminal && (byteValue == 256 || !node.first.contains(cast(ubyte)byteValue)))
            return 2;
        return 0;
    }

    nothrow unittest {
        Frontend frontend;
        GrammarAnalysis graph;
        foreach (source; [
            "and!(zeroOrMore!(literal!(\"a\")), option!(literal!(\"b\")))",
            "or!(literal!(\"a\"), eps)", "oneOrMore!(eps)", "fuse!(zeroOrMore!(literal!(\"a\")))",
            "discard!(eps)", "keep!(eps)", "drop!(eps)", "propagate!(eps)", "named!(eps, \"x\")",
            "defined!(eps, \"x\")",
        ]) {
            const root = frontend.expressionNode(graph, source);
            graph.appendFacts(root);
            assert(frontend.zeroMatch(graph, root, 'x') == 1);
        }
        foreach (source; [
            "and!(literal!(\"a\"), eps)", "or!(literal!(\"a\"), literal!(\"b\"))",
            "oneOrMore!(literal!(\"a\"))", "fail", "eoi"
        ]) {
            const root = frontend.expressionNode(graph, source);
            graph.appendFacts(root);
            assert(frontend.zeroMatch(graph, root, 'x') == 2);
        }
        const literalRoot = frontend.expressionNode(graph, "literal!(\"x\")");
        assert(frontend.zeroMatch(graph, literalRoot, 'x') == 0);
        assert(frontend.zeroMatch(graph, literalRoot, 'x', 64) == 0);
        const end = frontend.expressionNode(graph, "eoi");
        assert(frontend.zeroMatch(graph, end, 256) == 1);
        const endInput = frontend.expressionNode(graph, "endOfInput");
        assert(frontend.zeroMatch(graph, endInput, 256) == 1);
        assert(frontend.zeroMatch(graph, endInput, 'x') == 2);
        const emptyLit = frontend.expressionNode(graph, "literal!(\"\")");
        assert(frontend.zeroMatch(graph, emptyLit, 'x') == 1);
        const dfaNode = frontend.expressionNode(graph, "dfaToken!(eps, _dfa, 0, false)");
        assert(frontend.zeroMatch(graph, dfaNode, 'x') == 1);
        const branchNode = frontend.expressionNode(graph, "branch!(eps, 0UL, 0UL, 0UL, 0UL, true)");
        assert(frontend.zeroMatch(graph, branchNode, 'x') == 1);
        const predChoice = frontend.expressionNode(graph, "predictiveChoice!(branch!(literal!(\"a\"), 0UL, 0x2UL, 0UL, 0UL, false), branch!(eps, 0UL, 0UL, 0UL, 0UL, true))");
        graph.appendFacts(predChoice);
        assert(frontend.zeroMatch(graph, predChoice, 'a') == 0);
        assert(frontend.zeroMatch(graph, predChoice, 'z') == 1);
        const predFail = frontend.expressionNode(graph, "predictiveChoice!(branch!(literal!(\"a\"), 0UL, 0x2UL, 0UL, 0UL, false), branch!(literal!(\"b\"), 0UL, 0x4UL, 0UL, 0UL, false))");
        graph.appendFacts(predFail);
        assert(frontend.zeroMatch(graph, predFail, 'z') == 2);
        const suffix = frontend.expressionNode(graph, "option!(negLookahead!(literal!(\"xy\")))");
        assert(frontend.zeroMatch(graph, suffix, 'x') == 0);
    }

    /// Probe the existing optimized expression at CTFE, then batch only proven
    /// zero-width paths. One spare work unit keeps DFA speculation off its budget edge.
    private string emitEmpty(ref GrammarAnalysis graph, size_t root, string rule, out string guard,
            int outputMode, string position = "p", string complete = "return true;") nothrow {
        guard = null;
        auto facts = graph.facts[root];
        if (!facts.known || facts.nullable != Nullable.yes
                || graph.expressions[root].source.length > 16384 || !closedEmpty(graph, root))
            return null;
        int outside;
        while (outside < 256 && facts.first.contains(cast(ubyte)outside))
            ++outside;
        const ordinary = outside < 256 && zeroMatch(graph, root, outside) == 1;
        const atEnd = zeroMatch(graph, root, 256) == 1;
        if (!ordinary && !atEnd)
            return null;
        const type = "_Empty_" ~ rule ~ "_" ~ number(outputMode);
        string declarations = "private struct " ~ type ~ " { size_t cost; bool diagnostic, valid; }\n";
        foreach (eof; [false, true]) {
            const symbol = "_empty_" ~ rule ~ "_" ~ number(outputMode) ~ (eof ? "_eof" : "_byte");
            const eligible = eof ? atEnd : ordinary;
            declarations ~= "private enum " ~ symbol ~ " = ";
            if (!eligible)
                declarations ~= type ~ ".init;\n";
            else {
                declarations ~= "() { State!(true, " ~ number(outputMode) ~ ") state; " ~ (outputMode == 2 ? "import npegged.records : RecordBuffer; Arena owner; state.arena = &owner; RecordBuffer output; output.arena = &owner; state.attachRecords(output); " : "") ~ "state.context.stepLimit = 65536; state.input = " ~ quoted(
                        eof ? "" : [cast(char)outside].idup) ~ "; auto matched = " ~ graph.expressions[root].source ~ "(state, 0); auto failure = state.checkpointFailure(); return " ~ type ~ "(state.steps, failure.present, state.status == Status.ok && matched.successful" ~ " && matched.end == 0 && matched.failEnd == 0 && (!failure.present || failure.failEnd == 0)); }();\n";
            }
            guard ~= "static if (" ~ symbol ~ ".valid && " ~ symbol ~ ".cost >= " ~ number(
                    emptyCostThreshold) ~ ") { if (_live" ~ " && s.context.trace is null && " ~ position ~ " " ~ (eof
                    ? "==" : "<") ~ " s.input.length";
            if (!eof)
                guard ~= " && !CharSetMask([" ~ ulongHex(facts.first.bits[0]) ~ ", " ~ ulongHex(
                        facts.first.bits[1]) ~ ", " ~ ulongHex(facts.first.bits[2]) ~ ", " ~ ulongHex(
                        facts.first.bits[3]) ~ "]).contains(cast(ubyte)s.input[" ~ position ~ "])";
            guard ~= " && _steps < _limit && _limit - _steps > " ~ symbol ~ ".cost) { _steps += " ~ symbol ~ ".cost; " ~ (
                    acceptActive ? "" : "static if (" ~ symbol ~ ".diagnostic) s.recordFailure(s.node("
                    ~ position ~ ", " ~ position ~ ", false)); ") ~ complete ~ " } }\n";
        }
        return declarations;
    }

    nothrow unittest {
        Frontend frontend;
        GrammarAnalysis graph;
        string guard;
        const empty = frontend.expressionNode(graph,
                "and!(zeroOrMore!(literal!(\" \")), zeroOrMore!(and!(literal!(\"#\"), zeroOrMore!(any))))");
        graph.appendFacts(empty);
        auto source = frontend.emitEmpty(graph, empty, "Probe", guard, 2);
        assert(startsWith(source, "private struct _Empty_Probe_2"));
        assert(guard.length);
        const any = frontend.expressionNode(graph, "option!(any)");
        graph.appendFacts(any);
        assert(frontend.emitEmpty(graph, any, "ProbeAny", guard, 1).length);
        const predicate = frontend.expressionNode(graph, "option!(negLookahead!(literal!(\"xy\")))");
        graph.appendFacts(predicate);
        assert(frontend.emitEmpty(graph, predicate, "ProbeSuffix", guard, 1) is null && guard is null);
        const required = frontend.expressionNode(graph, "literal!(\"x\")");
        graph.appendFacts(required);
        assert(frontend.emitEmpty(graph, required, "Required", guard, 1) is null);
        char[16384] large;
        large[] = 'a';
        const oversized = frontend.expressionNode(graph, "zeroOrMore!(literal!(" ~ quoted(cast(string)large[]) ~ "))");
        graph.appendFacts(oversized);
        assert(frontend.emitEmpty(graph, oversized, "Large", guard, 1) is null);
    }

    /// Cursors with fewer tick sites than this keep the shared-memory step counter: the register copies cost more
    /// (three loads and a store per call) than they save when a rule ticks only a few times.
    enum localStepSites = 1;

    /// A failure diagnostic statement, omitted from the `accept` clone.
    private string diagnostic(string statement) const nothrow {
        return acceptActive ? "" : statement;
    }

    /// Cursor name prefix of the current clone.
    private string cursorName() const nothrow {
        return acceptActive ? "_acursor_" : "_cursor_";
    }

    /// Cursors that never tick but test liveness this often also keep it in a register.
    enum localLiveSites = 4;

    /// Minimum work units an empty path must charge before the FIRST-set shortcut replaces evaluating the expression.
    enum emptyCostThreshold = 1;

    private static size_t countOf(string text, string needle) nothrow {
        size_t count;
        for (size_t i; i + needle.length <= text.length; ++i)
            if (text[i .. i + needle.length] == needle)
                ++count;
        return count;
    }

    private static string replaceAll(string text, string from, string to) nothrow {
        string result;
        size_t i;
        while (i < text.length) {
            if (i + from.length <= text.length && text[i .. i + from.length] == from) {
                result ~= to;
                i += from.length;
            } else
                result ~= text[i++];
        }
        return result;
    }

    /// The same cursor body with `steps`/`status` accessed in the shared state (what the code did before S1).
    private static string withSharedSteps(string code) nothrow {
        code = replaceAll(code, ".cursorAccept(s, ", ".cursorShared(s, ");
        code = replaceAll(code, ".cursor(s, ", ".cursorShared(s, ");
        code = replaceAll(code, ", _steps, _live, _depth, ", ", _depth, ");
        code = replaceAll(code, "s.steps = _steps; ", "");
        code = replaceAll(code, " _steps = s.steps; _live = s.status == Status.ok;", "");
        code = replaceAll(code, "_steps = s.steps; _live = s.status == Status.ok;", "");
        code = replaceAll(code, "_tick()", "s.tick()");
        code = replaceAll(code, "!_live", "s.status != Status.ok");
        code = replaceAll(code, "_live", "s.status == Status.ok");
        code = replaceAll(code, "_depthLimit", "s.context.depthLimit");
        code = replaceAll(code, "_limit", "s.context.stepLimit");
        return replaceAll(code, "_steps", "s.steps");
    }

    /// Step accounting held in locals inside a cursor function (register resident). `s.steps` and `s.status` are
    /// synchronized around every call that can tick (rules, scanners, combinators) and written back on exit,
    /// so the work-unit count and resource-limit behavior stay exactly those of `State.tick`.
    enum llLocals = "size_t _steps = s.steps; const size_t _limit = s.context.stepLimit; const size_t _depthLimit = s.context.depthLimit; bool _live = s.status == Status.ok;\n" ~ "pragma(inline, true) bool _tick() @nogc nothrow { if (!_live) return false; if (_steps >= _limit) { s.status = Status.resourceLimit; _live = false; return false; } ++_steps; return true; }\n";

    /// L3: is the rule being emitted in a region the cheap FIRST/FOLLOW certifier accepts? Computed once, on first
    /// need. (The full L1 classification is too slow under CTFE; the cheap test certifies a subset of it.)
    private bool llRuleCertified() nothrow {
        if (!llComputed) {
            llComputed = true;
            llCertified = firstCertifiedRules(analyzed);
        }
        return llRule < llCertified.length && llCertified[llRule];
    }

    /// L3: nonzero when the direct form of `body` provably charges no work unit and records a single failure at its
    /// start when the next byte is outside FIRST(body) (work-unit model v2: sequences, terminals and predictive choices
    /// are free), or 0 when that is not statically known. Only nonnullable bodies with a known FIRST set qualify.
    private size_t llGuardTicks(ref GrammarAnalysis graph, size_t body) nothrow {
        if (body >= graph.facts.length || !graph.facts[body].known
                || graph.facts[body].nullable != Nullable.no || graph.facts[body].first.empty)
            return 0;
        auto node = graph.expressions[body];
        if (node.combinator != "and" || node.children.length < 2)
            return 0;
        auto first = graph.expressions[node.children[0]];
        if (startsWith(first.source, "literal!(") && decodedLiteral(first.source).length)
            return 2;
        if (first.byteTerminal && first.byteWidth == 1 && (first.source == "any"
                || first.source == "digit" || first.source == "alpha" || first.source == "Alpha"
                || first.source == "hexDigit" || startsWith(first.source, "charClass!(")
                || startsWith(first.source, "charRange!(")))
            return 2;
        if (first.combinator == "predictiveChoice") {
            foreach (child; first.children) {
                const args = graph.expressions[child].arguments;
                string nullable = args.length == 6 ? args[5] : null;
                while (nullable.length && (nullable[0] == ' ' || nullable[0] == '\t'))
                    nullable = nullable[1 .. $];
                if (nullable == "true")
                    return 0;
            }
            return 2;
        }
        return 0;
    }

    /// Lower rule-local recognition control flow without intermediate aggregate results.
    /// Terminals, scanners, predicates and unsupported operators retain their contracts.
    /// P8: a directly left-recursive rule `E <- E S1 / .. / E Sk / B1 / .. / Bm` (suffixes first, suffixes consume, bases
    /// never lead back to E) recognizes the same inputs as `E <- (B1 / .. / Bm) (S1 / .. / Sk)*`: seed growth tries the
    /// suffix alternatives in order on the current seed and stops when none succeeds or none consumes. The `accept` clone uses
    /// the loop form; `check` and the record modes keep seed growth, whose work units and failure positions differ.
    package struct IterativeForm {
        bool ok;
        string blocker;
        string lowered; // `and!(base, zeroOrMore!(suffix))` in rule-body syntax
    }

    private IterativeForm iterativeForm(size_t rule) nothrow {
        IterativeForm form;
        if (rule >= analyzed.roots.length || !analyzed.leftRecursive[rule]) {
            form.blocker = "not-left-recursive";
            return form;
        }
        auto root = analyzed.expressions[analyzed.roots[rule]];
        if (root.combinator != "or" || root.children.length < 2) {
            form.blocker = "not-a-choice";
            return form;
        }
        string[] bases, suffixes;
        bool sawBase;
        foreach (child; root.children) {
            auto node = analyzed.expressions[child];
            const leadsToSelf = node.combinator == "and" && node.children.length >= 2
                && analyzed.expressions[node.children[0]].kind == ExpressionKind.reference
                && analyzed.referenceRule(analyzed.expressions[node.children[0]]) == rule;
            if (leadsToSelf) {
                if (sawBase) {
                    form.blocker = "suffix-after-base";
                    return form;
                }
                bool consumes;
                string rest;
                foreach (i, part; node.children[1 .. $]) {
                    consumes = consumes || analyzed.facts[part].nullable == Nullable.no;
                    rest ~= (i ? ", " : "") ~ analyzed.expressions[part].source;
                }
                if (!consumes) {
                    form.blocker = "nullable-suffix";
                    return form;
                }
                suffixes ~= node.children.length == 2 ? analyzed.expressions[node.children[1]].source
                    : "and!(" ~ rest ~ ")";
            } else {
                sawBase = true;
                auto seen = new bool[analyzed.roots.length];
                size_t[] pending = analyzed.leadingRules(child);
                while (pending.length) {
                    const at = pending[$ - 1];
                    pending.length -= 1;
                    if (at == rule) {
                        form.blocker = "base-leads-to-self";
                        return form;
                    }
                    if (at < seen.length && !seen[at]) {
                        seen[at] = true;
                        pending ~= analyzed.leftEdges[at];
                    }
                }
                bases ~= node.source;
            }
        }
        if (!suffixes.length || !bases.length) {
            form.blocker = "no-base-or-suffix";
            return form;
        }
        string join(string[] parts) nothrow {
            if (parts.length == 1)
                return parts[0];
            string result = "or!(";
            foreach (i, part; parts)
                result ~= (i ? ", " : "") ~ part;
            return result ~ ")";
        }

        form.ok = true;
        form.lowered = "and!(" ~ join(bases) ~ ", zeroOrMore!(" ~ join(suffixes) ~ "))";
        return form;
    }

    nothrow unittest {
        Frontend frontend;
        frontend.input = "P8: A <- A '+' B / B B <- 'b' C <- 'c' / C 'd' D <- D 'x' / D 'y' / 'z' E <- E ' '? 'q' / 'r' F <- F 'f' / G G <- F 'g' H <- H 'h' / H";
        frontend.read();
        frontend.prepareAnalysis();
        assert(frontend.iterativeForm(0).ok && frontend.iterativeForm(0)
                .lowered == `and!(B, zeroOrMore!(and!(literal!("+"), B)))`);
        assert(!frontend.iterativeForm(1).ok && frontend.iterativeForm(1).blocker == "not-left-recursive");
        assert(frontend.iterativeForm(2).blocker == "suffix-after-base");
        const several = frontend.iterativeForm(3);
        assert(several.ok && several.lowered == `and!(literal!("z"), zeroOrMore!(or!(literal!("x"), literal!("y"))))`);
        // A suffix that can succeed without consuming makes the loop form non-progressing: not lowered.
        assert(frontend.iterativeForm(4).ok);
        // Indirect left recursion through the base alternative is not lowered.
        assert(frontend.iterativeForm(5).blocker == "base-leads-to-self");
        assert(frontend.iterativeForm(7).blocker.length);
        // Only suffixes, no base alternative: nothing to start the loop from.
        Frontend suffixOnly;
        suffixOnly.input = "S: A <- A 'a' / A 'b'";
        suffixOnly.read();
        suffixOnly.prepareAnalysis();
        assert(!suffixOnly.iterativeForm(0).ok && suffixOnly.iterativeForm(0).blocker == "no-base-or-suffix");
    }

    /// O2: can evaluating `index` (direct cursor, records mode) leave records in the buffer?
    private bool mayEmitRecords(ref GrammarAnalysis graph, size_t index, size_t depth = 0) nothrow {
        if (depth >= 64 || index >= graph.expressions.length)
            return true;
        auto node = graph.expressions[index];
        if (node.kind == ExpressionKind.reference) {
            const target = graph.referenceRule(node);
            return target >= recordKinds.length || recordKinds[target] != uint.max
                || target >= recordSubtrees.length || recordSubtrees[target];
        }
        if (node.kind == ExpressionKind.unknown)
            return true;
        if (node.kind == ExpressionKind.terminal)
            return false;
        if (node.combinator == "dfaToken" && node.arguments.length == 4) {
            string inner = node.arguments[3];
            while (inner.length && (inner[0] == ' ' || inner[0] == '\t'))
                inner = inner[1 .. $];
            if (inner == "false")
                return false;
        }
        foreach (child; node.children)
            if (mayEmitRecords(graph, child, depth + 1))
                return true;
        return false;
    }

    /// O2: when `index` fails (or exhausts a limit), it provably leaves no record behind, so an enclosing loop
    /// needs neither the per-iteration checkpoint nor the rollback. Proven only for shapes whose failure is
    /// rolled back by their own rule boundary: a sequence whose single record-emitting child is its last one
    /// (nothing after it can fail or tick), choices all of whose arms qualify, loops (they roll back or elide
    /// their own iteration), and non-emitting expressions. Everything else keeps the checkpoint.
    private bool failureLeavesNoOutput(ref GrammarAnalysis graph, size_t index, size_t depth = 0) nothrow {
        if (depth >= 64 || index >= graph.expressions.length)
            return false;
        if (!mayEmitRecords(graph, index))
            return true;
        auto node = graph.expressions[index];
        if (node.kind == ExpressionKind.reference) {
            const target = graph.referenceRule(node);
            return target < scalarRules.length && scalarRules[target];
        }
        const op = node.combinator;
        if (op == "and") {
            foreach (i, child; node.children) {
                if (!mayEmitRecords(graph, child, depth + 1))
                    continue;
                return i + 1 == node.children.length && failureLeavesNoOutput(graph, child, depth + 1);
            }
            return true;
        }
        if (op == "or" || op == "predictiveChoice") {
            foreach (child; node.children)
                if (!failureLeavesNoOutput(graph, child, depth + 1))
                    return false;
            return true;
        }
        if (op == "branch" || op == "named" || op == "defined" || op == "keep" || op == "drop" || op == "propagate")
            return node.children.length == 1 && failureLeavesNoOutput(graph, node.children[0], depth + 1);
        if (op == "zeroOrMore" || op == "oneOrMore" || op == "option")
            return true;
        return false;
    }

    private string emitDirect(ref GrammarAnalysis graph, size_t index, string start, string target,
            ref size_t serial, size_t depth = 0, int outputMode = 1) nothrow {
        auto expression = graph.expressions[index];
        const position = "_p" ~ number(serial++);
        string code = "size_t " ~ target ~ "End = " ~ start ~ ", " ~ target ~ "Fail = " ~ start
            ~ "; bool " ~ target ~ "Ok = _live; { const size_t " ~ position ~ " = " ~ start ~ ";\n";
        const op = expression.combinator;
        const checkpoint = "_checkpoint" ~ number(serial++);
        if (outputMode == 2 && (op == "or" || op == "predictiveChoice"))
            code ~= "const size_t " ~ checkpoint ~ " = s.outputCheckpoint();\n";
        code ~= "do {\n";
        // Bound rule-local expansion, including duplicated nullable fallback arms.
        const lower = depth < 64 && serial < 2048;
        if (lower && index < graph.facts.length && (op == "and" || op == "or" || op == "predictiveChoice"
                || op == "zeroOrMore" || op == "oneOrMore" || op == "option")) {
            bool cheap;
            if ((op == "zeroOrMore" || op == "oneOrMore" || op == "option") && expression.children.length) {
                auto child = graph.expressions[expression.children[0]];
                cheap = child.kind == ExpressionKind.terminal && !child.children.length
                    && child.source != "space" && child.source != "blank";
            }
            if (!cheap) {
                string guard;
                const complete = target ~ "End = " ~ position ~ "; " ~ target ~ "Fail = " ~ position
                    ~ "; " ~ target ~ "Ok = true; break;";
                directDeclarations ~= emitEmpty(graph, index, directRule ~ position, guard,
                        outputMode, position, complete);
                code ~= guard;
            }
        }
        const reference = expression.kind == ExpressionKind.reference ? graph.referenceRule(expression) : size_t.max;
        if (reference < scalarRules.length && (acceptActive ? acceptRules[reference] : scalarRules[reference])) {
            string entry = "recognizeRule";
            string tag = ", false";
            if (outputMode == 2) {
                entry = "recognizeRecordedRule";
                tag = ", -1L";
                if (recordKinds.length) {
                    if (recordKinds[reference] != uint.max)
                        tag = ", " ~ number(cast(ulong)recordKinds[reference] | (recordLeaves[reference]
                                ? 1UL << 32 : 0UL)) ~ "L";
                    else
                        tag = recordSubtrees[reference] ? ", -2L" : ", -3L";
                }
            }
            if (entry == "recognizeRecordedRule" && tag == ", -3L") {
                // A rule without selected records is a plain rule boundary in records mode too.
                entry = "recognizeRule";
                tag = ", false";
            }
            if (entry == "recognizeRule") // Work unit and depth come from the registers (S2b, S5); cursors run only without trace.
                code ~= "if (!_tick()) { " ~ target ~ "Fail = " ~ target ~ "End; " ~ target ~ "Ok = false; } else if (_depth >= _depthLimit) { s.steps = _steps; s.status = Status.resourceLimit; _steps = s.steps; _live = s.status == Status.ok; " ~ target ~ "Fail = " ~ target ~ "End; " ~ target ~ "Ok = false; } else { s.steps = _steps; " ~ target ~ "Ok = " ~ cursorName() ~ expression
                    .reference ~ "(s, " ~ target ~ "End, " ~ target
                    ~ "Fail, _depth + 1); _steps = s.steps; _live = s.status == Status.ok; }\n";
            else
                code ~= "s.steps = _steps; s.depth = _depth; " ~ target ~ "Ok = s." ~ entry ~ "!(_cursor_"
                    ~ expression.reference ~ ", " ~ quoted(name ~ "." ~ expression.reference) ~ tag ~ ")(" ~ target
                    ~ "End, " ~ target ~ "Fail); _steps = s.steps; _live = s.status == Status.ok;\n";
        } else if (outputMode == 2 && op == "dfaToken" && expression.arguments.length == 4) {
            string innerRecords = expression.arguments[3];
            while (innerRecords.length && (innerRecords[0] == ' ' || innerRecords[0] == '\t'))
                innerRecords = innerRecords[1 .. $];
            const next = "_d" ~ number(serial++);
            if (innerRecords == "2") {
                // O4: the table writes the leaf records itself; where it is too large for a tagged table the region is walked.
                const walked = "_d" ~ number(serial++);
                code ~= "size_t " ~ next ~ "End, " ~ next ~ "Fail; bool " ~ next ~ "Ok;\nstatic if ("
                    ~ expression.arguments[1] ~ ".tagged.valid) { " ~ next ~ "Ok = " ~ expression.source ~ ".cursor(s, "
                    ~ position ~ ", _steps, _live, _depth, " ~ next ~ "End, " ~ next ~ "Fail); } else {\n" ~ emitDirect(
                            graph, expression.children[0], position, walked, serial, depth + 1, outputMode)
                    ~ next ~ "End = " ~ walked ~ "End; "
                    ~ next ~ "Fail = " ~ walked ~ "Fail; " ~ next ~ "Ok = " ~ walked ~ "Ok; }\n";
            } else if (innerRecords == "true") {
                code ~= emitDirect(graph, expression.children[0], position, next, serial, depth + 1, outputMode);
                version (NPeggedScannerMetrics) {
                    const event = "_scannerEvent" ~ number(serial++);
                    code ~= "if (!__ctfe && s.context.scannerReport !is null) { ScannerEvent "
                        ~ event ~ "; " ~ event ~ ".rule = scannerName!(" ~ expression.arguments[1]
                        ~ "); " ~ event ~ ".reason = ScannerReason.recordLowering; "
                        ~ event ~ ".original = true; " ~ event ~ ".originalBytes = (" ~ next ~ "End > "
                        ~ next ~ "Fail ? " ~ next ~ "End : " ~ next ~ "Fail) - "
                        ~ position ~ "; s.context.scannerReport.record(" ~ event ~ "); }\n";
                }
            } else
                code ~= "size_t " ~ next ~ "End, " ~ next ~ "Fail; const bool " ~ next ~ "Ok = " ~ expression.source
                    ~ ".cursor(s, " ~ position ~ ", _steps, _live, _depth, " ~ next ~ "End, " ~ next ~ "Fail);\n";
            if (innerRecords == "true")
                code ~= target ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = " ~ next ~ "Fail; " ~ target
                    ~ "Ok = " ~ next ~ "Ok;\n";
            else
                code ~= target ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = " ~ next ~ "Fail; " ~ target
                    ~ "Ok = " ~ next ~ "Ok;\n";
        } else if (outputMode != 2 && op == "dfaToken" && expression.arguments.length == 4) {
            const next = "_d" ~ number(serial++);
            code ~= "size_t " ~ next ~ "End, " ~ next ~ "Fail; const bool " ~ next ~ "Ok = " ~ expression.source ~ (
                    acceptActive ? ".cursorAccept(s, " : ".cursor(s, ") ~ position
                ~ ", _steps, _live, _depth, " ~ next ~ "End, " ~ next ~ "Fail);\n" ~ target
                ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = " ~ next ~ "Fail; " ~ target ~ "Ok = " ~ next ~ "Ok;\n";
        } else if (lower && (op == "discard" || op == "fuse" || op == "keep" || op == "drop"
                || op == "propagate" || op == "named" || op == "defined")) {
            const next = "_d" ~ number(serial++);
            const scanner = op == "discard" || op == "fuse";
            if (scanner)
                code ~= "static if (!__traits(hasMember, "
                    ~ graph.expressions[expression.children[0]].source ~ ", \"scan\")) {\n";
            code ~= emitDirect(graph, expression.children[0], position, next, serial, depth + 1, outputMode);
            code ~= target ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = " ~ next ~ "Fail; " ~ target
                ~ "Ok = " ~ next ~ "Ok;\n";
            if (scanner) {
                const scanned = "_scanned" ~ number(serial++);
                code ~= "} else { s.steps = _steps; s.depth = _depth; auto " ~ scanned ~ " = " ~ expression.source
                    ~ "(s, " ~ position ~ "); _steps = s.steps; _live = s.status == Status.ok; " ~ target
                    ~ "End = " ~ scanned ~ ".end; " ~ target ~ "Fail = " ~ scanned ~ ".failEnd; "
                    ~ target ~ "Ok = " ~ scanned ~ ".successful; }\n";
            }
        } else if (lower && op == "and") {
            foreach (child; expression.children) {
                const next = "_d" ~ number(serial++);
                code ~= "if (!_live) { " ~ target ~ "End = " ~ position ~ "; " ~ target ~ "Fail = "
                    ~ position ~ "; " ~ target ~ "Ok = false; break; }\n";
                code ~= emitDirect(graph, child, target ~ "End", next, serial, depth + 1, outputMode);
                code ~= "if (!" ~ next ~ "Ok) { " ~ target ~ "Ok = false; " ~ target ~ "Fail = " ~ next
                    ~ "Fail; break; } " ~ target ~ "End = " ~ next ~ "End;\n";
            }
        } else if (lower && (op == "posLookahead" || op == "negLookahead" || op == "predictiveNot")) {
            const next = "_d" ~ number(serial++);
            const saved = "_probe" ~ number(serial++);
            const nested = "_nested" ~ number(serial++);
            const failure = "_failure" ~ number(serial++);
            if (op == "predictiveNot") {
                const probe = "_not" ~ number(serial++);
                code ~= "alias " ~ probe ~ " = " ~ expression.source ~ "; if (s.context.trace is null && "
                    ~ position ~ " < s.input.length && !" ~ probe ~ ".mask.contains(cast(ubyte)s.input["
                    ~ position ~ "])) { " ~ target ~ "Ok = _live; break; }\n";
            }
            code ~= diagnostic("const " ~ saved ~ " = s.beginProbe();\n") ~ emitDirect(graph,
                    expression.children[0], position,
                    next, serial, depth + 1, outputMode) ~ diagnostic(
                    "const " ~ nested ~ " = s.finishProbe(" ~ saved ~ ");\n") ~ target ~ "Ok = (" ~ next ~ "Ok == " ~ (
                    op == "posLookahead" ? "true" : "false") ~ ") && _live; if (!" ~ target ~ "Ok) {\n";
            if (op == "posLookahead")
                code ~= target ~ "Fail = " ~ next ~ "Fail;" ~ diagnostic(" auto " ~ failure ~ " = s.node(" ~ position
                        ~ ", " ~ position ~ ", false); " ~ failure ~ ".failEnd = " ~ nested ~ ".present ? "
                        ~ nested ~ ".failEnd : " ~ next ~ "Fail; s.recordFailure(" ~ failure ~ ");") ~ "\n";
            else
                code ~= diagnostic("s.failure(" ~ position ~ ", \"negative lookahead\");") ~ "\n";
            code ~= "}\n";
        } else if (lower && op == "predictiveChoice") {
            const dispatch = "_choice" ~ number(serial++);
            code ~= "if (!_live) { " ~ target ~ "Ok = false; break; }\n" ~ "alias " ~ dispatch ~ " = "
                ~ expression.source ~ ";\n" ~ "const ubyte " ~ dispatch ~ "Selected = " ~ position
                ~ " < s.input.length ? " ~ dispatch ~ ".branchTable[cast(ubyte)s.input[" ~ position
                ~ "]] : cast(ubyte)" ~ dispatch ~ ".fallback; switch (" ~ dispatch ~ "Selected) {\n";
            foreach (i, branch; expression.children) {
                const next = "_d" ~ number(serial++);
                code ~= "case " ~ number(i + 1) ~ ": {\n";
                code ~= emitDirect(graph, graph.expressions[branch].children[0], position, next,
                        serial, depth + 1, outputMode);
                code ~= target ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = " ~ next ~ "Fail; " ~ target
                    ~ "Ok = " ~ next ~ "Ok;\n";
                const last = expression.children[$ - 1];
                const args = graph.expressions[last].arguments;
                string nullableArgument = args.length == 6 ? args[5] : null;
                while (nullableArgument.length && (nullableArgument[0] == ' ' || nullableArgument[0] == '\t'))
                    nullableArgument = nullableArgument[1 .. $];
                if (i + 1 != expression.children.length && nullableArgument == "true") {
                    const fallback = "_d" ~ number(serial++);
                    code ~= "if (!" ~ next ~ "Ok && _live) {\n" ~ (outputMode == 2
                            ? "s.rollbackOutput(" ~ checkpoint ~ ");\n" : "") ~ emitDirect(graph,
                            graph.expressions[last].children[0], position, fallback, serial, depth + 1, outputMode)
                        ~ target ~ "End = " ~ fallback ~ "End; " ~ target
                        ~ "Fail = " ~ fallback ~ "Fail; " ~ target ~ "Ok = " ~ fallback ~ "Ok; }\n";
                }
                code ~= "break; }\n";
            }
            if (acceptActive)
                code ~= "default: { " ~ target ~ "End = " ~ position ~ "; " ~ target ~ "Fail = "
                    ~ position ~ "; " ~ target ~ "Ok = false; break; } }\n";
            else
                code ~= "default: { auto failed = s.failure(" ~ position ~ ", \"choice\"); " ~ target
                    ~ "End = failed.end; " ~ target
                    ~ "Fail = failed.failEnd; " ~ target ~ "Ok = failed.successful; break; } }\n";
        } else if (lower && startsWith(expression.source, "literalChoice2!(") && expression.arguments.length >= 2) {
            // P3: the winner of an ordered choice of 1-2 byte literals is a function of the first two bytes (F4's
            // table), tested inline. Literals and choices charge no work units. A hit replays the failure the skipped
            // earlier alternatives record; a miss means every alternative failed, the furthest one after one matched
            // byte when some alternative starts with the input byte and at the position otherwise (checked
            // exhaustively against the ordered choice, including early stops by step limits).
            const choice = "_lc" ~ number(serial++);
            string lengths;
            foreach (i, argument; expression.arguments)
                lengths ~= (i ? ", " : "") ~ number(decodedLiteral("literal!(" ~ argument ~ ")").length);
            code ~= "alias " ~ choice ~ " = " ~ expression.source ~ ";\nenum size_t[" ~ number(
                    expression.arguments.length) ~ "] " ~ choice ~ "Length = [" ~ lengths ~ "];\nsize_t "
                ~ choice ~ "Miss;\nif (_live && " ~ position ~ " < s.input.length) { const "
                ~ choice ~ "Row = " ~ choice ~ ".plan.slot[cast(ubyte)s.input[" ~ position ~ "]]; if ("
                ~ choice ~ "Row) { const " ~ choice
                ~ "Second = " ~ position ~ " + 1 < s.input.length ? cast(int)cast(ubyte)s.input["
                ~ position ~ " + 1] : 256; const " ~ choice ~ "Winner = " ~ choice ~ ".plan.winner[" ~ choice ~ "Row - 1]["
                ~ choice ~ "Second]; if (" ~ choice ~ "Winner) { " ~ diagnostic(
                        "if (const " ~ choice ~ "Skipped = " ~ choice ~ ".plan.skip[" ~ choice ~ "Row - 1]["
                        ~ choice ~ "Second]) s.recordFailure(s.node(" ~ position ~ ", " ~ position
                        ~ " + " ~ choice ~ "Skipped - 1, false)); ") ~ target ~ "End = " ~ position
                ~ " + " ~ choice ~ "Length[" ~ choice ~ "Winner - 1]; "
                ~ target ~ "Fail = " ~ target ~ "End; break; } " ~ choice ~ "Miss = 1; } }\n";
            code ~= target ~ "Ok = false;";
            if (!acceptActive)
                code ~= " " ~ target ~ "Fail = " ~ position ~ " + " ~ choice ~ "Miss; if (_live) s.recordFailure(s.node("
                    ~ position ~ ", " ~ position ~ " + " ~ choice ~ "Miss, false));";
            code ~= "\n";
        } else if (lower && startsWith(expression.source, "literalChoiceK!(") && expression.arguments.length >= 2) {
            // L4: the trie walk of `literalChoiceK.dispatch`, with the same replay rules as the two-byte table above.
            const choice = "_lc" ~ number(serial++);
            code ~= "alias " ~ choice ~ " = " ~ expression.source ~ ";\nsize_t " ~ choice ~ "Miss;\nif (_live && "
                ~ position ~ " < s.input.length) { const " ~ choice ~ "Hit = " ~ choice ~ (acceptActive
                        ? ".winnerOnly(s.input, " : ".dispatch(s.input, ") ~ position ~ "); if (" ~ choice
                ~ "Hit.winner) { " ~ diagnostic("if (" ~ choice ~ "Hit.failure) s.recordFailure(s.node("
                        ~ position ~ ", " ~ position ~ " + " ~ choice ~ "Hit.failure - 1, false)); ")
                ~ target ~ "End = " ~ position ~ " + " ~ choice ~ "Hit.length; " ~ target ~ "Fail = "
                ~ target ~ "End; break; } " ~ (acceptActive ? "" : choice ~ "Miss = " ~ choice ~ "Hit.failure - 1; ")
                ~ "}\n";
            code ~= target ~ "Ok = false;";
            if (!acceptActive)
                code ~= " " ~ target ~ "Fail = " ~ position ~ " + " ~ choice ~ "Miss; if (_live) s.recordFailure(s.node("
                    ~ position ~ ", " ~ position ~ " + " ~ choice ~ "Miss, false));";
            code ~= "\n";
        } else if (lower && op == "or") {
            code ~= target ~ "Ok = false;\n";
            foreach (child; expression.children) {
                if (outputMode == 2)
                    code ~= "s.rollbackOutput(" ~ checkpoint ~ ");\n";
                const next = "_d" ~ number(serial++);
                code ~= emitDirect(graph, child, position, next, serial, depth + 1, outputMode);
                code ~= "if (" ~ next ~ "Ok || " ~ next ~ "Fail >= " ~ target ~ "Fail) { " ~ target
                    ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = " ~ next ~ "Fail; " ~ target ~ "Ok = "
                    ~ next ~ "Ok; } if (" ~ next ~ "Ok) break;\n";
            }
        } else if (lower && (op == "zeroOrMore" || op == "oneOrMore" || op == "option")) {
            const next = "_d" ~ number(serial++);
            const count = "_count" ~ number(serial++);
            code ~= "size_t " ~ count ~ " = 0; while (" ~ (op == "option" ? count ~ " < 1 && " : "") ~ "_tick()) {\n";
            const keepCheckpoint = outputMode == 2 && !failureLeavesNoOutput(graph, expression.children[0]);
            if (keepCheckpoint)
                code ~= "const size_t " ~ checkpoint ~ " = s.outputCheckpoint();\n";
            const guard = llActive && llGuardTicks(graph, expression.children[0])
                && llRuleCertified() ? llGuardTicks(graph, expression.children[0]) : 0;
            if (guard) {
                // L3: the body provably fails on a byte outside FIRST(body), charging nothing (the repetition
                // attempt that got us here is already paid and `_live` holds) and recording one failure at the
                // cursor; replay that without running the body.
                const 
                body = "_g" ~ number(serial++);
                const mask = "_first" ~ number(serial++);
                const first = graph.facts[expression.children[0]].first;
                const here = target ~ "End";
                code ~= "size_t " ~ next ~ "End = " ~ here ~ ", " ~ next ~ "Fail = " ~ here ~ "; bool "
                    ~ next ~ "Ok = false;\nenum ulong[4] " ~ mask ~ " = [" ~ ulongHex(
                            first.bits[0]) ~ ", " ~ ulongHex(first.bits[1]) ~ ", " ~ ulongHex(
                            first.bits[2]) ~ ", " ~ ulongHex(first.bits[3]) ~ "];\nif (" ~ here
                    ~ " >= s.input.length || (" ~ mask ~ "[cast(ubyte)s.input[" ~ here
                    ~ "] >> 6] & (1UL << (cast(ubyte)s.input[" ~ here ~ "] & 63))) == 0) { " ~ diagnostic(
                            "s.recordFailure(s.node(" ~ here ~ ", " ~ here ~ ", false));") ~ " } else {\n" ~ emitDirect(graph,
                            expression.children[0], here, body, serial, depth + 1, outputMode) ~ next ~ "End = " ~ body
                    ~ "End; " ~ next ~ "Fail = " ~ body ~ "Fail; " ~ next ~ "Ok = " ~ body ~ "Ok; }\n";
            } else
                code ~= emitDirect(graph, expression.children[0], target ~ "End", next, serial, depth + 1, outputMode);
            code ~= "if (!" ~ next ~ "Ok) {\n";
            if (keepCheckpoint)
                code ~= "s.rollbackOutput(" ~ checkpoint ~ ");\n";
            if (op == "oneOrMore")
                code ~= "if (!" ~ count ~ ") { " ~ target ~ "End = " ~ next ~ "End; " ~ target ~ "Fail = "
                    ~ next ~ "Fail; " ~ target ~ "Ok = false; }\n";
            code ~= "break; } ++" ~ count ~ "; if (" ~ next ~ "End == " ~ target ~ "End) break; "
                ~ target ~ "End = " ~ next ~ "End; }\n";
            code ~= "if (!_live" ~ (op == "oneOrMore" ? " || !" ~ count : "") ~ ") " ~ target ~ "Ok = false;\n";
        } else if (startsWith(expression.source, "literal!(")) {
            const text = decodedLiteral(expression.source);
            code ~= "if (!_live) { " ~ target ~ "Ok = false; break; }\n";
            if (text.length) {
                const bytes = "_literal" ~ number(serial++);
                const matched = "_matched" ~ number(serial++);
                code ~= "enum " ~ bytes ~ " = " ~ quoted(text) ~ ";\n" ~ "if (" ~ position ~ " <= s.input.length && " ~ bytes
                    ~ ".length <= s.input.length - " ~ position ~ " && s.input[" ~ position ~ " .. " ~ position ~ " + "
                    ~ bytes ~ ".length] == " ~ bytes ~ ") { " ~ target ~ "End += " ~ bytes ~ ".length; "
                    ~ target ~ "Fail = " ~ target ~ "End; } else { ";
                if (acceptActive) // Only the verdict matters: no mismatch offset, no diagnostic.
                    code ~= target ~ "Ok = false; }\n";
                else
                    code ~= "size_t " ~ matched ~ "; while (" ~ matched ~ " < " ~ bytes ~ ".length && " ~ position ~ " + "
                        ~ matched ~ " < s.input.length && s.input[" ~ position ~ " + " ~ matched ~ "] == " ~ bytes ~ "["
                        ~ matched ~ "]) ++" ~ matched ~ "; " ~ target ~ "Ok = false; " ~ target ~ "Fail += " ~ matched
                        ~ "; s.recordFailure(s.node(" ~ position ~ ", " ~ target ~ "Fail, false)); }\n";
            }
        } else if (expression.byteTerminal && expression.byteWidth == 1 && (expression.source == "any"
                || expression.source == "digit" || expression.source == "alpha" || expression.source == "Alpha"
                || expression.source == "hexDigit" || startsWith(expression.source, "charClass!(")
                || startsWith(expression.source, "charRange!("))) {
            const mask = "_mask" ~ number(serial++);
            code ~= "enum ulong[4] " ~ mask ~ " = [" ~ ulongHex(
                    expression.alphabet.bits[0]) ~ ", " ~ ulongHex(expression.alphabet.bits[1]) ~ ", " ~ ulongHex(
                    expression.alphabet.bits[2]) ~ ", " ~ ulongHex(expression.alphabet.bits[3])
                ~ "]; if (!_live || " ~ position ~ " >= s.input.length || (" ~ mask ~ "[cast(ubyte)s.input["
                ~ position ~ "] >> 6] & (1UL << (cast(ubyte)s.input[" ~ position ~ "] & 63))) == 0) { "
                ~ target ~ "Ok = false; " ~ diagnostic("s.recordFailure(s.node(" ~ position
                        ~ ", " ~ position ~ ", false));") ~ " } else { ++" ~ target ~ "End; " ~ target
                ~ "Fail = " ~ target ~ "End; }\n";
        } else if (expression.source == "eps") {
            // Empty success neither consumes input nor charges a work unit.
        } else if (expression.source == "eoi" || expression.source == "endOfInput" || expression.source == "fail") {
            code ~= "if (" ~ (expression.source == "fail"
                    ? "true" : position ~ " != s.input.length") ~ ") { " ~ target ~ "Ok = false; " ~ diagnostic(
                    "s.recordFailure(s.node(" ~ position ~ ", " ~ position ~ ", false));") ~ " }\n";
        } else {
            const next = "_node" ~ number(serial++);
            code ~= "s.steps = _steps; s.depth = _depth; auto " ~ next ~ " = " ~ expression.source
                ~ "(s, " ~ position ~ "); _steps = s.steps; _live = s.status == Status.ok; "
                ~ target ~ "End = " ~ next ~ ".end; " ~ target ~ "Fail = " ~ next ~ ".failEnd; " ~ target
                ~ "Ok = " ~ next ~ ".successful;\n";
        }
        code ~= "} while (false);\n";
        if (outputMode == 2 && op == "or" && lower)
            code ~= "if (!" ~ target ~ "Ok) s.rollbackOutput(" ~ checkpoint ~ ");\n";
        return code ~ "}\n";
    }

    nothrow unittest {
        Frontend frontend;
        GrammarAnalysis graph;
        const root = frontend.expressionNode(graph,
                "and!(or!(literal!(\"a\"), literal!(\"b\")), oneOrMore!(option!(literal!(\"x\"))), zeroOrMore!(eps))");
        size_t serial;
        auto code = frontend.emitDirect(graph, root, "p", "result", serial);
        assert(code.length && serial > 10);
        assert(startsWith(code, "size_t resultEnd"));
        serial = 0;
        assert(frontend.emitDirect(graph, root, "p", "result", serial, 64).length);
        foreach (expr; [
            "named!(literal!(\"a\"), \"x\")", "defined!(literal!(\"a\"), \"x\")",
            "keep!(literal!(\"a\"))", "drop!(literal!(\"a\"))",
            "propagate!(literal!(\"a\"))", "discard!(literal!(\"a\"))",
            "fuse!(literal!(\"a\"))", "posLookahead!(literal!(\"a\"))",
            "negLookahead!(literal!(\"a\"))", "predictiveNot!(literal!(\"a\"), 0UL, 0UL, 0UL, 0UL)",
            "dfaToken!(literal!(\"a\"), _dfa, 0, true)", "dfaToken!(literal!(\"a\"), _dfa, 0, false)",
            "endOfInput", "space", "blank", "charRange!(97, 122)",
        ]) {
            serial = 0;
            const node = frontend.expressionNode(graph, expr);
            assert(frontend.emitDirect(graph, node, "p", "result", serial, 0, 2).length);
        }
    }

    /// Build a separate diagnostic graph; keep the generator's analysis unchanged.
    private RuleEffect[] reportEffects() nothrow {
        GrammarAnalysis graph;
        Frontend diagnostic;
        foreach (rule; rules)
            graph.names ~= rule.name;
        auto parameterized = new bool[rules.length];
        foreach (i, rule; rules) {
            parameterized[i] = params.length != 0 || rule.params.length != 0;
            graph.roots ~= parameterized[i]
                ? graph.appendExpression(Expression.init) : diagnostic.expressionNode(graph, rule.body);
        }
        // Action operands are unknown to the production FIRST/memo analyzer.
        // Only this graph opens them for diagnostic call/effect propagation.
        for (size_t i; i < graph.expressions.length; ++i) {
            auto node = graph.expressions[i];
            size_t marker;
            while (marker < node.source.length && node.source[marker] != '!')
                ++marker;
            if (marker < node.source.length && graph.ruleIndex(node.source[0 .. marker]) != size_t.max) {
                node.kind = ExpressionKind.unknown;
                node.children = null;
                graph.expressions[i] = node;
            } else if (node.kind == ExpressionKind.unknown && node.arguments.length >= 2
                    && startsWith(node.source, "action!(")) {
                const child = diagnostic.expressionNode(graph, node.arguments[0]);
                node.kind = ExpressionKind.wrapper;
                node.combinator = "action";
                node.children = [child];
                graph.expressions[i] = node;
            }
        }
        return graph.ruleEffects(parameterized);
    }

    nothrow unittest {
        Frontend frontend;
        frontend.input = "Local: Root <- Pure Pure <- 'a' Op <- external Act <- Root{effect} Lit <- 'action!('";
        frontend.read();
        assert(!frontend.error.message.length);
        auto effects = frontend.reportEffects();
        assert(effects[0].known && !effects[0].actionful);
        assert(effects[1].known && !effects[1].actionful);
        assert(!effects[2].known && effects[2].actionful);
        assert(effects[3].known && effects[3].actionful);
        assert(effects[4].known && !effects[4].actionful);
        // A parameter name in another rule must not taint a real rule reference.
        Frontend scoped;
        scoped.input = "Scoped: Root <- P P <- 'a' Param(P) <- P";
        scoped.read();
        auto local = scoped.reportEffects();
        assert(local[0].known && local[1].known && !local[2].known);
        Frontend shadow;
        shadow.input = "Shadow: Root <- literal!('a') literal(P) <- P";
        shadow.read();
        auto unknown = shadow.reportEffects();
        assert(!unknown[0].known && unknown[0].actionful);
    }

    version (NPeggedPureIslands) {
        /// Legacy parent combinators retain a named child only through its matches.
        private bool islandHasMatches(size_t index) nothrow {
            auto node = analyzed.expressions[index];
            final switch (node.kind) {
            case ExpressionKind.unknown:
                return false;
            case ExpressionKind.terminal:
                return node.source == "eps" || analyzed.facts[index].nullable == Nullable.no;
            case ExpressionKind.reference:
                const target = analyzed.referenceRule(node);
                return target != size_t.max && islandHasMatches(analyzed.roots[target]);
            case ExpressionKind.sequence:
                foreach (child; node.children)
                    if (islandHasMatches(child))
                        return true;
                return false;
            case ExpressionKind.choice:
                foreach (child; node.children)
                    if (!islandHasMatches(child))
                        return false;
                return node.children.length != 0;
            case ExpressionKind.optional:
            case ExpressionKind.repetition:
            case ExpressionKind.predicate:
                return false;
            case ExpressionKind.wrapper:
                return node.combinator != "discard" && node.children.length
                    && islandHasMatches(node.children[0]);
            }
        }

        nothrow unittest {
            Frontend matches;
            matches.input = "Matches: A <- 'a'";
            matches.read();
            matches.prepareAnalysis();
            const expressions = [
                `opaque!(A)`, `eps`, `eoi`, `A`, `missing`, `and!(eoi, A)`,
                `and!(eoi, literal!(""))`, `or!(A, eps)`, `or!(A, eoi)`, `or!()`,
                `option!(A)`, `zeroOrMore!(A)`, `posLookahead!(A)`, `discard!(A)`, `oneOrMore!(A)`,
                `fuse!(A)`
            ];
            const expected = [
                false, true, false, true, false, true, false, true, false, false, false, false,
                false, false, true, true
            ];
            foreach (i, text; expressions) {
                auto root = matches.expressionNode(matches.analyzed, text);
                matches.analyzed.appendFacts(root);
                assert(matches.islandHasMatches(root) == expected[i]);
            }
        }

        private bool islandRecordShape(size_t index) nothrow {
            auto node = analyzed.expressions[index];
            if (node.kind == ExpressionKind.unknown)
                return false;
            if (node.kind == ExpressionKind.predicate)
                return true; // Both modes suppress probe output.
            if (node.kind == ExpressionKind.reference) {
                const target = analyzed.referenceRule(node);
                if (target == size_t.max)
                    return false;
                if (recordKinds[target] != uint.max && !islandHasMatches(analyzed.roots[target]))
                    return false;
                return islandRecordShape(analyzed.roots[target]);
            }
            if (node.combinator == "named" || node.combinator == "defined")
                return false;
            if (node.combinator == "discard" || node.combinator == "fuse" || node.combinator == "drop"
                    || node.combinator == "propagate") {
                auto visited = new bool[rules.length];
                // Query descendants using the same selected-subtree graph, without
                // pretending the transform preserves their legacy tree edges.
                bool selected(size_t current) nothrow {
                    auto item = analyzed.expressions[current];
                    if (item.kind == ExpressionKind.reference) {
                        const target = analyzed.referenceRule(item);
                        if (target == size_t.max || recordKinds[target] != uint.max)
                            return true;
                        if (visited[target])
                            return false;
                        visited[target] = true;
                        return selected(analyzed.roots[target]);
                    }
                    if (item.kind == ExpressionKind.predicate)
                        return false;
                    foreach (child; item.children)
                        if (selected(child))
                            return true;
                    return false;
                }

                foreach (child; node.children)
                    if (selected(child))
                        return false;
            }
            foreach (child; node.children)
                if (!islandRecordShape(child))
                    return false;
            return true;
        }

        nothrow unittest {
            Frontend shape;
            shape.input = "Shape: Root <- Item Space Item <~ [a-z]+ Space <: ' '*";
            shape.read();
            shape.prepareAnalysis();
            shape.configureRecords!compactTag();
            assert(!shape.islandRecordShape(shape.analyzed.roots[0]));
            assert(shape.islandRecordShape(shape.analyzed.roots[1]));
            assert(shape.islandRecordShape(shape.analyzed.roots[2]));
            shape.recordKinds[2] = uint.max;
            assert(shape.islandRecordShape(shape.analyzed.roots[0]));
            foreach (text; [
                `opaque!(Item)`, `missing`, `named!(Item, "custom")`, `fuse!(Item)`,
                `discard!(Item)`, `drop!(Item)`, `propagate!(Item)`
            ]) {
                auto root = shape.expressionNode(shape.analyzed, text);
                shape.analyzed.appendFacts(root);
                assert(!shape.islandRecordShape(root));
            }
            auto repeated = shape.expressionNode(shape.analyzed, "fuse!(and!(Space, Space))");
            shape.analyzed.appendFacts(repeated);
            assert(shape.islandRecordShape(repeated));
            auto probe = shape.expressionNode(shape.analyzed, "posLookahead!(Item)");
            shape.analyzed.appendFacts(probe);
            assert(shape.islandRecordShape(probe));
        }
    }

    string emit() nothrow {
        prepareAnalysis();
        RuleEffect[] localEffects;
        version (NPeggedPureIslands)
            if (backend == ParserBackend.direct)
                localEffects = reportEffects();
        if (eligibility !is null) {
            if (!localEffects.length)
                localEffects = reportEffects();
            eligibility.grammarName = name;
            eligibility.conservative = analyzed.conservative;
            eligibility.unknownEvidence = analyzed.unknownEvidence();
        }
        foreach (i, ref rule; rules)
            rule.body = emitExpression(analyzed, analyzed.roots[i]);
        bool actionGrammar;
        foreach (rule; rules) {
            bool actionInRule;
            foreach (i; 0 .. rule.body.length)
                if (startsWith(rule.body[i .. $], "action!("))
                    actionInRule = true;
            actionGrammar = actionGrammar || actionInRule;
            if (eligibility !is null && actionInRule)
                eligibility.actionRules ~= name ~ "." ~ rule.name;
        }
        bool[] islands;
        version (NPeggedPureIslands)
            if (backend == ParserBackend.direct && actionGrammar) {
                islands = new bool[rules.length];
                foreach (i, rule; rules)
                    islands[i] = localEffects[i].known && !localEffects[i].actionful
                        && analyzed.shareable(analyzed.roots[i]);
            }
        scalarRules = new bool[rules.length];
        foreach (i, rule; rules)
            scalarRules[i] = backend == ParserBackend.direct && !actionGrammar && !params.length
                && !rule.params.length && !analyzed.leftRecursive[i] && !analyzed.conservative
                && (!memoize || selective);
        acceptRules = scalarRules.dup;
        iterativeForms = new IterativeForm[rules.length];
        foreach (i, rule; rules)
            if (!actionGrammar && !params.length && !rule.params.length
                    && analyzed.leftRecursive[i] && !analyzed.conservative && (!memoize || selective)) {
                iterativeForms[i] = iterativeForm(i);
                acceptRules[i] = backend == ParserBackend.direct && iterativeForms[i].ok;
            }
        string result = "struct " ~ name ~ params ~ " {\n";
        if (islands.length) {
            string[] entries;
            foreach (i, eligible; islands)
                if (eligible)
                    entries ~= rules[i].name;
            if (entries.length) {
                if (islands[0])
                    entries ~= "opCall";
                result ~= "enum string[] npeggedPureIslandEntries = [";
                foreach (i, entry; entries)
                    result ~= (i ? ", " : "") ~ quoted(entry);
                result ~= "];\n";
            }
        }
        if (recordKinds.length) {
            result ~= "enum string[] compactRuleNames = [";
            foreach (i, rule; rules)
                result ~= (i ? ", " : "") ~ quoted(name ~ "." ~ rule.name);
            result ~= "];\nenum uint[] compactRuleKinds = [";
            foreach (i, kind; recordKinds)
                result ~= (i ? ", " : "") ~ number(kind);
            result ~= "];\n";
        }
        if (recordKinds.length) {
            recordLeaves = analyzed.selectedLeaves(recordKinds);
            recordSubtrees = analyzed.selectedSubtrees(recordKinds);
        }
        version (NPeggedPureIslands)
            if (islands.length && recordKinds.length && islandOmitAnonymous) {
                string[] entries;
                foreach (i, eligible; islands)
                    if (eligible && islandRecordShape(analyzed.roots[i]))
                        entries ~= rules[i].name;
                // opCall renames the legacy tree root; named entries have exact tags.
                if (entries.length) {
                    result ~= "enum string[] npeggedPureIslandRecordEntries = [";
                    foreach (i, entry; entries)
                        result ~= (i ? ", " : "") ~ quoted(entry);
                    result ~= "];\n";
                }
            }
        bool sharedEligible = memoize && !actionGrammar && !analyzed.conservative && !params.length;
        bool selectedRecursive;
        foreach (i, rule; rules) {
            sharedEligible = sharedEligible && !rule.params.length;
            if (recordSubtrees.length && analyzed.leftRecursive[i] && recordSubtrees[i])
                selectedRecursive = true;
        }
        if (recordKinds.length)
            result ~= "version (NPeggedSharedOutput) enum npeggedSharedOutputEligible = " ~ (sharedEligible
                    && selectedRecursive ? "true" : "false") ~ ";\n";
        bool spacingDefined;
        foreach (rule; rules)
            if (rule.name == "Spacing")
                spacingDefined = true;
        if (!spacingDefined)
            result ~= "alias Spacing = npegged.peg.spacing;\n";
        version (NPeggedScannerMetrics) {
            auto scannerCounts = new size_t[rules.length];
            auto scannerProof = new bool[rules.length];
        }
        auto ruleChunks = new string[rules.length];
        WorkBound[] workByRule;
        if (eligibility !is null)
            workByRule = workBounds(analyzed);
        foreach (ruleIndex, rule; rules) {
            string ruleOut;
            const island = islands.length && islands[ruleIndex];
            bool cache = memoize && (!selective || analyzed.conservative || analyzed.leftRecursive[ruleIndex]);
            if (params.length || rule.params.length)
                cache = memoize;
            string recordTag;
            if (recordKinds.length) {
                if (recordKinds[ruleIndex] != uint.max)
                    recordTag = ", " ~ number(cast(ulong)recordKinds[ruleIndex] | (recordLeaves[ruleIndex]
                            ? 1UL << 32 : 0UL)) ~ "L";
                else if (recordSubtrees[ruleIndex])
                    recordTag = ", -2L";
                else
                    recordTag = ", -3L";
            }
            if (rule.params.length)
                ruleOut ~= "template " ~ rule.name ~ rule.params ~ " {\n";
            string r = rule.name;
            string entryName = rule.params.length ? "_entry" : r;
            const savedRuleExprs = analyzed.expressions.length;
            scope (exit)
                analyzed.truncate(savedRuleExprs);
            size_t tokenRoot = analyzed.roots[ruleIndex];
            if (rule.body != analyzed.expressions[tokenRoot].source) {
                tokenRoot = expressionNode(analyzed, rule.body);
                analyzed.appendFacts(tokenRoot);
            }
            size_t count;
            string declarations;
            const string body = emitTokens(analyzed, tokenRoot, r, count, declarations);
            version (NPeggedScannerMetrics) {
                scannerCounts[ruleIndex] = count;
                scannerProof[ruleIndex] = scannerWholeRegular(analyzed, tokenRoot);
            }
            ruleOut ~= declarations;
            const directRule = backend == ParserBackend.direct && (!actionGrammar || island)
                && !analyzed.leftRecursive[ruleIndex] && !params.length && !rule.params.length;
            bool useDirect, directRecords;
            if (directRule) {
                alias directGraph = analyzed;
                size_t directRoot = tokenRoot;
                if (body != analyzed.expressions[tokenRoot].source) {
                    directRoot = expressionNode(directGraph, body);
                    directGraph.appendFacts(directRoot);
                }
                const op = directGraph.expressions[directRoot].combinator;
                useDirect = op == "and" || op == "or" || op == "predictiveChoice" || op == "literalChoice2"
                    || op == "literalChoiceK" || op == "zeroOrMore" || op == "oneOrMore" || op == "option"
                    || op == "posLookahead" || op == "negLookahead" || op == "predictiveNot";
                // P2: a nonempty plain literal root lowers to the direct cursor form.
                if (startsWith(directGraph.expressions[directRoot].source, "literal!(")
                        && decodedLiteral(directGraph.expressions[directRoot].source).length)
                    useDirect = true;
                if ((op == "discard" || op == "fuse" || op == "keep" || op == "drop" || op == "propagate"
                        || op == "named" || op == "defined") && directGraph.expressions[directRoot].children.length) {
                    const child = directGraph.expressions[directRoot].children[0];
                    const childOp = directGraph.expressions[child].combinator;
                    // Sequences/choices and generated rule functions have no scan member.
                    useDirect = childOp == "and" || childOp == "or" || childOp == "predictiveChoice"
                        || directGraph.expressions[child].kind == ExpressionKind.reference;
                }
                if (op == "dfaToken" && directGraph.expressions[directRoot].arguments.length == 4) {
                    string inner = directGraph.expressions[directRoot].arguments[3];
                    while (inner.length && (inner[0] == ' ' || inner[0] == '\t'))
                        inner = inner[1 .. $];
                    directRecords = inner == "true" || inner == "2";
                }
                foreach (pass; [1, 2, 3]) {
                    // Pass 3 is the `accept` clone: recognition cursors without failure diagnostics (C1).
                    const check = pass == 3 ? 1 : pass;
                    acceptActive = pass == 3;
                    directDeclarations = null;
                    this.directRule = r;
                    size_t serial;
                    llActive = llGuards;
                    llRule = ruleIndex;
                    const cursorBody = emitDirect(directGraph, directRoot, "p", "_result", serial, 0, check);
                    llActive = false;
                    const localSteps = countOf(cursorBody, "_tick()") >= localStepSites
                        || countOf(cursorBody, "_live") >= localLiveSites;
                    if (!acceptActive) // The clone reuses the declarations of the exact pass (same numbering).
                        ruleOut ~= directDeclarations;
                    ruleOut ~= (useDirect || check == 2 && directRecords ? "" : "pragma(inline, true) ") ~ "private static bool " ~ cursorName() ~ r ~ "(ref State!(false, " ~ number(
                            check) ~ ") s, ref size_t cursor, ref size_t failure, const size_t _depth) @nogc nothrow { enum CT = false; const size_t p = cursor;\n" ~ (
                            localSteps ? llLocals ~ cursorBody ~ "s.steps = _steps; " : withSharedSteps(cursorBody))
                        ~ "cursor = _resultEnd; failure = _resultFail; return _resultOk; }\n";
                }
                acceptActive = false;
                // The exact entry may be asked for a yes/no answer (`accept`): route it to the clone.
                ruleOut ~= "pragma(inline, true) private static State!(CT, Check).Node _directAccept_" ~ r ~ "(bool CT, int Check)(ref State!(CT, Check) s, size_t p) nothrow { size_t end = p, failure = p; " ~ "const successful = _acursor_" ~ r ~ "(s, end, failure, s.depth); " ~ "auto result = s.node(p, end, successful); result.successful = successful; result.failEnd = failure; return result; }\n";
                ruleOut ~= "pragma(inline, true) private static State!(CT, Check).Node _direct_" ~ r ~ "(bool CT, int Check)(ref State!(CT, Check) s, size_t p) nothrow { size_t end = p, failure = p; " ~ "const successful = _cursor_" ~ r ~ "(s, end, failure, s.depth); " ~ "auto result = s.node(p, end, successful); result.successful = successful; result.failEnd = failure; return result; }\n";
                // S3: reference-free DFA success needs neither State nor finish replay.
                version (NPeggedLeanEntry)
                    if (!cache && op == "dfaToken") {
                        const args = directGraph.expressions[directRoot].arguments;
                        string entryDepth = args.length == 4 ? args[2] : "";
                        while (entryDepth.length && (entryDepth[0] == ' ' || entryDepth[0] == '\t'))
                            entryDepth = entryDepth[1 .. $];
                        if (args.length == 4 && entryDepth == "0") {
                            const names = "Entry == " ~ quoted(r) ~ (ruleIndex == 0 ? " || Entry == \"opCall\"" : "");
                            ruleOut ~= "pragma(inline, true) static bool npeggedTryCheck(string Entry)(ref ParseContext context, scope string input, ref CheckResult result) @nogc nothrow if (" ~ names ~ ") { return _cursor_" ~ r ~ "(context, input, result); }\n";
                            ruleOut ~= "pragma(inline, true) private static bool _cursor_" ~ r ~ "(ref ParseContext context, scope string input, ref CheckResult result) @nogc nothrow { return tryDFAEntry!(" ~ args[0] ~ ", " ~ args[1] ~ ")(context, input, result); }\n";
                        }
                    }
            }
            // P8: a directly left-recursive rule gets an `accept` cursor of its loop form (see iterativeForm).
            const loweredAccept = !directRule && ruleIndex < acceptRules.length
                && acceptRules[ruleIndex] && !scalarRules[ruleIndex] && iterativeForms[ruleIndex].ok;
            // The loop form also serves `check` (validation) on every backend: same verdict, end and failure frontier as seed growth.
            const loopForm = !directRule && ruleIndex < iterativeForms.length && iterativeForms[ruleIndex].ok;
            string loweredBody;
            if (loopForm) {
                size_t loweredCount = count;
                string loweredDeclarations;
                const loweredRoot = expressionNode(analyzed, iterativeForms[ruleIndex].lowered);
                analyzed.appendFacts(loweredRoot);
                loweredBody = emitTokens(analyzed, loweredRoot, r, loweredCount, loweredDeclarations);
                ruleOut ~= loweredDeclarations;
            }
            if (loweredAccept) {
                const cursorRoot = expressionNode(analyzed, loweredBody);
                analyzed.appendFacts(cursorRoot);
                directDeclarations = null;
                this.directRule = r;
                size_t serial;
                llActive = false;
                acceptActive = true;
                const cursorBody = emitDirect(analyzed, cursorRoot, "p", "_result", serial, 0, 1);
                acceptActive = false;
                const localSteps = countOf(cursorBody, "_tick()") >= localStepSites
                    || countOf(cursorBody, "_live") >= localLiveSites;
                ruleOut ~= directDeclarations;
                ruleOut ~= "private static bool _acursor_" ~ r ~ "(ref State!(false, 1) s, ref size_t cursor, ref size_t failure, const size_t _depth) @nogc nothrow { enum CT = false; const size_t p = cursor;\n" ~ (
                        localSteps ? llLocals ~ cursorBody ~ "s.steps = _steps; " : withSharedSteps(cursorBody))
                    ~ "cursor = _resultEnd; failure = _resultFail; return _resultOk; }\n";
                ruleOut ~= "pragma(inline, true) private static State!(CT, Check).Node _directAccept_" ~ r ~ "(bool CT, int Check)(ref State!(CT, Check) s, size_t p) nothrow { size_t end = p, failure = p; " ~ "const successful = _acursor_" ~ r ~ "(s, end, failure, s.depth); " ~ "auto result = s.node(p, end, successful); result.successful = successful; result.failEnd = failure; return result; }\n";
            }
            ruleOut ~= "private static State!(CT, Check).Node _" ~ r
                ~ "(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow { ";
            if (loopForm)
                ruleOut ~= "static if (Check == 1) { return defined!(" ~ loweredBody ~ ", " ~ quoted(
                        name ~ "." ~ r) ~ ")(s,p); } else { ";
            const original = analyzed.expressions[analyzed.roots[ruleIndex]].source;
            if (original != rule.body)
                ruleOut ~= "if (s.context.trace !is null) return defined!(" ~ original ~ ", " ~ quoted(
                        name ~ "." ~ r) ~ ")(s,p); ";
            if (useDirect || directRecords)
                ruleOut ~= "static if (!CT && ((Check == 1 && " ~ (useDirect
                        ? "true" : "false") ~ ") || (Check == 2 && " ~ (useDirect || directRecords
                        ? "true" : "false") ~ "))) { if (s.context.trace is null) { " ~ (useDirect
                        ? "static if (Check == 1) { if (s.acceptOnly) return defined!(_directAccept_"
                        ~ r ~ "!(CT, Check), " ~ quoted(name ~ "." ~ r) ~ ")(s,p); } " : "")
                    ~ "return defined!(_direct_" ~ r ~ "!(CT, Check), " ~ quoted(name ~ "." ~ r) ~ ")(s,p); } } ";
            if (loweredAccept)
                ruleOut ~= "static if (!CT && Check == 1) { if (s.acceptOnly && s.context.trace is null) return defined!(_directAccept_" ~ r ~ "!(CT, Check), " ~ quoted(
                        name ~ "." ~ r) ~ ")(s,p); } ";
            ruleOut ~= "return defined!(" ~ body ~ ", " ~ quoted(name ~ "." ~ r) ~ ")(s,p); " ~ (loopForm
                    ? "} " : "") ~ "}\n";
            // Concrete overloads break recursive attribute-inference cycles.
            foreach (mode; [
                "false, false", "true, false", "false, true", "true, true", "false, 2", "true, 2"
            ]) {
                auto attributes = !startsWith(mode, "true") ? " @nogc nothrow" : " nothrow";
                ruleOut ~= "static State!(" ~ mode ~ ").Node " ~ entryName ~ (startsWith(mode, "true")
                        ? "(CompileTime = void)" : "") ~ "(ref State!(" ~ mode ~ ") s, size_t p)" ~ attributes;
                const memoFlag = loopForm && (mode == "false, true" || mode == "true, true") ? false : cache;
                if (island && (mode == "false, true" || mode == "false, 2"))
                    ruleOut ~= " { if (s.pureIslandAllowed()) return s.rule!(_" ~ r ~ "!(" ~ mode ~ "), " ~ quoted(
                            name ~ "." ~ r) ~ ", " ~ (memoFlag
                            ? "true" : "false") ~ recordTag ~ ")(p); return s.treeFallback!(" ~ entryName ~ ")(p); }\n";
                else if (actionGrammar && (mode != "false, false" && mode != "true, false"))
                    ruleOut ~= " { return s.treeFallback!(" ~ entryName ~ ")(p); }\n";
                else if (loweredAccept && mode == "false, true")
                    ruleOut ~= " { if (s.acceptOnly && s.context.trace is null) return s.rule!(_"
                        ~ r ~ "!(" ~ mode ~ "), " ~ quoted(
                                name ~ "." ~ r) ~ ", false)(p); return s.rule!(_" ~ r ~ "!(" ~ mode ~ "), " ~ quoted(
                                name ~ "." ~ r) ~ ", " ~ (memoFlag ? "true" : "false") ~ recordTag ~ ")(p); }\n";
                else
                    ruleOut ~= " { return s.rule!(_" ~ r ~ "!(" ~ mode ~ "), " ~ quoted(name ~ "." ~ r) ~ ", " ~ (memoFlag
                            ? "true" : "false") ~ recordTag ~ ")(p); }\n";
            }
            ruleOut ~= "static ParseResult " ~ entryName ~ "(Context)(ref Context ctx, string input) @nogc nothrow if (is(Context == ParseContext)) { return parse!(" ~ entryName ~ ")(ctx,input); }\n";
            ruleOut ~= "static ParseTree " ~ entryName
                ~ "(Input)(Input input) nothrow if (is(Input == string)) { return parseCT!("
                ~ entryName ~ ")(input); }\n";
            if (rule.params.length)
                ruleOut ~= "alias " ~ r ~ " = _entry;\n}\n";
            if (eligibility !is null) {
                RuleEligibility row;
                row.name = name ~ "." ~ r;
                row.known = localEffects[ruleIndex].known;
                row.actionful = localEffects[ruleIndex].actionful;
                row.rootExpression = analyzed.expressions[analyzed.roots[ruleIndex]].source;
                row.leftRecursive = analyzed.leftRecursive[ruleIndex];
                row.memoized = cache;
                row.scalarEligible = scalarRules[ruleIndex];
                row.directRecognition = useDirect;
                row.directRecords = useDirect || directRecords;
                if (backend != ParserBackend.direct)
                    row.scalarBlockers ~= "backend-combinators";
                if (actionGrammar)
                    row.scalarBlockers ~= "grammar-action";
                if (params.length)
                    row.scalarBlockers ~= "grammar-parameters";
                if (rule.params.length)
                    row.scalarBlockers ~= "rule-parameters";
                if (row.leftRecursive)
                    row.scalarBlockers ~= "left-recursion";
                if (analyzed.conservative)
                    row.scalarBlockers ~= "grammar-unknown";
                if (memoize && !selective)
                    row.scalarBlockers ~= "full-memo";
                assert(row.scalarEligible == !row.scalarBlockers.length);
                row.directFallback = backend != ParserBackend.direct ? "backend-combinators" : actionGrammar && !island
                    ? "grammar-action" : params.length ? "grammar-parameters" : rule.params.length
                    ? "rule-parameters" : row.leftRecursive ? "left-recursion" : !useDirect ? "root-combinator" : "none";
                row.dfaScanner = count != 0 || startsWith(body, "dfaToken!(");
                row.scannerRegions = count;
                row.predictiveDispatch = containsText(body, "predictiveChoice!(");
                row.strategy = useDirect ? "direct-cursor" : row.dfaScanner ? "dfa-scanner" : "combinator";
                row.selectorConfigured = recordKinds.length != 0;
                if (row.selectorConfigured) {
                    row.recordKind = recordKinds[ruleIndex];
                    row.recordSelected = row.recordKind != uint.max;
                    row.recordLeaf = recordLeaves[ruleIndex];
                    row.recordSubtree = recordSubtrees[ruleIndex];
                }
                if (ruleIndex < workByRule.length)
                    row.workBound = describe(workByRule[ruleIndex]);
                eligibility.rules ~= row;
            }
            ruleChunks[ruleIndex] = ruleOut;
        }
        size_t totalLen = result.length;
        foreach (chunk; ruleChunks)
            totalLen += chunk.length;
        auto outBuf = new char[totalLen + 1024];
        outBuf[0 .. result.length] = result[];
        size_t outPos = result.length;
        foreach (chunk; ruleChunks) {
            outBuf[outPos .. outPos + chunk.length] = chunk[];
            outPos += chunk.length;
        }
        result = cast(string)outBuf[0 .. outPos];
        version (NPeggedScannerMetrics) {
            result ~= "enum string[] scannerRuleNames = [";
            foreach (i, rule; rules)
                result ~= (i ? ", " : "") ~ quoted(name ~ "." ~ rule.name);
            result ~= "];\nenum size_t[] scannerRegionCounts = [";
            foreach (i, count; scannerCounts)
                result ~= (i ? ", " : "") ~ number(count);
            result ~= "];\nenum bool[] scannerRootProven = [";
            foreach (i, proof; scannerProof)
                result ~= (i ? ", " : "") ~ (proof ? "true" : "false");
            result ~= "];\n";
        }
        if (!rules[0].params.length) {
            auto first = rules[0].name;
            foreach (mode; [
                "false, false", "true, false", "false, true", "true, true", "false, 2", "true, 2"
            ]) {
                result ~= "static State!(" ~ mode ~ ").Node opCall" ~ (startsWith(mode, "true")
                        ? "(CompileTime = void)" : "") ~ "(ref State!(" ~ mode ~ ") s, size_t p)" ~ (!startsWith(mode,
                        "true") ? " @nogc" : "") ~ " nothrow { auto t = " ~ first ~ "(s,p); " ~ ((mode != "false, false"
                        && mode != "true, false") ? "" : "t.name = " ~ quoted(name) ~ "; ") ~ "return t; }\n";
            }
            result ~= "static ParseResult opCall(Context)(ref Context ctx, string input) @nogc nothrow if (is(Context == ParseContext)) { return parse!(opCall)(ctx,input); }\n";
            result ~= "static ParseTree opCall(Input)(Input input) nothrow if (is(Input == string)) { return parseCT!(opCall)(input); }\n";
        }
        result ~= "}\n";
        return result;
    }
}

nothrow unittest {
    auto eligible = generate!(Memoization.selective, void, ParserBackend.direct)("Entry: Root <- [a-z]* eoi");
    assert(eligible.status == Status.ok);
    version (NPeggedLeanEntry) {
        assert(Frontend.countOf(eligible.source, "npeggedTryCheck") != 0);
        // S5: cursor-to-cursor calls pass the depth in a register and check the limit inline.
        assert(Frontend.countOf(eligible.source, "const size_t _depth)") != 0);
        assert(Frontend.countOf(eligible.source, "private static bool _cursor_Root(ref ParseContext") != 0);
    } else
        assert(Frontend.countOf(eligible.source, "npeggedTryCheck") == 0);
    auto reference = generate!(Memoization.selective)("Entry: Root <- [a-z]* eoi");
    assert(reference.status == Status.ok && Frontend.countOf(reference.source, "npeggedTryCheck") == 0);
    auto memoized = generate!(Memoization.yes, void, ParserBackend.direct)("Entry: Root <- [a-z]* eoi");
    assert(memoized.status == Status.ok && Frontend.countOf(memoized.source, "npeggedTryCheck") == 0);
    foreach (definition; [
        "Entry: Root <- Leaf+ eoi Leaf <- [a-z]", "Entry: Root <- 'a' eoi",
        "Entry: Root <- Root 'a' / 'a'", "Entry(T=identifier): Root <- T* eoi"
    ]) {
        auto fallback = generate!(Memoization.selective, void, ParserBackend.direct)(definition);
        assert(fallback.status == Status.ok && Frontend.countOf(fallback.source, "npeggedTryCheck") == 0);
    }
}

nothrow unittest {
    Frontend parser;
    parser.input = "ChoiceTest: Term <- Add / Sub Add <- '+' Term Sub <- '-' Term Cycle <- Cycle";
    parser.read();
    assert(!parser.error.message.length);
    auto emitted = parser.emit();
    assert(startsWith(parser.rules[0].body, "predictiveChoice!("));

    // Test computeFirstSet
    auto firstAdd = parser.computeFirstSet("Add");
    assert(firstAdd.known && !firstAdd.canBeEmpty && firstAdd.mask.contains('+'));
    auto firstSub = parser.computeFirstSet("Sub");
    assert(firstSub.known && !firstSub.canBeEmpty && firstSub.mask.contains('-'));
    assert(!firstAdd.mask.intersects(firstSub.mask));

    // Test literals and escapes in computeFirstSet
    assert(parser.computeFirstSet(`literal!("\n")`).mask.contains('\n'));
    assert(parser.computeFirstSet(`literal!("\r")`).mask.contains('\r'));
    assert(parser.computeFirstSet(`literal!("\t")`).mask.contains('\t'));
    assert(parser.computeFirstSet(`literal!("\0")`).mask.contains('\0'));
    assert(parser.computeFirstSet(`literal!("\\")`).mask.contains('\\'));
    assert(parser.computeFirstSet(`literal!("\"")`).mask.contains('"'));
    assert(parser.computeFirstSet(`literal!("foo")`).mask.contains('f'));
    assert(parser.computeFirstSet(`literal!("")`).canBeEmpty);
    assert(!parser.computeFirstSet(`literal!(`).known);

    // Test charRange
    assert(parser.computeFirstSet("charRange!(97, 122)").mask.contains('a'));
    assert(!parser.computeFirstSet("charRange!(300, 400)").known);
    assert(!parser.computeFirstSet("charRange!(100, 50)").known);
    assert(!parser.computeFirstSet("charRange!(invalid)").known);

    // Test charClass
    assert(parser.computeFirstSet("charClass!(0x1UL, 0x2UL, 0x3UL, 0x4UL)").known);
    assert(parser.computeFirstSet("charClass!(10UL, 20UL, 30UL, 40UL)").known);
    assert(!parser.computeFirstSet("charClass!(invalid)").known);

    // Test combinator unwrapping
    assert(parser.computeFirstSet(`and!(literal!("a"), literal!("b"))`).mask.contains('a'));
    assert(parser.computeFirstSet(`discard!(literal!("a"))`).mask.contains('a'));
    assert(parser.computeFirstSet(`fuse!(literal!("b"))`).mask.contains('b'));
    assert(parser.computeFirstSet(`keep!(literal!("c"))`).mask.contains('c'));
    assert(parser.computeFirstSet(`drop!(literal!("d"))`).mask.contains('d'));
    assert(parser.computeFirstSet(`oneOrMore!(literal!("e"))`).mask.contains('e'));

    // Test predefined symbols
    assert(parser.computeFirstSet("digit").mask.contains('5'));
    assert(parser.computeFirstSet("alpha").mask.contains('k'));
    assert(parser.computeFirstSet("Alpha").mask.contains('K'));
    assert(parser.computeFirstSet("hexDigit").mask.contains('f'));
    assert(parser.computeFirstSet("space").mask.contains(' '));
    assert(parser.computeFirstSet("blank").mask.contains('\n'));
    assert(parser.computeFirstSet("ident").mask.contains('_'));
    assert(parser.computeFirstSet("identifier").mask.contains('_'));
    assert(!parser.computeFirstSet("nonExistentRule").known);
    assert(!parser.computeFirstSet("Cycle").known); // recursion guard

    // Test splitTemplateArgs
    auto args = Frontend.splitTemplateArgs(`A, and!(B, C), literal!(",")`);
    assert(args.length == 3);

    // Test optimizeChoice
    assert(parser.firstTwoChoice(["literal!(\"==\")", "literal!(\"=\")"]) == "literalChoice2!(\"==\", \"=\")");
    assert(parser.firstTwoChoice(["literal!(\"abc\")", "literal!(\"a\")"]) == "literalChoiceK!(\"abc\", \"a\")");
    assert(parser.firstTwoChoice(["literal!(\"abcde\")", "literal!(\"a\")"]) is null);
    assert(parser.firstTwoChoice(["literal!(\"\")", "literal!(\"a\")"]) is null);
    assert(parser.firstTwoChoice(["literal!(\"a\")", "charRange!(48, 57)"]) is null);
    assert(parser.firstTwoChoice(["literal!(\"a\")"]) is null);
    assert(parser.optimizeChoice(["A"]) is null); // less than 2
    assert(parser.optimizeChoice(["unknown1", "unknown2"]) is null);

    // Shared prefixes are extracted before suffix dispatch.
    Frontend overlap;
    overlap.input = "OverlapTest: Term <- 'a' 'b' / 'a' 'c'";
    overlap.read();
    assert(!overlap.error.message.length);
    auto emittedOverlap = overlap.emit();
    assert(startsWith(overlap.rules[0].body, "and!(literal!(\"a\"), predictiveChoice!("));

    // Test character classes in primary
    Frontend charClasses;
    charClasses.input = "CharClasses: Single <- [a] ByteEsc <- [\\xFF] NonAscii <- [\\u03B1-\\u03C9] Mixed <- [a-z\\u03B1-\\u03C9] Empty <- []";
    charClasses.read();
    assert(!charClasses.error.message.length);
    auto emittedClasses = charClasses.emit();
    assert(emittedClasses.length > 0);

    assert(ulongHex(0x1234UL) == "0x1234UL");
    assert(ulongHex(0UL) == "0x0UL");

    Frontend opt;
    opt.input = "Opt: A <- 'a' / 'b' Single <- 'x'";
    opt.read();
    opt.emit();
    assert(opt.optimizeRule("or!(literal!('a'), literal!('b'))").length);
    assert(opt.optimizeRule("or!(literal!('a'), literal!('b'))").length);
    assert(opt.optimizeRule("longest_match!(literal!('a'), literal!('b'))").length);
    assert(opt.optimizeRule("predictiveChoice!(literal!('a'), literal!('b'))").length);
    assert(opt.optimizeRule("option!(literal!('a'))").length);
    assert(opt.optimizeRule("zeroOrMore!(literal!('a'))").length);
    assert(opt.optimizeRule("posLookahead!(literal!('a'))").length);
    assert(opt.optimizeRule("negLookahead!(literal!('a'))").length);
    assert(opt.optimizeRule("named!(literal!('a'), \"name\")").length);
    assert(opt.optimizeRule("branch!(literal!('a'), 0UL, 0UL, 0UL, 0UL)").length);
    assert(opt.optimizeRule("eps").length);
    assert(opt.optimizeRule("eoi").length);
    assert(opt.optimizeRule("endOfInput").length);
    assert(opt.optimizeRule("fail").length);
    assert(opt.optimizeRule("any").length);
    assert(opt.optimizeRule("spacing").length);
    assert(opt.optimizeRule("doublequote").length);
    assert(opt.optimizeRule("backslash").length);
    assert(opt.optimizeRule("quote").length);
    assert(opt.optimizeRule("slash").length);
    assert(opt.optimizeRule("backquote").length);
    assert(opt.optimizeRule("tab").length);
    assert(opt.optimizeRule("endOfLine").length);
    assert(opt.optimizeRule("eol").length);
    assert(opt.primitiveFirstSet("  literal!(\"a\")  ").known);
    assert(opt.primitiveFirstSet("literal!(\"\")").canBeEmpty);
    assert(opt.primitiveFirstSet("charClass!(0x1UL, 0X2UL, 3UL, 4UL)").known);
    assert(opt.primitiveFirstSet("charRange!(  10 ,  20 )").known);
    assert(Frontend.splitTemplateArgs(`"\\", a`).length == 2);
    assert(Frontend.splitTemplateArgs("a, b").length == 2);

    Frontend aheadTest;
    aheadTest.input = "DefAhead: Rule(T = ')') <- 'a' Other <- Rule";
    aheadTest.read();
    assert(!aheadTest.error.message.length);
    assert(aheadTest.emit().length);
}

unittest {
    foreach (definition; [
        "Test(Token = 'x'): A <- List(Token, ',') List(T, S = ',') < T (:S T)*",
        "Test: A <~ '\\u00E9' / '\\U0001F600' / '\\x80' / '\\377'", "Test: A <- [a-zé-ê] | 'ABC'i",
        "Test: A <: 'x' B <^ 'y' C <; 'z' D <% A E <{act} 'a'",
        "Test: A <- 'x'{ p => { /* }, */ return p; }, p => p }",
        "Test: A <- 'x'{ p => { /+ }, /+ nested +/ +/ return p; } }",
        "Test: A <- 'x'{ p => { // },\n return p; } }", "Test: A <- ^'x' %B :eoi B <- 'x'",
        "Test: A <- &'a' !'b' ~'c'? :'d'* ;'e'+ %'f' ^'g'", "Test: A <- Other.Rule('x') Other2.Thing",
        "Test: A <- 'x' B(X = '(') <- X", "Test: A <- '' / []",
    ]) {
        Frontend parser;
        parser.input = definition;
        parser.read();
        assert(!parser.error.message.length, parser.error.message);
        assert(parser.emit().length);
    }
    foreach (definition; [
        "", "Test:", "Test: A <-", "Test: A <- (", "Test: A <- 'x", "Test: A <- '\\'",
        "Test: A <- '\\uX000'", "Test: A <- '\\UFFFFFFFF'", "Test: A <- '\\u12'",
        "Test: A <- 'a' / 'b' | 'c'", "Test: A <- 'x'{ act", "Test: A(,) <- 'x'",
        "Test: A <- '\xff'", "Test: A <- 'x'{p => { /*", "Test: A <- 'x'{p => { /+"
    ]) {
        Frontend parser;
        parser.input = definition;
        parser.read();
        assert(parser.error.message.length);
    }
    assert(quoted("\0\r\t\x01\x80") == "\"\\0\\r\\t\\x01\\x80\"");
}

nothrow unittest {
    foreach (definition; [
        "Test:\r\t A <- 'a' # trailing comment", "Test: A <- / 'a' / 'b'",
        "Test: A <- | 'a' | 'b'", "Test: A <- [-a-]",
        "Test: A <- '\\b\\f\\v\\uFaBc\\xAf\\0\\07\\078'",
        "Test: A <- 'x'{p => foo('x', [1, 2], `raw`)}", "Test: A <- 'x'{p => p / 2}",
    ])
        assert(generate(definition).status == Status.ok);
    foreach (definition; [
        "Test: A <- @", "Test: A <- [a-", "Test: A <- '\\uD800'", "Test: A <- '\\u12",
        "Test: A <- '\\x", "Test: A <- '\\", "Test: A <- 'x'{p /", "Test: A(X='\\'",
        "Test: A <- 'x'{ // trailing"
    ])
        assert(generate(definition).status == Status.invalidInput);
    auto cached = grammar("Test: A <- 'a'");
    assert(cached.length);
    auto invalid = grammar("Test:");
    assert(invalid.length);
    auto uncached = generate!(Memoization.no)("Test: A <- 'a'");
    assert(uncached.status == Status.ok);
}

private string encode(dchar value) pure nothrow {
    if (value < 0x80)
        return [cast(char)value].idup;
    if (value < 0x800)
        return [cast(char)(0xC0 | value >> 6), cast(char)(0x80 | value & 0x3F)].idup;
    if (value < 0x10000)
        return [
        cast(char)(0xE0 | value >> 12), cast(char)(0x80 | value >> 6 & 0x3F),
        cast(char)(0x80 | value & 0x3F)
    ].idup;
    return [
        cast(char)(0xF0 | value >> 18), cast(char)(0x80 | value >> 12 & 0x3F),
        cast(char)(0x80 | value >> 6 & 0x3F), cast(char)(0x80 | value & 0x3F)
    ].idup;
}

unittest {
    assert(encode('a') == "a");
    assert(encode('é') == "é");
    assert(encode('€') == "€");
    assert(encode('😀') == "😀");
}

/// Returns D source for mixin() or cold runtime generation. Grammar errors become static diagnostics.
string grammar(Memoization memo = Memoization.yes, alias Selector = void,
        ParserBackend backend = ParserBackend.direct, bool TaggedRegions = true)(string definition) nothrow {
    Frontend frontend;
    frontend.input = definition;
    frontend.walkRecordRegions = !TaggedRegions;
    frontend.memoize = memo != Memoization.no;
    frontend.selective = memo == Memoization.selective;
    frontend.backend = backend == ParserBackend.ll1 ? ParserBackend.direct : backend;
    frontend.llGuards = backend == ParserBackend.ll1;
    frontend.read();
    if (frontend.error.message.length)
        return "static assert(false, " ~ quoted(
                frontend.error.message ~ " at byte " ~ number(frontend.error.offset)) ~ ");";
    frontend.configureRecords!Selector();
    return frontend.emit();
}

unittest {
    enum generated = grammar("Tiny: A <- 'x'+ eoi");
    static assert(generated.length > 0);
    mixin(generated);
    enum result = Tiny("xxx");
    static assert(result.successful && result.matches == ["x", "x", "x"]);
    enum invalid = grammar("Broken: A <- (");
    static assert(invalid.length > 0);
}

nothrow unittest {
    // L3: guards appear only for cheap-certified rules and only with the ll1 backend.
    static bool hasGuard(string source) nothrow {
        foreach (i; 0 .. source.length - 6)
            if (source[i .. i + 6] == "_first")
                return true;
        return false;
    }

    enum certified = "G: Num <- [0-9]+ Expr <- Term (('+' / '-') Term)* Term <- Num / '(' Expr ')' Root <- Expr eoi";
    auto guarded = generate!(Memoization.selective, void, ParserBackend.ll1)(certified);
    auto direct = generate!(Memoization.selective, void, ParserBackend.direct)(certified);
    assert(guarded.status == Status.ok && hasGuard(guarded.source) && !hasGuard(direct.source));
    // A greedy repetition that hides what follows is not certified, so it keeps the plain direct form.
    auto hidden = generate!(Memoization.selective, void, ParserBackend.ll1)("G: Root <- ('a' 'b')* 'a' 'c'");
    assert(hidden.status == Status.ok && !hasGuard(hidden.source));
    // Predicates and actions disable certification.
    auto predicate = generate!(Memoization.selective, void, ParserBackend.ll1)("G: Root <- (!'x' 'a' 'b')* 'c'");
    assert(predicate.status == Status.ok && !hasGuard(predicate.source));
    auto report = eligibilityReport!(Memoization.selective, void, ParserBackend.ll1)(certified);
    assert(report.status == Status.ok && report.backend == ParserBackend.ll1);
}

nothrow unittest {
    foreach (definition; [
        "DirectCold: Root <- Item+ eoi Item <- '(' Root ')' / 'a' 'x'? / 'b' / eps 'x'",
        "DirectCold: Root <- (!')' Item)* &')' Item <- '(' Root ')' / 'a'",
        "DirectCold: Root <- Item eoi Item <- 'a' Item 'x' / 'b'?", "DirectCold: Root <- [0-9]+ eoi",
        "DirectCold: Root <- Item* eoi Item <- '(' Root ')' / 'abé' / [a-z] '.' / ![()z] .",
        "DirectCold: Root <- '' fail", "DirectCold: Root <- Root '+' [0-9]+ / [0-9]+",
        "DirectCold(T=identifier): Root <- T", "DirectCold: Root <- 'a'{p => p}",
        "DirectCold: Rec <- '(' Rec ')' / 'a' ZStar <- Rec* ZPlus <- Rec+ ZOpt <- Rec? ZPos <- &Rec ZNeg <- !Rec ZPredNot <- !'a' . ZOr <- Rec 'a' / Rec 'b' ZDisc <- :(Rec 'a') ZFuse <- ~(Rec 'a') ZKeep <- ^(Rec 'a' / Rec 'b') ZDrop <- ;('a' / 'b') ZProp <- %Rec",
    ]) {
        auto direct = generate!(Memoization.selective, void, ParserBackend.direct)(definition);
        assert(direct.status == Status.ok && direct.source.length);
    }
    foreach (definition; [
        "DirectCold: Root <- Leaf+ Ignored eoi Leaf <- [a-z] Ignored <: ' '?",
        "DirectCold: Root <- Ignored eoi Ignored <- Leaf Leaf <- [a-z]",
        "DirectCold: Root <- alpha Alpha digit hexDigit . eoi",
        "DirectCold: Root <~ [a-z]+ ':' Leaf Leaf <- [a-z]",
    ]) {
        auto selected = generate!(Memoization.selective, compactTag, ParserBackend.direct)(definition);
        assert(selected.status == Status.ok && selected.source.length);
    }
    auto invalid = generate!(Memoization.selective, void, ParserBackend.direct)("Broken:");
    assert(invalid.status == Status.invalidInput);
}

version (unittest) mixin(grammar(`
RuntimeTest:
    Expr <- Expr '+' Number / Number
    Number <~ [0-9]+
`));

@nogc nothrow unittest {
    ParseContext ctx;
    auto result = RuntimeTest(ctx, "1+2+3");
    assert(result.successful && result.end == 5);
    assert(result.matches == ["1", "+", "2", "+", "3"]);
    assert(result.children[0].name == "RuntimeTest.Expr");
    auto bad = RuntimeTest(ctx, "x");
    assert(!bad.successful);
    ctx.depthLimit = 0;
    auto limited = RuntimeTest(ctx, "1");
    assert(limited.status == Status.resourceLimit);
}

@nogc nothrow unittest {
    foreach (budget; 0 .. 80) {
        ParseContext context;
        context.memoryLimit = budget * 128;
        auto memory = RuntimeTest(context, "1+2+3+4");
        assert(memory.status == Status.ok || memory.status == Status.resourceLimit);
        context = ParseContext.init;
        context.stepLimit = budget;
        auto work = RuntimeTest(context, "1+2+3+4");
        assert(work.status == Status.ok || work.status == Status.resourceLimit);
    }
}

@nogc nothrow unittest {
    ParseContext context;
    foreach (input; ["1+2+3", "x", "1+"]) {
        auto tree = RuntimeTest(context, input);
        auto recognized = check!(RuntimeTest.opCall)(context, input);
        assert(recognized.status == tree.status);
        assert(recognized.successful == tree.successful && recognized.end == tree.end);
        assert(recognized.failEnd == tree.failEnd);
    }
    context.depthLimit = 0;
    assert(check!(RuntimeTest.opCall)(context, "1").status == Status.resourceLimit);
    context = ParseContext.init;
    context.memoryLimit = 0;
    assert(check!(RuntimeTest.opCall)(context, "1").status == Status.resourceLimit);
}

version (unittest) private ParseTree countAction(bool CT)(ref State!CT state, ParseTree tree) nothrow {
    ++*cast(size_t*)state.context.userData;
    return tree;
}

version (unittest) mixin(grammar(`ActionRecognition: Root <- (Root 'a' / 'a'){countAction}`));
version (unittest) mixin(grammar(`PredicateAction: Root <- (&('a'{countAction}) 'a' / 'b') eoi`));
version (unittest) mixin(grammar(`NegativeAction: Root <- !(&('a'{countAction}) 'z') . eoi`));
version (unittest) mixin(grammar(`NegativeBoundary: Root <- !Boundary . eoi Boundary <- eoi / 'a' 'b'`));
version (unittest) mixin(grammar!(Memoization.selective)(`SelectiveAction: Root <- (Root 'a' / 'a'){countAction}`));

@nogc nothrow unittest {
    ParseContext context;
    size_t calls;
    context.userData = &calls;
    auto tree = ActionRecognition(context, "aaa");
    const treeCalls = calls;
    calls = 0;
    auto recognized = check!(ActionRecognition.opCall)(context, "aaa");
    assert(recognized.successful == tree.successful && recognized.end == tree.end);
    assert(calls == treeCalls && calls > 0);
    calls = 0;
    auto selected = check!(SelectiveAction.opCall)(context, "aaa");
    assert(selected.successful && selected.end == tree.end);
    assert(calls == treeCalls && selected.arena.allocationCalls > 0);
}

@nogc nothrow unittest {
    ParseContext context;
    size_t calls;
    context.userData = &calls;
    auto tree = PredicateAction(context, "b");
    assert(tree.successful && calls == 1);
    calls = 0;
    auto recognized = check!(PredicateAction.opCall)(context, "b");
    assert(recognized.successful && calls == 1);
}

@nogc nothrow unittest {
    ParseContext context;
    size_t calls;
    context.userData = &calls;
    assert(check!(NegativeAction.opCall)(context, "a").successful && calls == 1);
    foreach (input; ["", "a", "b", "x", "ab", "ax"]) {
        auto tree = NegativeBoundary(context, input);
        auto result = check!(NegativeBoundary.opCall)(context, input);
        assert(tree.successful == result.successful && tree.end == result.end);
        assert(tree.failEnd == result.failEnd);
    }
    calls = 0;
    context.trace = &countRecordTrace;
    assert(check!(NegativeBoundary.opCall)(context, "x").successful && calls == 2);
}

version (unittest) mixin(grammar!(Memoization.selective)(`
SelectiveLeft:
    Root <- Expr eoi
    Expr <- Expr '+' Number / Number
    Number <~ [0-9]+
`));
version (unittest) mixin(grammar!(Memoization.selective)(`
SelectiveNested:
    Root <- '(' Root ')' / 'x'
`));
version (unittest) mixin(grammar!(Memoization.selective)(`
SelectiveHidden:
    Root <- Prefix? Root 'a' / 'a'
    Prefix <- 'b'
`));

@nogc nothrow unittest {
    ParseContext context;
    foreach (input; ["1+2+3", "x", "1+"]) {
        auto full = RuntimeTest(context, input);
        auto selected = SelectiveLeft.Expr(context, input);
        assert(selected.successful == full.successful && selected.end == full.end);
        auto recognized = check!(SelectiveLeft.Expr)(context, input);
        assert(recognized.successful == selected.successful && recognized.end == selected.end);
    }
    auto nested = check!(SelectiveNested.opCall)(context, "(((x)))");
    assert(nested.successful && nested.end == 7 && nested.arena.allocationCalls == 0);
    auto hidden = check!(SelectiveHidden.opCall)(context, "aaaa");
    assert(hidden.successful && hidden.end == 4 && hidden.arena.allocationCalls > 0);
}

unittest {
    Frontend graph;
    graph.input = "Test: A <- B? C B <- 'b' C <- 'c'";
    graph.read();
    auto first = graph.computeFirstSet("A");
    assert(first.known && !first.canBeEmpty && first.mask.contains('b') && first.mask.contains('c'));
    assert(!graph.computeFirstSet("charRange!(128, 255)").known);
    assert(graph.optimizeRule(`literal!("or!(x)")`) == `literal!("or!(x)")`);
    auto args = Frontend.splitTemplateArgs(`literal!("\\"), literal!("a")`);
    assert(args.length == 2);
    auto selected = grammar!(Memoization.selective)("Nested: A <- '(' A ')' / 'x'");
    assert(selected.length);
}

nothrow unittest {
    // W1: static work bounds. Derived by hand: Num = rule(1) + `[0-9]+` attempt(1); Expr adds the two Num call sites, the
    // repetition and the `+` Num pair, with Num's body reached from both call sites.
    static string bound(string definition, string rule) nothrow {
        auto report = eligibilityReport!(Memoization.selective, void, ParserBackend.direct)(definition);
        assert(report.status == Status.ok);
        foreach (row; report.rules)
            if (row.name.length > rule.length && row.name[$ - rule.length - 1 .. $] == "." ~ rule)
                return row.workBound;
        return null;
    }

    enum expression = "W: Num <- [0-9]+ Expr <- Num ('+' Num)* Root <- Expr eoi";
    assert(bound(expression, "Num") == "2*(n+1)");
    assert(bound(expression, "Expr") == "9*(n+1)");
    assert(bound(expression, "Root") == "15*(n+1)");
    assert(bound("W: Root <- Item+ eoi Item <- 'a' / 'b' 'c'", "Item") == "1*(n+1)");
    // An option is a repetition-like node: it costs one attempt.
    assert(bound("W: Root <- Item? 'b' eoi Item <- 'a'", "Root").length);
    // Left recursion, predicates, ambiguous FIRST sets and nullable loop bodies have no bound.
    assert(bound("W: Root <- Root '+' 'a' / 'a'", "Root") == "unknown: not-certified-ll1");
    assert(bound("W: Root <- !'x' 'a'", "Root") == "unknown: not-certified-ll1");
    assert(bound("W: Root <- ('a' 'b' / 'a' 'c')* eoi", "Root") == "unknown: not-certified-ll1");
    assert(bound("W: Root <- ('a'*)* eoi", "Root") == "unknown: not-certified-ll1");
    // A rule that calls an uncertified rule inherits the blocker (closed region).
    assert(bound("W: Root <- Bad 'a' Bad <- !'x' 'b'", "Root") == "unknown: not-certified-ll1");
}

nothrow unittest {
    // P8: the accept clone of a directly left-recursive rule is its loop form; indirect or mis-ordered recursion keeps seed growth.
    auto direct = generate!(Memoization.selective, void, ParserBackend.direct)(
            "L: Root <- Expr eoi Expr <- Expr ('+' / '-') Term / Term Term <- [0-9]+");
    assert(direct.status == Status.ok && Frontend.countOf(direct.source, "_acursor_Expr(ref State!(false, 1)") == 1);
    assert(Frontend.countOf(direct.source, "_cursor_Expr(ref State!(false, 1)") == 0);
    foreach (definition; [
        "L: Root <- Expr eoi Expr <- Term / Expr '+' Term Term <- [0-9]+",
        "L: Root <- Expr eoi Expr <- Sum / Term Sum <- Expr '+' Term Term <- [0-9]+",
        "L: Root <- Expr eoi Expr <- Expr ' '? / 'a'"
    ]) {
        auto other = generate!(Memoization.selective, void, ParserBackend.direct)(definition);
        assert(other.status == Status.ok && Frontend.countOf(other.source, "_acursor_Expr(ref State!(false, 1)") == 0);
    }
    auto combinators = generate!(Memoization.selective, void, ParserBackend.combinators)(
            "L: Root <- Expr eoi Expr <- Expr '+' Term / Term Term <- [0-9]+");
    assert(Frontend.countOf(combinators.source, "_acursor_") == 0);
}

version (unittest) private uint checkpointTag(string name) @nogc nothrow pure {
    return name.length >= 5 && name[$ - 5 .. $] == ".Item" ? 1 : uint.max;
}

nothrow unittest {
    // O2: a loop keeps its per-iteration checkpoint exactly when a failed iteration could leave a record.
    static size_t checkpoints(string definition) nothrow {
        auto direct = generate!(Memoization.selective, checkpointTag, ParserBackend.direct)(definition);
        assert(direct.status == Status.ok);
        return Frontend.countOf(direct.source, "outputCheckpoint()");
    }

    // Only `Item` is selected as a record. Without loops there is no checkpoint at all.
    const base = checkpoints("O2: Root <- Item eoi Item <- 'a'");
    assert(base == 0);
    // Record child last: proven, so the loop takes no checkpoint.
    assert(checkpoints("O2: Root <- (Sep Item)* eoi Sep <- ',' Item <- 'a'") == base);
    assert(checkpoints("O2: Root <- (!'z' Item)+ eoi Item <- 'a'") == base);
    assert(checkpoints("O2: Root <- (Sep Item)? eoi Sep <- ',' Item <- 'a'") == base);
    // Record child followed by an element that can fail or tick: not proven.
    assert(checkpoints("O2: Root <- (Item Sep)* eoi Sep <- ',' Item <- 'a'") > base);
    assert(checkpoints("O2: Root <- (Sep Item Mark?)* eoi Sep <- ',' Item <- 'a' Mark <- '!'") > base);
    // Unselected rules emit nothing, so any shape qualifies.
    assert(checkpoints("O2: Root <- (Plain Sep)* eoi Sep <- ',' Plain <- 'a'") == base);
    // A choice qualifies only when every arm does.
    const choice = checkpoints("O2: Root <- Sep (Item / Other) eoi Sep <- ',' Item <- 'a' Other <- 'b'");
    assert(choice > base);
    assert(checkpoints("O2: Root <- (Sep (Item / Other))* eoi Sep <- ',' Item <- 'a' Other <- 'b'") == choice);
    assert(checkpoints("O2: Root <- (Sep Item / Item Sep)* eoi Sep <- ',' Item <- 'a'") > choice);
}

version (unittest) private uint compactTag(string name) @nogc nothrow pure {
    if (name.length >= 5 && name[$ - 5 .. $] == ".Root")
        return 0;
    if (name.length >= 5 && name[$ - 5 .. $] == ".Leaf")
        return 1;
    if (name.length >= 8 && name[$ - 8 .. $] == ".Ignored")
        return uint.max;
    return 2;
}

version (NPeggedPureIslands) {
    version (unittest) private uint islandUnitTag(string name) @nogc nothrow pure {
        return name.length ? 1 : uint.max;
    }

    @nogc nothrow unittest {
        assert(islandUnitTag("Root") == 1 && islandUnitTag("") == uint.max);
    }

    version (unittest) mixin(grammar!(Memoization.selective, islandUnitTag, ParserBackend.direct)(`
IslandUnit:
    Root <- Identifier eoi
    Identifier <~ [a-z]+
    Action <- Identifier{p => p}
`));
    @nogc nothrow unittest {
        ParseContext context;
        context.stepLimit = context.depthLimit = context.memoryLimit = size_t.max;
        version (NPeggedMetrics) {
            ParseMetrics metrics;
            context.metrics = &metrics;
        }
        auto recognized = check!(IslandUnit.Identifier)(context, "abc");
        assert(recognized.successful && recognized.end == 3);
        auto root = check!IslandUnit(context, "abc");
        assert(root.successful);
        auto records = parseRecords!(IslandUnit.Identifier, islandUnitTag)(context, "abc", size_t.max);
        assert(records.successful && records.nodes.length == 1);
        version (NPeggedMetrics)
            assert(metrics.pureIslandEntries > 0);
        context.stepLimit = 0;
        auto limited = check!(IslandUnit.Identifier)(context, "abc");
        assert(limited.status == Status.resourceLimit);
    }
}

version (NPeggedSharedOutput) {
    version (unittest) mixin(grammar!(Memoization.selective, compactTag)(`
SharedOutputUnit:
    Root <- Expr eoi
    Expr <- Expr '+' Leaf / Leaf
    Leaf <~ [0-9]+
`));
    @nogc nothrow unittest {
        static assert(SharedOutputUnit.npeggedSharedOutputEligible);
        char[256] input;
        foreach (i, ref c; input)
            c = i % 2 ? '+' : '1';
        ParseContext context;
        context.memoryLimit = context.depthLimit = context.stepLimit = size_t.max;
        auto reference = parseRecords!(SharedOutputUnit.opCall, compactTag)(context,
                cast(string)input[0 .. 255], size_t.max);
        context.sharedOutput = true;
        auto candidate = parseRecords!(SharedOutputUnit.opCall, compactTag)(context,
                cast(string)input[0 .. 255], size_t.max);
        assert(reference.status == candidate.status && reference.end == candidate.end
                && reference.failEnd == candidate.failEnd);
        assert(reference.nodes == candidate.nodes);
        context.stepLimit = 1024;
        auto guarded = parseRecords!(SharedOutputUnit.opCall, compactTag)(context,
                cast(string)input[0 .. 255], size_t.max);
        context.sharedOutput = false;
        auto ordinary = parseRecords!(SharedOutputUnit.opCall, compactTag)(context,
                cast(string)input[0 .. 255], size_t.max);
        assert(guarded.status == ordinary.status && guarded.end == ordinary.end && guarded.failEnd == ordinary.failEnd);
    }
}

version (NPeggedScannerMetrics) {
    version (unittest) mixin(grammar!(Memoization.selective, compactTag, ParserBackend.direct)(`
ScannerUnit:
    Root <- Leaf+ eoi
    Leaf <~ [0-9]+
    Merged <- [a-b]+ [c-d]+ !'x' [0-9]+
    Partial <- 'a'* 'a'
    Single <- 'x'
`));
    @nogc nothrow unittest {
        static assert(ScannerUnit.scannerRuleNames == [
            "ScannerUnit.Root", "ScannerUnit.Leaf", "ScannerUnit.Merged", "ScannerUnit.Partial",
            "ScannerUnit.Single"
        ]);
        static assert(ScannerUnit.scannerRegionCounts == [1, 1, 2, 1, 0]);
        static assert(ScannerUnit.scannerRootProven == [true, true, false, false, true]);
        ParseContext context;
        assert(parseRecords!(ScannerUnit.Root, compactTag, false)(context, "12").successful);
        ScannerStats[8] storage;
        ScannerReport report;
        report.rows = storage[];
        context.scannerReport = &report;
        assert(parseRecords!(ScannerUnit.Root, compactTag, false)(context, "12").successful);
        assert(!parseRecords!(ScannerUnit.Root, compactTag, false)(context, "12!").successful);
        assert(check!(ScannerUnit.Merged)(context, "ac7").successful);
        assert(report.total.reasons[ScannerReason.recordLowering] == 2);
        assert(report.total.fastSuccess >= 2);
        assert(!report.truncated);
    }

    nothrow unittest {
        Frontend parser;
        parser.input = `ScannerEmitTest:
    Root <- Leaf+ eoi
    Leaf <~ [0-9]+
    Merged <- [a-b]+ [c-d]+ !'x' [0-9]+
    Partial <- 'a'* 'a'
    Single <- 'x'`;
        parser.read();
        assert(!parser.error.message.length);
        auto emitted = parser.emit();
        assert(emitted.length > 0);
    }
}

version (unittest) mixin(grammar!(Memoization.selective)(`
RecordNested:
    Root <- Ignored Branch eoi
    Ignored <: ' '?
    Branch <- '[' Leaf (',' Leaf)* ']'
    Leaf <~ [a-z]+
`));
version (unittest) mixin(grammar!(Memoization.yes, compactTag)(`
RecordBacktrack:
    Root <- (Branch / Leaf) eoi
    Branch <- Leaf ':' Leaf
    Leaf <~ [a-z]+
`));
version (unittest) mixin(grammar(`
RecordPredicate:
    Root <- &Branch Branch eoi
    Branch <- Leaf
    Leaf <~ [a-z]+
`));
version (unittest) mixin(grammar!(Memoization.selective)(`
RecordLeft:
    Root <- Expr eoi
    Expr <- Expr '+' Leaf / Leaf
    Leaf <~ [0-9]+
`));
version (unittest) mixin(grammar!(Memoization.yes, compactTag)(`
RecordLongest:
    Root <- (Short | Long) eoi
    Short <- Leaf
    Long <- Leaf Leaf
    Leaf <- [a-z]
`));
version (unittest) mixin(grammar(`
RecordAction:
    Root <- Branch eoi
    Branch <- Leaf {countAction}
    Leaf <~ [a-z]+
`));

@nogc nothrow unittest {
    ParseContext context;
    auto nested = parseRecords!(RecordNested.opCall, compactTag)(context, "[a,b]");
    assert(nested.successful && nested.nodes.length == 4);
    assert(nested.nodes[0] == CompactNode(0, 0, 5));
    assert(nested.nodes[1] == CompactNode(2, 0, 5, 0));
    assert(nested.nodes[2] == CompactNode(1, 1, 2, 1));
    assert(nested.nodes[3] == CompactNode(1, 3, 4, 1));
    auto backtrack = parseRecords!(RecordBacktrack.opCall, compactTag)(context, "a");
    assert(backtrack.successful && backtrack.nodes.length == 2);
    assert(backtrack.nodes[1] == CompactNode(1, 0, 1, 0));
    auto predicate = parseRecords!(RecordPredicate.opCall, compactTag)(context, "abc");
    assert(predicate.successful && predicate.nodes.length == 3);
    assert(predicate.nodes[1] == CompactNode(2, 0, 3, 0));
    assert(predicate.nodes[2] == CompactNode(1, 0, 3, 1));
    auto left = parseRecords!(RecordLeft.opCall, compactTag)(context, "1+2+3");
    assert(left.successful && left.nodes.length == 7);
    assert(left.nodes[4] == CompactNode(1, 0, 1, 3));
    assert(left.nodes[5] == CompactNode(1, 2, 3, 2));
    assert(left.nodes[6] == CompactNode(1, 4, 5, 1));
    auto longest = parseRecords!(RecordLongest.opCall, compactTag)(context, "ab");
    assert(longest.successful && longest.nodes.length == 4);
    assert(longest.nodes[1] == CompactNode(2, 0, 2, 0));
    assert(longest.nodes[2] == CompactNode(1, 0, 1, 1));
    assert(longest.nodes[3] == CompactNode(1, 1, 2, 1));
    size_t calls;
    context.userData = &calls;
    auto action = parseRecords!(RecordAction.opCall, compactTag)(context, "abc");
    assert(action.successful && calls == 1 && action.nodes.length == 3);
    assert(action.nodes[2] == CompactNode(1, 0, 3, 1));
    auto bad = parseRecords!(RecordNested.opCall, compactTag)(context, "[a,]");
    assert(!bad.successful && bad.status == Status.mismatch && bad.nodes.length == 0);
    auto limited = parseRecords!(RecordNested.opCall, compactTag)(context, "[a]", 0);
    assert(!limited.successful && limited.status == Status.resourceLimit && limited.nodes.length == 0);
    foreach (budget; 0 .. 100) {
        context = ParseContext.init;
        context.stepLimit = budget;
        auto trial = parseRecords!(RecordLeft.opCall, compactTag)(context, "1+2+3");
        assert(trial.status == Status.ok || trial.status == Status.resourceLimit);
        if (!trial.successful)
            assert(trial.nodes.length == 0);
    }
}

version (unittest) private uint wrongCompactTag(string name) @nogc nothrow pure {
    return uint.max;
}

version (unittest) enum staticRecordDefinition = `StaticRecords:
    Root <- Ignored &Leaf Leaf eoi
    Ignored <: ' '?
    Leaf <~ [a-z]+
`;
version (unittest) mixin(grammar!(Memoization.selective, compactTag)(staticRecordDefinition));

@nogc nothrow unittest {
    ParseContext context;
    auto result = parseRecords!(StaticRecords.opCall, compactTag, false)(context, " abc");
    assert(result.successful && result.nodes.length == 2 && result.input is null);
    assert(result.nodes[0] == CompactNode(0, 0, 4));
    assert(result.nodes[1] == CompactNode(1, 1, 4, 0));
    auto typeEntry = parseRecords!(StaticRecords, compactTag)(context, "abc");
    assert(typeEntry.successful && typeEntry.nodes.length == 2 && typeEntry.input == "abc");
    static assert(!__traits(compiles, parseRecords!(StaticRecords.opCall, wrongCompactTag)(context, "abc")));
    auto owned = parseRecords!(RecordNested.opCall, compactTag)(context, "[a,b]");
    auto borrowed = parseRecords!(RecordNested.opCall, compactTag, false)(context, "[a,b]");
    assert(owned.nodes == borrowed.nodes && borrowed.input is null);
    assert(borrowed.arena.allocationCalls == 0 && owned.arena.allocationCalls == 1);
    auto rejectedLeaf = parseRecords!(StaticRecords.Leaf, compactTag, false)(context, "!", 0);
    assert(rejectedLeaf.status == Status.mismatch && rejectedLeaf.outputArena.allocationCalls == 0);
    auto limitedLeaf = parseRecords!(StaticRecords.Leaf, compactTag, false)(context, "abc", 0);
    assert(limitedLeaf.status == Status.resourceLimit && limitedLeaf.nodes.length == 0);
    assert(limitedLeaf.end == 3);
    foreach (budget; 0 .. 60) {
        context.stepLimit = budget;
        auto checked = check!(StaticRecords.opCall)(context, " abc");
        auto captured = parseRecords!(StaticRecords.opCall, compactTag, false)(context, " abc");
        assert(captured.status == checked.status && captured.end == checked.end);
        assert(captured.failEnd == checked.failEnd);
        if (!captured.successful)
            assert(captured.nodes.length == 0);
    }
}

nothrow unittest {
    auto source = generate!(Memoization.selective, compactTag)(staticRecordDefinition);
    assert(source.status == Status.ok && source.source.length > 0);
}

version (unittest) private void countRecordTrace(string name, size_t pos, bool success, void* user) @nogc nothrow {
    ++*cast(size_t*)user;
}

version (unittest) mixin(grammar!(Memoization.selective, compactTag)(`
RecordLookLeft:
    Root <- Expr eoi
    Expr <- &Expr 'a' / 'a'
`));

@nogc nothrow unittest {
    ParseContext context;
    size_t calls;
    context.userData = &calls;
    context.trace = &countRecordTrace;
    auto checked = check!(RecordLookLeft.opCall)(context, "a");
    const expectedCalls = calls;
    assert(checked.successful && expectedCalls == 2);
    calls = 0;
    auto captured = parseRecords!(RecordLookLeft.opCall, compactTag)(context, "a");
    assert(captured.successful && captured.nodes.length == 2 && calls == expectedCalls);
    foreach (budget; 0 .. 24) {
        context.stepLimit = budget;
        calls = 0;
        auto reference = check!(RecordLookLeft.opCall)(context, "a");
        const referenceCalls = calls;
        calls = 0;
        auto candidate = parseRecords!(RecordLookLeft.opCall, compactTag)(context, "a");
        assert(candidate.status == reference.status && candidate.end == reference.end);
        assert(candidate.failEnd == reference.failEnd && calls == referenceCalls);
    }
}

version (unittest) mixin(grammar!(Memoization.selective, compactTag)(`
ShadowedBuiltin(digit = 'x'):
    Root <- digit / 'y'
`));
version (unittest) mixin(grammar!(Memoization.selective, compactTag)(`
ShadowedRule:
    Root <- Item('x')
    Item(digit = 'x') <- digit / 'y'
`));

@nogc nothrow unittest {
    ParseContext context;
    auto grammarParam = parseRecords!(ShadowedBuiltin!().opCall, compactTag)(context, "x");
    assert(grammarParam.successful && grammarParam.nodes.length == 1);
    auto ruleParam = parseRecords!(ShadowedRule.opCall, compactTag)(context, "x");
    assert(ruleParam.successful && ruleParam.nodes.length == 2);
    assert(check!(ShadowedBuiltin!().opCall)(context, "y").successful);
    assert(!check!(ShadowedBuiltin!().opCall)(context, "1").successful);
}

/// Cold runtime generation reports errors explicitly. Output uses selective druntime GC.
struct GenerationResult {
    Status status = Status.invalidInput;
    string source;
    Diagnostic diagnostic;
}

private bool containsText(string input, string needle) @nogc nothrow pure {
    if (needle.length > input.length)
        return false;
    foreach (i; 0 .. input.length - needle.length + 1)
        if (input[i .. i + needle.length] == needle)
            return true;
    return false;
}

/// Cold, opt-in diagnostics. Runs the same emitter and captures its decisions;
/// neither the returned report nor its evidence changes generated parser policy.
EligibilityResult eligibilityReport(Memoization memo = Memoization.yes, alias Selector = void,
        ParserBackend backend = ParserBackend.direct)(string definition,
        EligibilityFormat format = EligibilityFormat.json) nothrow {
    EligibilityResult result;
    if (format != EligibilityFormat.json && format != EligibilityFormat.text) {
        result.diagnostic = Diagnostic(0, "Unknown eligibility report format");
        return result;
    }
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Eligibility report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.memoize = memo != Memoization.no;
    frontend.selective = memo == Memoization.selective;
    frontend.backend = backend == ParserBackend.ll1 ? ParserBackend.direct : backend;
    frontend.llGuards = backend == ParserBackend.ll1;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    frontend.configureRecords!Selector();
    result.backend = backend;
    result.memoPolicy = memo;
    frontend.eligibility = &result;
    frontend.emit();
    result.report = renderEligibility(result, format);
    result.status = Status.ok;
    return result;
}

nothrow unittest {
    enum definition = "Report: Root <- Leaf eoi Leaf <- 'a' Opaque <- external Effect <- 'x'{effect} Rec <- Rec 'n' / 'n'";
    auto mixed = eligibilityReport!(Memoization.selective, compactTag, ParserBackend.direct)(definition);
    assert(mixed.status == Status.ok && mixed.grammarName == "Report");
    assert(mixed.conservative && mixed.actionRules == ["Report.Effect"]);
    assert(mixed.unknownEvidence.length == 2);
    assert(!mixed.rules[1].scalarEligible && mixed.rules[4].leftRecursive);
    assert(mixed.rules[0].recordSelected && mixed.rules[0].recordSubtree);
    assert(mixed.report == eligibilityReport!(Memoization.selective, compactTag,
            ParserBackend.direct)(definition).report);
    // Report the current emitter barrier even when its textual check is conservative.
    auto literalAction = eligibilityReport!(Memoization.selective, void, ParserBackend.direct)(
            "LiteralAction: Root <- 'action!('");
    assert(literalAction.actionRules == ["LiteralAction.Root"] && !literalAction.unknownEvidence.length);
    assert(!literalAction.rules[0].scalarEligible);
    auto strategies = eligibilityReport!(Memoization.selective, void, ParserBackend.direct)(
            "Strat: Root <- Digits Alt eoi Digits <~ [0-9]+ Alt <- 'a' 'x' / 'b' 'y' Lit <- 'q' Chr <- [q-r]");
    assert(strategies.status == Status.ok);
    foreach (row; strategies.rules) {
        if (row.name == "Strat.Digits")
            assert(row.dfaScanner && row.scannerRegions >= 1 && row.strategy == "dfa-scanner");
        if (row.name == "Strat.Alt")
            assert(row.predictiveDispatch && row.strategy == "direct-cursor");
        if (row.name == "Strat.Lit") // P2: plain literal roots lower to the direct cursor form
            assert(row.directRecognition && row.strategy == "direct-cursor");
        if (row.name == "Strat.Chr")
            assert(!row.dfaScanner && !row.predictiveDispatch && row.strategy == "combinator");
    }
    assert(containsText(strategies.report, "\"strategy\":\"dfa-scanner\""));
    auto plain = eligibilityReport!(Memoization.yes, void, ParserBackend.combinators)("Plain: Root <- 'a'");
    assert(plain.status == Status.ok && plain.rules[0].memoized);
    assert(plain.rules[0].directFallback == "backend-combinators");
    auto recursion = eligibilityReport!(Memoization.selective, void, ParserBackend.direct)(
            "RecReport: Root <- Root 'a' / 'a' Leaf <- 'a'");
    assert(recursion.rules[0].directFallback == "left-recursion");
    assert(recursion.rules[1].scalarEligible && recursion.rules[1].directRecognition); // P2: literal root
    auto parameter = eligibilityReport!(Memoization.selective, void, ParserBackend.direct)(
            "ParamReport(T=identifier): Root <- T");
    assert(parameter.rules[0].directFallback == "grammar-parameters");
    auto ruleParameter = eligibilityReport!(Memoization.selective, void, ParserBackend.direct)(
            "ParamRule: Root(P) <- P");
    assert(ruleParameter.status == Status.ok && ruleParameter.rules[0].directFallback == "rule-parameters");
    auto badEncoding = eligibilityReport("Bad: Root <- 'a' #\x80");
    assert(badEncoding.status == Status.invalidInput && badEncoding.diagnostic.offset == 18);
    auto invalid = eligibilityReport("Broken:");
    assert(invalid.status == Status.invalidInput && invalid.diagnostic.message.length);
    auto badFormat = eligibilityReport("Valid: Root <- 'a'", cast(EligibilityFormat)99);
    assert(badFormat.status == Status.invalidInput && badFormat.diagnostic.message.length);
}

/// Report-only BITES/SUCC/NULL languages per rule (B3); see docs/BITES.md. Never affects generated code.
struct BitesResult {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    string grammarName;
    string report;
}

BitesResult bitesReport(string definition, size_t budgetStates = Budget.init.maxStates, bool regularSucc = false) nothrow {
    BitesResult result;
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "BITES report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    Budget budget;
    budget.maxStates = budgetStates;
    result.report = renderBites(frontend.analyzed, budget, regularSucc);
    result.status = Status.ok;
    return result;
}

nothrow unittest {
    auto both = bitesReport("B: Guard <- !'abc' [a-z]* Plain <- 'abc' [a-z]*");
    assert(both.status == Status.ok && both.grammarName == "B");
    assert(both.report == bitesReport("B: Guard <- !'abc' [a-z]* Plain <- 'abc' [a-z]*").report);
    assert(startsWith(both.report, "{\"scope\""));
    assert(bitesReport("Bad: Root <- 'a' #\x80").status == Status.invalidInput);
    assert(bitesReport("Broken:").status == Status.invalidInput);
}

nothrow unittest {
    // P3/L4: ordered choices of short literals become inline dispatch in the exact and the accept clones.
    foreach (definition; [
        "L: Root <- ('abc' / 'abd' / 'xyz')+ eoi", "L: Root <- ('a' / 'ab' / 'b')+ eoi"
    ]) {
        auto direct = generate!(Memoization.selective, void, ParserBackend.direct)(definition);
        assert(direct.status == Status.ok && Frontend.countOf(direct.source, "_lc") >= 1);
    }
}

nothrow unittest {
    auto report = nextBitesReport("N: Root <- ('a' / 'b')* 'c' eoi");
    assert(report.status == Status.ok && report.grammarName == "N" && report.report.length);
    assert(nextBitesReport("Bad: Root <- 'a' #\x80").status == Status.invalidInput);
    assert(nextBitesReport("Broken:").status == Status.invalidInput);
}

/// Report-only NEXTBITES and Proposition 10-13 premise checks per choice/star (B5).
BitesResult nextBitesReport(string definition, size_t budgetStates = Budget.init.maxStates) nothrow {
    BitesResult result;
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "NEXTBITES report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    Budget budget;
    budget.maxStates = budgetStates;
    result.report = renderNextBites(frontend.analyzed, budget);
    result.status = Status.ok;
    return result;
}

/// Report-only candidate commit (cut) sites with theorem and premises per site (B6). Emits no cut.
BitesResult commitSiteReport(string definition, size_t budgetStates = Budget.init.maxStates) nothrow {
    BitesResult result;
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Commit site report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    Budget budget;
    budget.maxStates = budgetStates;
    result.report = renderCommitSites(frontend.analyzed, budget);
    result.status = Status.ok;
    return result;
}

/// Unified FIRST / BITES / NEXTBITES diagnostics per choice and star (B8): lint verdict and optimization candidate
/// are separate, with the governing theorem and blockers. Report-only; generated code is unaffected.
BitesResult diagnosticReport(string definition, EligibilityFormat format = EligibilityFormat.json,
        size_t budgetStates = Budget.init.maxStates, bool regularSucc = false) nothrow {
    BitesResult result;
    if (format != EligibilityFormat.json && format != EligibilityFormat.text) {
        result.diagnostic = Diagnostic(0, "Unknown diagnostic report format");
        return result;
    }
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Diagnostic report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    Budget budget;
    budget.maxStates = budgetStates;
    result.report = renderUnified(unifiedDiagnostics(frontend.analyzed, budget, regularSucc),
            format == EligibilityFormat.json);
    result.status = Status.ok;
    return result;
}

/// Report-only PEG -> LL/CFG region classification with witnesses and blockers (L1).
BitesResult conversionReport(string definition, EligibilityFormat format = EligibilityFormat.json) nothrow {
    BitesResult result;
    if (format != EligibilityFormat.json && format != EligibilityFormat.text) {
        result.diagnostic = Diagnostic(0, "Unknown conversion report format");
        return result;
    }
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Conversion report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    result.report = renderRegions(classifyRegions(frontend.analyzed), format == EligibilityFormat.json);
    result.status = Status.ok;
    return result;
}

/// Certified CFG/EBNF export (L2): only `certifiedLL1` regions are converted; others get a not-convertible/unknown entry.
BitesResult ebnfExport(string definition, EligibilityFormat format = EligibilityFormat.text) nothrow {
    BitesResult result;
    if (format != EligibilityFormat.json && format != EligibilityFormat.text) {
        result.diagnostic = Diagnostic(0, "Unknown EBNF export format");
        return result;
    }
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "EBNF export input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    result.report = renderEbnf(frontend.analyzed, format == EligibilityFormat.json);
    result.status = Status.ok;
    return result;
}

/// Canonical LR(1) analysis (L5) of every `certifiedLL1` rule's CFG reading: states and conflicts, report-only. LR freedom of
/// the CFG reading does not by itself prove that the PEG means the same (docs/LL.md); uncertified rules are listed as such.
BitesResult lrReport(string definition, EligibilityFormat format = EligibilityFormat.text, size_t maxStates = 512) nothrow {
    BitesResult result;
    if (format != EligibilityFormat.json && format != EligibilityFormat.text) {
        result.diagnostic = Diagnostic(0, "Unknown LR report format");
        return result;
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    const regions = classifyRegions(frontend.analyzed);
    const json = format == EligibilityFormat.json;
    result.report = json ? "[" : "";
    foreach (rule; 0 .. frontend.analyzed.roots.length) {
        const grammar = lrGrammarOf(frontend.analyzed, rule, regions);
        const automaton = buildLr(grammar, maxStates);
        result.report ~= (json && rule ? "," : "") ~ renderLr(frontend.analyzed.names[rule], grammar, automaton, json);
    }
    result.report ~= json ? "]" : "";
    result.status = Status.ok;
    return result;
}

/// The CFG reading and LR(1) tables of one rule, for table-driven recognition and tests (L6a).
struct LrBuild {
    Status status = Status.invalidInput;
    LrGrammar grammar;
    LrAutomaton automaton;
}

LrBuild lrBuild(string definition, string rule, size_t maxStates = 512) nothrow {
    LrBuild result;
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length)
        return result;
    frontend.prepareAnalysis();
    const regions = classifyRegions(frontend.analyzed);
    foreach (index, name; frontend.analyzed.names)
        if (name == rule) {
            result.grammar = lrGrammarOf(frontend.analyzed, index, regions);
            result.automaton = buildLr(result.grammar, maxStates);
            result.status = Status.ok;
        }
    return result;
}

nothrow unittest {
    // Certified LL(1) regions are LR(1) (every LL(1) grammar is); uncertified ones are reported, never built.
    auto text = lrReport("L: Num <- [0-9]+ Expr <- Num ('+' Num)* Root <- Expr eoi Bad <- !'x' 'a'").report;
    assert(Frontend.countOf(text, ": lr1 (") == 3, text);
    assert(Frontend.countOf(text, "rule Bad: unsupported (") == 1 && Frontend.countOf(text,
            "region-not-certifiedLL1") == 1);
    const json = lrReport("L: Root <- 'a' Root 'b' / 'c'", EligibilityFormat.json).report;
    assert(json[0] == '[' && Frontend.countOf(json, "\"verdict\":\"lr1\"") == 1);
    assert(lrBuild("L: Root <- 'a' eoi", "Missing").status == Status.invalidInput);
    const built = lrBuild("L: Root <- 'a'+ 'b' eoi", "Root");
    assert(built.status == Status.ok && !built.automaton.truncated && !built.automaton.conflicts.length);
}

/// O4(a): regular regions that mention rule references (what a record-emitting selector would turn into regions with inner
/// records, which the scanner cannot take). Report-only count per grammar; see performance/milestones/O4.
struct TagRegionResult {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    size_t rules, regions, composedRegions, rulesWithComposed, taggedRegions;
}

TagRegionResult tagRegionReport(string definition) nothrow {
    TagRegionResult result;
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    frontend.prepareAnalysis();
    result.rules = frontend.rules.length;
    foreach (index, rule; frontend.rules) {
        const saved = frontend.analyzed.expressions.length;
        size_t root = frontend.analyzed.roots[index];
        if (rule.body != frontend.analyzed.expressions[root].source) {
            root = frontend.expressionNode(frontend.analyzed, rule.body);
            frontend.analyzed.appendFacts(root);
        }
        size_t count;
        string declarations;
        const 
        body = frontend.emitTokens(frontend.analyzed, root, rule.name, count, declarations);
        const parsed = frontend.expressionNode(frontend.analyzed, body);
        size_t composed;
        foreach (node; frontend.analyzed.expressions[saved .. $])
            if (node.combinator == "dfaToken" && node.arguments.length == 4) {
                string flag = node.arguments[3];
                while (flag.length && (flag[0] == ' ' || flag[0] == '\t'))
                    flag = flag[1 .. $];
                ++result.regions;
                if (flag == "true" || flag == "2")
                    ++composed;
                if (flag == "2")
                    ++result.taggedRegions;
            }
        result.composedRegions += composed;
        result.rulesWithComposed += composed != 0;
        frontend.analyzed.truncate(saved);
    }
    result.status = Status.ok;
    return result;
}

nothrow unittest {
    // A regular region that calls a rule is a composed region; a pure token rule is a plain scanner region.
    const composed = tagRegionReport("T: Root <- Field (',' Field)* eoi Field <- [a-z]+");
    assert(composed.status == Status.ok && composed.composedRegions >= 1 && composed.rulesWithComposed >= 1);
    const plain = tagRegionReport("T: Root <- [a-z]+ eoi");
    assert(plain.status == Status.ok && plain.composedRegions == 0);
    assert(tagRegionReport("T: Root <-").status == Status.invalidInput);
}

/// Seeded candidate stream for a grammar's start rule (G1). Candidates are proposals, not known to be accepted;
/// failures carry a status and reason and are never returned as candidates.
struct CandidateStream {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    string[] texts; /// successfully generated candidates, in stream order
    GenStatus[] statuses; /// one per requested candidate
    string[] reasons;
}

CandidateStream generateCandidates(string definition, string startRule, size_t count,
        GeneratorOptions options = GeneratorOptions.init) nothrow {
    CandidateStream result;
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Candidate generation input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max) {
        result.diagnostic = Diagnostic(0, "Unknown start rule");
        return result;
    }
    auto generator = CandidateGenerator(frontend.analyzed, rule, options);
    foreach (i; 0 .. count) {
        auto candidate = generator.next();
        result.statuses ~= candidate.status;
        result.reasons ~= candidate.reason;
        if (candidate.status == GenStatus.ok)
            result.texts ~= candidate.text;
    }
    result.status = Status.ok;
    return result;
}

/// Outcome of oracle-filtered generation (G2). Every entry of `texts` was accepted by the supplied parser with the
/// whole input consumed; nothing else is ever listed as valid.
struct AcceptedSet {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    string[] texts;
    size_t proposed; /// candidates the walk produced
    size_t rejected; /// proposals the parser rejected, including partial consumption and resource limits
    size_t generationFailures; /// unsupported constructs and budget hits (no candidate existed)
    bool exhausted; /// the attempt budget ran out before `count` samples were accepted
    string[] failureReasons; /// distinct generation failure reasons, first occurrences
}

/// Full-acceptance oracle for generated inputs (G2). `parser` must be the compiled rule for `startRule` of the grammar
/// given by `definition` (for example `Fixture.Root` from `mixin(grammar!(...)(definition))`); the pair is not
/// checked. Parsing uses a fresh default `ParseContext` per candidate, so user actions are never run: a start rule that
/// reaches an action fails generation as unsupported instead.
AcceptedSet generateAccepted(alias parser)(string definition, string startRule, size_t count,
        GeneratorOptions options = GeneratorOptions.init, size_t maxAttempts = 10_000) nothrow {
    AcceptedSet result;
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Candidate generation input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max) {
        result.diagnostic = Diagnostic(0, "Unknown start rule");
        return result;
    }
    auto generator = CandidateGenerator(frontend.analyzed, rule, options);
    size_t attempts;
    while (result.texts.length < count) {
        if (attempts++ >= maxAttempts) {
            result.exhausted = true;
            break;
        }
        auto candidate = generator.next();
        if (candidate.status != GenStatus.ok) {
            ++result.generationFailures;
            bool known;
            foreach (reason; result.failureReasons)
                known = known || reason == candidate.reason;
            if (!known && result.failureReasons.length < 8)
                result.failureReasons ~= candidate.reason;
            continue;
        }
        ++result.proposed;
        ParseContext context;
        auto verdict = check!parser(context, candidate.text);
        if (verdict.status == Status.ok && verdict.successful && verdict.end == candidate.text.length)
            result.texts ~= candidate.text;
        else
            ++result.rejected;
    }
    result.status = Status.ok;
    return result;
}

/// Coverage-guided generation result (G3). Coverage counts only accepted samples, attributed by a reference derivation.
struct CoveringSet {
    AcceptedSet accepted;
    size_t coverable; /// reachable targets the matcher can evaluate
    size_t covered; /// of those, hit by at least one accepted sample
    size_t unreachable; /// targets in rules the start rule cannot reach
    size_t unknown; /// targets with constructs the matcher cannot follow
    size_t unattributed; /// accepted samples the matcher could not follow
    size_t proposedAlternatives; /// alternatives the generator proposed at least once (accepted or not)
    size_t exercisedAlternatives; /// alternatives that occur in an accepted sample's derivation
    string[] uncovered; /// descriptions of reachable, evaluable targets no accepted sample hit
}

/// Generate `count` accepted samples, steering the walk toward targets no accepted sample has hit yet: uncovered
/// alternatives get weight 8 (others 1), uncovered optional/repetition outcomes are favored three times in four.
/// Rule `startRule` of `definition` must be compiled as `parser`, as in `generateAccepted`.
CoveringSet generateCovering(alias parser)(string definition, string startRule, size_t count,
        GeneratorOptions options = GeneratorOptions.init,
        size_t maxAttempts = 20_000, bool stopWhenCovered = false, bool guided = true) nothrow {
    CoveringSet result;
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.accepted.diagnostic = Diagnostic(begin, "Candidate generation input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.accepted.diagnostic = frontend.error;
        return result;
    }
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max) {
        result.accepted.diagnostic = Diagnostic(0, "Unknown start rule");
        return result;
    }
    auto coverage = buildTargets(frontend.analyzed, rule);
    auto attributor = Attributor(frontend.analyzed, coverage);
    auto generator = CandidateGenerator(frontend.analyzed, rule, options);
    auto steer = delegate() nothrow{
        foreach (target; coverage.targets) {
            if (!target.reachable || target.unknown)
                continue;
            if (target.kind == TargetKind.alternative)
                generator.setWeight(target.node, target.alternative, target.hits == 0 ? 8 : 1);
        }
        // Optional and repetition outcomes: favor an uncovered one, otherwise default behavior.
        foreach (node; 0 .. frontend.analyzed.expressions.length) {
            ubyte bias;
            foreach (target; coverage.targets) {
                if (target.node != node || !target.reachable || target.unknown || target.hits != 0)
                    continue;
                final switch (target.kind) {
                case TargetKind.alternative:
                    break;
                case TargetKind.optionalTaken:
                case TargetKind.repeatOne:
                    bias = 2;
                    break;
                case TargetKind.optionalSkipped:
                case TargetKind.repeatNone:
                    bias = 1;
                    break;
                case TargetKind.repeatMany:
                    bias = 3;
                    break;
                }
            }
            generator.setRepeatBias(node, bias);
        }
    };
    size_t attempts;
    while (result.accepted.texts.length < count) {
        if (stopWhenCovered && coverage.coverable() && coverage.covered() == coverage.coverable()
                && result.accepted.texts.length)
            break;
        if (attempts++ >= maxAttempts) {
            result.accepted.exhausted = true;
            break;
        }
        if (guided)
            steer();
        auto candidate = generator.next();
        if (candidate.status != GenStatus.ok) {
            ++result.accepted.generationFailures;
            bool known;
            foreach (reason; result.accepted.failureReasons)
                known = known || reason == candidate.reason;
            if (!known && result.accepted.failureReasons.length < 8)
                result.accepted.failureReasons ~= candidate.reason;
            continue;
        }
        ++result.accepted.proposed;
        ParseContext context;
        auto verdict = check!parser(context, candidate.text);
        if (verdict.status == Status.ok && verdict.successful && verdict.end == candidate.text.length) {
            result.accepted.texts ~= candidate.text;
            attributor.record(rule, candidate.text);
        } else
            ++result.accepted.rejected;
    }
    result.accepted.status = Status.ok;
    result.coverable = coverage.coverable();
    result.covered = coverage.covered();
    result.unattributed = coverage.unattributed;
    foreach (target; coverage.targets) {
        result.unreachable += !target.reachable;
        result.unknown += target.reachable && target.unknown;
        if (target.reachable && !target.unknown && target.hits == 0) {
            string kind = target.kind == TargetKind.alternative ? "alternative " ~ number(
                    target.alternative) : target.kind == TargetKind.optionalTaken
                ? "optional taken" : target.kind == TargetKind.optionalSkipped
                ? "optional skipped" : target.kind == TargetKind.repeatNone
                ? "repeat none" : target.kind == TargetKind.repeatOne ? "repeat one" : "repeat many";
            result.uncovered ~= "node " ~ number(target.node) ~ " " ~ kind;
        }
        if (target.kind == TargetKind.alternative && target.reachable && !target.unknown) {
            result.exercisedAlternatives += target.hits != 0;
            const base = generator.altBase[target.node];
            result.proposedAlternatives += generator.proposedAlt[base + target.alternative];
        }
    }
    return result;
}

/// Result of policy-driven generation (G4). A policy with errors or bindings that do not resolve is reported and
/// nothing is generated (no silent fallback to default weights).
struct PolicyGeneration {
    AcceptedSet accepted;
    bool policyOk;
    string[] problems; /// parse errors and unresolved bindings
    string metadata; /// normalized policy as JSON, for the provenance of a generated corpus
}

/// Weighted generation (G4): choice weights, optional probabilities, repetition histograms and recursion attenuation
/// from an external policy text (see `npegged.policy`), with the G2 oracle on top. Same seed and policy give the same stream.
PolicyGeneration generateWithPolicy(alias parser)(string definition, string startRule, size_t count,
        string policyText, GeneratorOptions options = GeneratorOptions.init, size_t maxAttempts = 20_000) nothrow {
    PolicyGeneration result;
    auto parsed = parsePolicy(policyText);
    result.problems = parsed.errors;
    result.metadata = policyMetadata(parsed.policy);
    if (!parsed.ok)
        return result;
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.accepted.diagnostic = frontend.error;
        return result;
    }
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max) {
        result.accepted.diagnostic = Diagnostic(0, "Unknown start rule");
        return result;
    }
    auto generator = CandidateGenerator(frontend.analyzed, rule, options);
    result.problems ~= applyPolicy(generator, frontend.analyzed, parsed.policy);
    if (result.problems.length)
        return result;
    result.policyOk = true;
    size_t attempts;
    while (result.accepted.texts.length < count) {
        if (attempts++ >= maxAttempts) {
            result.accepted.exhausted = true;
            break;
        }
        auto candidate = generator.next();
        if (candidate.status != GenStatus.ok) {
            ++result.accepted.generationFailures;
            bool known;
            foreach (reason; result.accepted.failureReasons)
                known = known || reason == candidate.reason;
            if (!known && result.accepted.failureReasons.length < 8)
                result.accepted.failureReasons ~= candidate.reason;
            continue;
        }
        ++result.accepted.proposed;
        ParseContext context;
        auto verdict = check!parser(context, candidate.text);
        if (verdict.status == Status.ok && verdict.successful && verdict.end == candidate.text.length)
            result.accepted.texts ~= candidate.text;
        else
            ++result.accepted.rejected;
    }
    result.accepted.status = Status.ok;
    return result;
}

/// Weights learned from a corpus (G5). Marginal per-construct statistics; see `npegged.learning` for the limits.
struct LearnedModel {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    size_t accepted; /// inputs the parser accepted and the derivation could follow (used for learning)
    size_t invalid; /// inputs the parser rejected (ignored)
    size_t unattributable; /// accepted inputs the derivation could not follow (ignored)
    string policyText; /// G4 policy
    string provenance;
    ulong[] choiceShares; /// observed alternative shares in permille per choice, flattened
}

/// Learn a policy from `corpus` by parsing every input with the real rule `parser` (full acceptance required to learn from it).
LearnedModel learnPolicy(alias parser)(string definition, string startRule, const string[] corpus, size_t smoothing = 1) nothrow {
    LearnedModel result;
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max) {
        result.diagnostic = Diagnostic(0, "Unknown start rule");
        return result;
    }
    auto learner = Learner(frontend.analyzed, rule);
    foreach (text; corpus) {
        ParseContext context;
        auto verdict = check!parser(context, text);
        learner.observe(text, verdict.status == Status.ok && verdict.successful && verdict.end == text.length);
    }
    result.accepted = learner.learned();
    result.invalid = learner.invalid;
    result.unattributable = learner.ignoredUnattributed;
    result.policyText = learner.policyText(smoothing);
    result.choiceShares = learner.choiceShares();
    result.provenance = "learned from " ~ number(corpus.length) ~ " input(s): " ~ number(
            result.accepted) ~ " used, " ~ number(result.invalid) ~ " invalid ignored, " ~ number(
            result.unattributable) ~ " unattributable ignored; smoothing "
        ~ number(smoothing) ~ "; marginal statistics (no context), sampling bias of the corpus is inherited";
    result.status = Status.ok;
    return result;
}

/// Holdout comparison (G5): how close generated samples are to real ones, in permille (0 = identical).
struct HoldoutReport {
    Status status = Status.invalidInput;
    size_t choiceShareDistance; /// mean absolute difference of alternative shares
    size_t lengthDistance; /// total variation distance of power-of-two length buckets
    size_t realMeanLength, generatedMeanLength;
}

HoldoutReport compareToHoldout(alias parser)(string definition, string startRule,
        const string[] holdout, const string[] generated) nothrow {
    HoldoutReport report;
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length)
        return report;
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max)
        return report;
    auto observed = Learner(frontend.analyzed, rule);
    auto synthetic = Learner(frontend.analyzed, rule);
    foreach (text; holdout) {
        ParseContext context;
        auto verdict = check!parser(context, text);
        observed.observe(text, verdict.status == Status.ok && verdict.successful && verdict.end == text.length);
        report.realMeanLength += text.length;
    }
    foreach (text; generated) {
        ParseContext context;
        auto verdict = check!parser(context, text);
        synthetic.observe(text, verdict.status == Status.ok && verdict.successful && verdict.end == text.length);
        report.generatedMeanLength += text.length;
    }
    report.realMeanLength = holdout.length ? report.realMeanLength / holdout.length : 0;
    report.generatedMeanLength = generated.length ? report.generatedMeanLength / generated.length : 0;
    report.choiceShareDistance = shareDistance(observed.choiceShares(), synthetic.choiceShares());
    report.lengthDistance = lengthDistance(holdout, generated);
    report.status = Status.ok;
    return report;
}

/// Options for differential fuzzing (G6). All sources are seeded; a run is a pure function of its options and grammar.
struct FuzzOptions {
    ulong seed = 1;
    size_t iterations = 2000;
    size_t seedSamples = 24; /// valid seeds (G2) the mutants start from
    size_t maxLength = 128;
    size_t stepLimit = 1_000_000;
    size_t deadlineMillis = 20_000; /// wall-clock budget; 0 disables
    size_t keepInvalid = 32; /// oracle-verified invalid inputs retained in the report
}

struct FuzzReport {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    size_t iterations; /// inputs compared (seeds, mutants and random bytes)
    size_t validSeeds, validMutants, invalidMutants, randomInputs; /// labels come from the real parser (parser A)
    string[] invalidSamples; /// retained inputs the parser rejected
    Mismatch[] mismatches; /// shrunk disagreements between A and B
    string[] regressionLines; /// versioned seeds for each mismatch
    bool deadlineHit;
}

/// Differential fuzzing of two parsers of the same grammar (for example the combinator and direct backends).
/// `parserA` labels inputs valid/invalid and is the reference; any disagreement of status, success, end or failEnd with
/// `parserB` is shrunk (delta debugging) and recorded. `definition`/`startRule` drive seeds and the mutation dictionary.
FuzzReport fuzzDifferential(alias parserA, alias parserB)(string definition, string startRule,
        string labelA, string labelB, FuzzOptions options = FuzzOptions.init) nothrow {
    FuzzReport report;
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        report.diagnostic = frontend.error;
        return report;
    }
    frontend.prepareAnalysis();
    const rule = frontend.analyzed.ruleIndex(startRule);
    if (rule == size_t.max) {
        report.diagnostic = Diagnostic(0, "Unknown start rule");
        return report;
    }
    // Mutation dictionary: literals and one member of each byte class used by the grammar.
    string[] dictionary;
    foreach (node; frontend.analyzed.expressions) {
        string text;
        if (node.kind == ExpressionKind.terminal && CandidateGenerator.literalBytes(node.source, text) && text.length) {
            bool known;
            foreach (entry; dictionary)
                known = known || entry == text;
            if (!known && dictionary.length < 64)
                dictionary ~= text;
        } else if (node.kind == ExpressionKind.terminal && node.byteTerminal && node.byteWidth == 1 && node.known)
            foreach (c; 0 .. 256)
                if (node.alphabet.contains(cast(char)c)) {
                    dictionary ~= [cast(char)c].idup;
                    break;
                }
    }
    GeneratorOptions generation;
    generation.seed = options.seed;
    auto seeds = generateAccepted!parserA(definition, startRule, options.seedSamples, generation, 5000);
    auto mutator = Mutator(options.seed ^ 0xA5A5A5A5UL, dictionary);
    mutator.maxLength = options.maxLength;
    const started = MonoTime.currTime;
    string[] seen;
    size_t step;
    void compare(string input, size_t iteration) nothrow {
        ++report.iterations;
        const a = observe!parserA(input, options.stepLimit);
        const b = observe!parserB(input, options.stepLimit);
        if (sameObservation(a, b))
            return;
        bool known;
        foreach (text; seen)
            known = known || text == input;
        if (known)
            return;
        auto minimal = shrink(input, delegate(string candidate) nothrow{
            return !sameObservation(observe!parserA(candidate, options.stepLimit),
                observe!parserB(candidate, options.stepLimit));
        });
        seen ~= input;
        report.mismatches ~= Mismatch(iteration, input, minimal, observe!parserA(minimal,
                options.stepLimit), observe!parserB(minimal, options.stepLimit));
        report.regressionLines ~= regressionLine(nameOfGrammar(definition), startRule, options.seed,
                iteration, labelA, labelB, minimal);
    }

    foreach (text; seeds.texts) {
        ++report.validSeeds;
        compare(text, step++);
    }
    foreach (iteration; 0 .. options.iterations) {
        if (options.deadlineMillis && (MonoTime.currTime - started).total!"msecs" > options.deadlineMillis) {
            report.deadlineHit = true;
            break;
        }
        string input;
        if (!seeds.texts.length || iteration % 4 == 3) {
            input = mutator.randomBytes();
            ++report.randomInputs;
        } else {
            input = mutator.mutate(seeds.texts[mutator.pickIndex(seeds.texts.length)]);
            const label = accepts(observe!parserA(input, options.stepLimit), input.length);
            if (label)
                ++report.validMutants;
            else {
                ++report.invalidMutants;
                if (report.invalidSamples.length < options.keepInvalid)
                    report.invalidSamples ~= input;
            }
        }
        compare(input, step++);
    }
    report.status = Status.ok;
    return report;
}

private string nameOfGrammar(string definition) nothrow {
    size_t end;
    while (end < definition.length && definition[end] != ':')
        ++end;
    return definition[0 .. end];
}

/// Replay one regression line against two parsers: true when the disagreement it records still exists.
bool replayStillMismatches(alias parserA, alias parserB)(string line, size_t stepLimit = 1_000_000) nothrow {
    Regression regression;
    if (!parseRegression(line, regression))
        return false;
    return !sameObservation(observe!parserA(regression.input, stepLimit),
            observe!parserB(regression.input, stepLimit));
}

/// Bounded literal-prefix discrimination report for ordered choice alternatives.
struct PrefixDiscriminationResult {
    Status status = Status.invalidInput;
    Diagnostic diagnostic;
    string grammarName;
    ChoiceDiscrimination[] choices;
    string report;
}

PrefixDiscriminationResult prefixDiscriminationReport(string definition,
        EligibilityFormat format = EligibilityFormat.json, bool regularSucc = false) nothrow {
    PrefixDiscriminationResult result;
    if (format != EligibilityFormat.json && format != EligibilityFormat.text) {
        result.diagnostic = Diagnostic(0, "Unknown prefix discrimination report format");
        return result;
    }
    size_t position;
    while (position < definition.length) {
        const begin = position;
        dchar scalar;
        if (!decode(definition, position, scalar)) {
            result.diagnostic = Diagnostic(begin, "Prefix discrimination report input is not UTF-8");
            return result;
        }
    }
    Frontend frontend;
    frontend.input = definition;
    frontend.read();
    if (frontend.error.message.length) {
        result.diagnostic = frontend.error;
        return result;
    }
    result.grammarName = frontend.name;
    frontend.prepareAnalysis();
    result.choices = frontend.analyzed.analyzeAllPrefixDiscriminations();
    annotateBites(frontend.analyzed, result.choices, Budget.init, regularSucc);
    result.report = renderDiscrimination(result.choices, format == EligibilityFormat.json);
    result.status = Status.ok;
    return result;
}

nothrow unittest {
    auto res = prefixDiscriminationReport("TestChoice: Root <- 'ab' / 'ac'");
    assert(res.status == Status.ok && res.grammarName == "TestChoice");
    assert(res.choices.length == 1 && res.choices[0].hasOverlap);
    assert(res.choices[0].pairs.length == 1);
    assert(res.choices[0].pairs[0].kind == DiscriminationKind.disjointTails);
    assert(res.choices[0].pairs[0].commonPrefix == "a");
    auto badEnc = prefixDiscriminationReport("Bad: Root <- 'a' #\x80");
    assert(badEnc.status == Status.invalidInput);
    auto badFmt = prefixDiscriminationReport("BadFmt: Root <- 'a'", cast(EligibilityFormat)99);
    assert(badFmt.status == Status.invalidInput);
    auto broken = prefixDiscriminationReport("Broken:");
    assert(broken.status == Status.invalidInput);
}

GenerationResult generate(Memoization memo = Memoization.yes, alias Selector = void,
        ParserBackend backend = ParserBackend.direct)(string definition, string moduleName = "") nothrow {
    Frontend frontend;
    frontend.input = definition;
    frontend.memoize = memo != Memoization.no;
    frontend.selective = memo == Memoization.selective;
    frontend.backend = backend == ParserBackend.ll1 ? ParserBackend.direct : backend;
    frontend.llGuards = backend == ParserBackend.ll1;
    frontend.read();
    if (frontend.error.message.length)
        return GenerationResult(Status.invalidInput, null, frontend.error);
    frontend.configureRecords!Selector();
    auto source = frontend.emit();
    if (moduleName.length)
        source = "module " ~ moduleName ~ ";\npublic import npegged.peg;\npublic import npegged.dfa;\n" ~ source;
    return GenerationResult(Status.ok, source);
}

unittest {
    auto result = generate("Test: A <- 'a'", "test_generated");
    assert(result.status == Status.ok && result.source.length);
    auto invalid = generate("Test: A <- (");
    assert(invalid.status == Status.invalidInput);
}

Status asModule(Memoization memo = Memoization.yes, alias Selector = void, ParserBackend backend = ParserBackend.direct)(
        string moduleName, string fileName, string definition, string header = "") nothrow {
    import npegged.io : File;

    auto result = generate!(memo, Selector, backend)(definition);
    if (result.status != Status.ok)
        return result.status;
    auto file = File.open(fileName ~ ".d", true);
    if (file.write("// Generated from Pegged-derived npegged grammar. Boost 1.0.\n") != Status.ok)
        return Status.ioError;
    if (file.write("module " ~ moduleName ~ ";\npublic import npegged.peg;\npublic import npegged.dfa;\n") != Status.ok)
        return Status.ioError;
    if (header.length && file.write(header ~ "\n") != Status.ok)
        return Status.ioError;
    return file.write(result.source);
}

unittest {
    assert(asModule("test", "/nonexistent/npegged", "Test: A <- 'a'") == Status.ioError);
    assert(asModule("test", "build/invalid", "Test:") == Status.invalidInput);
    assert(asModule("test", "build/roundtrip", "Test: A <- 'a'", "// custom header") == Status.ok);
}

/// Generate from a successful grammar parse while its owning result remains alive.
string grammar(Memoization memo = Memoization.yes, alias Selector = void, ParserBackend backend = ParserBackend.direct)(
        scope const ref ParseTree definition) nothrow {
    if (!definition.successful)
        return "static assert(false, `Cannot generate from a failed grammar parse`);";
    return grammar!(memo, Selector, backend)(definition.input);
}

nothrow unittest {
    import npegged.parser : Pegged;

    ParseContext context;
    auto parsed = Pegged(context, "TreeInput: A <- 'a'");
    auto source = grammar(parsed.tree);
    assert(source.length);
    ParseTree invalid;
    auto failure = grammar(invalid);
    assert(failure.length);
}

/// Borrow a scoped file and generate a parser module, preserving I/O error status.
Status asModule(Memoization memo = Memoization.yes, alias Selector = void, ParserBackend backend = ParserBackend.direct)(
        string moduleName, string destination, ref npegged.io.File input, string header = "") nothrow {
    import npegged.storage : Buffer;

    Buffer!char text;
    auto status = input.read(text);
    if (status != Status.ok)
        return status;
    return asModule!(memo, Selector, backend)(moduleName, destination, cast(string)text.data, header);
}

nothrow unittest {
    import npegged.io : File;

    File invalid;
    assert(asModule("test", "build/from-file", invalid) == Status.ioError);
    {
        auto output = File.open("build/input.peg", true);
        assert(output.write("FromFile: A <- 'a'") == Status.ok);
    }
    auto input = File.open("build/input.peg");
    assert(asModule("from_file", "build/from-file", input) == Status.ok);
}

version (unittest) mixin(grammar(`RawBytes: Start <- [\xFF] :eoi`));
@nogc nothrow unittest {
    ParseContext context;
    auto raw = RawBytes(context, "\xff");
    assert(raw.successful && raw.end == 1);
    auto unicode = RawBytes(context, "ÿ");
    assert(!unicode.successful);
}

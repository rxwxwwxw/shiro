/** Mutation, differential fuzzing and shrinking (G6). Cold tooling; no parser is changed.

    Inputs come from three sources: valid seeds (G1/G2), mutants of valid seeds, and uniformly random bytes. The real parser
    labels every mutant valid or invalid (a mutation may keep a sample valid; it is never assumed invalid). Two parsers are
    compared on every input; a disagreement in status, success, end or farthest-failure position is shrunk by delta
    debugging to a 1-minimal input and recorded as a versioned regression seed.

    Mutations: bit flip; insert a dictionary token (delimiters, keywords, class members taken from the grammar); delete a
    range; duplicate a slice; truncate (end-of-input boundary); replace a byte from the dictionary; UTF-8 damage (stray
    continuation or lead bytes, cutting inside a multi-byte sequence); and replacement by random bytes.
*/
module npegged.fuzz;
import npegged.peg;

nothrow:

struct Observation {
    Status status;
    bool successful;
    size_t end, failEnd;
}

bool sameObservation(const Observation a, const Observation b) @nogc pure {
    return a.status == b.status && a.successful == b.successful && a.end == b.end && a.failEnd == b.failEnd;
}

@nogc pure nothrow unittest {
    const original = Observation(Status.ok, true, 3, 4);
    assert(sameObservation(original, original));
    Observation changed = original;
    changed.status = Status.mismatch;
    assert(!sameObservation(original, changed));
    changed = original;
    changed.successful = false;
    assert(!sameObservation(original, changed));
    changed = original;
    changed.end = 2;
    assert(!sameObservation(original, changed));
    changed = original;
    changed.failEnd = 5;
    assert(!sameObservation(original, changed));
}

/// Observable result of the real parser on `input` with bounded work.
Observation observe(alias parser)(string input, size_t stepLimit = 1_000_000) {
    ParseContext context;
    context.stepLimit = stepLimit;
    auto node = check!parser(context, input);
    return Observation(node.status, node.successful, node.end, node.failEnd);
}

/// Whole-input acceptance, the oracle for labelling.
bool accepts(const Observation observation, size_t length) @nogc pure {
    return observation.status == Status.ok && observation.successful && observation.end == length;
}

@nogc pure nothrow unittest {
    assert(accepts(Observation(Status.ok, true, 0, 0), 0));
    assert(!accepts(Observation(Status.mismatch, true, 0, 0), 0));
    assert(!accepts(Observation(Status.ok, false, 0, 0), 0));
    assert(!accepts(Observation(Status.ok, true, 1, 1), 2));
}

private ulong splitmix(ref ulong state) @nogc pure {
    state += 0x9E3779B97F4A7C15UL;
    ulong z = state;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    return z ^ (z >> 31);
}

struct Mutator {
nothrow:
    ulong state;
    string[] dictionary;
    size_t maxLength = 256;

    this(ulong seed, string[] dictionary) {
        state = seed;
        this.dictionary = dictionary;
    }

    private size_t pick(size_t n) {
        return n ? splitmix(state) % n : 0;
    }

    size_t pickIndex(size_t n) {
        return pick(n);
    }

    private string token() {
        return dictionary.length ? dictionary[pick(dictionary.length)] : "a";
    }

    string randomBytes() {
        char[] bytes = new char[pick(maxLength / 4 + 1)];
        foreach (ref b; bytes)
            b = cast(char)pick(256);
        return cast(string)bytes;
    }

    string mutate(string seed) {
        char[] text = seed.dup;
        const operation = pick(9);
        const at = pick(text.length + 1);
        string result;
        switch (operation) {
        case 0: // flip one bit
            if (text.length) {
                // Compound-assignment operands are evaluated in different orders
                // by the supported toolchains. Keep the recorded PRNG stream portable.
                const index = pick(text.length);
                const bit = pick(8);
                text[index] ^= cast(char)(1 << bit);
            }
            result = cast(string)text;
            break;
        case 1: // insert a token
            result = seed[0 .. at] ~ token() ~ seed[at .. $];
            break;
        case 2: // delete a range
            if (text.length) {
                const from = pick(text.length);
                const to = from + 1 + pick(text.length - from);
                result = seed[0 .. from] ~ seed[to .. $];
            } else
                result = seed;
            break;
        case 3: // duplicate a slice
            if (text.length) {
                const from = pick(text.length);
                const to = from + 1 + pick(text.length - from);
                result = seed[0 .. to] ~ seed[from .. to] ~ seed[to .. $];
            } else
                result = seed;
            break;
        case 4: // truncate: the end-of-input boundary
            result = seed[0 .. at];
            break;
        case 5: // replace a byte by a dictionary byte
            if (text.length) {
                const t = token();
                text[pick(text.length)] = t.length ? t[0] : 'a';
            }
            result = cast(string)text;
            break;
        case 6: // UTF-8 damage: cut inside a multi-byte sequence if there is one, else insert stray bytes
            size_t lead = size_t.max;
            foreach (i, c; seed)
                if (cast(ubyte)c >= 0xC0)
                    lead = i;
            if (lead != size_t.max && pick(2))
                result = seed[0 .. lead + 1];
            else {
                enum stray = "\x80\xbf\xc3\xe2\xf0\xff\xc0\xed";
                result = seed[0 .. at] ~ stray[pick(stray.length) .. $][0 .. 1] ~ seed[at .. $];
            }
            break;
        case 7: // replacement by random bytes
            result = randomBytes();
            break;
        default: // two stacked mutations
            result = mutate(mutate(seed));
        }
        return result.length > maxLength ? result[0 .. maxLength] : result;
    }
}

nothrow unittest {
    auto mutator = Mutator(29, [""]);
    const before = mutator.state;
    assert(mutator.pickIndex(0) == 0 && mutator.state == before);
    foreach (limit; [0UL, 1UL, 4UL]) {
        mutator.maxLength = limit;
        foreach (seed; ["", "a", "é"]) {
            foreach (_; 0 .. 512)
                assert(mutator.mutate(seed).length <= limit);
        }
    }
}

nothrow unittest {
    enum input = "abcd";
    size_t checked;
    foreach (seed; 0 .. 256) {
        auto stream = Mutator(seed, []);
        const operation = stream.pickIndex(9);
        cast(void)stream.pickIndex(input.length + 1);
        if (operation != 0)
            continue;
        const index = stream.pickIndex(input.length);
        const bit = stream.pickIndex(8);
        auto expected = input.dup;
        expected[index] ^= cast(char)(1 << bit);
        auto actual = Mutator(seed, []);
        assert(actual.mutate(input) == expected && actual.state == stream.state);
        ++checked;
    }
    assert(checked > 0);
}

/// Delta debugging: remove chunks (halves, quarters, ... single bytes) while `fails` still holds, repeating each
/// size until it removes nothing; the result is 1-minimal (no single byte can be dropped).
string shrink(string input, bool delegate(string) nothrow fails) {
    string current = input;
    size_t chunk = current.length / 2 > 1 ? current.length / 2 : 1;
    while (current.length) {
        bool removed;
        size_t at;
        while (at < current.length) {
            const to = at + chunk < current.length ? at + chunk : current.length;
            const candidate = current[0 .. at] ~ current[to .. $];
            if (fails(candidate)) {
                current = candidate;
                removed = true;
            } else
                at += chunk;
        }
        if (removed)
            continue;
        if (chunk == 1)
            break;
        chunk /= 2;
    }
    return current;
}

nothrow unittest {
    assert(shrink("abc", (string) nothrow => true).length == 0);
    assert(shrink("abc", (string) nothrow => false) == "abc");
    assert(shrink("", (string) nothrow => true).length == 0);
}

/// One shrunk disagreement.
struct Mismatch {
    size_t iteration;
    string original, shrunk;
    Observation first, second;
}

private string hex(string bytes) nothrow {
    enum digits = "0123456789abcdef";
    string result;
    foreach (c; bytes) {
        result ~= digits[(cast(ubyte)c) >> 4];
        result ~= digits[(cast(ubyte)c) & 15];
    }
    return result;
}

private bool unhex(string text, out string bytes) nothrow {
    if (text.length % 2)
        return false;
    int nibble(char c) @nogc nothrow {
        return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
    }

    for (size_t i; i < text.length; i += 2) {
        const hi = nibble(text[i]), lo = nibble(text[i + 1]);
        if (hi < 0 || lo < 0)
            return false;
        bytes ~= cast(char)(hi * 16 + lo);
    }
    return true;
}

nothrow unittest {
    string decoded;
    assert(unhex("", decoded) && decoded.length == 0);
    assert(unhex("00ff61", decoded) && decoded == "\0\xffa");
    foreach (invalid; ["0", "g0", "0g", "A0", "-1"])
        assert(!unhex(invalid, decoded));
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

/// Versioned regression line: `fuzz-seed v1 grammar=<g> start=<r> seed=<n> iteration=<k> a=<label> b=<label> input=<hex>`.
string regressionLine(string grammar, string start, ulong seed, size_t iteration, string labelA,
        string labelB, string input) nothrow {
    return "fuzz-seed v1 grammar=" ~ grammar ~ " start=" ~ start ~ " seed=" ~ decimal(
            cast(size_t)seed) ~ " iteration=" ~ decimal(iteration) ~ " a=" ~ labelA ~ " b=" ~ labelB
        ~ " input=" ~ hex(input);
}

struct Regression {
    string grammar, start, labelA, labelB, input;
    size_t seed, iteration;
}

/// Parse a regression line; false for anything that is not a `v1` line.
bool parseRegression(string line, out Regression result) nothrow {
    string[] parts;
    size_t begin;
    foreach (i; 0 .. line.length + 1)
        if (i == line.length || line[i] == ' ') {
            if (i > begin)
                parts ~= line[begin .. i];
            begin = i + 1;
        }
    if (parts.length != 9 || parts[0] != "fuzz-seed" || parts[1] != "v1")
        return false;
    string value(string part, string key) nothrow {
        return part.length >= key.length + 1 && part[0 .. key.length] == key && part[key.length] == '='
            ? part[key.length + 1 .. $] : null;
    }

    result.grammar = value(parts[2], "grammar");
    result.start = value(parts[3], "start");
    result.labelA = value(parts[6], "a");
    result.labelB = value(parts[7], "b");
    const seed = value(parts[4], "seed"), iteration = value(parts[5], "iteration"), input = value(parts[8], "input");
    if (!result.grammar.length || !result.start.length || !result.labelA.length
            || !result.labelB.length || !seed.length || !iteration.length || input is null)
        return false;
    foreach (c; seed)
        if (c < '0' || c > '9')
            return false;
    foreach (c; iteration)
        if (c < '0' || c > '9')
            return false;
    foreach (c; seed) {
        const digit = cast(size_t)(c - '0');
        if (result.seed > (size_t.max - digit) / 10)
            return false;
        result.seed = result.seed * 10 + digit;
    }
    foreach (c; iteration) {
        const digit = cast(size_t)(c - '0');
        if (result.iteration > (size_t.max - digit) / 10)
            return false;
        result.iteration = result.iteration * 10 + digit;
    }
    return unhex(input, result.input);
}

nothrow unittest {
    Regression parsed;
    auto empty = regressionLine("G", "Root", size_t.max, size_t.max, "reference", "direct", "");
    assert(parseRegression(empty, parsed) && parsed.input.length == 0);
    assert(parsed.seed == size_t.max && parsed.iteration == size_t.max);
    const prefix = "fuzz-seed v1 grammar=G start=Root seed=";
    const suffix = " a=reference b=direct input=00";
    foreach (bad; [
        "fuzz-seed v1 grammar= start=Root seed=1 iteration=1" ~ suffix,
        "fuzz-seed v1 grammar=G start= seed=1 iteration=1" ~ suffix,
        prefix ~ "1 iteration=1 a= b=direct input=00", prefix ~ "1 iteration=1 a=reference b= input=00",
        prefix ~ "1 iteration=1 a=reference b=direct wrong=00", prefix ~ "x iteration=1" ~ suffix,
        prefix ~ "1 iteration=x" ~ suffix, prefix ~ decimal(size_t.max) ~ "0 iteration=1" ~ suffix,
        prefix ~ "1 iteration=" ~ decimal(size_t.max) ~ "0" ~ suffix
    ])
        assert(!parseRegression(bad, parsed));
}

nothrow unittest {
    // splitmix64 reference and mutator determinism
    ulong s = 1;
    assert(splitmix(s) == 0x910A2DEC89025CC1UL);
    auto one = Mutator(5, ["{", "}", "true"]), two = Mutator(5, ["{", "}", "true"]);
    foreach (i; 0 .. 100)
        assert(one.mutate("{\"a\":true}") == two.mutate("{\"a\":true}"));
    auto other = Mutator(6, ["{", "}", "true"]);
    bool differs;
    foreach (i; 0 .. 50)
        differs = differs || other.mutate("{\"a\":true}") != Mutator(5, ["{", "}", "true"]).mutate("{\"a\":true}");
    assert(differs);
    // shrinking reaches a 1-minimal input
    const minimal = shrink("xxxbxxxxcxx", (string t) nothrow{
        return contains(t, 'b') && contains(t, 'c');
    });
    assert(minimal.length == 2 && contains(minimal, 'b') && contains(minimal, 'c'));
    // regression lines roundtrip, bytes included
    const line = regressionLine("G", "Root", 42, 7, "combinators", "direct", "\x00\xffa");
    Regression parsed;
    assert(parseRegression(line, parsed) && parsed.input == "\x00\xffa" && parsed.seed == 42 && parsed.iteration == 7);
    assert(parsed.grammar == "G" && parsed.labelA == "combinators" && parsed.labelB == "direct");
    foreach (bad; [
        "", "fuzz-seed v2 grammar=G start=R seed=1 iteration=1 a=x b=y input=00",
        "fuzz-seed v1 grammar=G start=R seed=x iteration=1 a=x b=y input=00",
        "fuzz-seed v1 grammar=G start=R seed=1 iteration=1 a=x b=y input=0"
    ])
        assert(!parseRegression(bad, parsed));
}

private bool contains(string text, char wanted) @nogc nothrow pure {
    foreach (c; text)
        if (c == wanted)
            return true;
    return false;
}

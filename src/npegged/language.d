/** Cold input-language algebra for BITES analysis (B1). Report-only; no parser depends on it.

    An `InputLanguage` is a set of whole input strings (end of input included), kept as a complete
    byte DFA, so union, intersection and complement are exact and emptiness is decided, not sampled.

    Proof contract:
    - `provenEmpty` / `provenNonempty` are exact answers about the represented set.
    - `unknown` means a budget was exceeded; it is never treated as empty. Callers must pick the
      direction explicitly: an *over*-approximation (BITES, NULL) replaces `unknown` by `universal`,
      an *under*-approximation (SUCC) replaces it by `empty`. Complement is only meaningful on a
      language that is itself an exact or lower approximation.
    - Terminals that do not consume (`eps`, `eoi`) must never be turned into `prefix(...)`.
*/
module npegged.language;
import npegged.peg : CharSetMask;

nothrow:

enum Proof : ubyte {
    provenEmpty,
    provenNonempty,
    unknown
}

/// Work bounds shared by every operation; exceeding one makes the result `unknown`.
struct Budget {
    size_t maxStates = 512;
}

struct InputLanguage {
nothrow:
    // State 0 is the start. Every state has a transition for every byte (a dead state absorbs).
    ushort[256][] next;
    bool[] accepting;
    bool overflow; /// a budget was exceeded; the representation is meaningless

    /// No input string.
    static InputLanguage empty() {
        InputLanguage result;
        result.next = new ushort[256][1];
        result.accepting = [false];
        return result;
    }

    /// Every input string, including the empty one.
    static InputLanguage universal() {
        auto result = empty();
        result.accepting[0] = true;
        return result;
    }

    /// Only the empty input (end of input at the current position).
    static InputLanguage endOfInput() {
        InputLanguage result;
        result.next = new ushort[256][2];
        foreach (c; 0 .. 256) {
            result.next[0][c] = 1; // any byte leads to the dead state 1
            result.next[1][c] = 1;
        }
        result.accepting = [true, false];
        return result;
    }

    static InputLanguage unknownLanguage() {
        InputLanguage result = empty();
        result.overflow = true;
        return result;
    }

    /// Strings that start with one of the bytes in `first`, then anything: first Σ*.
    static InputLanguage bytePrefix(const CharSetMask first) {
        InputLanguage result;
        result.next = new ushort[256][3]; // 0 start, 1 accept-all, 2 dead
        foreach (c; 0 .. 256) {
            result.next[0][c] = first.contains(cast(char)c) ? 1 : 2;
            result.next[1][c] = 1;
            result.next[2][c] = 2;
        }
        result.accepting = [false, true, false];
        return result;
    }

    /// Strings that start with `text`, then anything: L(text) Σ*. An empty text is the universal language.
    static InputLanguage prefix(scope const(char)[] text) {
        if (!text.length)
            return universal();
        const n = text.length;
        InputLanguage result;
        result.next = new ushort[256][n + 2]; // 0..n-1 expect text[i], n accept-all, n+1 dead
        result.accepting = new bool[n + 2];
        result.accepting[n] = true;
        foreach (c; 0 .. 256) {
            foreach (i; 0 .. n)
                result.next[i][c] = cast(ubyte)c == cast(ubyte)text[i] ? cast(ushort)(i + 1) : cast(ushort)(n + 1);
            result.next[n][c] = cast(ushort)n;
            result.next[n + 1][c] = cast(ushort)(n + 1);
        }
        return result;
    }

    /// The strings `x y` where `x` has one byte from each class of `pattern` in order and `y` is in `rest`.
    /// Exceeding the budget yields `unknownLanguage`.
    static InputLanguage fixedThen(scope const(CharSetMask)[] pattern, const InputLanguage rest,
            Budget budget = Budget.init) {
        if (rest.overflow)
            return unknownLanguage();
        if (!pattern.length)
            return cast(InputLanguage)rest;
        const n = pattern.length, restStates = rest.states();
        if (n + restStates + 1 > budget.maxStates)
            return unknownLanguage();
        const dead = cast(ushort)(n + restStates);
        InputLanguage result;
        result.next = new ushort[256][n + restStates + 1];
        result.accepting = new bool[n + restStates + 1];
        foreach (i; 0 .. n)
            foreach (c; 0 .. 256)
                result.next[i][c] = pattern[i].contains(cast(char)c) ? cast(ushort)(i + 1) : dead;
        foreach (r; 0 .. restStates) {
            result.accepting[n + r] = rest.accepting[r];
            foreach (c; 0 .. 256)
                result.next[n + r][c] = cast(ushort)(n + rest.next[r][c]);
        }
        foreach (c; 0 .. 256)
            result.next[dead][c] = dead;
        return result;
    }

    size_t states() const @nogc {
        return next.length;
    }

    /// Does the language contain exactly this input?
    bool contains(scope const(char)[] input) const @nogc {
        if (overflow)
            return false;
        size_t state;
        foreach (c; input)
            state = next[state][cast(ubyte)c];
        return accepting[state];
    }

    /// Exact emptiness: the accepting set is unreachable. `unknown` only after overflow.
    Proof emptiness() const {
        if (overflow)
            return Proof.unknown;
        string witness;
        return shortestWitness(witness) ? Proof.provenNonempty : Proof.provenEmpty;
    }

    /// Breadth-first shortest member (bytes in increasing order); false when empty.
    bool shortestWitness(out string witness) const {
        if (overflow)
            return false;
        auto parent = new ptrdiff_t[next.length];
        auto via = new ubyte[next.length];
        auto seen = new bool[next.length];
        size_t[] queue = [0];
        seen[0] = true;
        for (size_t head; head < queue.length; ++head) {
            const state = queue[head];
            if (accepting[state]) {
                string reversed;
                for (ptrdiff_t at = cast(ptrdiff_t)state; at != 0; at = parent[at])
                    reversed ~= cast(char)via[at];
                foreach_reverse (c; reversed)
                    witness ~= c;
                return true;
            }
            foreach (c; 0 .. 256) {
                const target = next[state][c];
                if (!seen[target]) {
                    seen[target] = true;
                    parent[target] = cast(ptrdiff_t)state;
                    via[target] = cast(ubyte)c;
                    queue ~= target;
                }
            }
        }
        return false;
    }

    /// Set complement over all byte strings. Exact only when `this` is exact.
    InputLanguage complement() const {
        if (overflow)
            return unknownLanguage();
        InputLanguage result;
        result.next = next.dup;
        result.accepting = new bool[accepting.length];
        foreach (i, accepts; accepting)
            result.accepting[i] = !accepts;
        return result;
    }

    InputLanguage unionWith(const InputLanguage other, Budget budget = Budget.init) const {
        return product(other, budget, false);
    }

    InputLanguage intersect(const InputLanguage other, Budget budget = Budget.init) const {
        return product(other, budget, true);
    }

    private InputLanguage product(const InputLanguage other, Budget budget, bool both) const {
        if (overflow || other.overflow)
            return unknownLanguage();
        InputLanguage result;
        size_t[size_t] index;
        size_t[2][] pairs;
        const width = other.states();
        index[0] = 0;
        pairs ~= [cast(size_t)0, 0];
        result.next.length = 1;
        for (size_t at; at < pairs.length; ++at) {
            const a = pairs[at][0], b = pairs[at][1];
            result.accepting ~= both ? accepting[a] && other.accepting[b] : accepting[a] || other.accepting[b];
            foreach (c; 0 .. 256) {
                const key = next[a][c] * width + other.next[b][c];
                auto known = key in index;
                if (known is null) {
                    if (pairs.length >= budget.maxStates)
                        return unknownLanguage();
                    index[key] = pairs.length;
                    pairs ~= [cast(size_t)next[a][c], cast(size_t)other.next[b][c]];
                    result.next.length = pairs.length;
                    known = key in index;
                }
                result.next[at][c] = cast(ushort)*known;
            }
        }
        return result;
    }
}

nothrow unittest {
    // empty vs universal
    assert(InputLanguage.empty().emptiness() == Proof.provenEmpty);
    assert(InputLanguage.universal().emptiness() == Proof.provenNonempty);
    assert(InputLanguage.universal().contains("") && !InputLanguage.empty().contains(""));
    assert(InputLanguage.universal().complement().emptiness() == Proof.provenEmpty);
    assert(InputLanguage.empty().complement().emptiness() == Proof.provenNonempty);
}

nothrow unittest {
    // EOF / empty input: the end-of-input language holds only "", prefixes never hold ""
    auto eoi = InputLanguage.endOfInput();
    assert(eoi.contains("") && !eoi.contains("a"));
    assert(!InputLanguage.prefix("a").contains("") && InputLanguage.prefix("").contains(""));
    assert(eoi.intersect(InputLanguage.prefix("a")).emptiness() == Proof.provenEmpty);
    assert(eoi.unionWith(InputLanguage.prefix("a")).contains(""));
    string witness;
    assert(eoi.shortestWitness(witness) && witness == "");
}

nothrow unittest {
    // disjoint, overlapping and nested prefixes
    const ab = InputLanguage.prefix("ab"), ac = InputLanguage.prefix("ac"), a = InputLanguage.prefix("a");
    assert(ab.intersect(ac).emptiness() == Proof.provenEmpty);
    assert(ab.intersect(a).emptiness() == Proof.provenNonempty);
    string witness;
    assert(ab.intersect(a).shortestWitness(witness) && witness == "ab");
    assert(a.unionWith(ab).contains("ax") && !a.unionWith(ab).contains("b"));
    CharSetMask letters;
    letters.addRange('a', 'z');
    assert(InputLanguage.bytePrefix(letters).intersect(InputLanguage.prefix("abc")).emptiness() == Proof.provenNonempty);
    CharSetMask digits;
    digits.addRange('0', '9');
    assert(InputLanguage.bytePrefix(letters).intersect(InputLanguage.bytePrefix(digits))
            .emptiness() == Proof.provenEmpty);
}

nothrow unittest {
    // "a"Σ* ∩ (Σ* \ "a"Σ*) is provably empty; the paper's (!"abc") letter* example is nonempty but excludes "abc..."
    const a = InputLanguage.prefix("a");
    assert(a.intersect(a.complement()).emptiness() == Proof.provenEmpty);
    CharSetMask letters;
    letters.addRange('a', 'z');
    auto guarded = InputLanguage.prefix("abc").complement().intersect(InputLanguage.bytePrefix(letters));
    assert(guarded.contains("abd") && guarded.contains("x") && !guarded.contains("abcd") && !guarded.contains(""));
    assert(guarded.intersect(InputLanguage.prefix("abc")).emptiness() == Proof.provenEmpty);
    // De Morgan: complement of a union equals intersection of complements on probes
    const b = InputLanguage.prefix("b");
    const left = a.unionWith(b).complement(), right = a.complement().intersect(b.complement());
    foreach (probe; ["", "a", "b", "c", "ab", "ca"])
        assert(left.contains(probe) == right.contains(probe));
}

nothrow unittest {
    // a symbolically heavy case exceeds the budget -> unknown, never "empty"
    InputLanguage acc = InputLanguage.prefix("aaaaaaaaaaaa");
    Budget tiny;
    tiny.maxStates = 8;
    const result = acc.intersect(InputLanguage.prefix("aaaaaaaaaaaa").complement(), tiny);
    assert(result.overflow && result.emptiness() == Proof.unknown);
    // unknown propagates through further operations
    assert(result.unionWith(InputLanguage.universal()).emptiness() == Proof.unknown);
    assert(result.complement().emptiness() == Proof.unknown && !result.contains(""));
    // with the default budget the same query is decided
    assert(acc.intersect(InputLanguage.prefix("aaaaaaaaaaaa").complement()).emptiness() == Proof.provenEmpty);
}

nothrow unittest {
    // fixed-length prefix followed by a language: "ab" then (not starting with a letter)
    CharSetMask a, b, letters;
    a.addChar('a');
    b.addChar('b');
    letters.addRange('a', 'z');
    const pattern = [a, b];
    const notLetter = InputLanguage.bytePrefix(letters).complement();
    const keyword = InputLanguage.fixedThen(pattern, notLetter);
    assert(keyword.contains("ab") && keyword.contains("ab1") && keyword.contains("ab "));
    assert(!keyword.contains("abc") && !keyword.contains("a") && !keyword.contains("b") && !keyword.contains(""));
    assert(InputLanguage.fixedThen([], notLetter).contains("1") && !InputLanguage.fixedThen([],
            notLetter).contains("x"));
    Budget tiny;
    tiny.maxStates = 3;
    assert(InputLanguage.fixedThen(pattern, notLetter, tiny).overflow);
    assert(InputLanguage.fixedThen(pattern, InputLanguage.unknownLanguage()).overflow);
    // matches the exact concatenation on probes
    foreach (probe; ["abz", "ab9", "abab", "xab", "ab"])
        assert(keyword.contains(probe) == (probe.length >= 2 && probe[0 .. 2] == "ab"
                && notLetter.contains(probe[2 .. $])));
}

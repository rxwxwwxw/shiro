/** Explicit numeric conversion used by the Pegged-derived examples (Boost 1.0). */
module npegged.conversion;
import npegged.storage : Status;

struct NumberResult(T) {
    Status status = Status.invalidInput;
    T value;
}

NumberResult!T parseNumber(T)(scope string input) @nogc nothrow pure {
    NumberResult!T result;
    size_t pos;
    bool negative;
    if (pos < input.length && (input[pos] == '+' || input[pos] == '-'))
        negative = input[pos++] == '-';
    T value = 0;
    size_t digits;
    while (pos < input.length && input[pos] >= '0' && input[pos] <= '9') {
        auto digit = input[pos++] - '0';
        static if (is(T == int) || is(T == long) || is(T == uint) || is(T == ulong)) {
            if (value > (T.max - digit) / 10)
                return result;
        }
        value = value * 10 + digit;
        ++digits;
    }
    if (pos < input.length && input[pos] == '.') {
        static if (is(T == int) || is(T == long) || is(T == uint) || is(T == ulong))
            return result;
        ++pos;
        T scale = 1;
        while (pos < input.length && input[pos] >= '0' && input[pos] <= '9') {
            scale *= 10;
            value += (input[pos++] - '0') / scale;
            ++digits;
        }
    }
    if (!digits || pos != input.length)
        return result;
    result.status = Status.ok;
    result.value = negative ? -value : value;
    return result;
}

@nogc nothrow unittest {
    assert(parseNumber!float("-12.5").value == -12.5f);
    assert(parseNumber!int("12").value == 12);
    assert(parseNumber!int("").status == Status.invalidInput);
    assert(parseNumber!int("12x").status == Status.invalidInput);
    assert(parseNumber!int("2147483648").status == Status.invalidInput);
}

@nogc nothrow unittest {
    assert(parseNumber!float(".5").value == .5f);
    assert(parseNumber!float("+").status == Status.invalidInput);
    assert(parseNumber!int("1.5").status == Status.invalidInput);
    assert(parseNumber!float("1.").value == 1.0f);
}

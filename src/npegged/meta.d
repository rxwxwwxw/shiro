/** Small compile-time utilities for Pegged-derived examples (Boost 1.0). */
module npegged.meta;
template AliasSeq(T...) {
    alias AliasSeq = T;
}

template TypeTuple(T...) {
    alias TypeTuple = T;
}

template isInputRange(T) {
    enum isInputRange = __traits(compiles, {
            T r;
            bool empty = r.length == 0;
            auto value = r[0];
            r = r[1 .. $];
        });
}

template ElementType(T) {
    alias ElementType = typeof(T.init[0]);
}

@nogc nothrow unittest {
    static assert(isInputRange!(int[]));
    static assert(!isInputRange!int);
    static assert(is(ElementType!(int[]) == int));
    static assert(AliasSeq!(int, double).length == 2);
}

/// Every rule entry of the Pegged-derived parser, in each execution mode, is called once so the generated wrappers are exercised.
version (unittest) nothrow unittest {
    import npegged.parser : Pegged;
    import npegged.peg : State, Status;
    import npegged.records : RecordBuffer;
    import npegged.storage : Arena;

    static foreach (name; __traits(allMembers, Pegged)) {
        static if (name != "opCall" && __traits(compiles, {
                State!(false, false) probe;
                __traits(getMember, Pegged, name)(probe, 0);
            })) {
            {
                Arena owner;
                State!(false, false) plain;
                plain.arena = &owner;
                plain.input = "a";
                __traits(getMember, Pegged, name)(plain, 0);
                State!(false, true) checking;
                checking.arena = &owner;
                checking.input = "a";
                __traits(getMember, Pegged, name)(checking, 0);
                RecordBuffer output;
                output.arena = &owner;
                State!(false, 2) recording;
                recording.arena = &owner;
                recording.input = "a";
                recording.attachRecords(output);
                __traits(getMember, Pegged, name)(recording, 0);
                static if (__traits(compiles, {
                        State!(true, false) probe;
                        __traits(getMember, Pegged, name)(probe, 0);
                    })) {
                    State!(true, false) compileTime;
                    compileTime.arena = &owner;
                    compileTime.input = "a";
                    __traits(getMember, Pegged, name)(compileTime, 0);
                }
            }
        }
    }
}

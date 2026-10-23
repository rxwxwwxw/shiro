// Generated from Pegged-derived npegged grammar. Boost 1.0.
module npegged.parser;
public import npegged.peg;
public import npegged.dfa;

struct Pegged {
    private static State!(CT, Check).Node _Grammar(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(Spacing, GrammarName, oneOrMore!(Definition), discard!(eoi)), "Pegged.Grammar")(s, p);
    }

    static State!(false, false).Node Grammar(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Grammar!(false, false), "Pegged.Grammar", true)(p);
    }

    static State!(true, false).Node Grammar(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Grammar!(true, false), "Pegged.Grammar", true)(p);
    }

    static State!(false, true).Node Grammar(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Grammar!(false, true), "Pegged.Grammar", true)(p);
    }

    static State!(true, true).Node Grammar(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Grammar!(true, true), "Pegged.Grammar", true)(p);
    }

    static State!(false, 2).Node Grammar(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Grammar!(false, 2), "Pegged.Grammar", true)(p);
    }

    static State!(true, 2).Node Grammar(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Grammar!(true, 2), "Pegged.Grammar", true)(p);
    }

    static ParseResult Grammar(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Grammar)(ctx, input);
    }

    static ParseTree Grammar(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Grammar)(input);
    }

    private static State!(CT, Check).Node _Definition(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(LhsName, Arrow, Expression), "Pegged.Definition")(s, p);
    }

    static State!(false, false).Node Definition(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Definition!(false, false), "Pegged.Definition", true)(p);
    }

    static State!(true, false).Node Definition(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Definition!(true, false), "Pegged.Definition", true)(p);
    }

    static State!(false, true).Node Definition(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Definition!(false, true), "Pegged.Definition", true)(p);
    }

    static State!(true, true).Node Definition(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Definition!(true, true), "Pegged.Definition", true)(p);
    }

    static State!(false, 2).Node Definition(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Definition!(false, 2), "Pegged.Definition", true)(p);
    }

    static State!(true, 2).Node Definition(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Definition!(true, 2), "Pegged.Definition", true)(p);
    }

    static ParseResult Definition(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Definition)(ctx, input);
    }

    static ParseTree Definition(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Definition)(input);
    }

    private static State!(CT, Check).Node _Expression(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(FirstExpression, LongestExpression), "Pegged.Expression")(s, p);
    }

    static State!(false, false).Node Expression(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Expression!(false, false), "Pegged.Expression", true)(p);
    }

    static State!(true, false).Node Expression(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Expression!(true, false), "Pegged.Expression", true)(p);
    }

    static State!(false, true).Node Expression(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Expression!(false, true), "Pegged.Expression", true)(p);
    }

    static State!(true, true).Node Expression(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Expression!(true, true), "Pegged.Expression", true)(p);
    }

    static State!(false, 2).Node Expression(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Expression!(false, 2), "Pegged.Expression", true)(p);
    }

    static State!(true, 2).Node Expression(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Expression!(true, 2), "Pegged.Expression", true)(p);
    }

    static ParseResult Expression(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Expression)(ctx, input);
    }

    static ParseTree Expression(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Expression)(input);
    }

    private static State!(CT, Check).Node _FirstExpression(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(discard!(option!(OR)), Sequence, oneOrMore!(and!(discard!(OR), Sequence))),
                "Pegged.FirstExpression")(s, p);
    }

    static State!(false, false).Node FirstExpression(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_FirstExpression!(false, false), "Pegged.FirstExpression", true)(p);
    }

    static State!(true, false).Node FirstExpression(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_FirstExpression!(true, false), "Pegged.FirstExpression", true)(p);
    }

    static State!(false, true).Node FirstExpression(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_FirstExpression!(false, true), "Pegged.FirstExpression", true)(p);
    }

    static State!(true, true).Node FirstExpression(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_FirstExpression!(true, true), "Pegged.FirstExpression", true)(p);
    }

    static State!(false, 2).Node FirstExpression(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_FirstExpression!(false, 2), "Pegged.FirstExpression", true)(p);
    }

    static State!(true, 2).Node FirstExpression(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_FirstExpression!(true, 2), "Pegged.FirstExpression", true)(p);
    }

    static ParseResult FirstExpression(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(FirstExpression)(ctx, input);
    }

    static ParseTree FirstExpression(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(FirstExpression)(input);
    }

    private static State!(CT, Check).Node _LongestExpression(bool CT, int Check = 0)(ref State!(CT,
            Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(and!(discard!(option!(or!(OR, LONGEST_OR))), Sequence,
                    zeroOrMore!(and!(discard!(LONGEST_OR), Sequence))), "Pegged.LongestExpression")(s, p);
        return defined!(and!(discard!(option!(predictiveChoice!(branch!(OR, 0x800000000000UL,
                0x0UL, 0x0UL, 0x0UL), branch!(LONGEST_OR, 0x0UL, 0x1000000000000000UL, 0x0UL, 0x0UL)))),
                Sequence, zeroOrMore!(and!(discard!(LONGEST_OR), Sequence))), "Pegged.LongestExpression")(s, p);
    }

    static State!(false, false).Node LongestExpression(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_LongestExpression!(false, false), "Pegged.LongestExpression", true)(p);
    }

    static State!(true, false).Node LongestExpression(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_LongestExpression!(true, false), "Pegged.LongestExpression", true)(p);
    }

    static State!(false, true).Node LongestExpression(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_LongestExpression!(false, true), "Pegged.LongestExpression", true)(p);
    }

    static State!(true, true).Node LongestExpression(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_LongestExpression!(true, true), "Pegged.LongestExpression", true)(p);
    }

    static State!(false, 2).Node LongestExpression(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_LongestExpression!(false, 2), "Pegged.LongestExpression", true)(p);
    }

    static State!(true, 2).Node LongestExpression(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_LongestExpression!(true, 2), "Pegged.LongestExpression", true)(p);
    }

    static ParseResult LongestExpression(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(LongestExpression)(ctx, input);
    }

    static ParseTree LongestExpression(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(LongestExpression)(input);
    }

    private static State!(CT, Check).Node _Sequence(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(oneOrMore!(Prefix), "Pegged.Sequence")(s, p);
    }

    static State!(false, false).Node Sequence(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Sequence!(false, false), "Pegged.Sequence", true)(p);
    }

    static State!(true, false).Node Sequence(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Sequence!(true, false), "Pegged.Sequence", true)(p);
    }

    static State!(false, true).Node Sequence(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Sequence!(false, true), "Pegged.Sequence", true)(p);
    }

    static State!(true, true).Node Sequence(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Sequence!(true, true), "Pegged.Sequence", true)(p);
    }

    static State!(false, 2).Node Sequence(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Sequence!(false, 2), "Pegged.Sequence", true)(p);
    }

    static State!(true, 2).Node Sequence(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Sequence!(true, 2), "Pegged.Sequence", true)(p);
    }

    static ParseResult Sequence(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Sequence)(ctx, input);
    }

    static ParseTree Sequence(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Sequence)(input);
    }

    private static State!(CT, Check).Node _Prefix(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(and!(zeroOrMore!(or!(POS, NEG, FUSE, DISCARD, KEEP, DROP,
                    PROPAGATE)), Suffix), "Pegged.Prefix")(s, p);
        return defined!(and!(zeroOrMore!(predictiveChoice!(branch!(POS, 0x4000000000UL, 0x0UL,
                0x0UL, 0x0UL), branch!(NEG, 0x200000000UL, 0x0UL, 0x0UL, 0x0UL), branch!(FUSE,
                0x0UL, 0x4000000000000000UL, 0x0UL, 0x0UL), branch!(DISCARD, 0x400000000000000UL,
                0x0UL, 0x0UL, 0x0UL), branch!(KEEP, 0x0UL, 0x40000000UL, 0x0UL, 0x0UL),
                branch!(DROP, 0x800000000000000UL, 0x0UL, 0x0UL, 0x0UL), branch!(PROPAGATE,
                0x2000000000UL, 0x0UL, 0x0UL, 0x0UL))), Suffix), "Pegged.Prefix")(s, p);
    }

    static State!(false, false).Node Prefix(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Prefix!(false, false), "Pegged.Prefix", true)(p);
    }

    static State!(true, false).Node Prefix(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Prefix!(true, false), "Pegged.Prefix", true)(p);
    }

    static State!(false, true).Node Prefix(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Prefix!(false, true), "Pegged.Prefix", true)(p);
    }

    static State!(true, true).Node Prefix(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Prefix!(true, true), "Pegged.Prefix", true)(p);
    }

    static State!(false, 2).Node Prefix(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Prefix!(false, 2), "Pegged.Prefix", true)(p);
    }

    static State!(true, 2).Node Prefix(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Prefix!(true, 2), "Pegged.Prefix", true)(p);
    }

    static ParseResult Prefix(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Prefix)(ctx, input);
    }

    static ParseTree Prefix(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Prefix)(input);
    }

    private static State!(CT, Check).Node _Suffix(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(and!(Primary, zeroOrMore!(or!(OPTION, ZEROORMORE, ONEORMORE, Action))), "Pegged.Suffix")(s,
                    p);
        return defined!(and!(Primary, zeroOrMore!(predictiveChoice!(branch!(OPTION,
                0x8000000000000000UL, 0x0UL, 0x0UL, 0x0UL), branch!(ZEROORMORE, 0x40000000000UL, 0x0UL,
                0x0UL, 0x0UL), branch!(ONEORMORE, 0x80000000000UL, 0x0UL, 0x0UL, 0x0UL),
                branch!(Action, 0x0UL, 0x800000000000000UL, 0x0UL, 0x0UL)))), "Pegged.Suffix")(s, p);
    }

    static State!(false, false).Node Suffix(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Suffix!(false, false), "Pegged.Suffix", true)(p);
    }

    static State!(true, false).Node Suffix(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Suffix!(true, false), "Pegged.Suffix", true)(p);
    }

    static State!(false, true).Node Suffix(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Suffix!(false, true), "Pegged.Suffix", true)(p);
    }

    static State!(true, true).Node Suffix(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Suffix!(true, true), "Pegged.Suffix", true)(p);
    }

    static State!(false, 2).Node Suffix(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Suffix!(false, 2), "Pegged.Suffix", true)(p);
    }

    static State!(true, 2).Node Suffix(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Suffix!(true, 2), "Pegged.Suffix", true)(p);
    }

    static ParseResult Suffix(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Suffix)(ctx, input);
    }

    static ParseTree Suffix(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Suffix)(input);
    }

    private static State!(CT, Check).Node _Primary(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(negLookahead!(and!(LhsName, Arrow)), or!(RhsName,
                and!(discard!(OPEN), Expression, discard!(CLOSE)), Literal, CILiteral, CharClass, ANY)),
                "Pegged.Primary")(s, p);
    }

    static State!(false, false).Node Primary(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Primary!(false, false), "Pegged.Primary", true)(p);
    }

    static State!(true, false).Node Primary(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Primary!(true, false), "Pegged.Primary", true)(p);
    }

    static State!(false, true).Node Primary(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Primary!(false, true), "Pegged.Primary", true)(p);
    }

    static State!(true, true).Node Primary(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Primary!(true, true), "Pegged.Primary", true)(p);
    }

    static State!(false, 2).Node Primary(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Primary!(false, 2), "Pegged.Primary", true)(p);
    }

    static State!(true, 2).Node Primary(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Primary!(true, 2), "Pegged.Primary", true)(p);
    }

    static ParseResult Primary(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Primary)(ctx, input);
    }

    static ParseTree Primary(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Primary)(input);
    }

    private static State!(CT, Check).Node _Identifier(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(identifier, "Pegged.Identifier")(s, p);
    }

    static State!(false, false).Node Identifier(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Identifier!(false, false), "Pegged.Identifier", true)(p);
    }

    static State!(true, false).Node Identifier(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Identifier!(true, false), "Pegged.Identifier", true)(p);
    }

    static State!(false, true).Node Identifier(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Identifier!(false, true), "Pegged.Identifier", true)(p);
    }

    static State!(true, true).Node Identifier(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Identifier!(true, true), "Pegged.Identifier", true)(p);
    }

    static State!(false, 2).Node Identifier(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Identifier!(false, 2), "Pegged.Identifier", true)(p);
    }

    static State!(true, 2).Node Identifier(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Identifier!(true, 2), "Pegged.Identifier", true)(p);
    }

    static ParseResult Identifier(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Identifier)(ctx, input);
    }

    static ParseTree Identifier(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Identifier)(input);
    }

    private static State!(CT, Check).Node _GrammarName(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(Identifier, option!(ParamList), Spacing, discard!(literal!(":")),
                Spacing), "Pegged.GrammarName")(s, p);
    }

    static State!(false, false).Node GrammarName(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_GrammarName!(false, false), "Pegged.GrammarName", true)(p);
    }

    static State!(true, false).Node GrammarName(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_GrammarName!(true, false), "Pegged.GrammarName", true)(p);
    }

    static State!(false, true).Node GrammarName(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_GrammarName!(false, true), "Pegged.GrammarName", true)(p);
    }

    static State!(true, true).Node GrammarName(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_GrammarName!(true, true), "Pegged.GrammarName", true)(p);
    }

    static State!(false, 2).Node GrammarName(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_GrammarName!(false, 2), "Pegged.GrammarName", true)(p);
    }

    static State!(true, 2).Node GrammarName(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_GrammarName!(true, 2), "Pegged.GrammarName", true)(p);
    }

    static ParseResult GrammarName(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(GrammarName)(ctx, input);
    }

    static ParseTree GrammarName(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(GrammarName)(input);
    }

    private static State!(CT, Check).Node _LhsName(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(Identifier, option!(ParamList), Spacing), "Pegged.LhsName")(s, p);
    }

    static State!(false, false).Node LhsName(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_LhsName!(false, false), "Pegged.LhsName", true)(p);
    }

    static State!(true, false).Node LhsName(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_LhsName!(true, false), "Pegged.LhsName", true)(p);
    }

    static State!(false, true).Node LhsName(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_LhsName!(false, true), "Pegged.LhsName", true)(p);
    }

    static State!(true, true).Node LhsName(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_LhsName!(true, true), "Pegged.LhsName", true)(p);
    }

    static State!(false, 2).Node LhsName(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_LhsName!(false, 2), "Pegged.LhsName", true)(p);
    }

    static State!(true, 2).Node LhsName(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_LhsName!(true, 2), "Pegged.LhsName", true)(p);
    }

    static ParseResult LhsName(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(LhsName)(ctx, input);
    }

    static ParseTree LhsName(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(LhsName)(input);
    }

    private static State!(CT, Check).Node _RhsName(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(Identifier, option!(ArgList), zeroOrMore!(and!(NAMESEP,
                Identifier, option!(ArgList))), Spacing), "Pegged.RhsName")(s, p);
    }

    static State!(false, false).Node RhsName(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_RhsName!(false, false), "Pegged.RhsName", true)(p);
    }

    static State!(true, false).Node RhsName(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_RhsName!(true, false), "Pegged.RhsName", true)(p);
    }

    static State!(false, true).Node RhsName(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_RhsName!(false, true), "Pegged.RhsName", true)(p);
    }

    static State!(true, true).Node RhsName(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_RhsName!(true, true), "Pegged.RhsName", true)(p);
    }

    static State!(false, 2).Node RhsName(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_RhsName!(false, 2), "Pegged.RhsName", true)(p);
    }

    static State!(true, 2).Node RhsName(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_RhsName!(true, 2), "Pegged.RhsName", true)(p);
    }

    static ParseResult RhsName(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(RhsName)(ctx, input);
    }

    static ParseTree RhsName(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(RhsName)(input);
    }

    private static State!(CT, Check).Node _ParamList(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(discard!(OPEN), Param, zeroOrMore!(and!(discard!(SEPARATOR),
                Param)), discard!(CLOSE)), "Pegged.ParamList")(s, p);
    }

    static State!(false, false).Node ParamList(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ParamList!(false, false), "Pegged.ParamList", true)(p);
    }

    static State!(true, false).Node ParamList(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ParamList!(true, false), "Pegged.ParamList", true)(p);
    }

    static State!(false, true).Node ParamList(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ParamList!(false, true), "Pegged.ParamList", true)(p);
    }

    static State!(true, true).Node ParamList(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ParamList!(true, true), "Pegged.ParamList", true)(p);
    }

    static State!(false, 2).Node ParamList(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ParamList!(false, 2), "Pegged.ParamList", true)(p);
    }

    static State!(true, 2).Node ParamList(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ParamList!(true, 2), "Pegged.ParamList", true)(p);
    }

    static ParseResult ParamList(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ParamList)(ctx, input);
    }

    static ParseTree ParamList(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ParamList)(input);
    }

    private static State!(CT, Check).Node _Param(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(DefaultParam, SingleParam), "Pegged.Param")(s, p);
    }

    static State!(false, false).Node Param(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Param!(false, false), "Pegged.Param", true)(p);
    }

    static State!(true, false).Node Param(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Param!(true, false), "Pegged.Param", true)(p);
    }

    static State!(false, true).Node Param(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Param!(false, true), "Pegged.Param", true)(p);
    }

    static State!(true, true).Node Param(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Param!(true, true), "Pegged.Param", true)(p);
    }

    static State!(false, 2).Node Param(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Param!(false, 2), "Pegged.Param", true)(p);
    }

    static State!(true, 2).Node Param(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Param!(true, 2), "Pegged.Param", true)(p);
    }

    static ParseResult Param(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Param)(ctx, input);
    }

    static ParseTree Param(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Param)(input);
    }

    private static State!(CT, Check).Node _DefaultParam(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(Identifier, Spacing, discard!(ASSIGN), Expression), "Pegged.DefaultParam")(s, p);
    }

    static State!(false, false).Node DefaultParam(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DefaultParam!(false, false), "Pegged.DefaultParam", true)(p);
    }

    static State!(true, false).Node DefaultParam(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DefaultParam!(true, false), "Pegged.DefaultParam", true)(p);
    }

    static State!(false, true).Node DefaultParam(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DefaultParam!(false, true), "Pegged.DefaultParam", true)(p);
    }

    static State!(true, true).Node DefaultParam(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DefaultParam!(true, true), "Pegged.DefaultParam", true)(p);
    }

    static State!(false, 2).Node DefaultParam(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DefaultParam!(false, 2), "Pegged.DefaultParam", true)(p);
    }

    static State!(true, 2).Node DefaultParam(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DefaultParam!(true, 2), "Pegged.DefaultParam", true)(p);
    }

    static ParseResult DefaultParam(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DefaultParam)(ctx, input);
    }

    static ParseTree DefaultParam(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DefaultParam)(input);
    }

    private static State!(CT, Check).Node _SingleParam(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(Identifier, Spacing), "Pegged.SingleParam")(s, p);
    }

    static State!(false, false).Node SingleParam(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_SingleParam!(false, false), "Pegged.SingleParam", true)(p);
    }

    static State!(true, false).Node SingleParam(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_SingleParam!(true, false), "Pegged.SingleParam", true)(p);
    }

    static State!(false, true).Node SingleParam(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_SingleParam!(false, true), "Pegged.SingleParam", true)(p);
    }

    static State!(true, true).Node SingleParam(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_SingleParam!(true, true), "Pegged.SingleParam", true)(p);
    }

    static State!(false, 2).Node SingleParam(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_SingleParam!(false, 2), "Pegged.SingleParam", true)(p);
    }

    static State!(true, 2).Node SingleParam(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_SingleParam!(true, 2), "Pegged.SingleParam", true)(p);
    }

    static ParseResult SingleParam(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(SingleParam)(ctx, input);
    }

    static ParseTree SingleParam(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(SingleParam)(input);
    }

    private static State!(CT, Check).Node _ArgList(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(discard!(OPEN), Expression, zeroOrMore!(and!(discard!(SEPARATOR),
                Expression)), discard!(CLOSE)), "Pegged.ArgList")(s, p);
    }

    static State!(false, false).Node ArgList(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ArgList!(false, false), "Pegged.ArgList", true)(p);
    }

    static State!(true, false).Node ArgList(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ArgList!(true, false), "Pegged.ArgList", true)(p);
    }

    static State!(false, true).Node ArgList(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ArgList!(false, true), "Pegged.ArgList", true)(p);
    }

    static State!(true, true).Node ArgList(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ArgList!(true, true), "Pegged.ArgList", true)(p);
    }

    static State!(false, 2).Node ArgList(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ArgList!(false, 2), "Pegged.ArgList", true)(p);
    }

    static State!(true, 2).Node ArgList(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ArgList!(true, 2), "Pegged.ArgList", true)(p);
    }

    static ParseResult ArgList(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ArgList)(ctx, input);
    }

    static ParseTree ArgList(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ArgList)(input);
    }

    private static State!(CT, Check).Node _Literal(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(or!(and!(quote, fuse!(zeroOrMore!(and!(negLookahead!(quote),
                    Char))), quote, negLookahead!(literal!("i")), Spacing), and!(doublequote,
                    fuse!(zeroOrMore!(and!(negLookahead!(doublequote),
                    Char))), doublequote, negLookahead!(literal!("i")), Spacing)), "Pegged.Literal")(s, p);
        return defined!(predictiveChoice!(branch!(and!(quote,
                fuse!(zeroOrMore!(and!(negLookahead!(quote), Char))), quote, negLookahead!(literal!("i")), Spacing),
                0x8000000000UL, 0x0UL, 0x0UL, 0x0UL), branch!(and!(doublequote,
                fuse!(zeroOrMore!(and!(negLookahead!(doublequote), Char))), doublequote,
                negLookahead!(literal!("i")), Spacing), 0x400000000UL, 0x0UL, 0x0UL, 0x0UL)), "Pegged.Literal")(s, p);
    }

    static State!(false, false).Node Literal(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Literal!(false, false), "Pegged.Literal", true)(p);
    }

    static State!(true, false).Node Literal(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Literal!(true, false), "Pegged.Literal", true)(p);
    }

    static State!(false, true).Node Literal(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Literal!(false, true), "Pegged.Literal", true)(p);
    }

    static State!(true, true).Node Literal(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Literal!(true, true), "Pegged.Literal", true)(p);
    }

    static State!(false, 2).Node Literal(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Literal!(false, 2), "Pegged.Literal", true)(p);
    }

    static State!(true, 2).Node Literal(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Literal!(true, 2), "Pegged.Literal", true)(p);
    }

    static ParseResult Literal(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Literal)(ctx, input);
    }

    static ParseTree Literal(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Literal)(input);
    }

    private static State!(CT, Check).Node _CILiteral(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(or!(and!(quote, fuse!(zeroOrMore!(and!(negLookahead!(quote),
                    Char))), quote, discard!(literal!("i")), Spacing), and!(doublequote,
                    fuse!(zeroOrMore!(and!(negLookahead!(doublequote), Char))), doublequote,
                    discard!(literal!("i")), Spacing)), "Pegged.CILiteral")(s, p);
        return defined!(predictiveChoice!(branch!(and!(quote,
                fuse!(zeroOrMore!(and!(negLookahead!(quote), Char))), quote, discard!(literal!("i")), Spacing),
                0x8000000000UL, 0x0UL, 0x0UL, 0x0UL), branch!(and!(doublequote,
                fuse!(zeroOrMore!(and!(negLookahead!(doublequote), Char))), doublequote,
                discard!(literal!("i")), Spacing), 0x400000000UL, 0x0UL, 0x0UL, 0x0UL)), "Pegged.CILiteral")(s, p);
    }

    static State!(false, false).Node CILiteral(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_CILiteral!(false, false), "Pegged.CILiteral", true)(p);
    }

    static State!(true, false).Node CILiteral(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_CILiteral!(true, false), "Pegged.CILiteral", true)(p);
    }

    static State!(false, true).Node CILiteral(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_CILiteral!(false, true), "Pegged.CILiteral", true)(p);
    }

    static State!(true, true).Node CILiteral(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_CILiteral!(true, true), "Pegged.CILiteral", true)(p);
    }

    static State!(false, 2).Node CILiteral(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_CILiteral!(false, 2), "Pegged.CILiteral", true)(p);
    }

    static State!(true, 2).Node CILiteral(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_CILiteral!(true, 2), "Pegged.CILiteral", true)(p);
    }

    static ParseResult CILiteral(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(CILiteral)(ctx, input);
    }

    static ParseTree CILiteral(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(CILiteral)(input);
    }

    private static State!(CT, Check).Node _CharClass(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(discard!(literal!("[")),
                zeroOrMore!(and!(negLookahead!(literal!("]")), CharRange)), discard!(literal!("]")), Spacing),
                "Pegged.CharClass")(s, p);
    }

    static State!(false, false).Node CharClass(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_CharClass!(false, false), "Pegged.CharClass", true)(p);
    }

    static State!(true, false).Node CharClass(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_CharClass!(true, false), "Pegged.CharClass", true)(p);
    }

    static State!(false, true).Node CharClass(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_CharClass!(false, true), "Pegged.CharClass", true)(p);
    }

    static State!(true, true).Node CharClass(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_CharClass!(true, true), "Pegged.CharClass", true)(p);
    }

    static State!(false, 2).Node CharClass(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_CharClass!(false, 2), "Pegged.CharClass", true)(p);
    }

    static State!(true, 2).Node CharClass(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_CharClass!(true, 2), "Pegged.CharClass", true)(p);
    }

    static ParseResult CharClass(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(CharClass)(ctx, input);
    }

    static ParseTree CharClass(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(CharClass)(input);
    }

    private static State!(CT, Check).Node _CharRange(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(or!(and!(Char, literal!("-"), Char), Char), "Pegged.CharRange")(s, p);
        return defined!(and!(Char, predictiveChoice!(branch!(and!(literal!("-"), Char),
                0x200000000000UL, 0x0UL, 0x0UL, 0x0UL), branch!(discard!(eps), 0x0UL, 0x0UL, 0x0UL, 0x0UL, true))),
                "Pegged.CharRange")(s, p);
    }

    static State!(false, false).Node CharRange(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_CharRange!(false, false), "Pegged.CharRange", true)(p);
    }

    static State!(true, false).Node CharRange(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_CharRange!(true, false), "Pegged.CharRange", true)(p);
    }

    static State!(false, true).Node CharRange(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_CharRange!(false, true), "Pegged.CharRange", true)(p);
    }

    static State!(true, true).Node CharRange(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_CharRange!(true, true), "Pegged.CharRange", true)(p);
    }

    static State!(false, 2).Node CharRange(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_CharRange!(false, 2), "Pegged.CharRange", true)(p);
    }

    static State!(true, 2).Node CharRange(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_CharRange!(true, 2), "Pegged.CharRange", true)(p);
    }

    static ParseResult CharRange(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(CharRange)(ctx, input);
    }

    static ParseTree CharRange(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(CharRange)(input);
    }

    private static State!(CT, Check).Node _Char(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(fuse!(or!(and!(backslash, or!(quote, doublequote, backquote, backslash,
                literal!("-"), literal!("["), literal!("]"), charClass!(0x0UL,
                0x14400000000000UL, 0x0UL, 0x0UL), and!(charRange!(48, 50), charRange!(48, 55),
                charRange!(48, 55)), and!(charRange!(48, 55), option!(charRange!(48, 55))), and!(literal!("x"),
                hexDigit, hexDigit), and!(literal!("u"), hexDigit, hexDigit, hexDigit, hexDigit),
                and!(literal!("U"), hexDigit, hexDigit, hexDigit, hexDigit, hexDigit, hexDigit, hexDigit, hexDigit))),
                any)), "Pegged.Char")(s, p);
    }

    static State!(false, false).Node Char(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Char!(false, false), "Pegged.Char", true)(p);
    }

    static State!(true, false).Node Char(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Char!(true, false), "Pegged.Char", true)(p);
    }

    static State!(false, true).Node Char(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Char!(false, true), "Pegged.Char", true)(p);
    }

    static State!(true, true).Node Char(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Char!(true, true), "Pegged.Char", true)(p);
    }

    static State!(false, 2).Node Char(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Char!(false, 2), "Pegged.Char", true)(p);
    }

    static State!(true, 2).Node Char(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Char!(true, 2), "Pegged.Char", true)(p);
    }

    static ParseResult Char(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Char)(ctx, input);
    }

    static ParseTree Char(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Char)(input);
    }

    private static State!(CT, Check).Node _Arrow(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(LEFTARROW, FUSEARROW, DISCARDARROW, KEEPARROW, DROPARROW,
                PROPAGATEARROW, ACTIONARROW, SPACEARROW), "Pegged.Arrow")(s, p);
    }

    static State!(false, false).Node Arrow(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Arrow!(false, false), "Pegged.Arrow", true)(p);
    }

    static State!(true, false).Node Arrow(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Arrow!(true, false), "Pegged.Arrow", true)(p);
    }

    static State!(false, true).Node Arrow(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Arrow!(false, true), "Pegged.Arrow", true)(p);
    }

    static State!(true, true).Node Arrow(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Arrow!(true, true), "Pegged.Arrow", true)(p);
    }

    static State!(false, 2).Node Arrow(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Arrow!(false, 2), "Pegged.Arrow", true)(p);
    }

    static State!(true, 2).Node Arrow(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Arrow!(true, 2), "Pegged.Arrow", true)(p);
    }

    static ParseResult Arrow(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Arrow)(ctx, input);
    }

    static ParseTree Arrow(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Arrow)(input);
    }

    private static State!(CT, Check).Node _LEFTARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<-"), Spacing), "Pegged.LEFTARROW")(s, p);
    }

    static State!(false, false).Node LEFTARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_LEFTARROW!(false, false), "Pegged.LEFTARROW", true)(p);
    }

    static State!(true, false).Node LEFTARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_LEFTARROW!(true, false), "Pegged.LEFTARROW", true)(p);
    }

    static State!(false, true).Node LEFTARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_LEFTARROW!(false, true), "Pegged.LEFTARROW", true)(p);
    }

    static State!(true, true).Node LEFTARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_LEFTARROW!(true, true), "Pegged.LEFTARROW", true)(p);
    }

    static State!(false, 2).Node LEFTARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_LEFTARROW!(false, 2), "Pegged.LEFTARROW", true)(p);
    }

    static State!(true, 2).Node LEFTARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_LEFTARROW!(true, 2), "Pegged.LEFTARROW", true)(p);
    }

    static ParseResult LEFTARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(LEFTARROW)(ctx, input);
    }

    static ParseTree LEFTARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(LEFTARROW)(input);
    }

    private static State!(CT, Check).Node _FUSEARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<~"), Spacing), "Pegged.FUSEARROW")(s, p);
    }

    static State!(false, false).Node FUSEARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_FUSEARROW!(false, false), "Pegged.FUSEARROW", true)(p);
    }

    static State!(true, false).Node FUSEARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_FUSEARROW!(true, false), "Pegged.FUSEARROW", true)(p);
    }

    static State!(false, true).Node FUSEARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_FUSEARROW!(false, true), "Pegged.FUSEARROW", true)(p);
    }

    static State!(true, true).Node FUSEARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_FUSEARROW!(true, true), "Pegged.FUSEARROW", true)(p);
    }

    static State!(false, 2).Node FUSEARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_FUSEARROW!(false, 2), "Pegged.FUSEARROW", true)(p);
    }

    static State!(true, 2).Node FUSEARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_FUSEARROW!(true, 2), "Pegged.FUSEARROW", true)(p);
    }

    static ParseResult FUSEARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(FUSEARROW)(ctx, input);
    }

    static ParseTree FUSEARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(FUSEARROW)(input);
    }

    private static State!(CT, Check).Node _DISCARDARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<:"), Spacing), "Pegged.DISCARDARROW")(s, p);
    }

    static State!(false, false).Node DISCARDARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DISCARDARROW!(false, false), "Pegged.DISCARDARROW", true)(p);
    }

    static State!(true, false).Node DISCARDARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DISCARDARROW!(true, false), "Pegged.DISCARDARROW", true)(p);
    }

    static State!(false, true).Node DISCARDARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DISCARDARROW!(false, true), "Pegged.DISCARDARROW", true)(p);
    }

    static State!(true, true).Node DISCARDARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DISCARDARROW!(true, true), "Pegged.DISCARDARROW", true)(p);
    }

    static State!(false, 2).Node DISCARDARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DISCARDARROW!(false, 2), "Pegged.DISCARDARROW", true)(p);
    }

    static State!(true, 2).Node DISCARDARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DISCARDARROW!(true, 2), "Pegged.DISCARDARROW", true)(p);
    }

    static ParseResult DISCARDARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DISCARDARROW)(ctx, input);
    }

    static ParseTree DISCARDARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DISCARDARROW)(input);
    }

    private static State!(CT, Check).Node _KEEPARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<^"), Spacing), "Pegged.KEEPARROW")(s, p);
    }

    static State!(false, false).Node KEEPARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_KEEPARROW!(false, false), "Pegged.KEEPARROW", true)(p);
    }

    static State!(true, false).Node KEEPARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_KEEPARROW!(true, false), "Pegged.KEEPARROW", true)(p);
    }

    static State!(false, true).Node KEEPARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_KEEPARROW!(false, true), "Pegged.KEEPARROW", true)(p);
    }

    static State!(true, true).Node KEEPARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_KEEPARROW!(true, true), "Pegged.KEEPARROW", true)(p);
    }

    static State!(false, 2).Node KEEPARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_KEEPARROW!(false, 2), "Pegged.KEEPARROW", true)(p);
    }

    static State!(true, 2).Node KEEPARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_KEEPARROW!(true, 2), "Pegged.KEEPARROW", true)(p);
    }

    static ParseResult KEEPARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(KEEPARROW)(ctx, input);
    }

    static ParseTree KEEPARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(KEEPARROW)(input);
    }

    private static State!(CT, Check).Node _DROPARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<;"), Spacing), "Pegged.DROPARROW")(s, p);
    }

    static State!(false, false).Node DROPARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DROPARROW!(false, false), "Pegged.DROPARROW", true)(p);
    }

    static State!(true, false).Node DROPARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DROPARROW!(true, false), "Pegged.DROPARROW", true)(p);
    }

    static State!(false, true).Node DROPARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DROPARROW!(false, true), "Pegged.DROPARROW", true)(p);
    }

    static State!(true, true).Node DROPARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DROPARROW!(true, true), "Pegged.DROPARROW", true)(p);
    }

    static State!(false, 2).Node DROPARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DROPARROW!(false, 2), "Pegged.DROPARROW", true)(p);
    }

    static State!(true, 2).Node DROPARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DROPARROW!(true, 2), "Pegged.DROPARROW", true)(p);
    }

    static ParseResult DROPARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DROPARROW)(ctx, input);
    }

    static ParseTree DROPARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DROPARROW)(input);
    }

    private static State!(CT, Check).Node _PROPAGATEARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<%"), Spacing), "Pegged.PROPAGATEARROW")(s, p);
    }

    static State!(false, false).Node PROPAGATEARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_PROPAGATEARROW!(false, false), "Pegged.PROPAGATEARROW", true)(p);
    }

    static State!(true, false).Node PROPAGATEARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_PROPAGATEARROW!(true, false), "Pegged.PROPAGATEARROW", true)(p);
    }

    static State!(false, true).Node PROPAGATEARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_PROPAGATEARROW!(false, true), "Pegged.PROPAGATEARROW", true)(p);
    }

    static State!(true, true).Node PROPAGATEARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_PROPAGATEARROW!(true, true), "Pegged.PROPAGATEARROW", true)(p);
    }

    static State!(false, 2).Node PROPAGATEARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_PROPAGATEARROW!(false, 2), "Pegged.PROPAGATEARROW", true)(p);
    }

    static State!(true, 2).Node PROPAGATEARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_PROPAGATEARROW!(true, 2), "Pegged.PROPAGATEARROW", true)(p);
    }

    static ParseResult PROPAGATEARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(PROPAGATEARROW)(ctx, input);
    }

    static ParseTree PROPAGATEARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(PROPAGATEARROW)(input);
    }

    private static State!(CT, Check).Node _SPACEARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<"), Spacing), "Pegged.SPACEARROW")(s, p);
    }

    static State!(false, false).Node SPACEARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_SPACEARROW!(false, false), "Pegged.SPACEARROW", true)(p);
    }

    static State!(true, false).Node SPACEARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_SPACEARROW!(true, false), "Pegged.SPACEARROW", true)(p);
    }

    static State!(false, true).Node SPACEARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_SPACEARROW!(false, true), "Pegged.SPACEARROW", true)(p);
    }

    static State!(true, true).Node SPACEARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_SPACEARROW!(true, true), "Pegged.SPACEARROW", true)(p);
    }

    static State!(false, 2).Node SPACEARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_SPACEARROW!(false, 2), "Pegged.SPACEARROW", true)(p);
    }

    static State!(true, 2).Node SPACEARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_SPACEARROW!(true, 2), "Pegged.SPACEARROW", true)(p);
    }

    static ParseResult SPACEARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(SPACEARROW)(ctx, input);
    }

    static ParseTree SPACEARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(SPACEARROW)(input);
    }

    private static State!(CT, Check).Node _ACTIONARROW(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("<"), Action, Spacing), "Pegged.ACTIONARROW")(s, p);
    }

    static State!(false, false).Node ACTIONARROW(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONARROW!(false, false), "Pegged.ACTIONARROW", true)(p);
    }

    static State!(true, false).Node ACTIONARROW(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ACTIONARROW!(true, false), "Pegged.ACTIONARROW", true)(p);
    }

    static State!(false, true).Node ACTIONARROW(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONARROW!(false, true), "Pegged.ACTIONARROW", true)(p);
    }

    static State!(true, true).Node ACTIONARROW(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ACTIONARROW!(true, true), "Pegged.ACTIONARROW", true)(p);
    }

    static State!(false, 2).Node ACTIONARROW(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONARROW!(false, 2), "Pegged.ACTIONARROW", true)(p);
    }

    static State!(true, 2).Node ACTIONARROW(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ACTIONARROW!(true, 2), "Pegged.ACTIONARROW", true)(p);
    }

    static ParseResult ACTIONARROW(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ACTIONARROW)(ctx, input);
    }

    static ParseTree ACTIONARROW(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ACTIONARROW)(input);
    }

    private static State!(CT, Check).Node _OR(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("/"), Spacing), "Pegged.OR")(s, p);
    }

    static State!(false, false).Node OR(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_OR!(false, false), "Pegged.OR", true)(p);
    }

    static State!(true, false).Node OR(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_OR!(true, false), "Pegged.OR", true)(p);
    }

    static State!(false, true).Node OR(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_OR!(false, true), "Pegged.OR", true)(p);
    }

    static State!(true, true).Node OR(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_OR!(true, true), "Pegged.OR", true)(p);
    }

    static State!(false, 2).Node OR(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_OR!(false, 2), "Pegged.OR", true)(p);
    }

    static State!(true, 2).Node OR(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_OR!(true, 2), "Pegged.OR", true)(p);
    }

    static ParseResult OR(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(OR)(ctx, input);
    }

    static ParseTree OR(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(OR)(input);
    }

    private static State!(CT, Check).Node _LONGEST_OR(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("|"), Spacing), "Pegged.LONGEST_OR")(s, p);
    }

    static State!(false, false).Node LONGEST_OR(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_LONGEST_OR!(false, false), "Pegged.LONGEST_OR", true)(p);
    }

    static State!(true, false).Node LONGEST_OR(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_LONGEST_OR!(true, false), "Pegged.LONGEST_OR", true)(p);
    }

    static State!(false, true).Node LONGEST_OR(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_LONGEST_OR!(false, true), "Pegged.LONGEST_OR", true)(p);
    }

    static State!(true, true).Node LONGEST_OR(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_LONGEST_OR!(true, true), "Pegged.LONGEST_OR", true)(p);
    }

    static State!(false, 2).Node LONGEST_OR(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_LONGEST_OR!(false, 2), "Pegged.LONGEST_OR", true)(p);
    }

    static State!(true, 2).Node LONGEST_OR(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_LONGEST_OR!(true, 2), "Pegged.LONGEST_OR", true)(p);
    }

    static ParseResult LONGEST_OR(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(LONGEST_OR)(ctx, input);
    }

    static ParseTree LONGEST_OR(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(LONGEST_OR)(input);
    }

    private static State!(CT, Check).Node _POS(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("&"), Spacing), "Pegged.POS")(s, p);
    }

    static State!(false, false).Node POS(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_POS!(false, false), "Pegged.POS", true)(p);
    }

    static State!(true, false).Node POS(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_POS!(true, false), "Pegged.POS", true)(p);
    }

    static State!(false, true).Node POS(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_POS!(false, true), "Pegged.POS", true)(p);
    }

    static State!(true, true).Node POS(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_POS!(true, true), "Pegged.POS", true)(p);
    }

    static State!(false, 2).Node POS(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_POS!(false, 2), "Pegged.POS", true)(p);
    }

    static State!(true, 2).Node POS(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_POS!(true, 2), "Pegged.POS", true)(p);
    }

    static ParseResult POS(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(POS)(ctx, input);
    }

    static ParseTree POS(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(POS)(input);
    }

    private static State!(CT, Check).Node _NEG(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("!"), Spacing), "Pegged.NEG")(s, p);
    }

    static State!(false, false).Node NEG(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_NEG!(false, false), "Pegged.NEG", true)(p);
    }

    static State!(true, false).Node NEG(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_NEG!(true, false), "Pegged.NEG", true)(p);
    }

    static State!(false, true).Node NEG(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_NEG!(false, true), "Pegged.NEG", true)(p);
    }

    static State!(true, true).Node NEG(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_NEG!(true, true), "Pegged.NEG", true)(p);
    }

    static State!(false, 2).Node NEG(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_NEG!(false, 2), "Pegged.NEG", true)(p);
    }

    static State!(true, 2).Node NEG(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_NEG!(true, 2), "Pegged.NEG", true)(p);
    }

    static ParseResult NEG(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(NEG)(ctx, input);
    }

    static ParseTree NEG(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(NEG)(input);
    }

    private static State!(CT, Check).Node _FUSE(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("~"), Spacing), "Pegged.FUSE")(s, p);
    }

    static State!(false, false).Node FUSE(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_FUSE!(false, false), "Pegged.FUSE", true)(p);
    }

    static State!(true, false).Node FUSE(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_FUSE!(true, false), "Pegged.FUSE", true)(p);
    }

    static State!(false, true).Node FUSE(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_FUSE!(false, true), "Pegged.FUSE", true)(p);
    }

    static State!(true, true).Node FUSE(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_FUSE!(true, true), "Pegged.FUSE", true)(p);
    }

    static State!(false, 2).Node FUSE(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_FUSE!(false, 2), "Pegged.FUSE", true)(p);
    }

    static State!(true, 2).Node FUSE(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_FUSE!(true, 2), "Pegged.FUSE", true)(p);
    }

    static ParseResult FUSE(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(FUSE)(ctx, input);
    }

    static ParseTree FUSE(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(FUSE)(input);
    }

    private static State!(CT, Check).Node _DISCARD(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!(":"), Spacing), "Pegged.DISCARD")(s, p);
    }

    static State!(false, false).Node DISCARD(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DISCARD!(false, false), "Pegged.DISCARD", true)(p);
    }

    static State!(true, false).Node DISCARD(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DISCARD!(true, false), "Pegged.DISCARD", true)(p);
    }

    static State!(false, true).Node DISCARD(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DISCARD!(false, true), "Pegged.DISCARD", true)(p);
    }

    static State!(true, true).Node DISCARD(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DISCARD!(true, true), "Pegged.DISCARD", true)(p);
    }

    static State!(false, 2).Node DISCARD(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DISCARD!(false, 2), "Pegged.DISCARD", true)(p);
    }

    static State!(true, 2).Node DISCARD(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DISCARD!(true, 2), "Pegged.DISCARD", true)(p);
    }

    static ParseResult DISCARD(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DISCARD)(ctx, input);
    }

    static ParseTree DISCARD(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DISCARD)(input);
    }

    private static State!(CT, Check).Node _KEEP(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("^"), Spacing), "Pegged.KEEP")(s, p);
    }

    static State!(false, false).Node KEEP(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_KEEP!(false, false), "Pegged.KEEP", true)(p);
    }

    static State!(true, false).Node KEEP(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_KEEP!(true, false), "Pegged.KEEP", true)(p);
    }

    static State!(false, true).Node KEEP(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_KEEP!(false, true), "Pegged.KEEP", true)(p);
    }

    static State!(true, true).Node KEEP(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_KEEP!(true, true), "Pegged.KEEP", true)(p);
    }

    static State!(false, 2).Node KEEP(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_KEEP!(false, 2), "Pegged.KEEP", true)(p);
    }

    static State!(true, 2).Node KEEP(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_KEEP!(true, 2), "Pegged.KEEP", true)(p);
    }

    static ParseResult KEEP(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(KEEP)(ctx, input);
    }

    static ParseTree KEEP(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(KEEP)(input);
    }

    private static State!(CT, Check).Node _DROP(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!(";"), Spacing), "Pegged.DROP")(s, p);
    }

    static State!(false, false).Node DROP(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DROP!(false, false), "Pegged.DROP", true)(p);
    }

    static State!(true, false).Node DROP(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DROP!(true, false), "Pegged.DROP", true)(p);
    }

    static State!(false, true).Node DROP(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DROP!(false, true), "Pegged.DROP", true)(p);
    }

    static State!(true, true).Node DROP(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DROP!(true, true), "Pegged.DROP", true)(p);
    }

    static State!(false, 2).Node DROP(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DROP!(false, 2), "Pegged.DROP", true)(p);
    }

    static State!(true, 2).Node DROP(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DROP!(true, 2), "Pegged.DROP", true)(p);
    }

    static ParseResult DROP(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DROP)(ctx, input);
    }

    static ParseTree DROP(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DROP)(input);
    }

    private static State!(CT, Check).Node _PROPAGATE(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("%"), Spacing), "Pegged.PROPAGATE")(s, p);
    }

    static State!(false, false).Node PROPAGATE(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_PROPAGATE!(false, false), "Pegged.PROPAGATE", true)(p);
    }

    static State!(true, false).Node PROPAGATE(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_PROPAGATE!(true, false), "Pegged.PROPAGATE", true)(p);
    }

    static State!(false, true).Node PROPAGATE(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_PROPAGATE!(false, true), "Pegged.PROPAGATE", true)(p);
    }

    static State!(true, true).Node PROPAGATE(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_PROPAGATE!(true, true), "Pegged.PROPAGATE", true)(p);
    }

    static State!(false, 2).Node PROPAGATE(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_PROPAGATE!(false, 2), "Pegged.PROPAGATE", true)(p);
    }

    static State!(true, 2).Node PROPAGATE(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_PROPAGATE!(true, 2), "Pegged.PROPAGATE", true)(p);
    }

    static ParseResult PROPAGATE(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(PROPAGATE)(ctx, input);
    }

    static ParseTree PROPAGATE(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(PROPAGATE)(input);
    }

    private static State!(CT, Check).Node _OPTION(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("?"), Spacing), "Pegged.OPTION")(s, p);
    }

    static State!(false, false).Node OPTION(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_OPTION!(false, false), "Pegged.OPTION", true)(p);
    }

    static State!(true, false).Node OPTION(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_OPTION!(true, false), "Pegged.OPTION", true)(p);
    }

    static State!(false, true).Node OPTION(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_OPTION!(false, true), "Pegged.OPTION", true)(p);
    }

    static State!(true, true).Node OPTION(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_OPTION!(true, true), "Pegged.OPTION", true)(p);
    }

    static State!(false, 2).Node OPTION(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_OPTION!(false, 2), "Pegged.OPTION", true)(p);
    }

    static State!(true, 2).Node OPTION(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_OPTION!(true, 2), "Pegged.OPTION", true)(p);
    }

    static ParseResult OPTION(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(OPTION)(ctx, input);
    }

    static ParseTree OPTION(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(OPTION)(input);
    }

    private static State!(CT, Check).Node _ZEROORMORE(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("*"), Spacing), "Pegged.ZEROORMORE")(s, p);
    }

    static State!(false, false).Node ZEROORMORE(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ZEROORMORE!(false, false), "Pegged.ZEROORMORE", true)(p);
    }

    static State!(true, false).Node ZEROORMORE(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ZEROORMORE!(true, false), "Pegged.ZEROORMORE", true)(p);
    }

    static State!(false, true).Node ZEROORMORE(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ZEROORMORE!(false, true), "Pegged.ZEROORMORE", true)(p);
    }

    static State!(true, true).Node ZEROORMORE(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ZEROORMORE!(true, true), "Pegged.ZEROORMORE", true)(p);
    }

    static State!(false, 2).Node ZEROORMORE(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ZEROORMORE!(false, 2), "Pegged.ZEROORMORE", true)(p);
    }

    static State!(true, 2).Node ZEROORMORE(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ZEROORMORE!(true, 2), "Pegged.ZEROORMORE", true)(p);
    }

    static ParseResult ZEROORMORE(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ZEROORMORE)(ctx, input);
    }

    static ParseTree ZEROORMORE(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ZEROORMORE)(input);
    }

    private static State!(CT, Check).Node _ONEORMORE(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("+"), Spacing), "Pegged.ONEORMORE")(s, p);
    }

    static State!(false, false).Node ONEORMORE(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ONEORMORE!(false, false), "Pegged.ONEORMORE", true)(p);
    }

    static State!(true, false).Node ONEORMORE(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ONEORMORE!(true, false), "Pegged.ONEORMORE", true)(p);
    }

    static State!(false, true).Node ONEORMORE(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ONEORMORE!(false, true), "Pegged.ONEORMORE", true)(p);
    }

    static State!(true, true).Node ONEORMORE(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ONEORMORE!(true, true), "Pegged.ONEORMORE", true)(p);
    }

    static State!(false, 2).Node ONEORMORE(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ONEORMORE!(false, 2), "Pegged.ONEORMORE", true)(p);
    }

    static State!(true, 2).Node ONEORMORE(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ONEORMORE!(true, 2), "Pegged.ONEORMORE", true)(p);
    }

    static ParseResult ONEORMORE(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ONEORMORE)(ctx, input);
    }

    static ParseTree ONEORMORE(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ONEORMORE)(input);
    }

    private static State!(CT, Check).Node _ACTIONOPEN(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("{"), Spacing), "Pegged.ACTIONOPEN")(s, p);
    }

    static State!(false, false).Node ACTIONOPEN(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONOPEN!(false, false), "Pegged.ACTIONOPEN", true)(p);
    }

    static State!(true, false).Node ACTIONOPEN(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ACTIONOPEN!(true, false), "Pegged.ACTIONOPEN", true)(p);
    }

    static State!(false, true).Node ACTIONOPEN(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONOPEN!(false, true), "Pegged.ACTIONOPEN", true)(p);
    }

    static State!(true, true).Node ACTIONOPEN(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ACTIONOPEN!(true, true), "Pegged.ACTIONOPEN", true)(p);
    }

    static State!(false, 2).Node ACTIONOPEN(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONOPEN!(false, 2), "Pegged.ACTIONOPEN", true)(p);
    }

    static State!(true, 2).Node ACTIONOPEN(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ACTIONOPEN!(true, 2), "Pegged.ACTIONOPEN", true)(p);
    }

    static ParseResult ACTIONOPEN(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ACTIONOPEN)(ctx, input);
    }

    static ParseTree ACTIONOPEN(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ACTIONOPEN)(input);
    }

    private static State!(CT, Check).Node _ACTIONCLOSE(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("}"), Spacing), "Pegged.ACTIONCLOSE")(s, p);
    }

    static State!(false, false).Node ACTIONCLOSE(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONCLOSE!(false, false), "Pegged.ACTIONCLOSE", true)(p);
    }

    static State!(true, false).Node ACTIONCLOSE(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ACTIONCLOSE!(true, false), "Pegged.ACTIONCLOSE", true)(p);
    }

    static State!(false, true).Node ACTIONCLOSE(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONCLOSE!(false, true), "Pegged.ACTIONCLOSE", true)(p);
    }

    static State!(true, true).Node ACTIONCLOSE(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ACTIONCLOSE!(true, true), "Pegged.ACTIONCLOSE", true)(p);
    }

    static State!(false, 2).Node ACTIONCLOSE(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ACTIONCLOSE!(false, 2), "Pegged.ACTIONCLOSE", true)(p);
    }

    static State!(true, 2).Node ACTIONCLOSE(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ACTIONCLOSE!(true, 2), "Pegged.ACTIONCLOSE", true)(p);
    }

    static ParseResult ACTIONCLOSE(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ACTIONCLOSE)(ctx, input);
    }

    static ParseTree ACTIONCLOSE(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ACTIONCLOSE)(input);
    }

    private static State!(CT, Check).Node _SEPARATOR(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!(","), Spacing), "Pegged.SEPARATOR")(s, p);
    }

    static State!(false, false).Node SEPARATOR(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_SEPARATOR!(false, false), "Pegged.SEPARATOR", true)(p);
    }

    static State!(true, false).Node SEPARATOR(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_SEPARATOR!(true, false), "Pegged.SEPARATOR", true)(p);
    }

    static State!(false, true).Node SEPARATOR(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_SEPARATOR!(false, true), "Pegged.SEPARATOR", true)(p);
    }

    static State!(true, true).Node SEPARATOR(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_SEPARATOR!(true, true), "Pegged.SEPARATOR", true)(p);
    }

    static State!(false, 2).Node SEPARATOR(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_SEPARATOR!(false, 2), "Pegged.SEPARATOR", true)(p);
    }

    static State!(true, 2).Node SEPARATOR(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_SEPARATOR!(true, 2), "Pegged.SEPARATOR", true)(p);
    }

    static ParseResult SEPARATOR(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(SEPARATOR)(ctx, input);
    }

    static ParseTree SEPARATOR(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(SEPARATOR)(input);
    }

    private static State!(CT, Check).Node _ASSIGN(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("="), Spacing), "Pegged.ASSIGN")(s, p);
    }

    static State!(false, false).Node ASSIGN(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ASSIGN!(false, false), "Pegged.ASSIGN", true)(p);
    }

    static State!(true, false).Node ASSIGN(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ASSIGN!(true, false), "Pegged.ASSIGN", true)(p);
    }

    static State!(false, true).Node ASSIGN(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ASSIGN!(false, true), "Pegged.ASSIGN", true)(p);
    }

    static State!(true, true).Node ASSIGN(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ASSIGN!(true, true), "Pegged.ASSIGN", true)(p);
    }

    static State!(false, 2).Node ASSIGN(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ASSIGN!(false, 2), "Pegged.ASSIGN", true)(p);
    }

    static State!(true, 2).Node ASSIGN(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ASSIGN!(true, 2), "Pegged.ASSIGN", true)(p);
    }

    static ParseResult ASSIGN(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ASSIGN)(ctx, input);
    }

    static ParseTree ASSIGN(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ASSIGN)(input);
    }

    private static State!(CT, Check).Node _NAMESEP(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(literal!("."), "Pegged.NAMESEP")(s, p);
    }

    static State!(false, false).Node NAMESEP(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_NAMESEP!(false, false), "Pegged.NAMESEP", true)(p);
    }

    static State!(true, false).Node NAMESEP(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_NAMESEP!(true, false), "Pegged.NAMESEP", true)(p);
    }

    static State!(false, true).Node NAMESEP(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_NAMESEP!(false, true), "Pegged.NAMESEP", true)(p);
    }

    static State!(true, true).Node NAMESEP(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_NAMESEP!(true, true), "Pegged.NAMESEP", true)(p);
    }

    static State!(false, 2).Node NAMESEP(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_NAMESEP!(false, 2), "Pegged.NAMESEP", true)(p);
    }

    static State!(true, 2).Node NAMESEP(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_NAMESEP!(true, 2), "Pegged.NAMESEP", true)(p);
    }

    static ParseResult NAMESEP(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(NAMESEP)(ctx, input);
    }

    static ParseTree NAMESEP(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(NAMESEP)(input);
    }

    private static State!(CT, Check).Node _OPEN(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("("), Spacing), "Pegged.OPEN")(s, p);
    }

    static State!(false, false).Node OPEN(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_OPEN!(false, false), "Pegged.OPEN", true)(p);
    }

    static State!(true, false).Node OPEN(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_OPEN!(true, false), "Pegged.OPEN", true)(p);
    }

    static State!(false, true).Node OPEN(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_OPEN!(false, true), "Pegged.OPEN", true)(p);
    }

    static State!(true, true).Node OPEN(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_OPEN!(true, true), "Pegged.OPEN", true)(p);
    }

    static State!(false, 2).Node OPEN(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_OPEN!(false, 2), "Pegged.OPEN", true)(p);
    }

    static State!(true, 2).Node OPEN(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_OPEN!(true, 2), "Pegged.OPEN", true)(p);
    }

    static ParseResult OPEN(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(OPEN)(ctx, input);
    }

    static ParseTree OPEN(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(OPEN)(input);
    }

    private static State!(CT, Check).Node _CLOSE(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!(")"), Spacing), "Pegged.CLOSE")(s, p);
    }

    static State!(false, false).Node CLOSE(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_CLOSE!(false, false), "Pegged.CLOSE", true)(p);
    }

    static State!(true, false).Node CLOSE(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_CLOSE!(true, false), "Pegged.CLOSE", true)(p);
    }

    static State!(false, true).Node CLOSE(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_CLOSE!(false, true), "Pegged.CLOSE", true)(p);
    }

    static State!(true, true).Node CLOSE(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_CLOSE!(true, true), "Pegged.CLOSE", true)(p);
    }

    static State!(false, 2).Node CLOSE(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_CLOSE!(false, 2), "Pegged.CLOSE", true)(p);
    }

    static State!(true, 2).Node CLOSE(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_CLOSE!(true, 2), "Pegged.CLOSE", true)(p);
    }

    static ParseResult CLOSE(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(CLOSE)(ctx, input);
    }

    static ParseTree CLOSE(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(CLOSE)(input);
    }

    private static State!(CT, Check).Node _ANY(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("."), Spacing), "Pegged.ANY")(s, p);
    }

    static State!(false, false).Node ANY(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_ANY!(false, false), "Pegged.ANY", true)(p);
    }

    static State!(true, false).Node ANY(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_ANY!(true, false), "Pegged.ANY", true)(p);
    }

    static State!(false, true).Node ANY(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_ANY!(false, true), "Pegged.ANY", true)(p);
    }

    static State!(true, true).Node ANY(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_ANY!(true, true), "Pegged.ANY", true)(p);
    }

    static State!(false, 2).Node ANY(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_ANY!(false, 2), "Pegged.ANY", true)(p);
    }

    static State!(true, 2).Node ANY(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_ANY!(true, 2), "Pegged.ANY", true)(p);
    }

    static ParseResult ANY(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(ANY)(ctx, input);
    }

    static ParseTree ANY(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(ANY)(input);
    }

    private static State!(CT, Check).Node _Spacing(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(discard!(zeroOrMore!(or!(blank, Comment))), "Pegged.Spacing")(s, p);
        return defined!(discard!(zeroOrMore!(predictiveChoice!(branch!(blank, 0x100002e00UL,
                0x0UL, 0x0UL, 0x0UL), branch!(Comment, 0x800000000UL, 0x0UL, 0x0UL, 0x0UL)))), "Pegged.Spacing")(s, p);
    }

    static State!(false, false).Node Spacing(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Spacing!(false, false), "Pegged.Spacing", true)(p);
    }

    static State!(true, false).Node Spacing(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Spacing!(true, false), "Pegged.Spacing", true)(p);
    }

    static State!(false, true).Node Spacing(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Spacing!(false, true), "Pegged.Spacing", true)(p);
    }

    static State!(true, true).Node Spacing(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Spacing!(true, true), "Pegged.Spacing", true)(p);
    }

    static State!(false, 2).Node Spacing(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Spacing!(false, 2), "Pegged.Spacing", true)(p);
    }

    static State!(true, 2).Node Spacing(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Spacing!(true, 2), "Pegged.Spacing", true)(p);
    }

    static ParseResult Spacing(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Spacing)(ctx, input);
    }

    static ParseTree Spacing(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Spacing)(input);
    }

    private static State!(CT, Check).Node _Comment(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("#"), zeroOrMore!(and!(negLookahead!(eol), any)), discard!(eol)),
                "Pegged.Comment")(s, p);
    }

    static State!(false, false).Node Comment(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Comment!(false, false), "Pegged.Comment", true)(p);
    }

    static State!(true, false).Node Comment(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Comment!(true, false), "Pegged.Comment", true)(p);
    }

    static State!(false, true).Node Comment(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Comment!(false, true), "Pegged.Comment", true)(p);
    }

    static State!(true, true).Node Comment(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Comment!(true, true), "Pegged.Comment", true)(p);
    }

    static State!(false, 2).Node Comment(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Comment!(false, 2), "Pegged.Comment", true)(p);
    }

    static State!(true, 2).Node Comment(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Comment!(true, 2), "Pegged.Comment", true)(p);
    }

    static ParseResult Comment(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Comment)(ctx, input);
    }

    static ParseTree Comment(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Comment)(input);
    }

    private static State!(CT, Check).Node _Space(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(spacing, literal!("\\t"), literal!("\\n"), literal!("\\r")), "Pegged.Space")(s, p);
    }

    static State!(false, false).Node Space(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Space!(false, false), "Pegged.Space", true)(p);
    }

    static State!(true, false).Node Space(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Space!(true, false), "Pegged.Space", true)(p);
    }

    static State!(false, true).Node Space(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Space!(false, true), "Pegged.Space", true)(p);
    }

    static State!(true, true).Node Space(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Space!(true, true), "Pegged.Space", true)(p);
    }

    static State!(false, 2).Node Space(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Space!(false, 2), "Pegged.Space", true)(p);
    }

    static State!(true, 2).Node Space(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Space!(true, 2), "Pegged.Space", true)(p);
    }

    static ParseResult Space(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Space)(ctx, input);
    }

    static ParseTree Space(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Space)(input);
    }

    private static State!(CT, Check).Node _Action(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(discard!(ACTIONOPEN), Spacing, and!(or!(Lambda,
                qualifiedIdentifier), zeroOrMore!(and!(discard!(SEPARATOR), or!(Lambda, qualifiedIdentifier)))),
                Spacing, discard!(ACTIONCLOSE)), "Pegged.Action")(s, p);
    }

    static State!(false, false).Node Action(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Action!(false, false), "Pegged.Action", true)(p);
    }

    static State!(true, false).Node Action(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Action!(true, false), "Pegged.Action", true)(p);
    }

    static State!(false, true).Node Action(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Action!(false, true), "Pegged.Action", true)(p);
    }

    static State!(true, true).Node Action(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Action!(true, true), "Pegged.Action", true)(p);
    }

    static State!(false, 2).Node Action(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Action!(false, 2), "Pegged.Action", true)(p);
    }

    static State!(true, 2).Node Action(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Action!(true, 2), "Pegged.Action", true)(p);
    }

    static ParseResult Action(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Action)(ctx, input);
    }

    static ParseTree Action(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Action)(input);
    }

    private static State!(CT, Check).Node _Lambda(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(fuse!(zeroOrMore!(and!(negLookahead!(or!(ACTIONCLOSE, SEPARATOR)),
                    or!(LambdaItems, NestedList!(literal!("{"), LambdaItems, literal!("}")), any)))), "Pegged.Lambda")(
                    s, p);
        return defined!(fuse!(zeroOrMore!(and!(negLookahead!(predictiveChoice!(branch!(ACTIONCLOSE,
                0x0UL, 0x2000000000000000UL, 0x0UL, 0x0UL), branch!(SEPARATOR, 0x100000000000UL,
                0x0UL, 0x0UL, 0x0UL))), or!(LambdaItems, NestedList!(literal!("{"), LambdaItems,
                literal!("}")), any)))), "Pegged.Lambda")(s, p);
    }

    static State!(false, false).Node Lambda(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_Lambda!(false, false), "Pegged.Lambda", true)(p);
    }

    static State!(true, false).Node Lambda(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_Lambda!(true, false), "Pegged.Lambda", true)(p);
    }

    static State!(false, true).Node Lambda(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_Lambda!(false, true), "Pegged.Lambda", true)(p);
    }

    static State!(true, true).Node Lambda(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_Lambda!(true, true), "Pegged.Lambda", true)(p);
    }

    static State!(false, 2).Node Lambda(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_Lambda!(false, 2), "Pegged.Lambda", true)(p);
    }

    static State!(true, 2).Node Lambda(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_Lambda!(true, 2), "Pegged.Lambda", true)(p);
    }

    static ParseResult Lambda(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(Lambda)(ctx, input);
    }

    static ParseTree Lambda(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(Lambda)(input);
    }

    private static State!(CT, Check).Node _LambdaItems(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(fuse!(DComment), fuse!(DString), fuse!(DParamList)), "Pegged.LambdaItems")(s, p);
    }

    static State!(false, false).Node LambdaItems(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_LambdaItems!(false, false), "Pegged.LambdaItems", true)(p);
    }

    static State!(true, false).Node LambdaItems(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_LambdaItems!(true, false), "Pegged.LambdaItems", true)(p);
    }

    static State!(false, true).Node LambdaItems(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_LambdaItems!(false, true), "Pegged.LambdaItems", true)(p);
    }

    static State!(true, true).Node LambdaItems(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_LambdaItems!(true, true), "Pegged.LambdaItems", true)(p);
    }

    static State!(false, 2).Node LambdaItems(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_LambdaItems!(false, 2), "Pegged.LambdaItems", true)(p);
    }

    static State!(true, 2).Node LambdaItems(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_LambdaItems!(true, 2), "Pegged.LambdaItems", true)(p);
    }

    static ParseResult LambdaItems(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(LambdaItems)(ctx, input);
    }

    static ParseTree LambdaItems(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(LambdaItems)(input);
    }

    private static State!(CT, Check).Node _DString(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(WYSString, DBQString, TKNString, DLMString), "Pegged.DString")(s, p);
    }

    static State!(false, false).Node DString(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DString!(false, false), "Pegged.DString", true)(p);
    }

    static State!(true, false).Node DString(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DString!(true, false), "Pegged.DString", true)(p);
    }

    static State!(false, true).Node DString(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DString!(false, true), "Pegged.DString", true)(p);
    }

    static State!(true, true).Node DString(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DString!(true, true), "Pegged.DString", true)(p);
    }

    static State!(false, 2).Node DString(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DString!(false, 2), "Pegged.DString", true)(p);
    }

    static State!(true, 2).Node DString(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DString!(true, 2), "Pegged.DString", true)(p);
    }

    static ParseResult DString(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DString)(ctx, input);
    }

    static ParseTree DString(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DString)(input);
    }

    struct _dfa_WYSString {
        enum automaton = compileDFA([
            regularByte(0x0UL, 0x4000000000000UL, 0x0UL, 0x0UL), // node 0
            regularNode(RegularKind.sequence, [0]), // node 1
            regularByte(0x400000000UL, 0x0UL, 0x0UL,
                    0x0UL), // node 2
            regularByte(0xfffffffbffffffffUL, 0xffffffffffffffffUL, 0xffffffffffffffffUL,
                    0xffffffffffffffffUL), // node 3
            regularNode(RegularKind.repetition, [3]), // node 4
            regularByte(0x400000000UL, 0x0UL, 0x0UL,
                    0x0UL), // node 5
            regularNode(RegularKind.sequence, [1, 2, 4, 5]), // node 6
            regularNode(RegularKind.sequence, [6]), // node 7
            regularByte(0x0UL, 0x100000000UL, 0x0UL,
                    0x0UL), // node 8
            regularByte(0xffffffffffffffffUL, 0xfffffffeffffffffUL, 0xffffffffffffffffUL,
                    0xffffffffffffffffUL), // node 9
            regularNode(RegularKind.repetition, [9]), // node 10
            regularByte(0x0UL, 0x100000000UL, 0x0UL,
                    0x0UL), // node 11
            regularNode(RegularKind.sequence, [8, 10, 11]), // node 12
            regularNode(RegularKind.sequence,
                    [12]), // node 13
            regularNode(RegularKind.choice, [7, 13]), // node 14
        ], 14, false);
        enum valid = automaton.valid;
        enum requireEnd = automaton.requireEnd;
    }

    private static State!(CT, Check).Node _WYSString(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        if (s.context.trace !is null)
            return defined!(or!(and!(literal!("r"), doublequote,
                    zeroOrMore!(and!(negLookahead!(doublequote), any)), doublequote), and!(backquote,
                    zeroOrMore!(and!(negLookahead!(backquote), any)), backquote)), "Pegged.WYSString")(s, p);
        return defined!(dfaToken!(predictiveChoice!(branch!(and!(literal!("r"), doublequote,
                zeroOrMore!(charClass!(0xfffffffbffffffffUL, 0xffffffffffffffffUL,
                0xffffffffffffffffUL, 0xffffffffffffffffUL)), doublequote), 0x0UL, 0x4000000000000UL, 0x0UL, 0x0UL),
                branch!(and!(backquote,
                zeroOrMore!(charClass!(0xffffffffffffffffUL,
                0xfffffffeffffffffUL,
                0xffffffffffffffffUL, 0xffffffffffffffffUL)), backquote), 0x0UL, 0x100000000UL, 0x0UL, 0x0UL)),
                _dfa_WYSString, 0, false), "Pegged.WYSString")(s, p);
    }

    static State!(false, false).Node WYSString(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_WYSString!(false, false), "Pegged.WYSString", true)(p);
    }

    static State!(true, false).Node WYSString(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_WYSString!(true, false), "Pegged.WYSString", true)(p);
    }

    static State!(false, true).Node WYSString(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_WYSString!(false, true), "Pegged.WYSString", true)(p);
    }

    static State!(true, true).Node WYSString(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_WYSString!(true, true), "Pegged.WYSString", true)(p);
    }

    static State!(false, 2).Node WYSString(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_WYSString!(false, 2), "Pegged.WYSString", true)(p);
    }

    static State!(true, 2).Node WYSString(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_WYSString!(true, 2), "Pegged.WYSString", true)(p);
    }

    static ParseResult WYSString(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(WYSString)(ctx, input);
    }

    static ParseTree WYSString(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(WYSString)(input);
    }

    private static State!(CT, Check).Node _DBQString(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(doublequote, zeroOrMore!(and!(negLookahead!(doublequote), Char)),
                doublequote), "Pegged.DBQString")(s, p);
    }

    static State!(false, false).Node DBQString(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DBQString!(false, false), "Pegged.DBQString", true)(p);
    }

    static State!(true, false).Node DBQString(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DBQString!(true, false), "Pegged.DBQString", true)(p);
    }

    static State!(false, true).Node DBQString(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DBQString!(false, true), "Pegged.DBQString", true)(p);
    }

    static State!(true, true).Node DBQString(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DBQString!(true, true), "Pegged.DBQString", true)(p);
    }

    static State!(false, 2).Node DBQString(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DBQString!(false, 2), "Pegged.DBQString", true)(p);
    }

    static State!(true, 2).Node DBQString(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DBQString!(true, 2), "Pegged.DBQString", true)(p);
    }

    static ParseResult DBQString(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DBQString)(ctx, input);
    }

    static ParseTree DBQString(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DBQString)(input);
    }

    private static State!(CT, Check).Node _TKNString(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(posLookahead!(literal!("q{")), and!(literal!("q"),
                NestedList!(literal!("{"), DString, literal!("}")))), "Pegged.TKNString")(s, p);
    }

    static State!(false, false).Node TKNString(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_TKNString!(false, false), "Pegged.TKNString", true)(p);
    }

    static State!(true, false).Node TKNString(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_TKNString!(true, false), "Pegged.TKNString", true)(p);
    }

    static State!(false, true).Node TKNString(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_TKNString!(false, true), "Pegged.TKNString", true)(p);
    }

    static State!(true, true).Node TKNString(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_TKNString!(true, true), "Pegged.TKNString", true)(p);
    }

    static State!(false, 2).Node TKNString(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_TKNString!(false, 2), "Pegged.TKNString", true)(p);
    }

    static State!(true, 2).Node TKNString(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_TKNString!(true, 2), "Pegged.TKNString", true)(p);
    }

    static ParseResult TKNString(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(TKNString)(ctx, input);
    }

    static ParseTree TKNString(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(TKNString)(input);
    }

    private static State!(CT, Check).Node _DLMString(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(and!(literal!("q"), doublequote),
                or!(and!(posLookahead!(literal!("{")), NestedList!(literal!("{"), DString, literal!("}"))),
                and!(posLookahead!(literal!("[")), NestedList!(literal!("["), DString, literal!("]"))),
                and!(posLookahead!(literal!("(")), NestedList!(literal!("("), DString, literal!(")"))),
                and!(posLookahead!(literal!("<")), NestedList!(literal!("<"), DString, literal!(">")))), doublequote),
                "Pegged.DLMString")(s, p);
    }

    static State!(false, false).Node DLMString(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DLMString!(false, false), "Pegged.DLMString", true)(p);
    }

    static State!(true, false).Node DLMString(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DLMString!(true, false), "Pegged.DLMString", true)(p);
    }

    static State!(false, true).Node DLMString(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DLMString!(false, true), "Pegged.DLMString", true)(p);
    }

    static State!(true, true).Node DLMString(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DLMString!(true, true), "Pegged.DLMString", true)(p);
    }

    static State!(false, 2).Node DLMString(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DLMString!(false, 2), "Pegged.DLMString", true)(p);
    }

    static State!(true, 2).Node DLMString(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DLMString!(true, 2), "Pegged.DLMString", true)(p);
    }

    static ParseResult DLMString(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DLMString)(ctx, input);
    }

    static ParseTree DLMString(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DLMString)(input);
    }

    private static State!(CT, Check).Node _DComment(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(or!(DLineComment, DBlockComment, DNestingBlockComment), "Pegged.DComment")(s, p);
    }

    static State!(false, false).Node DComment(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DComment!(false, false), "Pegged.DComment", true)(p);
    }

    static State!(true, false).Node DComment(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DComment!(true, false), "Pegged.DComment", true)(p);
    }

    static State!(false, true).Node DComment(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DComment!(false, true), "Pegged.DComment", true)(p);
    }

    static State!(true, true).Node DComment(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DComment!(true, true), "Pegged.DComment", true)(p);
    }

    static State!(false, 2).Node DComment(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DComment!(false, 2), "Pegged.DComment", true)(p);
    }

    static State!(true, 2).Node DComment(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DComment!(true, 2), "Pegged.DComment", true)(p);
    }

    static ParseResult DComment(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DComment)(ctx, input);
    }

    static ParseTree DComment(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DComment)(input);
    }

    private static State!(CT, Check).Node _DLineComment(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("//"), zeroOrMore!(and!(negLookahead!(endOfLine), any)),
                endOfLine), "Pegged.DLineComment")(s, p);
    }

    static State!(false, false).Node DLineComment(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DLineComment!(false, false), "Pegged.DLineComment", true)(p);
    }

    static State!(true, false).Node DLineComment(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DLineComment!(true, false), "Pegged.DLineComment", true)(p);
    }

    static State!(false, true).Node DLineComment(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DLineComment!(false, true), "Pegged.DLineComment", true)(p);
    }

    static State!(true, true).Node DLineComment(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DLineComment!(true, true), "Pegged.DLineComment", true)(p);
    }

    static State!(false, 2).Node DLineComment(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DLineComment!(false, 2), "Pegged.DLineComment", true)(p);
    }

    static State!(true, 2).Node DLineComment(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DLineComment!(true, 2), "Pegged.DLineComment", true)(p);
    }

    static ParseResult DLineComment(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DLineComment)(ctx, input);
    }

    static ParseTree DLineComment(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DLineComment)(input);
    }

    private static State!(CT, Check).Node _DBlockComment(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(and!(literal!("/*"), zeroOrMore!(and!(negLookahead!(literal!("*/")),
                any)), literal!("*/")), "Pegged.DBlockComment")(s, p);
    }

    static State!(false, false).Node DBlockComment(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DBlockComment!(false, false), "Pegged.DBlockComment", true)(p);
    }

    static State!(true, false).Node DBlockComment(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DBlockComment!(true, false), "Pegged.DBlockComment", true)(p);
    }

    static State!(false, true).Node DBlockComment(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DBlockComment!(false, true), "Pegged.DBlockComment", true)(p);
    }

    static State!(true, true).Node DBlockComment(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DBlockComment!(true, true), "Pegged.DBlockComment", true)(p);
    }

    static State!(false, 2).Node DBlockComment(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DBlockComment!(false, 2), "Pegged.DBlockComment", true)(p);
    }

    static State!(true, 2).Node DBlockComment(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DBlockComment!(true, 2), "Pegged.DBlockComment", true)(p);
    }

    static ParseResult DBlockComment(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DBlockComment)(ctx, input);
    }

    static ParseTree DBlockComment(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DBlockComment)(input);
    }

    private static State!(CT, Check).Node _DNestingBlockComment(bool CT, int Check = 0)(ref State!(CT,
            Check) s, size_t p) nothrow {
        return defined!(NestedList!(literal!("/+"), literal!("+/")), "Pegged.DNestingBlockComment")(s, p);
    }

    static State!(false, false).Node DNestingBlockComment(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DNestingBlockComment!(false, false), "Pegged.DNestingBlockComment", true)(p);
    }

    static State!(true, false).Node DNestingBlockComment(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DNestingBlockComment!(true, false), "Pegged.DNestingBlockComment", true)(p);
    }

    static State!(false, true).Node DNestingBlockComment(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DNestingBlockComment!(false, true), "Pegged.DNestingBlockComment", true)(p);
    }

    static State!(true, true).Node DNestingBlockComment(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DNestingBlockComment!(true, true), "Pegged.DNestingBlockComment", true)(p);
    }

    static State!(false, 2).Node DNestingBlockComment(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DNestingBlockComment!(false, 2), "Pegged.DNestingBlockComment", true)(p);
    }

    static State!(true, 2).Node DNestingBlockComment(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DNestingBlockComment!(true, 2), "Pegged.DNestingBlockComment", true)(p);
    }

    static ParseResult DNestingBlockComment(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DNestingBlockComment)(ctx, input);
    }

    static ParseTree DNestingBlockComment(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DNestingBlockComment)(input);
    }

    private static State!(CT, Check).Node _DParamList(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
        return defined!(NestedList!(literal!("("), literal!(")")), "Pegged.DParamList")(s, p);
    }

    static State!(false, false).Node DParamList(ref State!(false, false) s, size_t p) @nogc nothrow {
        return s.rule!(_DParamList!(false, false), "Pegged.DParamList", true)(p);
    }

    static State!(true, false).Node DParamList(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        return s.rule!(_DParamList!(true, false), "Pegged.DParamList", true)(p);
    }

    static State!(false, true).Node DParamList(ref State!(false, true) s, size_t p) @nogc nothrow {
        return s.rule!(_DParamList!(false, true), "Pegged.DParamList", true)(p);
    }

    static State!(true, true).Node DParamList(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        return s.rule!(_DParamList!(true, true), "Pegged.DParamList", true)(p);
    }

    static State!(false, 2).Node DParamList(ref State!(false, 2) s, size_t p) @nogc nothrow {
        return s.rule!(_DParamList!(false, 2), "Pegged.DParamList", true)(p);
    }

    static State!(true, 2).Node DParamList(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        return s.rule!(_DParamList!(true, 2), "Pegged.DParamList", true)(p);
    }

    static ParseResult DParamList(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(DParamList)(ctx, input);
    }

    static ParseTree DParamList(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(DParamList)(input);
    }

    template NestedList(alias L, alias Items, alias R) {
        private static State!(CT, Check).Node _NestedList(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
            return defined!(and!(keep!(L), zeroOrMore!(and!(negLookahead!(or!(L, R, Items)),
                    any)), zeroOrMore!(or!(Items, NestedList!(L, Items, R),
                    zeroOrMore!(and!(negLookahead!(or!(L, R, Items)), any)))),
                    zeroOrMore!(and!(negLookahead!(or!(L, R, Items)), any)), keep!(R)), "Pegged.NestedList")(s, p);
        }

        static State!(false, false).Node _entry(ref State!(false, false) s, size_t p) @nogc nothrow {
            return s.rule!(_NestedList!(false, false), "Pegged.NestedList", true)(p);
        }

        static State!(true, false).Node _entry(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
            return s.rule!(_NestedList!(true, false), "Pegged.NestedList", true)(p);
        }

        static State!(false, true).Node _entry(ref State!(false, true) s, size_t p) @nogc nothrow {
            return s.rule!(_NestedList!(false, true), "Pegged.NestedList", true)(p);
        }

        static State!(true, true).Node _entry(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
            return s.rule!(_NestedList!(true, true), "Pegged.NestedList", true)(p);
        }

        static State!(false, 2).Node _entry(ref State!(false, 2) s, size_t p) @nogc nothrow {
            return s.rule!(_NestedList!(false, 2), "Pegged.NestedList", true)(p);
        }

        static State!(true, 2).Node _entry(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
            return s.rule!(_NestedList!(true, 2), "Pegged.NestedList", true)(p);
        }

        static ParseResult _entry(Context)(ref Context ctx, string input) @nogc nothrow 
                if (is(Context == ParseContext)) {
            return parse!(_entry)(ctx, input);
        }

        static ParseTree _entry(Input)(Input input) nothrow if (is(Input == string)) {
            return parseCT!(_entry)(input);
        }

        alias NestedList = _entry;
    }

    template NestedList(alias L, alias R) {
        private static State!(CT, Check).Node _NestedList(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t p) nothrow {
            return defined!(and!(keep!(L), zeroOrMore!(and!(negLookahead!(or!(L, R)), any)),
                    zeroOrMore!(or!(NestedList!(L, R), zeroOrMore!(and!(negLookahead!(or!(L, R)), any)))),
                    zeroOrMore!(and!(negLookahead!(or!(L, R)), any)), keep!(R)), "Pegged.NestedList")(s, p);
        }

        static State!(false, false).Node _entry(ref State!(false, false) s, size_t p) @nogc nothrow {
            return s.rule!(_NestedList!(false, false), "Pegged.NestedList", true)(p);
        }

        static State!(true, false).Node _entry(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
            return s.rule!(_NestedList!(true, false), "Pegged.NestedList", true)(p);
        }

        static State!(false, true).Node _entry(ref State!(false, true) s, size_t p) @nogc nothrow {
            return s.rule!(_NestedList!(false, true), "Pegged.NestedList", true)(p);
        }

        static State!(true, true).Node _entry(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
            return s.rule!(_NestedList!(true, true), "Pegged.NestedList", true)(p);
        }

        static State!(false, 2).Node _entry(ref State!(false, 2) s, size_t p) @nogc nothrow {
            return s.rule!(_NestedList!(false, 2), "Pegged.NestedList", true)(p);
        }

        static State!(true, 2).Node _entry(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
            return s.rule!(_NestedList!(true, 2), "Pegged.NestedList", true)(p);
        }

        static ParseResult _entry(Context)(ref Context ctx, string input) @nogc nothrow 
                if (is(Context == ParseContext)) {
            return parse!(_entry)(ctx, input);
        }

        static ParseTree _entry(Input)(Input input) nothrow if (is(Input == string)) {
            return parseCT!(_entry)(input);
        }

        alias NestedList = _entry;
    }

    static State!(false, false).Node opCall(ref State!(false, false) s, size_t p) @nogc nothrow {
        auto t = Grammar(s, p);
        t.name = "Pegged";
        return t;
    }

    static State!(true, false).Node opCall(CompileTime = void)(ref State!(true, false) s, size_t p) nothrow {
        auto t = Grammar(s, p);
        t.name = "Pegged";
        return t;
    }

    static State!(false, true).Node opCall(ref State!(false, true) s, size_t p) @nogc nothrow {
        auto t = Grammar(s, p);
        return t;
    }

    static State!(true, true).Node opCall(CompileTime = void)(ref State!(true, true) s, size_t p) nothrow {
        auto t = Grammar(s, p);
        return t;
    }

    static State!(false, 2).Node opCall(ref State!(false, 2) s, size_t p) @nogc nothrow {
        auto t = Grammar(s, p);
        return t;
    }

    static State!(true, 2).Node opCall(CompileTime = void)(ref State!(true, 2) s, size_t p) nothrow {
        auto t = Grammar(s, p);
        return t;
    }

    static ParseResult opCall(Context)(ref Context ctx, string input) @nogc nothrow 
            if (is(Context == ParseContext)) {
        return parse!(opCall)(ctx, input);
    }

    static ParseTree opCall(Input)(Input input) nothrow if (is(Input == string)) {
        return parseCT!(opCall)(input);
    }
}

@nogc nothrow unittest {
    ParseContext context;
    enum definition = "Tiny: A <- 'a' eoi";
    auto valid = Pegged(context, definition);
    assert(valid.successful && valid.end == definition.length);
    auto invalid = Pegged(context, "Tiny: A <- (");
    assert(!invalid.successful);
    auto space = Pegged.Space(context, "\t\n");
    assert(space.successful && space.end == 2);
}

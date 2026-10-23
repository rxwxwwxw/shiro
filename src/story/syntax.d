// The `.story` line grammar, generated at compile time by npegged. Story files are parsed one line
// at a time (after the compiler strips indentation, blank lines and `#` comment lines), so a typo
// costs one diagnostic for its own line and block structure is the compiler's job.
//
//   label elder_hi:
//       elder (worried): Ah, you came, {player_name}.     speaker line, raw text to end of line
//       set met_elder                                      statements
//       * What is out there?  if not asked_west            choice with an optional condition
//
// Model layer: no SDL. Parsing is @nogc nothrow (npegged arena storage per parse).
module story.syntax;

public import npegged.grammar : ParseContext, ParseTree, ParseResult;
import npegged.grammar;

mixin(grammar(`
StoryLine:
    Line        <- Stmt Sp Comment? eoi

    Stmt        <- Import / TypeDecl / CharDecl / PlaceDecl / VarDecl / On / LabelDecl / SubLabel
                 / Option / Goto / Call / Return / End / If / Elif / Else / For
                 / SetStmt / ClearStmt / EventStmt / Show / Hide / SceneCmd / Play / StopCmd / Battle
                 / Ware / Topic / Prop / Derived / Assign / CallStmt / Say / Narrate

    Import      <- "import" Sp1 String
    TypeDecl    <- "type" Sp1 Name Sp ":"
    CharDecl    <- "character" Sp1 Name (Sp1 String)? (Sp ":")?
    PlaceDecl   <- "place" Sp1 Name (Sp1 String)? (Sp ":")?
    VarDecl     <- "var" Sp1 Name Sp (VarType / VarInit) Bounds?
    VarType     <- ":" Sp Name
    VarInit     <- "=" Sp Expr
    Bounds      <- Sp1 "in" Sp1 SignedNumber Sp ".." Sp SignedNumber

    On          <- "on" Sp1 TrigKind (Sp1 OnTarget)? (Sp1 Once)? (Sp1 "if" Sp1 Expr)? Sp (OnGoto / OnBlock)
    TrigKind    <~ ("start" / "talk" / "enter" / "return") !NameChar
    OnTarget    <~ !(("once" / "if") !NameChar) [a-zA-Z_] NameChar*
    Once        <- "once" !NameChar
    OnGoto      <- "->" Sp Target
    OnBlock     <- ":"

    LabelDecl   <- "label" Sp1 Name Sp ":"
    SubLabel    <- "." Name Sp ":"

    Option      <- "*" Sp Caption OptCond?
    Caption     <- String &(OptCond? Sp eoi) / RawCaption
    RawCaption  <~ (!(OptCond Sp eoi) .)+
    OptCond     <- Sp1 "if" Sp1 Expr

    Goto        <- ("->" / "jump" Sp1) Sp Target
    Call        <- "call" Sp1 Target
    Target      <~ "."? [a-zA-Z_] NameChar* ("." [a-zA-Z_] NameChar*)*
    Return      <- "return" !NameChar
    End         <- "end" !NameChar
    If          <- "if" Sp1 Expr Sp ":"
    Elif        <- "elif" Sp1 Expr Sp ":"
    Else        <- "else" Sp ":"
    For         <- "for" Sp1 Name Sp1 "in" Sp1 Expr Sp ":"

    SetStmt     <- "set" Sp1 Path (Sp "=" Sp Expr)?
    ClearStmt   <- "clear" Sp1 Path
    EventStmt   <- "event" Sp1 Name (Sp1 Expr)?
    Show        <- "show" Sp1 Name (Sp1 Name)?
    Hide        <- "hide" Sp1 Name
    SceneCmd    <- "scene" Sp1 Name
    Play        <- "play" Sp1 Channel Sp1 String
    StopCmd     <- "stop" Sp1 Channel
    Channel     <~ ("music" / "sound") !NameChar
    Battle      <- "battle" !NameChar (Sp1 Name)?

    Ware        <- "ware" Sp1 String Sp1 Number Sp "->" Sp Name Sp ":" Sp Text
    Topic       <- "topic" Sp1 String Sp ":" Sp Text
    Prop        <- PropKey (Sp1 Atom)+
    PropKey     <~ ("portrait" / "figure" / "sprite" / "home" / "wander" / "image" / "host") !NameChar
    Atom        <- SignedNumber / String / Name
    Derived     <- Name Sp "=>" Sp Expr
    Assign      <- Lval Sp AssignOp Sp Expr Bounds?
    Lval        <- Path (Index / Member)*
    CallStmt    <- CallExpr &(Sp ("#" / eoi))
    AssignOp    <~ "+=" / "-=" / "*=" / "/=" / "%=" / "=" !"="

    Say         <- Name (Sp Mood)? Sp ":" Sp Text
    Mood        <- "(" Sp Name Sp ")"
    Narrate     <- ":" Sp Text / !([a-z_] / "->" / "*" / "." [a-zA-Z_]) Text
    Text        <~ .+

    Expr        <- Or
    Or          <- And (Sp OrOp Sp And)*
    OrOp        <~ "or" !NameChar
    And         <- Not (Sp AndOp Sp Not)*
    AndOp       <~ "and" !NameChar
    Not         <- NotOp Sp Not / Cmp
    NotOp       <~ "not" !NameChar / "!" !"="
    Cmp         <- Sum (Sp CmpOp Sp Sum)?
    CmpOp       <~ "==" / "!=" / "<=" / ">=" / "<" / ">"
    Sum         <- Term (Sp AddOp Sp Term)*
    AddOp       <~ "+" !"=" / "-" !"=" !">"
    Term        <- Unary (Sp MulOp Sp Unary)*
    MulOp       <~ ("*" / "/" / "%") !"="
    Unary       <- NegOp Sp Unary / Postfix
    Postfix     <- Primary (Index / Member)*
    Index       <- "[" Sp Expr Sp "]"
    Member      <- "." Name
    NegOp       <~ "-"
    Primary     <- Number / String / ListLit / MapLit / Paren / CallExpr / Literal / Path
    ListLit     <- "[" Sp (Expr (Sp "," Sp Expr)* (Sp ",")?)? Sp "]"
    MapLit      <- "{" Sp (Pair (Sp "," Sp Pair)* (Sp ",")?)? Sp "}"
    Pair        <- (String / Name) Sp ":" Sp Expr
    Paren       <- "(" Sp Expr Sp ")"
    CallExpr    <- Name Sp "(" Sp (Expr (Sp "," Sp Expr)*)? Sp ")"
    Literal     <~ ("true" / "false" / "nil") !NameChar
    Path        <- Name ("." Name)*

    Name        <~ !Keyword [a-zA-Z_] NameChar*
    Keyword     <- ("import" / "type" / "character" / "place" / "var" / "on" / "label" / "if" / "elif"
                 / "else" / "set" / "clear" / "event" / "show" / "hide" / "scene" / "play" / "stop"
                 / "battle" / "call" / "return" / "end" / "jump" / "for" / "and" / "or" / "not" / "true"
                 / "false" / "nil" / "in") !NameChar
    NameChar    <- [a-zA-Z0-9_]
    SignedNumber <~ "-"? Number
    Number      <~ [0-9]+ ("." [0-9]+)?
    String      <~ doublequote (backslash . / !doublequote .)* doublequote
    Comment     <- "#" .*
    Sp          <: [ \t]*
    Sp1         <: [ \t]+
`));

/// Parses one line (indentation already stripped). The tree's slices point into `line`, which
/// must outlive the result.
auto parseLine(ref ParseContext ctx, const(char)[] line) @nogc nothrow @trusted {
    return StoryLine(ctx, cast(string)line);
}

/// Parses a whole expression (the inside of a `{...}` interpolation); check `end == text.length`.
auto parseExpr(ref ParseContext ctx, const(char)[] text) @nogc nothrow @trusted {
    return StoryLine.Expr(ctx, cast(string)text);
}

/// The statement node of a parsed line: `tree` -> Line -> Stmt -> <statement>.
ref const(ParseTree) statementOf(ref const ParseTree root) @nogc nothrow @safe {
    return root.children[0].children[0].children[0];
}

/// Rule name without the grammar prefix ("StoryLine.Say" -> "Say").
const(char)[] ruleName(ref const ParseTree t) @nogc nothrow pure @safe {
    enum prefix = "StoryLine.";
    return t.name.length > prefix.length && t.name[0 .. prefix.length] == prefix ? t.name[prefix.length .. $] : t.name;
}

version (unittest) {
    private bool parsesAs(const(char)[] line, const(char)[] rule) @nogc nothrow {
        ParseContext ctx;
        auto r = parseLine(ctx, line);
        return r.successful && ruleName(statementOf(r.tree)) == rule;
    }
}

@nogc nothrow unittest {
    assert(parsesAs(`import "elder.story"`, "Import"));
    assert(parsesAs("type Bond:", "TypeDecl"));
    assert(parsesAs(`character elder "Bà Lan":`, "CharDecl"));
    assert(parsesAs("character guard:", "CharDecl"));
    assert(parsesAs(`place smithy "Chú Tư's Forge":`, "PlaceDecl"));
    assert(parsesAs("var coins = 40", "VarDecl"));
    assert(parsesAs("var town: Town", "VarDecl"));
    assert(parsesAs("var mood = 0 in -10..10", "VarDecl"));
    assert(parsesAs("on start once -> intro", "On"));
    assert(parsesAs("on talk elder if not met_elder -> elder_hi", "On"));
    assert(parsesAs("on return won:", "On"));
    assert(parsesAs("on return:", "On"));
    assert(parsesAs("label elder_hi:", "LabelDecl"));
    assert(parsesAs(".ask:", "SubLabel"));
    assert(parsesAs("* I will hold it.", "Option"));
    assert(parsesAs("* What is out there?  if not asked_west", "Option"));
    assert(parsesAs(`* "Quoted {name}" if a`, "Option"));
    assert(parsesAs("-> .bless", "Goto"));
    assert(parsesAs("jump elder_hi.ask", "Goto"));
    assert(parsesAs("call blessing", "Call"));
    assert(parsesAs("return", "Return"));
    assert(parsesAs("end", "End"));
    assert(parsesAs("if elder.bond.trust >= 60:", "If"));
    assert(parsesAs("elif td_runs > 2 or x:", "Elif"));
    assert(parsesAs("else:", "Else"));
    assert(parsesAs("set met_elder", "SetStmt"));
    assert(parsesAs("set gold = 30 + 2", "SetStmt"));
    assert(parsesAs("clear gate_open", "ClearStmt"));
    assert(parsesAs("event gate_open", "EventStmt"));
    assert(parsesAs("show elder happy", "Show"));
    assert(parsesAs("hide elder", "Hide"));
    assert(parsesAs("scene plaza", "SceneCmd"));
    assert(parsesAs(`play music "theme.ogg"`, "Play"));
    assert(parsesAs("stop sound", "StopCmd"));
    assert(parsesAs("battle", "Battle"));
    assert(parsesAs(`ware "Iron caltrops" 12 -> has_caltrops: Scatter them.`, "Ware"));
    assert(parsesAs(`topic "What are you forging?": Arrowheads, mostly.`, "Topic"));
    assert(parsesAs("sprite 1", "Prop"));
    assert(parsesAs("home plaza wander 2", "Prop"));
    assert(parsesAs("disposition => (affection + respect + trust) / 3", "Derived"));
    assert(parsesAs("affection = 50 in 0..100", "Assign"));
    assert(parsesAs("elder.bond.trust += 5", "Assign"));
    assert(parsesAs("x = -y * (2 - z) % 3", "Assign"));
    assert(parsesAs("elder (worried): Ah, you came. Sit, child. # not a comment", "Say"));
    assert(parsesAs("bond: Bond", "Say"));
    assert(parsesAs("Morning mist lifts off the rice terraces.", "Narrate"));
    assert(parsesAs("(WASD to walk, E to talk.)", "Narrate"));
    assert(parsesAs(": lower-case narration", "Narrate"));
    assert(parsesAs("set met_elder # trailing comment", "SetStmt"));
    assert(parsesAs("for c in citizens:", "For"));
    assert(parsesAs("xs[0].health[\"food\"] -= 1", "Assign"));
    assert(parsesAs("append(xs, {\"name\": \"Cy\", hp: [1, 2,]})", "CallStmt"));
    assert(parsesAs("x = xs[i + 1].name", "Assign"));
}

@nogc nothrow unittest {
    // Typos are errors, not narration: lines starting with a lower-case word must parse as code.
    foreach (bad; [
        "sett met_elder", "set", "-> ", "x = ", "x == 3", "if a", "on dance -> x", "var x",
        "elder (worried: hi", "* ", "x = 1 +", "label :"
    ]) {
        ParseContext ctx;
        auto r = parseLine(ctx, bad);
        assert(!r.successful);
    }
}

@nogc nothrow unittest {
    // The condition of a choice is only split off when it is a whole expression to end of line.
    ParseContext ctx;
    auto r = parseLine(ctx, "* What if they come back?");
    assert(r.successful);
    const opt = &statementOf(r.tree);
    assert(opt.children.length == 1 && ruleName(opt.children[0]) == "Caption");
    auto c = parseLine(ctx, "* What if they come back?  if td_runs > 0");
    const o2 = &statementOf(c.tree);
    assert(o2.children.length == 2 && ruleName(o2.children[1]) == "OptCond");
    assert(o2.children[0].children[0].matches[0] == "What if they come back?");

    auto e = parseExpr(ctx, "a.b + max(1, 2) * -3");
    assert(e.successful && e.end == 20);
}

// Villagers manning towers. How much a crew helps is the story's business: before a battle (and
// for the planning view) the game asks the script
//
//   def crew_buff(npc, tower):          npc and tower are symbols (:elder, :arrow)
//       return {damage: 10, range: 5, cooldown: -5}     percent changes
//   def can_crew(npc):                  optional: false while injured, away, unwilling...
//   data crew_rules = {unmanned: {damage: -25}}         optional: a tower nobody mans
//   def on_injury(npc):                 optional: told after a battle who was hurt
//
// and writes the answers into the towers, so the tick itself never runs script. Headless
// Model: no SDL, @nogc nothrow.
module campaign.crews;

import story.program;
import story.state;
import story.value;
import story.vm : callFunction;
import td.catalog;
import td.defs;
import td.game;

enum string fnCrewBuff = "crew_buff", fnCanCrew = "can_crew", varCrewRules = "crew_rules", fnOnInjury = "on_injury";

/// Percent changes a crew (or the lack of one) makes to a tower.
struct CrewBuff {
    int damagePct, rangePct, cooldownPct;
}

/// Buffs are clamped to this range, so a script slip cannot break the simulation.
enum int minBuffPct = -90, maxBuffPct = 300;

private int clampPct(int v) @nogc nothrow pure @safe {
    return v < minBuffPct ? minBuffPct : (v > maxBuffPct ? maxBuffPct : v);
}

/// Reads {damage, range, cooldown} from a story map (missing keys are 0).
CrewBuff buffFrom(ref const StoryState st, const Value m) @nogc nothrow @trusted {
    CrewBuff b;
    int v;
    if (toIntExact(st.at(m, Value.constText("damage")), v))
        b.damagePct = clampPct(v);
    if (toIntExact(st.at(m, Value.constText("range")), v))
        b.rangePct = clampPct(v);
    if (toIntExact(st.at(m, Value.constText("cooldown")), v))
        b.cooldownPct = clampPct(v);
    return b;
}

/// What the story says villager `speaker` adds to a tower of `kind` (zero without `crew_buff`).
CrewBuff crewBuff(ref const StoryProgram p, ref StoryState st, ref const Catalog cat, int speaker, TowerKind kind) @nogc nothrow @trusted {
    immutable fn = p.findFunction(fnCrewBuff);
    if (fn < 0 || p.functions[fn].argc != 2 || speaker < 0 || speaker >= p.speakers.length || kind >= cat.numTowers)
        return CrewBuff.init;
    Value[2] args = [st.symbol(p.speakers[speaker].id), st.symbol(cat.towers[kind].id)];
    return buffFrom(st, callFunction(p, fn, args[], st));
}

/// What an unmanned tower suffers (`crew_rules.unmanned`).
CrewBuff unmannedBuff(ref const StoryState st) @nogc nothrow @trusted {
    return buffFrom(st, st.at(st.value(st.find(varCrewRules)), Value.constText("unmanned")));
}

/// Whether villager `speaker` may man a tower now (`can_crew`; true when the story has none).
bool canCrew(ref const StoryProgram p, ref StoryState st, int speaker) @nogc nothrow @trusted {
    if (speaker < 0 || speaker >= p.speakers.length)
        return false;
    immutable fn = p.findFunction(fnCanCrew);
    if (fn < 0 || p.functions[fn].argc != 1)
        return true;
    Value[1] args = [st.symbol(p.speakers[speaker].id)];
    return truthy(callFunction(p, fn, args[], st));
}

/// Tells the story who was hurt in `g` (`on_injury(npc)` once each); returns how many were.
int reportInjuries(ref const Game g, ref const StoryProgram p, ref StoryState st) @nogc nothrow @trusted {
    immutable fn = p.findFunction(fnOnInjury);
    foreach (crew; g.injuries)
        if (fn >= 0 && p.functions[fn].argc == 1 && crew < p.speakers.length) {
            Value[1] args = [st.symbol(p.speakers[crew].id)];
            callFunction(p, fn, args[], st);
        }
    st.collect();
    return cast(int)g.injuries.length;
}

/// Writes every tower's crew buff (or the unmanned penalty) into `g`. Crews that may no longer
/// serve are sent home first.
void applyCrews(ref Game g, ref const StoryProgram p, ref StoryState st) @nogc nothrow @trusted {
    immutable unmanned = unmannedBuff(st);
    foreach (i, ref t; g.towers) {
        if (!t.alive)
            continue;
        if (t.crew != noCrew && !canCrew(p, st, t.crew))
            g.setCrew(cast(int)i, noCrew);
        immutable b = g.towers[i].crew == noCrew ? unmanned : crewBuff(p, st, g.catalog, t.crew, t.kind);
        g.setCrewBuff(cast(int)i, b.damagePct, b.rangePct, b.cooldownPct);
    }
    // The calls built maps; nothing lives on an expression stack here.
    st.collect();
}

version (unittest) {
    import story.compile : compileText;
    import story.vm : initialize;
    import td.board : CellFlag;
    import wfc.grid_connector : MapRect;
}

@nogc nothrow @trusted unittest {
    // The story decides: a trusted archer helps an arrow tower most, an injured villager goes
    // home, and an empty tower pays the unmanned penalty.
    immutable text = `
character elder "Ba Lan":
    sprite 1
character smith "Chu Tu":
    sprite 3
var bonds = {elder: 80, smith: 20}
var injured = {smith: true}
data crew_rules = {unmanned: {damage: -25}}
def crew_buff(npc, tower):
    b = bonds[npc]
    d = floor((b - 30) / 2)
    if tower == :arrow:
        d += 5
    return {damage: d, range: floor(b / 20), cooldown: -floor(b / 10)}
def can_crew(npc):
    return not injured[npc]
`;
    StoryProgram p;
    StoryState st;
    assert(compileText(p, st, text) == StoryError.none);
    initialize(p, st);
    immutable elder = p.findSpeaker("elder"), smith = p.findSpeaker("smith");
    immutable b = crewBuff(p, st, defaultCatalog, elder, TowerKind.arrow);
    assert(b.damagePct == 30 && b.rangePct == 4 && b.cooldownPct == -8);
    assert(crewBuff(p, st, defaultCatalog, elder, TowerKind.cannon).damagePct == 25);
    assert(canCrew(p, st, elder) && !canCrew(p, st, smith) && !canCrew(p, st, 99));
    assert(unmannedBuff(st).damagePct == -25);

    Game g;
    auto bd = &g.boardForSetup();
    bd.allocate(MapRect(12, 5));
    foreach (row; 0 .. 5)
        foreach (col; 0 .. 12)
            bd.setCell(col, row, row == 2 ? cast(ubyte)(CellFlag.walk | CellFlag.road | (col == 0
                    ? CellFlag.source : 0) | (col == 11 ? CellFlag.sink : 0)) : CellFlag.buildable);
    bd.finish(1, false);
    g.begin(1);
    g.restoreTower(TowerKind.arrow, Stage.lv1, 3, 1, Targeting.first, 50, -1, cast(ubyte)elder);
    g.restoreTower(TowerKind.cannon, Stage.lv1, 5, 1, Targeting.first, 80, -1, cast(ubyte)smith);
    g.restoreTower(TowerKind.frost, Stage.lv1, 7, 1, Targeting.first, 70, -1, noCrew);
    applyCrews(g, p, st);
    assert(g.towerAt(3, 1).buffDamagePct == 30 && g.towerAt(3, 1).crew == elder);
    assert(g.towerAt(5, 1).crew == noCrew && g.towerAt(5, 1).buffDamagePct == -25);
    assert(g.towerAt(7, 1).buffDamagePct == -25);
}

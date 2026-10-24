// Integration: the week loop on the shipped story. A campaign starts on Monday at dawn, its day
// and slot scenes play, Saturday afternoon holds the clock until the battle is fought, and the
// campaign ends after its last Sunday night, the same way on every run.
module tests.test_campaign;

import campaign.calendar;
import campaign.campaign;
import campaign.crews;
import campaign.director;
import campaign.fort;
import core.stdc.stdio : printf;
import story.program;
import story.state;
import story.vm;
import td.bot;
import td.catalog;
import td.defs;
import td.game;
import tests.harness : Report;
import wfc.map_session;
import tests.test_dialogue : compileShippedStory;

/// Plays a scene to its end, taking the first choice; returns the lines shown.
private int playScene(ref const StoryProgram p, ref StoryState st, int entry) @nogc nothrow @trusted {
    StoryRunner r;
    StoryEvents ev;
    r.start(p, entry, st, ev);
    int lines = 0;
    foreach (_; 0 .. 64) {
        if (!r.active)
            break;
        lines++;
        if (r.choiceCount > 0)
            r.choose(0, st, ev);
        else
            r.advance(st, ev);
    }
    return lines;
}

void run(ref Report rep) @nogc nothrow @trusted {
    StoryProgram p;
    StoryState st;
    if (compileShippedStory(p, st) != StoryError.none) {
        rep.check(false, "campaign: story compiles");
        return;
    }
    ulong[2] hashes;
    foreach (pass; 0 .. 2) {
        st.reset(11);
        initialize(p, st);
        Campaign c;
        c.setup(&p, &st);
        c.begin();
        int scenes = 0, battles = 0, directors = 0, lines = 0;
        bool held = true;
        foreach (step; 0 .. 2000) {
            int entry;
            while (c.popScene(entry)) {
                scenes++;
                lines += playScene(p, st, entry);
            }
            if (c.directorDue) {
                directors++;
                held &= c.cal.day == Day.wed && c.cal.slot == Slot.night;
                c.directorDue = false;
            }
            if (c.battleDue) {
                battles++;
                held &= c.cal.day == Day.sat && c.cal.slot == Slot.afternoon && c.spend(3) == 0;
                c.battleOver();
            }
            if (c.over)
                break;
            c.act("rest");
        }
        rep.check(c.over && c.cal.week == c.weeks && c.cal.day == Day.sun && c.cal.slot == Slot.night,
                "campaign runs to its last Sunday night");
        rep.check(battles == c.weeks && directors == c.weeks && held,
                "a director beat on Wednesday night and a battle on Saturday afternoon each week");
        rep.check(scenes >= 2 * c.weeks && lines >= scenes && c.droppedScenes == 0, "day and slot scenes play");
        hashes[pass] = st.hash() ^ c.hash();
        if (pass == 0)
            printf("  campaign: %d weeks, %d scenes, %d lines\n", c.weeks, scenes, lines);
    }
    rep.check(hashes[0] == hashes[1], "campaign replays exactly");
    runBattlefield(p, st, rep);
}

/// Three weeks on one persistent battlefield: a midweek visit where the bot builds and every
/// villager takes a post, then Saturday's battle on what stands there, saved back each time.
private void runBattlefield(ref const StoryProgram p, ref StoryState st, ref Report rep) @nogc nothrow @trusted {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams gp;
    gp.cols = 64;
    gp.rows = 36;
    gp.radius = 6;
    gp.seed = 5;
    gp.reveal.enabled = false;
    if (!s.regenerate(gp).isOk) {
        rep.check(false, "battlefield map generates");
        return;
    }
    // A crew buff from the shipped rules: the guard, an archer, helps an arrow tower.
    st.reset(3);
    initialize(p, st);
    immutable guard = p.findSpeaker("guard"), child = p.findSpeaker("child");
    immutable gb = crewBuff(p, st, defaultCatalog, guard, TowerKind.arrow);
    immutable cb = crewBuff(p, st, defaultCatalog, child, TowerKind.cannon);
    rep.check(gb.damagePct > cb.damagePct && gb.cooldownPct < 0 && unmannedBuff(st).damagePct < 0,
            "crew buffs follow bonds and knacks");

    ulong[2] hashes;
    int[2] towersAfter;
    bool persisted = true, harder = true, crewed = true, benched = true, overkill = true;
    int hits = 0, hurt = 0, held = 0;
    static Director director;
    foreach (pass; 0 .. 2) {
        st.reset(3);
        initialize(p, st);
        static Fort fort;
        fort.begin(defaultCatalog);
        int lastHp = 0;
        foreach (week; 0 .. 3) {
            // Midweek: build and post crews.
            Game plan;
            plan.start(*s, gp.seed);
            fort.restore(plan);
            persisted &= plan.towers.length == fort.numTowers;
            plan.startPlanning();
            // One earthwork a week, before the gold goes on towers: raise the first open ground that takes it.
            dug: foreach (row; 0 .. plan.board.rect.rows)
                foreach (col; 0 .. plan.board.rect.cols)
                    if (plan.apply(GameCommand(CommandType.terraform, TowerKind.arrow, 0, col,
                            row)) == CommandError.none)
                        break dug;
            Bot bot;
            bot.setup(plan);
            foreach (k; 0 .. 40)
                bot.act(plan);
            int post = 0;
            foreach (i, ref t; plan.towers)
                if (t.alive && plan.catalog.fights(t.kind) && post < p.npcs.length)
                    plan.apply(GameCommand(CommandType.assignCrew, t.kind,
                            cast(ubyte)p.npcs[post++].speaker, t.col, t.row));
            applyCrews(plan, p, st);
            fort.save(plan);
            RunModifiers mods;
            mods.waveOffset = fort.battles * defaultWavesPerBattle;
            mods.waves = defaultWavesPerBattle;
            immutable seed = gp.seed + week;
            // Wednesday night: the director plans 5% past what this defense can hold.
            CrewSnapshot crews;
            crews.capture(plan);
            director.start(s, &fort, &defaultCatalog, crews, mods, seed);
            const attack = &director.run();
            overkill &= attack.budgetPct > attack.capacityPct && attack.budgetPct * 100 >= attack.capacityPct * 105;
            attack.applyTo(mods);
            // Left as it stood on Wednesday, the defense falls on Saturday.
            {
                Game still;
                still.start(*s, seed, mods);
                fort.restore(still);
                applyCrews(still, p, st);
                foreach (t; 0 .. 200_000) {
                    if (still.status == GameStatus.waiting)
                        still.apply(GameCommand(CommandType.startWave));
                    still.advance();
                    if (still.status == GameStatus.lost || still.status == GameStatus.won)
                        break;
                }
                overkill &= still.status == GameStatus.lost;
                if (pass == 0)
                    printf("  week %d: the defense holds %d%%, Saturday brings %d%% (%d probes)\n",
                            week + 1, attack.capacityPct, attack.budgetPct, attack.probes);
            }
            // Saturday, with the bot playing.
            Game battle;
            battle.start(*s, seed, mods);
            fort.restore(battle);
            persisted &= battle.edits.length == fort.numEdits && fort.numEdits == week + 1;
            applyCrews(battle, p, st);
            int manned = 0;
            foreach (ref t; battle.towers)
                manned += t.alive && t.crew != noCrew && t.buffDamagePct != 0;
            crewed &= manned > 0;
            Bot b2;
            b2.setup(battle);
            foreach (t; 0 .. 200_000) {
                b2.act(battle);
                battle.advance();
                foreach (ref e; battle.events)
                    hits += pass == 0 && e.kind == EventKind.towerHit;
                if (battle.status == GameStatus.lost || battle.status == GameStatus.won)
                    break;
            }
            // The story hears who was hurt; they sit out the next week.
            st.set(st.find("week"), week + 1);
            immutable n = reportInjuries(battle, p, st);
            if (pass == 0)
                hurt += n;
            foreach (crew; battle.injuries)
                benched &= !canCrew(p, st, crew);
            // Later Saturdays bring tougher creeps.
            immutable hp = battle.catalog.scaledHp(CreepKind.grunt, 1 + mods.waveOffset);
            harder &= hp > lastHp;
            lastHp = hp;
            if (pass == 0)
                held += battle.status == GameStatus.won;
            fort.save(battle);
            fort.battles++;
        }
        hashes[pass] = fort.hash();
        towersAfter[pass] = fort.numTowers;
    }
    rep.check(persisted && towersAfter[0] > 4, "towers persist across visits and battles");
    rep.check(crewed, "villagers man towers in battle");
    rep.check(harder, "each Saturday continues the waves");
    rep.check(hits > 0 && benched, "siege creeps strike towers; hurt crews sit out");
    rep.check(overkill, "Wednesday's plan overkills the standing defense by 5%");
    rep.check(hashes[0] == hashes[1], "battlefield campaign replays exactly");
    printf("  battlefield: %d towers after 3 weeks, %d siege hits, %d crews hurt, %d of 3 Saturdays held\n",
            towersAfter[0], hits, hurt, held);
}

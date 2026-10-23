// Integration: whole tower defense games on generated maps, played headlessly by the bot. Checks
// that games end, replay identically tick for tick, stay inside their pools, that an undefended
// map is lost and that the bot holds the early waves.
module tests.test_td_sim;

import core.stdc.stdio : printf;
import td.bot;
import td.defs;
import td.game;
import tests.harness : Report;
import wfc.map_session;

/// Generous cap: 30 waves of building time plus long waves.
enum uint tickCap = 250_000;

void run(ref Report rep, int seeds) @nogc nothrow @trusted {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    int games = 0, ended = 0, replayed = 0, wavesSum = 0, held = 0, won = 0;
    size_t dropped = 0;
    bool undefendedLost = true;
    foreach (layout; 0 .. 2)
        foreach (seed; 1 .. seeds + 1) {
            GenParams p;
            p.layout = layout == 0 ? Layout.rect : Layout.island;
            p.cols = 72;
            p.rows = 40;
            p.radius = 6;
            p.rings = 2;
            p.seed = cast(uint)seed;
            p.routes.place.sources = 1 + seed % 3;
            p.routes.place.sinks = 1 + seed % 2;
            if (!s.regenerate(p).isOk || !s.routeReport.ok)
                continue;
            games++;
            Game a, b;
            a.start(*s, seed * 31);
            b.start(*s, seed * 31);
            Bot ba, bb;
            ba.setup(a);
            bb.setup(b);
            bool same = true;
            foreach (t; 0 .. tickCap) {
                ba.act(a);
                bb.act(b);
                a.advance();
                b.advance();
                same &= a.stateHash() == b.stateHash();
                dropped += a.droppedEvents;
                if (a.status == GameStatus.lost || a.status == GameStatus.won)
                    break;
            }
            ended += a.status == GameStatus.lost || a.status == GameStatus.won;
            replayed += same;
            wavesSum += a.waveNo;
            held += a.waveNo >= 5;
            won += a.status == GameStatus.won;

            // Nobody building: the creeps walk in until the lives run out.
            Game idle;
            idle.start(*s, seed * 31);
            foreach (t; 0 .. tickCap) {
                idle.advance();
                if (idle.status == GameStatus.lost)
                    break;
            }
            undefendedLost &= idle.status == GameStatus.lost && idle.killed == 0;
        }
    printf("  td: %d games, %d ended, %d replayed exactly, %.1f waves avg, %d won, %d held 5+ waves\n",
            games, ended, replayed, games ? wavesSum * 1.0 / games : 0.0, won, held);
    rep.check(games == 2 * seeds, "every td map generates");
    rep.check(ended == games, "every bot game ends (won or lost) within the tick cap");
    rep.check(replayed == games, "games replay identically from seed and commands");
    rep.check(held == games, "the bot holds at least 5 waves on every map");
    rep.check(games > 0 && wavesSum >= 10 * games, "the bot averages at least 10 waves");
    rep.check(undefendedLost, "an undefended game is lost");
    rep.check(dropped == 0, "no tick overflows the event list");
}

/// Reveal campaigns: maps uncovered in stages. Every stage must be playable (creeps enter inside
/// the window, far from the sinks; stage 0 has one sink with entries on its far side), creeps
/// never leave the window, the board grows only between waves, and games replay exactly.
void runReveal(ref Report rep, int seeds) @nogc nothrow @trusted {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    int maps = 0, playable = 0, games = 0, replayed = 0, stagesSeen = 0, stagesTotal = 0;
    bool entriesOk = true, inWindow = true, revealBetweenWaves = true, firstOk = true;
    foreach (seed; 1 .. seeds + 1) {
        GenParams p;
        p.cols = 96;
        p.rows = 54;
        p.radius = 6;
        p.seed = cast(uint)seed;
        p.routes.place.sources = 1 + seed % 2;
        p.routes.place.sinks = 1 + (seed / 2) % 2;
        p.reveal.enabled = true;
        p.reveal.wavesPerStage = 4;
        if (!s.regenerate(p).isOk)
            continue;
        maps++;
        if (!s.routeReport.ok || !s.revealPlayable)
            continue;
        playable++;
        Game a, b;
        a.start(*s, seed * 17);
        b.start(*s, seed * 17);
        games++;
        // Stage 0: one sink at the back, every entry in the front third of the window.
        const b0 = &a.board();
        firstOk &= b0.numSinks == 1 && b0.numSources >= 1;
        foreach (k; 0 .. b0.numSources)
            firstOk &= b0.plan.fromFront(b0.window, b0.sources[k]) <= b0.plan.depth(b0.window) / 3;
        Bot ba, bb;
        ba.setup(a);
        bb.setup(b);
        bool same = true;
        int lastStage = -1;
        foreach (t; 0 .. tickCap) {
            ba.act(a);
            bb.act(b);
            a.advance();
            b.advance();
            same &= a.stateHash() == b.stateHash();
            const brd = &a.board();
            if (brd.stage != lastStage) {
                lastStage = brd.stage;
                stagesSeen++;
                revealBetweenWaves &= a.status != GameStatus.wave && a.creepsAlive == 0;
                foreach (k; 0 .. brd.numSources) {
                    entriesOk &= brd.window.contains(brd.sources[k]);
                    entriesOk &= brd.distAt(brd.rect.index(brd.sources[k])) >= p.reveal.minDefensePath;
                }
                entriesOk &= brd.numSources >= 1;
            }
            foreach (ref c; a.creeps)
                if (c.alive && !brd.visible(c.cell))
                    inWindow = false;
            if (a.status == GameStatus.lost || a.status == GameStatus.won)
                break;
        }
        // Stages the waves cleared should have uncovered (a game is lost mid-wave).
        immutable cleared = a.status == GameStatus.lost ? a.waveNo - 1 : a.waveNo;
        immutable expect = 1 + cleared / p.reveal.wavesPerStage;
        stagesTotal += expect < a.board.numStages ? expect : a.board.numStages;
        replayed += same;
    }
    printf("  reveal: %d maps, %d playable, %d games, %d stages reached, %d replayed exactly\n",
            maps, playable, games, stagesSeen, replayed);
    rep.check(maps == seeds, "every reveal map generates");
    rep.check(playable == maps, "every reveal map passes the stage checks");
    rep.check(firstOk, "stage 0 holds one sink, entered from its far side");
    rep.check(entriesOk, "every stage's entries are visible and far enough from the sinks");
    rep.check(inWindow, "creeps never walk outside the visible window");
    rep.check(revealBetweenWaves, "the map grows only between waves");
    rep.check(stagesSeen == stagesTotal, "each cleared stage reveals the next");
    rep.check(replayed == games, "reveal games replay identically");
}

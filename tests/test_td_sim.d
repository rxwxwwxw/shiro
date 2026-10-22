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

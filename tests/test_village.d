// Integration: generated villages are walkable (gate, plaza and every landmark connected), and a
// scripted playthrough of the shipped story works end to end: talk to the elder, the priestess
// and the smith, leave by the west gate, play the tower defense run the story earned with the
// bot, come home and hear about it. The village part replays identically.
module tests.test_village;

import core.file;
import core.stdc.stdio : printf;
import story.dialogue;
import story.state;
import story.td_link;
import td.bot;
import td.defs : TowerKind;
import td.game;
import tests.harness : Report;
import tests.test_dialogue : storyPath;
import village.bot;
import village.plan;
import village.walk;
import village.world;
import wfc.hex;
import wfc.map_session;

private enum int tickBudget = 20_000;
private enum uint tdTickCap = 250_000;

/// Plays the line on screen to its end, always taking the first visible choice.
private void finishTalk(ref VillageWorld w) @nogc nothrow @trusted {
    foreach (_; 0 .. 64) {
        if (!w.talking)
            return;
        w.apply(w.talk.choiceCount > 0 ? VillageCommand(VillageCmd.choose, 0, 0, 0) : VillageCommand(VillageCmd.advance));
    }
}

/// Walks to the villager speaking as `speaker` and talks the conversation through; false if the
/// player never got there or nobody answered.
private bool talkTo(ref VillageWorld w, ref const WalkGrid walk, ref VillageBot bot, ref const DialogueDb db,
        const(char)[] speaker, ref int ticks) @nogc nothrow @trusted {
    int npc = -1;
    foreach (i, ref n; w.npcs)
        if (db.speakers[n.speaker].id == speaker)
            npc = cast(int)i;
    if (npc < 0)
        return false;
    while (ticks++ < tickBudget) {
        if (w.talking) {
            // A zone scene on the way (the temple steps): see it through and keep walking.
            finishTalk(w);
            continue;
        }
        if (w.npcInReach() == npc) {
            w.apply(VillageCommand(VillageCmd.move, 0, 0));
            w.apply(VillageCommand(VillageCmd.interact));
            immutable answered = w.talking && w.talkNpc == npc;
            finishTalk(w);
            return answered;
        }
        const n = &w.npcs[npc];
        bot.aim(walk, worldCell(n.body.x, n.body.y));
        w.clearEvents();
        w.apply(bot.steer(w, walk));
        w.step();
    }
    return false;
}

/// Walks out of the west gate; true on the leaveWest event.
private bool leaveWest(ref VillageWorld w, ref const WalkGrid walk, ref VillageBot bot, ref int ticks) @nogc nothrow @trusted {
    bot.walkTo(w, walk, offsetToCube(0, w.plan.gateRow), tickBudget);
    while (ticks++ < tickBudget) {
        finishTalk(w);
        w.clearEvents();
        w.apply(VillageCommand(VillageCmd.move, -1, 0));
        w.step();
        foreach (e; w.events)
            if (e.kind == VillageEventKind.leaveWest)
                return true;
    }
    return false;
}

void run(ref Report rep, int seeds) @nogc nothrow @trusted {
    FileBytes f;
    if (f.load(storyPath) != 0) {
        rep.check(false, "village: story file readable");
        return;
    }
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    int built = 0, played = 0, replayed = 0, gateHeld = 0, earned = 0, tdDone = 0, homecoming = 0;
    foreach (seed; 1 .. seeds + 1) {
        VillagePlan plan;
        WalkGrid walk;
        if (buildVillage(s, seed, plan, walk).isErr)
            continue;
        built++;

        ulong[2] hashes;
        RunModifiers mods;
        StoryState st;
        DialogueDb db;
        foreach (pass; 0 .. 2) {
            st = StoryState.init;
            internLinkVars(st);
            if (db.load(f.text, st) != StoryError.none)
                break;
            VillageWorld w;
            w.setup(&plan, &walk, &db, &st, seed * 7);
            if (w.loadNpcs(f.text) != 5)
                break;
            w.begin();
            immutable intro = w.talking;
            finishTalk(w);
            VillageBot bot;
            int ticks = 0;
            // The guard keeps the gate shut until the elder agrees.
            bot.walkTo(w, walk, offsetToCube(0, plan.gateRow), tickBudget);
            bool locked;
            foreach (_; 0 .. 120) {
                w.clearEvents();
                w.apply(VillageCommand(VillageCmd.move, -1, 0));
                w.step();
                foreach (e; w.events)
                    locked |= e.kind == VillageEventKind.gateLocked;
                if (locked)
                    break;
            }
            finishTalk(w);
            immutable ok = intro && locked && talkTo(w, walk, bot, db, "elder", ticks)
                && st.named(varGateOpen) == 1 && talkTo(w, walk, bot, db, "priestess", ticks)
                && talkTo(w, walk, bot, db, "smith", ticks) && talkTo(w, walk, bot, db, "child",
                        ticks) && leaveWest(w, walk, bot, ticks);
            if (pass == 0) {
                gateHeld += locked;
                played += ok;
            }
            hashes[pass] = w.hash();
            mods = fromStory(st);
        }
        replayed += hashes[0] == hashes[1];
        // First choices everywhere: the serpent's lightning and the fire pots.
        earned += !(mods.lockedKinds & (1 << TowerKind.tesla)) && !(mods.lockedKinds & (1 << TowerKind.flame));

        // One tower defense run per test pass, on a quick map, then home again.
        if (seed != 1)
            continue;
        auto td = MapSession.create().value;
        scope (exit)
            MapSession.release(td);
        GenParams p;
        p.cols = 64;
        p.rows = 36;
        p.radius = 6;
        p.seed = seed;
        p.reveal.enabled = false;
        if (!td.regenerate(p).isOk)
            continue;
        Game g;
        g.start(*td, seed, mods);
        Bot b;
        b.setup(g);
        foreach (t; 0 .. tdTickCap) {
            b.act(g);
            g.advance();
            if (g.status == GameStatus.lost || g.status == GameStatus.won)
                break;
        }
        immutable won = g.status == GameStatus.won;
        tdDone += won || g.status == GameStatus.lost;
        recordRun(st, won, g.waveNo);
        VillageWorld home;
        home.setup(&plan, &walk, &db, &st, seed * 7);
        home.loadNpcs(f.text);
        home.arriveFromTd(won);
        immutable scene = home.talking && home.talk.line.id == (won ? "return_won" : "return_lost");
        finishTalk(home);
        VillageBot bot;
        int ticks = 0;
        // The elder's line now depends on how the run went.
        bool reacted;
        if (talkTo(home, walk, bot, db, "elder", ticks))
            reacted = st.named("elder_heard") == 1;
        homecoming += scene && reacted;
        printf("  td run on the story's modifiers: %s after %d waves (+%d gold, locked mask %d)\n",
                won ? "won".ptr : "lost".ptr, g.waveNo, mods.bonusGold, mods.lockedKinds);
    }
    printf("  village: %d/%d built, %d played through, %d replayed exactly, %d gate held, %d earned unlocks\n",
            built, seeds, played, replayed, gateHeld, earned);
    rep.check(built == seeds, "village: every seed builds a walkable village");
    rep.check(played == built, "village: scripted playthrough reaches the west gate");
    rep.check(gateHeld == built, "village: gate stays shut until the elder agrees");
    rep.check(replayed == built, "village: playthrough replays exactly");
    rep.check(earned == built, "village: story choices unlock tower kinds");
    rep.check(tdDone == 1, "village: tower defense run on story modifiers ends");
    rep.check(homecoming == 1, "village: homecoming scene and elder reaction");
}

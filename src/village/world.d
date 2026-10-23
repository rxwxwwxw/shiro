// The village simulation: the player walking on the walk grid, villagers wandering near their
// homes, conversations driven by story triggers, landmark zones, and the west gate exit. Runs a
// fixed tick (td.defs.ticksPerSecond) on integer world units (td.defs: halfHex / rowUnits), so
// a seed plus the ordered command stream always replays the same. Model layer: no SDL.
module village.world;

import core.json;
import core.random : Random;
import story.dialogue;
import story.events : TriggerKind;
import story.script : StoryEvents;
import story.state;
import story.td_link : varGateOpen;
import village.interior;
import td.defs : cellUnits, cellWorld, halfHex, rowUnits;
import village.plan;
import village.walk;
import wfc.hex;
import wfc.placement : isqrt;

enum int maxNpcs = 12;
/// World units per tick: the player covers about three cells a second, villagers about one.
enum int playerSpeed = 110;
enum int npcSpeed = 36;
/// How close (world units) the player must be to talk to someone.
enum int talkReach = cellUnits * 3 / 2;

/// Nearest cell center to a world position.
CubeCoord worldCell(int x, int y) @nogc nothrow pure @safe {
    immutable r0 = (y >= 0 ? y : y - rowUnits + 1) / rowUnits;
    CubeCoord best;
    long bd = long.max;
    foreach (row; r0 - 1 .. r0 + 3) {
        immutable shifted = x / halfHex - (row & 1);
        foreach (col; (shifted >= 0 ? shifted : shifted - 1) / 2 - 1 .. shifted / 2 + 2) {
            int cx, cy;
            cellWorld(col, row, cx, cy);
            immutable long d = cast(long)(cx - x) * (cx - x) + cast(long)(cy - y) * (cy - y);
            if (d < bd) {
                bd = d;
                best = offsetToCube(col, row);
            }
        }
    }
    return best;
}

@nogc nothrow pure @safe unittest {
    foreach (row; 0 .. 6)
        foreach (col; 0 .. 6) {
            int x, y;
            cellWorld(col, row, x, y);
            assert(worldCell(x, y) == offsetToCube(col, row));
            assert(worldCell(x + halfHex - 40, y) == offsetToCube(col, row));
            assert(worldCell(x + halfHex + 40, y) == offsetToCube(col + 1, row));
        }
    assert(cubeToOffset(worldCell(-3 * halfHex, 0)).col < 0);
}

enum VillageCmd : ubyte {
    /// Held movement: dx, dy in -1..1 until the next move command.
    move,
    /// Talk to whoever is in reach, or continue the line on screen.
    interact,
    /// Continue the line on screen (does nothing while choices wait).
    advance,
    /// Pick visible choice `arg`.
    choose,
    /// Close the conversation.
    cancel,
    /// Step into the building whose zone the player stands in.
    enter,
    /// Step back out of the building.
    leave,
    /// Talk to whoever keeps the building.
    talkHost,
    /// Buy ware `arg` of the building.
    buy
}

struct VillageCommand {
    VillageCmd kind;
    byte dx, dy;
    ubyte arg;
}

/// Fixed ring of pending commands (full: newest dropped).
struct VillageQueue {
    private VillageCommand[32] items;
    private int head, count;

    bool push(VillageCommand c) @nogc nothrow pure @safe {
        if (count == items.length)
            return false;
        items[(head + count++) % items.length] = c;
        return true;
    }

    bool pop(out VillageCommand c) @nogc nothrow pure @safe {
        if (count == 0)
            return false;
        c = items[head];
        head = (head + 1) % cast(int)items.length;
        count--;
        return true;
    }
}

enum VillageEventKind : ubyte {
    /// A conversation opened (arg: NPC index, or -1 for a zone or story scene).
    talkStart,
    /// The conversation closed.
    talkEnd,
    /// The player walked into a landmark zone (arg: Landmark).
    enterZone,
    /// The player walked out of the west gate with the gate open: start tower defense.
    leaveWest,
    /// The player tried the west gate while it is shut.
    gateLocked,
    /// The player stepped into a building (arg: Landmark).
    enterBuilding,
    /// The player stepped back out (arg: Landmark).
    leaveBuilding
}

struct VillageEvent {
    VillageEventKind kind;
    short arg;
}

/// Something that walks: position in world units and the last movement for facing.
struct Walker {
    int x, y;
    /// Position at the start of the last tick (View: interpolation).
    int px, py;
    /// Last nonzero motion (View: sprite facing); a unit-free direction.
    int faceX = 1, faceY;
    bool moving;
}

struct Npc {
    Walker body;
    /// Index into the story's speakers (the NPC's id and art).
    int speaker;
    CubeCoord home;
    int wander;
    private int targetX, targetY;
    private int wait;
    private bool going;
}

struct VillageWorld {
    private const(VillagePlan)* plan_;
    private const(WalkGrid)* walk_;
    private const(DialogueDb)* db_;
    private StoryState* story_;
    Walker player;
    private Npc[maxNpcs] npcs_;
    private int numNpcs_;
    private DialogueRunner talk_;
    /// NPC in the conversation, or -1.
    private int talkNpc_ = -1;
    private int moveX, moveY;
    /// Landmark zone the player stands in, or -1.
    private int zone_ = -1;
    private const(Interiors)* interiors_;
    /// Landmark whose building the player is inside, or -1.
    private int inside_ = -1;
    private BuyResult lastBuy_;
    private Random rng;
    private uint tick_;
    private VillageEvent[16] events_;
    private int numEvents_;
    /// Story events raised by effects this tick (see story.script).
    StoryEvents storyEvents;

    @disable this(this);

    /// Places the player inside the gate and the villagers at home. Every pointer must outlive
    /// the world.
    void setup(const(VillagePlan)* plan, const(WalkGrid)* walk, const(DialogueDb)* db, StoryState* story, uint seed) @nogc nothrow @trusted {
        plan_ = plan;
        walk_ = walk;
        db_ = db;
        story_ = story;
        rng = Random(seed ^ 0x51A6E5u);
        tick_ = 0;
        numNpcs_ = 0;
        talk_.stop();
        talkNpc_ = -1;
        moveX = moveY = 0;
        numEvents_ = 0;
        storyEvents.clear();
        inside_ = -1;
        lastBuy_ = BuyResult.none;
        placePlayerAtGate();
    }

    /// Building interiors (optional; must outlive the world). Without them nothing can be entered.
    void setInteriors(const(Interiors)* ins) @nogc nothrow @safe {
        interiors_ = ins;
    }

    /// Adds a villager living at landmark `home`; false when full or the speaker is unknown.
    bool addNpc(int speaker, Landmark home, int wander) @nogc nothrow @trusted {
        if (numNpcs_ == maxNpcs || speaker < 0 || speaker >= db_.speakers.length)
            return false;
        Npc n;
        n.speaker = speaker;
        n.home = plan_.spot[home];
        n.wander = wander < 0 ? 0 : wander;
        cellWorld(n.home, n.body.x, n.body.y);
        n.body.px = n.body.x;
        n.body.py = n.body.y;
        n.wait = 30 + cast(int)rng.below(90);
        npcs_[numNpcs_++] = n;
        return true;
    }

    /// Reads the "npcs" list of the story file: [{"speaker": "elder", "home": "plaza", "wander": 2}].
    /// Returns the number added, or -1 on an unknown speaker or landmark.
    int loadNpcs(const(char)[] storyJson) @nogc nothrow @trusted {
        Json j;
        if (!j.parse(storyJson))
            return -1;
        immutable list = j.get(0, "npcs");
        int added = 0;
        foreach (i; 0 .. j.length(list)) {
            immutable o = j.at(list, i);
            immutable sp = db_.findSpeaker(j.str(j.get(o, "speaker")));
            immutable home = landmarkByName(j.str(j.get(o, "home")));
            if (sp < 0 || home < 0 || !addNpc(sp, cast(Landmark)home, j.integer(j.get(o, "wander"), 1)))
                return -1;
            added++;
        }
        return added;
    }

    /// Fires the story's start triggers (call once per playthrough, after the NPCs are in).
    void begin() @nogc nothrow @trusted {
        numEvents_ = 0;
        int node;
        if (db_.trigger(TriggerKind.start, null, *story_, storyEvents, node) >= 0)
            openTalk(node, -1);
        zone_ = zoneAt(worldCell(player.x, player.y));
    }

    /// Back from tower defense: the player stands inside the gate again, and the story hears how
    /// it went (record the run with story.td_link.recordRun first).
    void arriveFromTd(bool won) @nogc nothrow @trusted {
        numEvents_ = 0;
        talk_.stop();
        talkNpc_ = -1;
        moveX = moveY = 0;
        inside_ = -1;
        placePlayerAtGate();
        int node;
        if (db_.trigger(TriggerKind.returned, won ? "won" : "lost", *story_, storyEvents, node) >= 0)
            openTalk(node, -1);
        zone_ = zoneAt(worldCell(player.x, player.y));
    }

    /// Puts the player beside villager `speakerId` and opens the talk trigger, as if they had
    /// walked there (for screenshots and scripted scenes); false if nobody answers.
    bool talkNow(const(char)[] speakerId) @nogc nothrow @trusted {
        foreach (i, ref n; npcs_[0 .. numNpcs_]) {
            if (db_.speakers[n.speaker].id != speakerId)
                continue;
            talk_.stop();
            talkNpc_ = -1;
            player.x = player.px = n.body.x - halfHex;
            player.y = player.py = n.body.y;
            apply(VillageCommand(VillageCmd.interact));
            return talk_.active;
        }
        return false;
    }

    // ---- read-only views ----

    const(Npc)[] npcs() const return @nogc nothrow @trusted {
        return npcs_[0 .. numNpcs_];
    }

    ref const(DialogueRunner) talk() const return @nogc nothrow pure @safe {
        return talk_;
    }

    bool talking() const @nogc nothrow pure @safe {
        return talk_.active;
    }

    /// NPC in the current conversation, or -1.
    int talkNpc() const @nogc nothrow pure @safe {
        return talkNpc_;
    }

    const(VillageEvent)[] events() const return @nogc nothrow @trusted {
        return events_[0 .. numEvents_];
    }

    uint tick() const @nogc nothrow pure @safe {
        return tick_;
    }

    int zone() const @nogc nothrow pure @safe {
        return zone_;
    }

    /// Landmark whose building the player is inside, or -1.
    int inside() const @nogc nothrow pure @safe {
        return inside_;
    }

    /// The interior the player is in, or null.
    const(Interior)* interior() const return @nogc nothrow pure @safe {
        return interiors_ is null ? null : interiors_.of(inside_);
    }

    /// The building whose door the player stands at (a Landmark), or -1.
    int doorInReach() const @nogc nothrow pure @safe {
        return inside_ < 0 && interiors_ !is null && interiors_.of(zone_) !is null ? zone_ : -1;
    }

    /// Outcome of the last purchase (cleared on entering a building).
    BuyResult lastBuy() const @nogc nothrow pure @safe {
        return lastBuy_;
    }

    /// Whether the player has bought `w`.
    bool owns(ref const Ware w) const @nogc nothrow @safe {
        return w.flag >= 0 && story_.flag(w.flag);
    }

    /// The player's money.
    int coins() const @nogc nothrow @safe {
        return interiors_ is null || interiors_.coinsVar < 0 ? 0 : story_.get(interiors_.coinsVar);
    }

    /// Puts the player in front of landmark `name` and steps inside (screenshots, scripted
    /// scenes); false when it has no interior.
    bool enterNow(const(char)[] name) @nogc nothrow @trusted {
        immutable l = landmarkByName(name);
        if (l < 0 || interiors_ is null || interiors_.of(l) is null)
            return false;
        talk_.stop();
        talkNpc_ = -1;
        cellWorld(plan_.spot[l], player.x, player.y);
        player.px = player.x;
        player.py = player.y;
        zone_ = l;
        apply(VillageCommand(VillageCmd.enter));
        return inside_ == l;
    }

    ref const(VillagePlan) plan() const return @nogc nothrow pure @trusted {
        return *plan_;
    }

    /// The NPC the player would talk to now, or -1.
    int npcInReach() const @nogc nothrow @trusted {
        int best = -1;
        long bd = cast(long)talkReach * talkReach;
        foreach (i, ref n; npcs_[0 .. numNpcs_]) {
            immutable dx = cast(long)(n.body.x - player.x), dy = cast(long)(n.body.y - player.y);
            if (dx * dx + dy * dy <= bd) {
                bd = dx * dx + dy * dy;
                best = cast(int)i;
            }
        }
        return best;
    }

    // ---- commands and ticks ----

    /// Applies one command at once (before the next `step`); its events land in `events`.
    void apply(const VillageCommand c) @nogc nothrow @trusted {
        final switch (c.kind) {
        case VillageCmd.move:
            moveX = c.dx < 0 ? -1 : (c.dx > 0 ? 1 : 0);
            moveY = c.dy < 0 ? -1 : (c.dy > 0 ? 1 : 0);
            break;
        case VillageCmd.interact:
            if (talk_.active) {
                talk_.advance(*story_, storyEvents);
                endTalkIfDone();
            } else if (inside_ >= 0) {
                apply(VillageCommand(VillageCmd.talkHost));
            } else if (doorInReach() >= 0) {
                apply(VillageCommand(VillageCmd.enter));
            } else {
                immutable n = npcInReach();
                if (n < 0)
                    break;
                int node;
                if (db_.trigger(TriggerKind.talk, db_.speakers[npcs_[n].speaker].id, *story_,
                        storyEvents, node) >= 0 && node >= 0) {
                    openTalk(node, n);
                    // Speakers turn to each other.
                    npcs_[n].body.faceX = player.x - npcs_[n].body.x;
                    npcs_[n].body.faceY = player.y - npcs_[n].body.y;
                    player.faceX = -npcs_[n].body.faceX;
                    player.faceY = -npcs_[n].body.faceY;
                }
            }
            break;
        case VillageCmd.advance:
            if (talk_.active) {
                talk_.advance(*story_, storyEvents);
                endTalkIfDone();
            }
            break;
        case VillageCmd.choose:
            if (talk_.active) {
                talk_.choose(c.arg, *story_, storyEvents);
                endTalkIfDone();
            }
            break;
        case VillageCmd.cancel:
            if (talk_.active) {
                talk_.stop();
                endTalkIfDone();
            }
            break;
        case VillageCmd.enter: {
                immutable d = doorInReach();
                if (talk_.active || d < 0)
                    break;
                inside_ = d;
                lastBuy_ = BuyResult.none;
                moveX = moveY = 0;
                push(VillageEventKind.enterBuilding, d);
                break;
            }
        case VillageCmd.leave:
            if (talk_.active || inside_ < 0)
                break;
            push(VillageEventKind.leaveBuilding, inside_);
            inside_ = -1;
            break;
        case VillageCmd.talkHost: {
                const it = interior();
                if (talk_.active || it is null || it.host < 0)
                    break;
                int node;
                if (db_.trigger(TriggerKind.talk, db_.speakers[it.host].id, *story_, storyEvents, node) < 0 || node < 0)
                    break;
                int npc = -1;
                foreach (i, ref n; npcs_[0 .. numNpcs_])
                    if (n.speaker == it.host)
                        npc = cast(int)i;
                openTalk(node, npc);
                break;
            }
        case VillageCmd.buy:
            if (!talk_.active && inside_ >= 0)
                lastBuy_ = interiors_.buy(inside_, c.arg, *story_);
            break;
        }
    }

    /// Clears last tick's events (call before applying the frame's commands).
    void clearEvents() @nogc nothrow pure @safe {
        numEvents_ = 0;
        storyEvents.clear();
    }

    /// One tick: movement (frozen during conversations), villagers, zones and the gate.
    void step() @nogc nothrow @trusted {
        tick_++;
        player.moving = false;
        player.px = player.x;
        player.py = player.y;
        foreach (ref n; npcs_[0 .. numNpcs_]) {
            n.body.moving = false;
            n.body.px = n.body.x;
            n.body.py = n.body.y;
        }
        if (talk_.active || inside_ >= 0)
            return;
        if (moveX != 0 || moveY != 0)
            movePlayer();
        foreach (i; 0 .. numNpcs_)
            wanderNpc(npcs_[i]);
        immutable z = zoneAt(worldCell(player.x, player.y));
        if (z != zone_) {
            zone_ = z;
            if (z >= 0) {
                push(VillageEventKind.enterZone, z);
                int node;
                if (db_.trigger(TriggerKind.enter, landmarkNames[z], *story_, storyEvents, node) >= 0)
                    openTalk(node, -1);
            }
        }
    }

    /// FNV-1a over positions, the tick, the conversation and the story, for replay checks.
    ulong hash() const @nogc nothrow @trusted {
        ulong h = story_.hash();
        void mix(int v) {
            foreach (k; 0 .. 4)
                h = (h ^ ((v >> (k * 8)) & 0xFF)) * 0x100000001b3UL;
        }

        mix(tick_);
        mix(player.x);
        mix(player.y);
        mix(talk_.nodeIndex);
        mix(inside_);
        foreach (ref n; npcs_[0 .. numNpcs_]) {
            mix(n.body.x);
            mix(n.body.y);
        }
        return h;
    }

    // ---- internals ----

    private void push(VillageEventKind k, int arg) @nogc nothrow @safe {
        if (numEvents_ < events_.length)
            events_[numEvents_++] = VillageEvent(k, cast(short)arg);
    }

    private void openTalk(int node, int npc) @nogc nothrow @trusted {
        if (node < 0)
            return;
        talk_.start(*db_, node, *story_, storyEvents);
        talkNpc_ = npc;
        moveX = moveY = 0;
        if (talk_.active)
            push(VillageEventKind.talkStart, npc);
    }

    private void endTalkIfDone() @nogc nothrow @safe {
        if (talk_.active)
            return;
        push(VillageEventKind.talkEnd, talkNpc_);
        talkNpc_ = -1;
    }

    private void placePlayerAtGate() @nogc nothrow @trusted {
        cellWorld(offsetToCube(2, plan_.gateRow), player.x, player.y);
        player.px = player.x;
        player.py = player.y;
        player.faceX = 1;
        player.faceY = 0;
        player.moving = false;
    }

    private int zoneAt(const CubeCoord c) const @nogc nothrow @trusted {
        foreach (i, ref s; plan_.spot)
            if (cubeDistance(s, c) <= 1)
                return cast(int)i;
        return -1;
    }

    /// Moves `w` to (nx, ny) if the cells it crosses allow the step.
    private bool tryMove(ref Walker w, int nx, int ny) const @nogc nothrow @trusted {
        immutable from = worldCell(w.x, w.y), to = worldCell(nx, ny);
        if (to != from) {
            HexDir d;
            if (!directionTo(from, to, d) || !walk_.canStep(from, d))
                return false;
        }
        w.x = nx;
        w.y = ny;
        return true;
    }

    private void movePlayer() @nogc nothrow @trusted {
        // Diagonals at 1/sqrt(2) speed (181/256).
        immutable sp = moveX != 0 && moveY != 0 ? playerSpeed * 181 / 256 : playerSpeed;
        immutable vx = moveX * sp, vy = moveY * sp;
        player.faceX = moveX;
        player.faceY = moveY;
        immutable from = worldCell(player.x, player.y);
        // Full step, else slide along whichever axis is open.
        player.moving = tryMove(player, player.x + vx, player.y + vy) || (vx != 0 && tryMove(player,
                player.x + vx, player.y)) || (vy != 0 && tryMove(player, player.x, player.y + vy));
        if (player.moving || moveX >= 0 || !plan_.isExit(from))
            return;
        // Pressing west against the map edge in the gate passage.
        if (cubeToOffset(worldCell(player.x + vx, player.y)).col >= 0)
            return;
        if (story_.named(varGateOpen)) {
            push(VillageEventKind.leaveWest, 0);
            moveX = moveY = 0;
            return;
        }
        push(VillageEventKind.gateLocked, 0);
        moveX = moveY = 0;
        // Step back inside so the guard's words do not repeat every tick.
        tryMove(player, player.x + halfHex, player.y);
        int node;
        if (db_.trigger(TriggerKind.enter, "gate_locked", *story_, storyEvents, node) >= 0)
            openTalk(node, -1);
    }

    private void wanderNpc(ref Npc n) @nogc nothrow @trusted {
        if (!n.going) {
            if (n.wait-- > 0)
                return;
            // Pick a standable spot near home; an unlucky pick just waits again.
            CubeCoord[37] near = void;
            immutable count = cubeCoordsInRadius(n.home, n.wander > 3 ? 3 : n.wander, near[]);
            immutable t = near[rng.below(cast(uint)count)];
            n.wait = 60 + cast(int)rng.below(150);
            if (!walk_.standable(t))
                return;
            cellWorld(t, n.targetX, n.targetY);
            n.going = true;
        }
        immutable dx = n.targetX - n.body.x, dy = n.targetY - n.body.y;
        immutable len = cast(int)isqrt(cast(long)dx * dx + cast(long)dy * dy);
        if (len <= npcSpeed) {
            tryMove(n.body, n.targetX, n.targetY);
            n.going = false;
            return;
        }
        immutable sx = dx * npcSpeed / len, sy = dy * npcSpeed / len;
        if (!tryMove(n.body, n.body.x + sx, n.body.y + sy)) {
            n.going = false;
            return;
        }
        n.body.moving = true;
        n.body.faceX = sx;
        n.body.faceY = sy;
    }
}

version (unittest) {
    private immutable testStory = `{
      "speakers": [{"id": "elder", "name": "Ba Lan"}, {"id": "guard", "name": "Guard"}],
      "npcs": [{"speaker": "elder", "home": "plaza", "wander": 0}, {"speaker": "guard", "home": "gate", "wander": 0}],
      "nodes": [
        {"id": "hello", "speaker": "elder", "text": "Will you go west?",
         "choices": [{"text": "Yes.", "effects": ["set gate_open"]}, {"text": "No."}]},
        {"id": "shut", "speaker": "guard", "text": "The gate is shut."},
        {"id": "back", "speaker": "elder", "text": "Welcome home."}
      ],
      "triggers": [
        {"on": "talk", "target": "elder", "node": "hello"},
        {"on": "enter", "target": "gate_locked", "node": "shut"},
        {"on": "return", "target": "won", "node": "back"}
      ]
    }`;
}

@nogc nothrow unittest {
    import village.bot : VillageBot;
    import wfc.map_session : MapSession;

    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);

    VillagePlan plan;
    WalkGrid walk;
    assert(buildVillage(s, 3, plan, walk).isOk);
    StoryState st;
    DialogueDb db;
    assert(db.load(testStory, st) == StoryError.none);
    st.intern(varGateOpen);

    ulong runOnce(ref VillageWorld w) @nogc nothrow {
        w.setup(&plan, &walk, &db, &st, 11);
        assert(w.loadNpcs(testStory) == 2);
        w.begin();
        assert(!w.talking && worldCell(w.player.x, w.player.y) == offsetToCube(2, plan.gateRow));

        // The gate is shut: walking west at the gate brings the guard's line.
        bool locked;
        foreach (_; 0 .. 60) {
            w.clearEvents();
            w.apply(VillageCommand(VillageCmd.move, -1, 0));
            w.step();
            foreach (e; w.events)
                locked |= e.kind == VillageEventKind.gateLocked;
            if (locked)
                break;
        }
        assert(locked && w.talking && w.talk.line.id == "shut");
        w.apply(VillageCommand(VillageCmd.interact));
        assert(!w.talking);

        // Walk to the elder, say yes, and the gate opens.
        VillageBot bot;
        bot.walkTo(w, walk, plan.spot[Landmark.plaza], 3000);
        assert(w.npcInReach() == 0);
        w.apply(VillageCommand(VillageCmd.interact));
        assert(w.talking && w.talkNpc == 0 && w.talk.choiceCount == 2);
        immutable p0 = w.player;
        w.apply(VillageCommand(VillageCmd.move, 1, 0));
        w.step();
        assert(w.player.x == p0.x && w.player.y == p0.y);
        w.apply(VillageCommand(VillageCmd.choose, 0, 0, 0));
        assert(!w.talking && st.named(varGateOpen) == 1);

        // Back to the gate and out.
        bot.walkTo(w, walk, offsetToCube(0, plan.gateRow), 3000);
        bool left;
        foreach (_; 0 .. 60) {
            w.clearEvents();
            w.apply(VillageCommand(VillageCmd.move, -1, 0));
            w.step();
            foreach (e; w.events)
                left |= e.kind == VillageEventKind.leaveWest;
            if (left)
                break;
        }
        assert(left);
        w.arriveFromTd(true);
        assert(w.talking && w.talk.line.id == "back");
        return w.hash();
    }

    // Into the smithy: the smith talks from behind the counter, wares cost coins, and out again.
    {
        Interiors ins;
        assert(ins.load(`{"coins": 5, "interiors": [{"place": "plaza", "title": "Square", "host": "elder",
            "wares": [{"name": "Tea", "price": 3, "flag": "has_tea"}]}]}`, db, st) == 1);
        VillageWorld w;
        w.setup(&plan, &walk, &db, &st, 11);
        w.setInteriors(&ins);
        assert(w.loadNpcs(testStory) == 2);
        assert(!w.enterNow("smithy") && w.enterNow("plaza"));
        assert(w.inside == Landmark.plaza && w.interior.title == "Square");
        immutable p0 = w.player;
        w.apply(VillageCommand(VillageCmd.move, 1, 0));
        w.step();
        assert(w.player.x == p0.x);
        w.apply(VillageCommand(VillageCmd.buy, 0, 0, 0));
        assert(w.lastBuy == BuyResult.bought && w.coins == 2);
        w.apply(VillageCommand(VillageCmd.buy, 0, 0, 0));
        assert(w.lastBuy == BuyResult.owned);
        w.apply(VillageCommand(VillageCmd.interact));
        assert(w.talking && w.talkNpc == 0 && w.talk.line.id == "hello");
        w.apply(VillageCommand(VillageCmd.leave));
        assert(w.inside == Landmark.plaza);
        w.apply(VillageCommand(VillageCmd.cancel));
        w.apply(VillageCommand(VillageCmd.leave));
        assert(w.inside == -1 && w.doorInReach == Landmark.plaza);
        st.reset();
    }

    VillageWorld a, b;
    immutable ha = runOnce(a);
    st.reset();
    immutable hb = runOnce(b);
    assert(ha == hb);
}

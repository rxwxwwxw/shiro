// The tower defense simulation: creeps walking the roads in waves, towers, projectiles, burning
// ground, gold and lives. Deterministic: the same board, seed and ordered commands give the same
// game on every platform (integer math only, fixed pools, slot-order iteration). The tick is
// @nogc and allocation-free; pools are sized once in `begin`. Headless Model; the View reads it
// through const accessors and the per-tick event list.
module td.game;

import core.stdc.stdlib : calloc, free;
import core.stdc.string : memset;
import td.board;
import td.defs;
import td.spatial;
import td.waves;
import wfc.hex;
import wfc.map_session : MapSession;
import wfc.passability : unreachable;

enum int maxCreeps = 2048, maxProjectiles = 1024, maxTowers = 1024, maxPatches = 128;
enum int maxEvents = 2048;

enum Targeting : ubyte {
    /// Furthest along the road (closest to leaking).
    first,
    /// Most hit points.
    strongest,
    closest
}

struct Creep {
    /// Position this tick and last tick (the View interpolates between them).
    int x, y, px, py;
    /// Cell it left and cell it walks to (cell indices), and progress between them.
    uint cell, next;
    int progress;
    int hp, maxHp;
    /// Spawn number: drives its junction choices.
    uint serial;
    /// Road left to walk, in step units.
    int pathLeft;
    CreepKind kind;
    bool alive;
    ubyte armor;
    ubyte slowPct;
    ubyte chillPct;
    ushort slowTicks, chillTicks, stunTicks, burnTicks;
    ushort burnDmg;
}

struct Tower {
    int col, row;
    uint cell;
    int x, y;
    TowerKind kind;
    Stage stage;
    Targeting targeting;
    bool alive;
    bool ley;
    int cooldown;
    /// High ground range bonus (percent).
    int rangePct;
    int invested;
    /// Where it last fired (the View turns effects towards it) and when.
    int aimX, aimY;
    uint lastFired;
    int shots, kills;
    long dealt;
}

enum ProjKind : ubyte {
    arrow,
    shell,
    shard,
    bomblet
}

struct Projectile {
    int x, y, px, py;
    int sx, sy, tx, ty;
    int age, flight;
    /// Homing target (creep slot and serial), or none.
    int target = -1;
    uint targetSerial;
    int tower = -1;
    int damage;
    ProjKind kind;
    TowerKind tkind;
    Stage stage;
    bool alive;
}

/// Burning ground left by napalm.
struct Patch {
    int x, y, radius, ticks, dmg;
    bool alive;
}

enum EventKind : ubyte {
    /// a = tower kind, b = stage; (x, y) tower, (x2, y2) aim.
    fired,
    /// Arrow hit; (x, y) where.
    hit,
    /// Splash; a = projectile kind, b = tower kind, value = radius.
    explode,
    /// Lightning segment (x, y) -> (x2, y2); a = stage.
    chain,
    /// Blizzard pulse; value = radius.
    frostPulse,
    /// Flame cone from (x, y) towards (x2, y2); value = range, a = stage.
    flame,
    /// a = creep kind, value = bounty.
    death,
    /// a = creep kind, value = lives lost.
    leak,
    /// value = wave number.
    waveStart,
    /// value = gold paid.
    waveClear,
    /// a = tower kind, b = stage.
    built,
    upgraded,
    /// value = refund.
    sold,
    /// New burning patch; value = radius.
    napalm,
    gameOver,
    victory,
    /// More of the map was uncovered; value = the new stage.
    reveal
}

struct SimEvent {
    EventKind kind;
    ubyte a, b;
    int x, y, x2, y2;
    int value;
}

enum GameStatus : ubyte {
    /// Between waves (or before the first): building time, counting down.
    waiting,
    wave,
    lost,
    won
}

enum CommandType : ubyte {
    place,
    upgrade,
    sell,
    startWave,
    setTargeting
}

struct GameCommand {
    CommandType type;
    /// place: what to build.
    TowerKind kind;
    /// upgrade: branch (0 = A, 1 = B) at Lv2; setTargeting: a Targeting.
    ubyte arg;
    int col = -1, row = -1;
}

enum CommandError : ubyte {
    none,
    outside,
    notBuildable,
    occupied,
    /// Mines need a gold vein, and gold veins take only mines.
    wrongTile,
    noGold,
    noTower,
    maxed,
    wrongPhase,
    full,
    /// The cell is still in the fog.
    hidden
}

struct Game {
    private Board board_;
    private Creep* creeps_;
    private Projectile* projs_;
    private Tower* towers_;
    private Patch* patches_;
    private ushort* towerAt_;
    private SimEvent* events_;
    private ushort* scratch, hitList;
    private SpatialGrid grid;
    private int numEvents_, numTowers_;
    private int creepHint, projHint;
    private Wave wave_;
    private int waveSpawned, waveTick;
    private uint tick_, seed_, serials;
    int gold, lives;
    /// Waves started so far.
    int waveNo;
    /// Waves to clear for a win: totalWaves, or every stage's waves on a reveal map.
    int waveLimit = totalWaves;
    /// Reveal maps: waves per stage (0 = the whole map from the start).
    int wavesPerStage;
    GameStatus status;
    /// Ticks until the next wave starts by itself (while waiting).
    int countdown;
    int creepsAlive, killed, leaked;
    /// Events lost because a tick produced more than maxEvents (View only).
    size_t droppedEvents;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        freePools();
    }

    private void freePools() @nogc nothrow @trusted {
        free(creeps_);
        free(projs_);
        free(towers_);
        free(patches_);
        free(towerAt_);
        free(events_);
        free(scratch);
        free(hitList);
        creeps_ = null;
        projs_ = null;
        towers_ = null;
        patches_ = null;
        towerAt_ = null;
        events_ = null;
        scratch = hitList = null;
    }

    /// Ends the game (no game is active until the next `start`).
    void stop() @nogc nothrow @trusted {
        freePools();
        numEvents_ = numTowers_ = 0;
    }

    /// New game on a generated map.
    void start(ref const MapSession s, uint seed) @nogc nothrow @trusted {
        board_.load(s, seed);
        begin(seed);
        if (board_.plan.enabled) {
            wavesPerStage = s.params.reveal.wavesPerStage > 0 ? s.params.reveal.wavesPerStage : 1;
            waveLimit = board_.numStages * wavesPerStage;
        }
    }

    /// New game on the current board (tests fill it by hand, then call this).
    void begin(uint seed) @nogc nothrow @trusted {
        assert(board_.allocated);
        freePools();
        creeps_ = cast(Creep*)calloc(maxCreeps, Creep.sizeof);
        projs_ = cast(Projectile*)calloc(maxProjectiles, Projectile.sizeof);
        towers_ = cast(Tower*)calloc(maxTowers, Tower.sizeof);
        patches_ = cast(Patch*)calloc(maxPatches, Patch.sizeof);
        towerAt_ = cast(ushort*)calloc(board_.rect.cellCount, ushort.sizeof);
        events_ = cast(SimEvent*)calloc(maxEvents, SimEvent.sizeof);
        scratch = cast(ushort*)calloc(maxCreeps, ushort.sizeof);
        hitList = cast(ushort*)calloc(maxCreeps, ushort.sizeof);
        assert(creeps_ && projs_ && towers_ && patches_ && towerAt_ && events_ && scratch && hitList,
                "game allocation failed");
        int wx, wy;
        cellWorld(board_.rect.cols, board_.rect.rows, wx, wy);
        grid.setup(wx + cellUnits, wy + cellUnits, maxCreeps);
        seed_ = seed;
        tick_ = serials = 0;
        numEvents_ = numTowers_ = creepHint = projHint = 0;
        waveSpawned = waveTick = 0;
        wave_.count = 0;
        gold = startGold;
        lives = startLives;
        waveNo = 0;
        waveLimit = totalWaves;
        wavesPerStage = 0;
        status = GameStatus.waiting;
        countdown = firstWaveDelay;
        creepsAlive = killed = leaked = 0;
        droppedEvents = 0;
    }

    bool active() const @nogc nothrow pure @safe {
        return creeps_ !is null;
    }

    // ---- read-only views ----

    ref const(Board) board() const return @nogc nothrow pure @safe {
        return board_;
    }

    /// Test hook: the board to fill before `begin`.
    ref Board boardForSetup() return @nogc nothrow pure @safe {
        return board_;
    }

    uint tick() const @nogc nothrow pure @safe {
        return tick_;
    }

    const(Creep)[] creeps() const @nogc nothrow @trusted {
        return creeps_ is null ? null : creeps_[0 .. maxCreeps];
    }

    const(Tower)[] towers() const @nogc nothrow @trusted {
        return towers_ is null ? null : towers_[0 .. numTowers_];
    }

    const(Projectile)[] projectiles() const @nogc nothrow @trusted {
        return projs_ is null ? null : projs_[0 .. maxProjectiles];
    }

    const(Patch)[] patches() const @nogc nothrow @trusted {
        return patches_ is null ? null : patches_[0 .. maxPatches];
    }

    /// Events of the last tick.
    const(SimEvent)[] events() const @nogc nothrow @trusted {
        return events_ is null ? null : events_[0 .. numEvents_];
    }

    const(Wave)* currentWave() const return @nogc nothrow pure @safe {
        return &wave_;
    }

    /// Creeps of the current wave still to spawn.
    int pendingSpawns() const @nogc nothrow pure @safe {
        return status == GameStatus.wave ? wave_.count - waveSpawned : 0;
    }

    /// Tower on a cell, or null.
    const(Tower)* towerAt(int col, int row) const @nogc nothrow @trusted {
        if (towerAt_ is null || !board_.inside(col, row))
            return null;
        immutable t = towerAt_[cast(size_t)row * board_.rect.cols + col];
        return t == 0 ? null : &towers_[t - 1];
    }

    /// Effective range of a tower, high ground included.
    int rangeOf(ref const Tower t) const @nogc nothrow pure @safe {
        return towerStats(t.kind, t.stage).range * (100 + t.rangePct) / 100;
    }

    /// Why `kind` could not be placed on (col, row) right now (`none` if it can).
    CommandError canPlace(TowerKind kind, int col, int row) const @nogc nothrow @trusted {
        if (!active || status == GameStatus.lost || status == GameStatus.won)
            return CommandError.wrongPhase;
        if (!board_.inside(col, row))
            return CommandError.outside;
        immutable i = cast(size_t)row * board_.rect.cols + col;
        if (!board_.visible(i))
            return CommandError.hidden;
        if (!(board_.flagsAt(i) & CellFlag.buildable))
            return CommandError.notBuildable;
        if (towerAt_[i] != 0)
            return CommandError.occupied;
        if ((board_.specialAt(i) == SpecialKind.goldVein) != (kind == TowerKind.mine))
            return CommandError.wrongTile;
        if (gold < towerStats(kind, Stage.lv1).cost)
            return CommandError.noGold;
        return CommandError.none;
    }

    /// Order-sensitive digest of the whole game state (determinism checks).
    ulong stateHash() const @nogc nothrow @trusted {
        ulong h = 0xCBF29CE484222325UL;
        void put(long v) {
            foreach (k; 0 .. 8) {
                h ^= (v >> (8 * k)) & 0xFF;
                h *= 0x100000001B3UL;
            }
        }

        put(tick_);
        put(gold);
        put(lives);
        put(waveNo);
        put(board_.stage);
        put(status);
        put(countdown);
        foreach (i; 0 .. maxCreeps) {
            const c = &creeps_[i];
            if (!c.alive)
                continue;
            put(i);
            put(c.x);
            put(c.y);
            put(c.hp);
            put(c.slowTicks + c.burnTicks * 7 + c.stunTicks * 13);
        }
        foreach (i; 0 .. numTowers_) {
            const t = &towers_[i];
            if (!t.alive)
                continue;
            put(i);
            put(t.kind * 4 + t.stage);
            put(t.cooldown);
        }
        foreach (i; 0 .. maxProjectiles)
            if (projs_[i].alive) {
                put(projs_[i].x);
                put(projs_[i].y);
            }
        return h;
    }

    // ---- commands ----

    CommandError apply(const GameCommand cmd) @nogc nothrow @trusted {
        if (!active || status == GameStatus.lost || status == GameStatus.won)
            return CommandError.wrongPhase;
        final switch (cmd.type) {
        case CommandType.place: {
                immutable err = canPlace(cmd.kind, cmd.col, cmd.row);
                if (err != CommandError.none)
                    return err;
                return place(cmd.kind, cmd.col, cmd.row);
            }
        case CommandType.upgrade: {
                auto t = mutableTower(cmd.col, cmd.row);
                if (t is null)
                    return CommandError.noTower;
                Stage next;
                if (!nextStage(t.kind, t.stage, cmd.arg, next))
                    return CommandError.maxed;
                immutable cost = towerStats(t.kind, next).cost;
                if (gold < cost)
                    return CommandError.noGold;
                gold -= cost;
                t.stage = next;
                t.invested += cost;
                emit(SimEvent(EventKind.upgraded, t.kind, next, t.x, t.y));
                return CommandError.none;
            }
        case CommandType.sell: {
                auto t = mutableTower(cmd.col, cmd.row);
                if (t is null)
                    return CommandError.noTower;
                immutable refund = t.invested * sellPercent / 100;
                gold += refund;
                towerAt_[t.cell] = 0;
                t.alive = false;
                emit(SimEvent(EventKind.sold, t.kind, t.stage, t.x, t.y, 0, 0, refund));
                return CommandError.none;
            }
        case CommandType.startWave:
            if (status != GameStatus.waiting)
                return CommandError.wrongPhase;
            // Calling a wave early pays a gold per second skipped.
            gold += countdown / ticksPerSecond;
            startWave();
            return CommandError.none;
        case CommandType.setTargeting: {
                auto t = mutableTower(cmd.col, cmd.row);
                if (t is null)
                    return CommandError.noTower;
                t.targeting = cast(Targeting)(cmd.arg % 3);
                return CommandError.none;
            }
        }
    }

    private Tower* mutableTower(int col, int row) @nogc nothrow @trusted {
        return cast(Tower*)towerAt(col, row);
    }

    private CommandError place(TowerKind kind, int col, int row) @nogc nothrow @trusted {
        int slot = -1;
        foreach (i; 0 .. numTowers_)
            if (!towers_[i].alive) {
                slot = i;
                break;
            }
        if (slot < 0) {
            if (numTowers_ == maxTowers)
                return CommandError.full;
            slot = numTowers_++;
        }
        immutable i = cast(size_t)row * board_.rect.cols + col;
        auto t = &towers_[slot];
        *t = Tower.init;
        t.col = col;
        t.row = row;
        t.cell = cast(uint)i;
        cellWorld(col, row, t.x, t.y);
        t.kind = kind;
        t.alive = true;
        t.ley = board_.specialAt(i) == SpecialKind.leyStone;
        t.rangePct = board_.highGroundPct(i);
        t.invested = towerStats(kind, Stage.lv1).cost;
        // A new tower takes a moment to man.
        t.cooldown = ticksPerSecond / 2;
        gold -= t.invested;
        towerAt_[i] = cast(ushort)(slot + 1);
        emit(SimEvent(EventKind.built, kind, Stage.lv1, t.x, t.y));
        return CommandError.none;
    }

    // ---- tick ----

    private void emit(const SimEvent e) @nogc nothrow @trusted {
        if (numEvents_ < maxEvents)
            events_[numEvents_++] = e;
        else
            droppedEvents++;
    }

    /// Clears the event list; call before applying a batch of commands whose events the View
    /// should see on their own (`tick` clears it too).
    void clearEvents() @nogc nothrow pure @safe {
        numEvents_ = 0;
    }

    void advance() @nogc nothrow @trusted {
        if (!active)
            return;
        numEvents_ = 0;
        if (status == GameStatus.lost || status == GameStatus.won)
            return;
        tick_++;
        if (status == GameStatus.waiting && --countdown <= 0)
            startWave();
        if (status == GameStatus.wave)
            spawnDue();
        moveCreeps();
        updateEffects();
        grid.rebuild(creeps_[0 .. maxCreeps]);
        updatePatches();
        updateTowers();
        updateProjectiles();
        if (status == GameStatus.wave && waveSpawned == wave_.count && creepsAlive == 0)
            clearWave();
    }

    private void startWave() @nogc nothrow @trusted {
        waveNo++;
        buildWave(waveNo, seed_, wave_);
        waveSpawned = 0;
        waveTick = 0;
        status = GameStatus.wave;
        emit(SimEvent(EventKind.waveStart, 0, 0, 0, 0, 0, 0, waveNo));
    }

    private void clearWave() @nogc nothrow @trusted {
        int pay = waveClearBonus(waveNo);
        foreach (i; 0 .. numTowers_)
            if (towers_[i].alive && towers_[i].kind == TowerKind.mine) {
                pay += towerStats(TowerKind.mine, towers_[i].stage).income;
                emit(SimEvent(EventKind.waveClear, TowerKind.mine, towers_[i].stage, towers_[i].x,
                        towers_[i].y, 0, 0, towerStats(TowerKind.mine, towers_[i].stage).income));
            }
        gold += pay;
        emit(SimEvent(EventKind.waveClear, 0, 0, 0, 0, 0, 0, pay));
        // A stage's last wave uncovers the next stage (no creeps are left on the board).
        if (wavesPerStage > 0 && waveNo % wavesPerStage == 0 && waveNo < waveLimit && board_.advanceStage())
            emit(SimEvent(EventKind.reveal, 0, 0, 0, 0, 0, 0, board_.stage));
        if (waveNo >= waveLimit) {
            status = GameStatus.won;
            emit(SimEvent(EventKind.victory));
        } else {
            status = GameStatus.waiting;
            countdown = waveBreak;
        }
    }

    private void spawnDue() @nogc nothrow @trusted {
        while (waveSpawned < wave_.count && wave_.spawns[waveSpawned].at <= waveTick) {
            const sp = &wave_.spawns[waveSpawned];
            if (board_.numSources == 0 || spawn(sp.kind, sp.source % board_.numSources) < 0)
                break; // no room: try again next tick
            waveSpawned++;
        }
        // The wave clock stalls while the pool is full so spacing is kept.
        if (waveSpawned == wave_.count || wave_.spawns[waveSpawned].at > waveTick)
            waveTick++;
    }

    /// Benchmark / test hook: spawns a creep at source `src` outside any wave. Returns its slot,
    /// or -1 when the pool is full.
    int inject(CreepKind kind, int src) @nogc nothrow @trusted {
        if (!active || board_.numSources == 0)
            return -1;
        return spawn(kind, src % board_.numSources);
    }

    /// Spawns a creep at source `src`; returns its slot or -1 when the pool is full.
    private int spawn(CreepKind kind, int src) @nogc nothrow @trusted {
        return spawnAt(kind, cast(uint)board_.rect.index(board_.sources[src]));
    }

    private int spawnAt(CreepKind kind, uint cell) @nogc nothrow @trusted {
        foreach (k; 0 .. maxCreeps) {
            immutable i = (creepHint + k) % maxCreeps;
            if (creeps_[i].alive)
                continue;
            creepHint = (i + 1) % maxCreeps;
            auto c = &creeps_[i];
            *c = Creep.init;
            c.kind = kind;
            c.alive = true;
            c.serial = ++serials;
            c.hp = c.maxHp = scaledHp(kind, waveNo > 0 ? waveNo : 1);
            c.armor = cast(ubyte)creepTable[kind].armor;
            c.cell = cell;
            c.next = chooseNext(cell, c.serial);
            placeCreep(*c);
            c.px = c.x;
            c.py = c.y;
            creepsAlive++;
            return i;
        }
        return -1;
    }

    /// Next cell one step closer to a sink; ties between branches are split by the creep's serial.
    private uint chooseNext(uint cell, uint serial) const @nogc nothrow @trusted {
        immutable d = board_.distAt(cell);
        if (d == 0 || d == unreachable)
            return cell;
        uint[6] cand;
        int n = 0;
        immutable c = board_.rect.cellAt(cell);
        foreach (k; 0 .. numHexDirs) {
            immutable nc = c.neighbor(cast(HexDir)k);
            if (!board_.rect.contains(nc))
                continue;
            immutable j = board_.rect.index(nc);
            if (board_.distAt(j) == d - 1)
                cand[n++] = cast(uint)j;
        }
        if (n == 0)
            return cell;
        return cand[mix(serial, cell, 0xC4EE9u) % n];
    }

    private void placeCreep(ref Creep c) const @nogc nothrow @trusted {
        int ax, ay, bx, by;
        cellWorld(board_.rect.cellAt(c.cell), ax, ay);
        cellWorld(board_.rect.cellAt(c.next), bx, by);
        c.x = ax + (bx - ax) * c.progress / stepUnits;
        c.y = ay + (by - ay) * c.progress / stepUnits;
        immutable d = board_.distAt(c.cell);
        c.pathLeft = d == unreachable ? int.max : d * stepUnits - c.progress;
    }

    private void moveCreeps() @nogc nothrow @trusted {
        foreach (i; 0 .. maxCreeps) {
            auto c = &creeps_[i];
            if (!c.alive)
                continue;
            c.px = c.x;
            c.py = c.y;
            if (c.stunTicks > 0)
                continue;
            int speed = creepTable[c.kind].speed;
            if (c.slowTicks > 0)
                speed = speed * (100 - c.slowPct) / 100;
            c.progress += speed;
            while (c.progress >= stepUnits) {
                c.progress -= stepUnits;
                c.cell = c.next;
                if (board_.distAt(c.cell) == 0) {
                    leak(*c);
                    break;
                }
                c.next = chooseNext(c.cell, c.serial);
                if (c.next == c.cell)
                    c.progress = 0;
            }
            if (c.alive)
                placeCreep(*c);
        }
    }

    private void leak(ref Creep c) @nogc nothrow @trusted {
        immutable cost = creepTable[c.kind].leak;
        int x, y;
        cellWorld(board_.rect.cellAt(c.cell), x, y);
        c.alive = false;
        creepsAlive--;
        leaked++;
        lives -= cost;
        emit(SimEvent(EventKind.leak, c.kind, 0, x, y, 0, 0, cost));
        if (lives <= 0) {
            lives = 0;
            status = GameStatus.lost;
            emit(SimEvent(EventKind.gameOver));
        }
    }

    private void updateEffects() @nogc nothrow @trusted {
        foreach (i; 0 .. maxCreeps) {
            auto c = &creeps_[i];
            if (!c.alive)
                continue;
            if (c.slowTicks > 0 && --c.slowTicks == 0)
                c.slowPct = 0;
            if (c.chillTicks > 0 && --c.chillTicks == 0)
                c.chillPct = 0;
            if (c.stunTicks > 0)
                c.stunTicks--;
            if (c.burnTicks > 0) {
                c.burnTicks--;
                if ((tick_ + c.serial) % burnEvery == 0)
                    hurt(i, c.burnDmg, DamageType.fire, 0, -1);
                if (c.burnTicks == 0)
                    c.burnDmg = 0;
            }
        }
    }

    /// Deals damage to creep `ci` (armor, chill); credits tower `ti` (or none) and pays the bounty
    /// on a kill.
    private void hurt(size_t ci, int dmg, DamageType type, int pierce, int ti) @nogc nothrow @trusted {
        auto c = &creeps_[ci];
        if (!c.alive)
            return;
        immutable d = mitigate(dmg, type, c.armor, pierce, c.chillTicks > 0 ? c.chillPct : 0);
        c.hp -= d;
        if (ti >= 0)
            towers_[ti].dealt += d;
        if (c.hp > 0)
            return;
        c.alive = false;
        creepsAlive--;
        killed++;
        immutable bounty = creepTable[c.kind].bounty;
        gold += bounty;
        if (ti >= 0)
            towers_[ti].kills++;
        emit(SimEvent(EventKind.death, c.kind, 0, c.x, c.y, 0, 0, bounty));
    }

    private void slow(ref Creep c, int pct, int ticks) @nogc nothrow pure @safe {
        immutable resist = creepTable[c.kind].slowResist;
        immutable eff = pct * (100 - resist) / 100;
        if (eff >= c.slowPct) {
            c.slowPct = cast(ubyte)eff;
            if (ticks > c.slowTicks)
                c.slowTicks = cast(ushort)ticks;
        }
    }

    private void stun(ref Creep c, int ticks) @nogc nothrow pure @safe {
        immutable eff = ticks * (100 - creepTable[c.kind].slowResist) / 100;
        if (eff > c.stunTicks)
            c.stunTicks = cast(ushort)eff;
    }

    private void burn(ref Creep c, int dmg, int ticks) @nogc nothrow pure @safe {
        if (dmg > c.burnDmg)
            c.burnDmg = cast(ushort)dmg;
        if (ticks > c.burnTicks)
            c.burnTicks = cast(ushort)ticks;
    }

    private void chill(ref Creep c, int pct, int ticks) @nogc nothrow pure @safe {
        if (pct > c.chillPct)
            c.chillPct = cast(ubyte)pct;
        if (ticks > c.chillTicks)
            c.chillTicks = cast(ushort)ticks;
    }

    private void updatePatches() @nogc nothrow @trusted {
        foreach (i; 0 .. maxPatches) {
            auto p = &patches_[i];
            if (!p.alive)
                continue;
            if (--p.ticks <= 0) {
                p.alive = false;
                continue;
            }
            if (tick_ % burnEvery != 0)
                continue;
            immutable n = grid.query(creeps(), p.x, p.y, p.radius, scratch[0 .. maxCreeps]);
            foreach (k; 0 .. n) {
                burn(creeps_[scratch[k]], p.dmg, burnEvery * 2);
                hurt(scratch[k], p.dmg, DamageType.fire, 0, -1);
            }
        }
    }

    private void addPatch(int x, int y, int radius, int ticks, int dmg) @nogc nothrow @trusted {
        foreach (i; 0 .. maxPatches)
            if (!patches_[i].alive) {
                patches_[i] = Patch(x, y, radius, ticks, dmg, true);
                emit(SimEvent(EventKind.napalm, 0, 0, x, y, 0, 0, radius));
                return;
            }
    }

    /// Better target of two candidate slots under a targeting mode (ties keep `a`).
    private bool better(Targeting mode, size_t a, size_t b, int tx, int ty) const @nogc nothrow @trusted {
        const ca = &creeps_[a], cb = &creeps_[b];
        final switch (mode) {
        case Targeting.first:
            return cb.pathLeft < ca.pathLeft;
        case Targeting.strongest:
            return cb.hp > ca.hp || (cb.hp == ca.hp && cb.pathLeft < ca.pathLeft);
        case Targeting.closest:
            return dist2(cb.x, cb.y, tx, ty) < dist2(ca.x, ca.y, tx, ty);
        }
    }

    /// Index into scratch[0 .. n] of the best target, skipping ids already in hitList[0 .. skip].
    private int pick(Targeting mode, size_t n, size_t skip, int tx, int ty) const @nogc nothrow @trusted {
        int best = -1;
        foreach (k; 0 .. n) {
            bool taken = false;
            foreach (j; 0 .. skip)
                taken |= hitList[j] == scratch[k];
            if (taken)
                continue;
            if (best < 0 || better(mode, scratch[best], scratch[k], tx, ty))
                best = cast(int)k;
        }
        return best;
    }

    private void updateTowers() @nogc nothrow @trusted {
        foreach (ti; 0 .. numTowers_) {
            auto t = &towers_[ti];
            if (!t.alive || t.kind == TowerKind.mine)
                continue;
            if (t.cooldown > 0) {
                t.cooldown--;
                continue;
            }
            const st = &towerStats(t.kind, t.stage);
            immutable range = rangeOf(*t);
            immutable n = grid.query(creeps(), t.x, t.y, range, scratch[0 .. maxCreeps]);
            if (n == 0)
                continue;
            immutable dmg = st.damage * (t.ley ? 100 + leyDamagePct : 100) / 100;
            t.cooldown = st.cooldown;
            t.lastFired = tick_;
            t.shots++;
            if (st.pulse) {
                foreach (k; 0 .. n) {
                    slow(creeps_[scratch[k]], st.slowPct, st.slowTicks);
                    hurt(scratch[k], dmg, st.type, 0, ti);
                }
                t.aimX = t.x;
                t.aimY = t.y;
                emit(SimEvent(EventKind.frostPulse, t.kind, t.stage, t.x, t.y, t.x, t.y, range));
                continue;
            }
            immutable first = pick(t.targeting, n, 0, t.x, t.y);
            const target = &creeps_[scratch[first]];
            t.aimX = target.x;
            t.aimY = target.y;
            emit(SimEvent(EventKind.fired, t.kind, t.stage, t.x, t.y, target.x, target.y));
            final switch (t.kind) {
            case TowerKind.arrow: {
                    size_t shot = 0;
                    foreach (v; 0 .. st.targets) {
                        immutable k = pick(t.targeting, n, shot, t.x, t.y);
                        if (k < 0)
                            break;
                        hitList[shot++] = scratch[k];
                        launch(ProjKind.arrow, *t, ti, scratch[k], creeps_[scratch[k]].x,
                                creeps_[scratch[k]].y, dmg, st.projSpeed);
                    }
                    break;
                }
            case TowerKind.cannon:
                // Shells land where the target stood when they were fired.
                launch(ProjKind.shell, *t, ti, -1, target.x, target.y, dmg, st.projSpeed);
                break;
            case TowerKind.frost:
                launch(ProjKind.shard, *t, ti, scratch[first], target.x, target.y, dmg, st.projSpeed);
                break;
            case TowerKind.tesla:
                lightning(*t, ti, *st, scratch[first], dmg);
                break;
            case TowerKind.flame:
                flame(*t, ti, *st, n, target.x, target.y, dmg);
                break;
            case TowerKind.mine:
                break;
            }
        }
    }

    private void lightning(ref Tower t, int ti, ref const TowerStats st, ushort first, int dmg) @nogc nothrow @trusted {
        int fromX = t.x, fromY = t.y;
        ushort cur = first;
        size_t hits = 0;
        int d = dmg;
        foreach (hop; 0 .. st.chains + 1) {
            auto c = &creeps_[cur];
            hitList[hits++] = cur;
            emit(SimEvent(EventKind.chain, t.stage, cast(ubyte)hop, fromX, fromY, c.x, c.y, d));
            fromX = c.x;
            fromY = c.y;
            if (st.stunTicks > 0)
                stun(*c, st.stunTicks);
            hurt(cur, d, st.type, 0, ti);
            if (hop == st.chains)
                break;
            // Hop to the nearest creep not hit yet.
            immutable n = grid.query(creeps(), fromX, fromY, st.chainRange, scratch[0 .. maxCreeps]);
            immutable k = pick(Targeting.closest, n, hits, fromX, fromY);
            if (k < 0)
                break;
            cur = scratch[k];
            d = d * st.chainKeep / 100;
        }
    }

    private void flame(ref Tower t, int ti, ref const TowerStats st, size_t n, int ax, int ay, int dmg) @nogc nothrow @trusted {
        immutable long dx = ax - t.x, dy = ay - t.y;
        immutable long dd = dx * dx + dy * dy;
        immutable long cos2 = cast(long)st.coneCos * st.coneCos;
        emit(SimEvent(EventKind.flame, t.kind, t.stage, t.x, t.y, ax, ay, rangeOf(t)));
        foreach (k; 0 .. n) {
            auto c = &creeps_[scratch[k]];
            immutable long ex = c.x - t.x, ey = c.y - t.y;
            immutable long dot = dx * ex + dy * ey;
            // Inside the cone: angle to the aim line under acos(coneCos / 100).
            if (dd > 0 && (dot <= 0 || dot * dot * 10_000 < cos2 * dd * (ex * ex + ey * ey)))
                continue;
            burn(*c, st.burnDmg * (t.ley ? 100 + leyDamagePct : 100) / 100, st.burnTicks);
            hurt(scratch[k], dmg, st.type, 0, ti);
        }
        if (st.patchTicks > 0 && t.shots % 4 == 1)
            addPatch(ax, ay, st.splash, st.patchTicks, st.burnDmg);
    }

    private void launch(ProjKind kind, ref const Tower t, int ti, int target, int tx, int ty, int dmg, int speed) @nogc nothrow @trusted {
        launchFrom(kind, t.x, t.y, t.kind, t.stage, ti, target, tx, ty, dmg, speed);
    }

    private void launchFrom(ProjKind kind, int sx, int sy, TowerKind tk, Stage stage, int ti, int target,
            int tx, int ty, int dmg, int speed) @nogc nothrow @trusted {
        foreach (k; 0 .. maxProjectiles) {
            immutable i = (projHint + k) % maxProjectiles;
            if (projs_[i].alive)
                continue;
            projHint = (i + 1) % maxProjectiles;
            auto p = &projs_[i];
            *p = Projectile.init;
            p.kind = kind;
            p.x = p.px = p.sx = sx;
            p.y = p.py = p.sy = sy;
            p.tx = tx;
            p.ty = ty;
            immutable len = isqrtL(dist2(sx, sy, tx, ty));
            p.flight = speed > 0 ? cast(int)(len / speed) + 1 : 1;
            p.target = target;
            p.targetSerial = target >= 0 ? creeps_[target].serial : 0;
            p.tower = ti;
            p.damage = dmg;
            p.tkind = tk;
            p.stage = stage;
            p.alive = true;
            return;
        }
        // Pool full: the shot is lost.
    }

    private void updateProjectiles() @nogc nothrow @trusted {
        foreach (i; 0 .. maxProjectiles) {
            auto p = &projs_[i];
            if (!p.alive)
                continue;
            p.px = p.x;
            p.py = p.y;
            p.age++;
            if (p.target >= 0) {
                const c = &creeps_[p.target];
                if (c.alive && c.serial == p.targetSerial) {
                    p.tx = c.x;
                    p.ty = c.y;
                } else
                    p.target = -1;
            }
            if (p.age < p.flight) {
                p.x = p.sx + cast(int)(cast(long)(p.tx - p.sx) * p.age / p.flight);
                p.y = p.sy + cast(int)(cast(long)(p.ty - p.sy) * p.age / p.flight);
                continue;
            }
            p.x = p.tx;
            p.y = p.ty;
            p.alive = false;
            impact(*p);
        }
    }

    private void impact(ref const Projectile p) @nogc nothrow @trusted {
        immutable ti = p.tower >= 0 && p.tower < numTowers_ && towers_[p.tower].alive ? p.tower : -1;
        const st = &towerStats(p.tkind, p.stage);
        final switch (p.kind) {
        case ProjKind.arrow:
            if (p.target >= 0) {
                emit(SimEvent(EventKind.hit, p.tkind, p.stage, p.x, p.y, p.sx, p.sy, p.damage));
                hurt(p.target, p.damage, st.type, st.pierce, ti);
            }
            break;
        case ProjKind.shard:
            splash(p, ti, *st, st.splash, p.damage);
            break;
        case ProjKind.shell:
            splash(p, ti, *st, st.splash, p.damage);
            // Bomblets land in a ring around the blast.
            foreach (b; 0 .. st.bomblets) {
                immutable h = mix(p.x, p.y, b);
                static immutable int[2][6] ring = [
                    [1024, 0], [512, 887], [-512, 887], [-1024, 0], [-512, -887], [512, -887]
                ];
                immutable dir = ring[(b + h % 6) % 6];
                immutable reach = 90 + cast(int)(h >> 8) % 50;
                launchFrom(ProjKind.bomblet, p.x, p.y, p.tkind, p.stage, ti, -1,
                        p.x + dir[0] * reach / 100, p.y + dir[1] * reach / 100, p.damage * 45 / 100, 70);
            }
            break;
        case ProjKind.bomblet:
            splash(p, ti, *st, 600, p.damage);
            break;
        }
    }

    private void splash(ref const Projectile p, int ti, ref const TowerStats st, int radius, int dmg) @nogc nothrow @trusted {
        emit(SimEvent(EventKind.explode, p.kind, p.tkind, p.x, p.y, 0, 0, radius));
        immutable n = grid.query(creeps(), p.x, p.y, radius, scratch[0 .. maxCreeps]);
        foreach (k; 0 .. n) {
            auto c = &creeps_[scratch[k]];
            immutable pct = splashPercent(dist2(c.x, c.y, p.x, p.y), radius, st.splashEdge);
            if (pct <= 0)
                continue;
            if (st.slowPct > 0)
                slow(*c, st.slowPct, st.slowTicks);
            if (st.chillPct > 0)
                chill(*c, st.chillPct, st.chillTicks);
            if (st.shred > 0)
                c.armor = cast(ubyte)(c.armor > st.shred ? c.armor - st.shred : 0);
            hurt(scratch[k], dmg * pct / 100, st.type, st.pierce, ti);
        }
    }
}

private long isqrtL(long v) @nogc nothrow pure @safe {
    if (v <= 0)
        return 0;
    long x = v, y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + v / x) / 2;
    }
    return x;
}

@nogc nothrow pure @safe unittest {
    assert(isqrtL(0) == 0 && isqrtL(1) == 1 && isqrtL(15) == 3 && isqrtL(16) == 4);
    assert(isqrtL(1_000_000_000_000L) == 1_000_000);
}

// ---- tests -----------------------------------------------------------------------------------

version (unittest) {
    import wfc.grid_connector : MapRect;

    /// A 20 x 7 board: a straight road on row 3 from a source at col 1 to a sink at col 18, flat
    /// buildable ground elsewhere.
    private void straightBoard(ref Game g, uint seed = 1) @nogc nothrow @trusted {
        auto b = &g.boardForSetup();
        b.allocate(MapRect(20, 7));
        foreach (row; 0 .. 7)
            foreach (col; 0 .. 20)
                b.setCell(col, row, row == 3 && col >= 1 && col <= 18
                        ? cast(ubyte)(CellFlag.walk | CellFlag.road | (col == 1 ? CellFlag.source
                            : 0) | (col == 18 ? CellFlag.sink : 0)) : CellFlag.buildable);
        b.finish(seed, false);
        g.begin(seed);
    }

    private GameCommand placeCmd(TowerKind k, int col, int row) @nogc nothrow pure @safe {
        return GameCommand(CommandType.place, k, 0, col, row);
    }

    private int countAlive(ref const Game g) @nogc nothrow @safe {
        int n = 0;
        foreach (ref c; g.creeps)
            n += c.alive;
        return n;
    }

    /// Puts a creep on the road cell (col, 3) of the straight board.
    private int dropCreep(ref Game g, CreepKind k, int col) @nogc nothrow @trusted {
        return g.spawnAt(k, cast(uint)g.board_.rect.index(offsetToCube(col, 3)));
    }
}

@nogc nothrow unittest {
    // Building rules, gold, upgrades and selling.
    Game g;
    straightBoard(g);
    assert(g.gold == startGold && g.lives == startLives && g.status == GameStatus.waiting);
    assert(g.apply(placeCmd(TowerKind.arrow, 5, 3)) == CommandError.notBuildable);
    assert(g.apply(placeCmd(TowerKind.arrow, 25, 3)) == CommandError.outside);
    assert(g.apply(placeCmd(TowerKind.mine, 5, 2)) == CommandError.wrongTile);
    assert(g.apply(placeCmd(TowerKind.arrow, 5, 2)) == CommandError.none);
    assert(g.gold == startGold - 50 && g.towerAt(5, 2) !is null);
    assert(g.apply(placeCmd(TowerKind.cannon, 5, 2)) == CommandError.occupied);
    g.boardForSetup().setSpecial(9, 2, SpecialKind.goldVein);
    assert(g.apply(placeCmd(TowerKind.arrow, 9, 2)) == CommandError.wrongTile);
    assert(g.apply(placeCmd(TowerKind.mine, 9, 2)) == CommandError.none);

    auto up = GameCommand(CommandType.upgrade, TowerKind.arrow, 0, 5, 2);
    immutable before = g.gold;
    assert(g.apply(up) == CommandError.none && g.towerAt(5, 2).stage == Stage.lv2);
    assert(g.gold == before - towerStats(TowerKind.arrow, Stage.lv2).cost);
    g.gold = 1000;
    up.arg = 1;
    assert(g.apply(up) == CommandError.none && g.towerAt(5, 2).stage == Stage.branchB);
    assert(g.apply(up) == CommandError.maxed);
    immutable invested = investedIn(TowerKind.arrow, Stage.branchB);
    assert(g.towerAt(5, 2).invested == invested);
    immutable gold0 = g.gold;
    assert(g.apply(GameCommand(CommandType.sell, TowerKind.arrow, 0, 5, 2)) == CommandError.none);
    assert(g.gold == gold0 + invested * sellPercent / 100 && g.towerAt(5, 2) is null);
    assert(g.apply(GameCommand(CommandType.sell, TowerKind.arrow, 0, 5, 2)) == CommandError.noTower);
    // The freed slot is reused.
    assert(g.apply(placeCmd(TowerKind.frost, 6, 2)) == CommandError.none && g.towers.length == 2);
    g.gold = 0;
    assert(g.apply(placeCmd(TowerKind.arrow, 7, 2)) == CommandError.noGold);
}

@nogc nothrow unittest {
    // With no towers every creep of wave 1 walks to the sink and costs lives; the wave then
    // clears, pays its bonus, and the countdown to wave 2 starts.
    Game g;
    straightBoard(g);
    assert(g.apply(GameCommand(CommandType.startWave)) == CommandError.none);
    assert(g.gold == startGold + firstWaveDelay / ticksPerSecond);
    immutable spawns = g.currentWave.count;
    int leakedLives = 0;
    foreach (t; 0 .. 20_000) {
        g.advance();
        foreach (ref e; g.events)
            if (e.kind == EventKind.leak)
                leakedLives += e.value;
        if (g.status != GameStatus.wave)
            break;
    }
    assert(g.status == GameStatus.waiting || g.status == GameStatus.lost);
    assert(g.leaked == spawns && g.killed == 0);
    assert(g.lives == (startLives - leakedLives > 0 ? startLives - leakedLives : 0));
    if (g.status == GameStatus.waiting)
        assert(g.countdown == waveBreak);
}

@nogc nothrow unittest {
    // Creeps walk at their speed: a grunt covers the 17 steps in about 17 * 1024 / 34 ticks;
    // slowing it by half doubles that; stunning it stops it.
    Game g;
    straightBoard(g);
    g.status = GameStatus.wave;
    g.waveSpawned = g.wave_.count = 0;
    immutable a = dropCreep(g, CreepKind.grunt, 1);
    int ticks = 0;
    while (g.creeps_[a].alive && ticks < 2000) {
        g.advance();
        ticks++;
    }
    assert(ticks >= 17 * 1024 / 34 && ticks <= 17 * 1024 / 34 + 2);
    assert(g.lives == startLives - 1);

    g.status = GameStatus.wave;
    immutable b = dropCreep(g, CreepKind.grunt, 1);
    g.creeps_[b].slowPct = 50;
    g.creeps_[b].slowTicks = 10_000;
    foreach (t; 0 .. 100)
        g.advance();
    immutable slowedLeft = g.creeps_[b].pathLeft;
    immutable c = dropCreep(g, CreepKind.grunt, 1);
    foreach (t; 0 .. 100)
        g.advance();
    assert(17 * 1024 - g.creeps_[c].pathLeft > (17 * 1024 - slowedLeft) * 19 / 10);
    g.creeps_[c].stunTicks = 50;
    immutable x0 = g.creeps_[c].x;
    foreach (t; 0 .. 40)
        g.advance();
    assert(g.creeps_[c].x == x0);
}

@nogc nothrow unittest {
    // At a fork with two equally short branches, creeps take both.
    Game g;
    auto b = &g.boardForSetup();
    b.allocate(MapRect(11, 5));
    enum ubyte walk = CellFlag.walk | CellFlag.road;
    b.setCell(1, 2, walk | CellFlag.source);
    b.setCell(9, 2, walk | CellFlag.sink);
    foreach (col; 1 .. 9) {
        b.setCell(col, 1, walk);
        b.setCell(col, 3, walk);
    }
    b.finish(1, false);
    g.begin(1);
    g.status = GameStatus.wave;
    int up = 0, down = 0;
    foreach (k; 0 .. 40) {
        immutable i = g.spawnAt(CreepKind.grunt, cast(uint)b.rect.index(offsetToCube(1, 2)));
        immutable row = cubeToOffset(b.rect.cellAt(g.creeps_[i].next)).row;
        up += row == 1;
        down += row == 3;
    }
    assert(up + down == 40 && up > 5 && down > 5);
}

@nogc nothrow unittest {
    // Each tower kind damages creeps in its own way.
    Game g;

    // Cannon splash hits a tight group at once.
    straightBoard(g);
    g.status = GameStatus.wave;
    assert(g.apply(placeCmd(TowerKind.cannon, 8, 2)) == CommandError.none);
    int[3] ids = [
        dropCreep(g, CreepKind.brute, 9), dropCreep(g, CreepKind.brute, 9),
        dropCreep(g, CreepKind.brute, 9)
    ];
    foreach (t; 0 .. 45)
        g.advance();
    int damaged = 0;
    foreach (i; ids)
        damaged += g.creeps_[i].hp < g.creeps_[i].maxHp;
    assert(damaged == 3);

    // Frost shards slow what they hit.
    straightBoard(g);
    g.status = GameStatus.wave;
    assert(g.apply(placeCmd(TowerKind.frost, 6, 2)) == CommandError.none);
    immutable f = dropCreep(g, CreepKind.brute, 4);
    foreach (t; 0 .. 40)
        g.advance();
    assert(g.creeps_[f].slowTicks > 0 && g.creeps_[f].slowPct == 35 * 80 / 100);

    // Tesla chains through several creeps, ignoring armor.
    straightBoard(g);
    g.status = GameStatus.wave;
    assert(g.apply(placeCmd(TowerKind.tesla, 8, 2)) == CommandError.none);
    int[4] line = [
        dropCreep(g, CreepKind.brute, 6), dropCreep(g, CreepKind.brute, 7),
        dropCreep(g, CreepKind.brute, 8), dropCreep(g, CreepKind.brute, 9)
    ];
    foreach (t; 0 .. 16)
        g.advance();
    int zapped = 0;
    foreach (i; line)
        zapped += g.creeps_[i].hp < g.creeps_[i].maxHp;
    assert(zapped == 3); // the first bolt plus 2 hops

    // Flame sets creeps alight; burning continues after the tower is sold.
    straightBoard(g);
    g.status = GameStatus.wave;
    assert(g.apply(placeCmd(TowerKind.flame, 8, 2)) == CommandError.none);
    immutable fl = dropCreep(g, CreepKind.brute, 7);
    foreach (t; 0 .. 16)
        g.advance();
    assert(g.creeps_[fl].burnTicks > 0);
    assert(g.apply(GameCommand(CommandType.sell, TowerKind.flame, 0, 8, 2)) == CommandError.none);
    immutable hp0 = g.creeps_[fl].hp;
    foreach (t; 0 .. 25)
        g.advance();
    assert(g.creeps_[fl].hp < hp0);

    // Kills pay the bounty.
    straightBoard(g);
    g.status = GameStatus.wave;
    assert(g.apply(placeCmd(TowerKind.arrow, 8, 2)) == CommandError.none);
    immutable gold0 = g.gold;
    immutable sw = dropCreep(g, CreepKind.swarm, 6);
    foreach (t; 0 .. 120)
        g.advance();
    // The forced wave then clears too, paying its bonus on top.
    assert(!g.creeps_[sw].alive && g.killed == 1);
    assert(g.gold == gold0 + creepTable[CreepKind.swarm].bounty + waveClearBonus(0));
    assert(g.towerAt(8, 2).kills == 1);
}

@nogc nothrow unittest {
    // Specializations: Volley shoots three targets, Overload stuns, Blizzard slows all in range,
    // Shatter chills, Napalm leaves burning ground, Cluster throws bomblets.
    Game g;
    void setup(TowerKind k, ubyte branch) {
        straightBoard(g);
        g.status = GameStatus.wave;
        g.gold = 10_000;
        assert(g.apply(placeCmd(k, 8, 2)) == CommandError.none);
        assert(g.apply(GameCommand(CommandType.upgrade, k, 0, 8, 2)) == CommandError.none);
        assert(g.apply(GameCommand(CommandType.upgrade, k, branch, 8, 2)) == CommandError.none);
        g.towers_[0].cooldown = 0;
    }

    int arrows() {
        int n = 0;
        foreach (ref p; g.projectiles)
            n += p.alive && p.kind == ProjKind.arrow;
        return n;
    }

    setup(TowerKind.arrow, 1);
    foreach (col; 6 .. 10)
        dropCreep(g, CreepKind.brute, col);
    g.advance();
    assert(arrows() == 3);

    setup(TowerKind.tesla, 1);
    immutable s = dropCreep(g, CreepKind.boss, 8);
    g.advance();
    assert(g.creeps_[s].stunTicks > 0);

    setup(TowerKind.frost, 0);
    int[3] fr = [
        dropCreep(g, CreepKind.grunt, 7), dropCreep(g, CreepKind.grunt, 8),
        dropCreep(g, CreepKind.grunt, 9)
    ];
    g.advance();
    foreach (i; fr)
        assert(g.creeps_[i].slowTicks > 0);

    setup(TowerKind.frost, 1);
    immutable ch = dropCreep(g, CreepKind.brute, 8);
    foreach (t; 0 .. 12)
        g.advance();
    assert(g.creeps_[ch].chillTicks > 0 && g.creeps_[ch].chillPct == 40);

    setup(TowerKind.flame, 1);
    dropCreep(g, CreepKind.boss, 8);
    g.advance();
    int patches = 0;
    foreach (ref p; g.patches)
        patches += p.alive;
    assert(patches == 1);

    setup(TowerKind.cannon, 0);
    dropCreep(g, CreepKind.boss, 9);
    int bomblets = 0;
    foreach (t; 0 .. 40) {
        g.advance();
        foreach (ref p; g.projectiles)
            bomblets += p.alive && p.kind == ProjKind.bomblet && p.age == 1;
    }
    assert(bomblets == towerStats(TowerKind.cannon, Stage.branchA).bomblets);
}

@nogc nothrow unittest {
    // Ley stones add damage, high ground adds range.
    Game g;
    straightBoard(g);
    g.boardForSetup().setSpecial(4, 2, SpecialKind.leyStone);
    g.boardForSetup().setCell(12, 1, CellFlag.buildable, 2);
    assert(g.apply(placeCmd(TowerKind.arrow, 4, 2)) == CommandError.none);
    assert(g.apply(placeCmd(TowerKind.arrow, 12, 1)) == CommandError.none);
    assert(g.towerAt(4, 2).ley && g.towerAt(12, 1).rangePct == 24);
    assert(g.rangeOf(*g.towerAt(12, 1)) == towerStats(TowerKind.arrow, Stage.lv1).range * 124 / 100);
}

@nogc nothrow unittest {
    // Losing every life ends the game; nothing more happens after.
    Game g;
    straightBoard(g);
    g.lives = 1;
    g.apply(GameCommand(CommandType.startWave));
    foreach (t; 0 .. 5000)
        g.advance();
    assert(g.status == GameStatus.lost && g.lives == 0);
    immutable h = g.stateHash();
    g.advance();
    assert(g.stateHash() == h);
    assert(g.apply(placeCmd(TowerKind.arrow, 5, 2)) == CommandError.wrongPhase);
}

@nogc nothrow unittest {
    // Same seed and commands, same game, tick for tick; another seed diverges.
    Game a, b, c;
    straightBoard(a, 3);
    straightBoard(b, 3);
    straightBoard(c, 4);
    Game*[3] all = [&a, &b, &c];
    foreach (g; all) {
        g.apply(placeCmd(TowerKind.cannon, 6, 2));
        g.apply(placeCmd(TowerKind.tesla, 12, 4));
        g.apply(GameCommand(CommandType.startWave));
    }
    bool diverged = false;
    foreach (t; 0 .. 3000) {
        a.advance();
        b.advance();
        c.advance();
        assert(a.stateHash() == b.stateHash());
        diverged |= a.stateHash() != c.stateHash();
        if (t == 1500)
            foreach (g; all)
                g.apply(GameCommand(CommandType.startWave));
    }
    assert(diverged);
}

@nogc nothrow unittest {
    import wfc.reveal : Side, Window;

    // Reveal chapters: the road from a source at col 18 enters a window of cols 0 .. 9; creeps walk
    // in from col 9 and never outside the window, fog cells refuse towers, and clearing the
    // stage's wave uncovers the rest, keeping the towers.
    Game g;
    auto b = &g.boardForSetup();
    b.allocate(MapRect(20, 7));
    foreach (row; 0 .. 7)
        foreach (col; 0 .. 20)
            b.setCell(col, row, row == 3 && col >= 1 && col <= 18
                    ? cast(ubyte)(CellFlag.walk | CellFlag.road | (col == 18 ? CellFlag.source
                        : 0) | (col == 1 ? CellFlag.sink : 0)) : CellFlag.buildable);
    foreach (col; 1 .. 19)
        b.setExits(col, 3, cast(ubyte)((col > 1 ? 1 << HexDir.W : 0) | (col < 18 ? 1 << HexDir.E : 0)));
    b.plan.world = b.rect;
    b.plan.numStages = 2;
    b.plan.entrySide = Side.east;
    b.plan.windows[0] = Window(0, 0, 10, 7);
    b.plan.windows[1] = Window.of(b.rect);
    b.applyWindow(b.plan.window(0));
    g.begin(1);
    g.wavesPerStage = 1;
    g.waveLimit = 2;
    assert(g.apply(placeCmd(TowerKind.arrow, 14, 2)) == CommandError.hidden);
    assert(g.apply(placeCmd(TowerKind.arrow, 5, 2)) == CommandError.none);
    assert(g.apply(GameCommand(CommandType.startWave)) == CommandError.none);
    bool revealed = false, outside = false;
    foreach (t; 0 .. 20_000) {
        g.advance();
        foreach (ref c; g.creeps)
            if (c.alive && !g.board.visible(c.cell))
                outside = true;
        foreach (ref e; g.events)
            if (e.kind == EventKind.reveal) {
                assert(e.value == 1);
                revealed = true;
            }
        if (g.status != GameStatus.wave)
            break;
    }
    assert(!outside && revealed && g.status == GameStatus.waiting && g.board.stage == 1);
    assert(g.towerAt(5, 2) !is null);
    assert(g.board.numSources == 1 && g.board.sources[0] == offsetToCube(18, 3));
    assert(g.apply(placeCmd(TowerKind.arrow, 14, 2)) == CommandError.none);
}

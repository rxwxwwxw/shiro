// The enemy's planner. On Wednesday night it sizes up the defenses as they stand (towers, their
// crews, the terrain) by fighting Saturday's battle in its head, again and again, headless:
//
//   1. Mix: one probe per creep kind at the normal budget. How far each kind gets down the road
//      shows what the defense handles worst; that kind gets most of the attack (60%), the rest
//      is shared out by the same measure, so every Saturday still brings variety.
//   2. Capacity: a binary search on the budget (percent of normal) with that mix finds B*, the
//      biggest attack the defense survives.
//   3. Plan: Saturday comes at `overkillPct` (105) percent of B*: the defense as it stood on
//      Wednesday would fall, so Thursday and Friday are for the player to do better.
//
// Probes are ordinary deterministic games, so the plan is the same on every machine. The work is
// sliced (`step` runs a bounded number of ticks) so the View can keep drawing "night falls" while
// it thinks. Headless Model: no SDL, @nogc nothrow.
module campaign.director;

import campaign.fort;
import td.catalog;
import td.defs;
import td.game;
import wfc.map_session : MapSession;

/// What Saturday brings: a budget (percent of the rules' normal) and pick weights per creep kind.
struct AttackPlan {
    int budgetPct = 100;
    int[maxCreepKinds] weights;
    /// The biggest attack (percent) the defense was found to survive, and the overkill applied.
    int capacityPct;
    int overkillPct = 105;
    /// How far each kind got in its probe (permille of the road; -1: not probed).
    int[maxCreepKinds] reach = -1;
    /// Probes fought to find it.
    int probes;

    /// Run modifiers for a battle on this plan.
    void applyTo(ref RunModifiers m) const @nogc nothrow pure @safe {
        m.budgetPct = budgetPct;
        m.aimed = true;
        m.weights = weights;
    }
}

/// Crew effects per fort tower, captured when the director starts (crews are the story's
/// business; the probes only need the numbers).
struct CrewSnapshot {
    int[3][maxFortTowers] buffs;
    ubyte[maxFortTowers] crews;
    int count;

    void capture(ref const Game g) @nogc nothrow @safe {
        count = 0;
        foreach (ref t; g.towers)
            if (t.alive && count < maxFortTowers) {
                buffs[count] = [t.buffDamagePct, t.buffRangePct, t.buffCooldownPct];
                crews[count++] = t.crew;
            }
    }
}

enum DirectorStage : ubyte {
    idle,
    mix,
    capacity,
    done
}

struct Director {
    /// Planned attack: percent of B*, and the search bounds (percent of the normal budget).
    int overkillPct = 105, minPct = 10, maxPct = 1600;
    /// Share of the weight the defense's worst matchup gets (percent).
    int focusPct = 60;
    /// Ticks one probe may run before it counts as survived.
    uint probeTickCap = 60_000;

    private const(MapSession)* map;
    private const(Fort)* fort;
    private const(Catalog)* cat;
    private CrewSnapshot crews;
    private RunModifiers base;
    private uint seed;
    private DirectorStage stage_;
    private int kind;
    private int lo, hi, mid;
    private Game probe;
    private bool probing;
    private AttackPlan plan_;

    @disable this(this);

    DirectorStage stage() const @nogc nothrow pure @safe {
        return stage_;
    }

    bool done() const @nogc nothrow pure @safe {
        return stage_ == DirectorStage.done;
    }

    ref const(AttackPlan) plan() const return @nogc nothrow pure @safe {
        return plan_;
    }

    /// Starts planning a battle with `mods` (its waves and wave offset) against `f` on map `m`
    /// under `c`; `crewsNow` holds the crew buffs as they stand (fort order). All pointers must
    /// outlive the planning.
    void start(const(MapSession)* m, const(Fort)* f, const(Catalog)* c,
            ref const CrewSnapshot crewsNow, RunModifiers mods, uint seed_) @nogc nothrow @trusted {
        map = m;
        fort = f;
        cat = c;
        crews = crewsNow;
        base = mods;
        base.aimed = false;
        base.budgetPct = 0;
        seed = seed_;
        plan_ = AttackPlan.init;
        plan_.overkillPct = overkillPct;
        kind = -1;
        probing = false;
        stage_ = DirectorStage.mix;
        nextMixKind();
    }

    /// Thinks for up to `ticks` simulation ticks; true once the plan is ready.
    bool step(uint ticks) @nogc nothrow @trusted {
        while (ticks > 0 && stage_ != DirectorStage.done && stage_ != DirectorStage.idle) {
            if (!probing)
                beginProbe();
            immutable spent = runProbe(ticks);
            ticks -= spent < ticks ? spent : ticks;
            if (probing)
                break;
            finishProbe();
        }
        return done;
    }

    /// Plans in one go (tests and tools).
    ref const(AttackPlan) run() return @nogc nothrow @trusted {
        while (!step(uint.max)) {
        }
        return plan_;
    }

    // ---- probes ----

    private bool pickable(int k, int firstWave) const @nogc nothrow @safe {
        const d = &cat.creeps[k];
        return !d.boss && d.pickWeight > 0 && d.stats.cost > 0 && d.unlockWave <= firstWave + base.waves - 1;
    }

    private void nextMixKind() @nogc nothrow @safe {
        immutable firstWave = base.waveOffset + 1;
        do
            kind++;
        while (kind < cat.numCreeps && !pickable(kind, firstWave));
        if (kind >= cat.numCreeps)
            settleMix();
    }

    /// Turns the probes' reach into weights: the worst matchup gets `focusPct`, the rest share
    /// the remainder by reach (each at least 1, so variety survives).
    private void settleMix() @nogc nothrow @safe {
        int worst = -1;
        long others = 0;
        foreach (k; 0 .. cat.numCreeps)
            if (plan_.reach[k] >= 0 && (worst < 0 || plan_.reach[k] > plan_.reach[worst]))
                worst = k;
        foreach (k; 0 .. cat.numCreeps)
            if (plan_.reach[k] >= 0 && k != worst)
                others += plan_.reach[k] + 1;
        foreach (k; 0 .. cat.numCreeps) {
            if (plan_.reach[k] < 0)
                plan_.weights[k] = 0;
            else if (k == worst)
                plan_.weights[k] = others > 0 ? focusPct * 10 : 1000;
            else
                plan_.weights[k] = 1 + cast(int)((100 - focusPct) * 10L * (plan_.reach[k] + 1) / others);
        }
        stage_ = DirectorStage.capacity;
        lo = minPct;
        hi = maxPct;
    }

    private void beginProbe() @nogc nothrow @trusted {
        RunModifiers m = base;
        m.aimed = true;
        if (stage_ == DirectorStage.mix) {
            m.weights[] = 0;
            m.weights[kind] = 1;
            m.budgetPct = 100;
        } else {
            mid = (lo + hi + 1) / 2;
            m.weights = plan_.weights;
            m.budgetPct = mid;
        }
        probe.start(*map, seed, m, cat);
        fort.restore(probe);
        foreach (i, ref t; probe.towers)
            if (i < crews.count) {
                probe.setCrew(cast(int)i, crews.crews[i]);
                probe.setCrewBuff(cast(int)i, crews.buffs[i][0], crews.buffs[i][1], crews.buffs[i][2]);
            }
        probing = true;
        plan_.probes++;
    }

    /// Runs the probe up to `ticks`; returns the ticks used. Waves are called at once (the
    /// defense does nothing between them, so waiting changes nothing).
    private uint runProbe(uint ticks) @nogc nothrow @trusted {
        uint used = 0;
        while (used < ticks) {
            if (probe.status == GameStatus.lost || probe.status == GameStatus.won || probe.tick >= probeTickCap) {
                probing = false;
                break;
            }
            if (probe.status == GameStatus.waiting)
                probe.apply(GameCommand(CommandType.startWave));
            probe.advance();
            used++;
        }
        return used;
    }

    private void finishProbe() @nogc nothrow @trusted {
        if (stage_ == DirectorStage.mix) {
            plan_.reach[kind] = probe.reachPermille;
            nextMixKind();
            return;
        }
        // Capacity: survive means the lives held (a probe hitting the tick cap counts as held).
        if (probe.status != GameStatus.lost)
            lo = mid;
        else
            hi = mid - 1;
        if (lo >= hi) {
            plan_.capacityPct = lo;
            // Rounded up: never less than the overkill asked for.
            plan_.budgetPct = cast(int)((cast(long)lo * overkillPct + 99) / 100);
            if (plan_.budgetPct <= lo)
                plan_.budgetPct = lo + 1;
            stage_ = DirectorStage.done;
            probe.stop();
        }
    }
}

version (unittest) {
    import td.bot : Bot;
    import wfc.map_session : GenParams;

    /// Fights a battle on `plan` against `f` (crews as captured); true when the defense holds.
    private bool holds(ref const MapSession m, ref const Fort f, ref const CrewSnapshot crews,
            RunModifiers mods, ref const AttackPlan plan, int budgetPct, uint seed) @nogc nothrow @trusted {
        AttackPlan p = plan;
        p.budgetPct = budgetPct;
        p.applyTo(mods);
        Game g;
        g.start(m, seed, mods);
        f.restore(g);
        foreach (i, ref t; g.towers)
            g.setCrewBuff(cast(int)i, crews.buffs[i][0], crews.buffs[i][1], crews.buffs[i][2]);
        foreach (k; 0 .. 60_000) {
            if (g.status == GameStatus.waiting)
                g.apply(GameCommand(CommandType.startWave));
            g.advance();
            if (g.status == GameStatus.lost || g.status == GameStatus.won)
                break;
        }
        return g.status != GameStatus.lost;
    }
}

@nogc nothrow @trusted unittest {
    // A defense the bot built: the director finds what it can hold, aims at its weakness, and
    // plans 5% more than that. The plan is the same every time.
    auto ms = MapSession.create().value;
    scope (exit)
        MapSession.release(ms);
    GenParams gp;
    gp.cols = 56;
    gp.rows = 32;
    gp.radius = 6;
    gp.seed = 9;
    gp.reveal.enabled = false;
    assert(ms.regenerate(gp).isOk);
    static Fort f;
    f.begin(defaultCatalog);
    {
        Game g;
        g.start(*ms, 1);
        g.startPlanning();
        g.gold = 900;
        Bot bot;
        bot.setup(g);
        foreach (k; 0 .. 30)
            bot.act(g);
        f.save(g);
    }
    assert(f.numTowers >= 4);
    CrewSnapshot crews;
    crews.count = f.numTowers;
    RunModifiers mods;
    mods.waves = 3;
    mods.waveOffset = 4;
    static Director a, b;
    a.start(ms, &f, &defaultCatalog, crews, mods, 77);
    // Sliced: many small steps reach the same plan as one big run.
    int slices = 0;
    while (!a.step(500))
        slices++;
    b.start(ms, &f, &defaultCatalog, crews, mods, 77);
    const pb = &b.run();
    const pa = &a.plan();
    assert(slices > 10 && pa.budgetPct == pb.budgetPct && pa.weights == pb.weights && pa.probes == pb.probes);
    assert(pa.capacityPct >= a.minPct && pa.budgetPct > pa.capacityPct);
    assert(pa.budgetPct >= pa.capacityPct * 105 / 100);
    // The worst matchup carries the attack; the others still come.
    int worst = -1, sum = 0, kinds = 0;
    foreach (k; 0 .. defaultCatalog.numCreeps) {
        sum += pa.weights[k];
        kinds += pa.weights[k] > 0;
        if (pa.reach[k] >= 0 && (worst < 0 || pa.reach[k] > pa.reach[worst]))
            worst = k;
    }
    assert(worst >= 0 && pa.weights[worst] * 100 >= sum * 55 && kinds >= 2);
    // Held at capacity, lost to the plan.
    assert(holds(*ms, f, crews, mods, *pa, pa.capacityPct, 77));
    assert(!holds(*ms, f, crews, mods, *pa, pa.budgetPct, 77));
}

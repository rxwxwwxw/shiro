// Particle effects for the tower defense game: explosions, frost, lightning, fire, deaths, gold.
// Effects are spawned from the simulation's per-tick events (and a little ambient emission from
// burning creeps, napalm and ley stones) and live entirely in the View: they never feed back into
// the Model, so they can use a cheap float RNG and real frame time. Fixed pools, no allocation
// per frame; emission scales down with the renderer's quality factor on slow machines.
module gfx.particles;

import bindings.sdl3.sdl;
import core.stdc.math : cosf, sinf, sqrtf;
import core.stdc.stdlib : free, malloc;
import gfx.camera;
import gfx.hex_mesh : MapMesh;
import gfx.iso : IsoPoint, squash;
import gfx.td_overlay : isoPerX, isoPerY, towerTop, worldToScreen;
import td.defs;
import td.game;

enum int maxParticles = 8192, maxBolts = 96, maxRings = 128;

private struct Bolt {
    float x0, y0, h0, x1, y1, h1;
    float life, maxLife;
    uint seed;
    bool big;
}

private struct Ring {
    float x, y, r0, r1, life, maxLife;
    SDL_FColor color;
}

struct Particles {
    // Structure of arrays: world position (td units) and lift (iso units), velocities per second.
    private float* x, y, h, vx, vy, vh, life, maxLife, size0, size1, gravity, drag;
    private SDL_FColor* c0, c1;
    private bool* additive;
    private int count;
    private Bolt[maxBolts] bolts;
    private Ring[maxRings] rings;
    private SDL_Texture* dot;
    private SDL_Vertex* verts;
    private int* idx;
    private uint rng = 0x2545F491u;
    /// 0..1: fraction of the full emission to spawn (follows the mesh quality factor).
    float density = 1;
    private int[32] leyCells;
    private int numLey;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        float*[12] fields = [x, y, h, vx, vy, vh, life, maxLife, size0, size1, gravity, drag];
        foreach (p; fields)
            free(p);
        free(c0);
        free(c1);
        free(additive);
        free(verts);
        free(idx);
        if (dot !is null)
            SDL_DestroyTexture(dot);
    }

    /// Allocates the pools and the soft round particle texture.
    bool open(SDL_Renderer* r) @nogc nothrow @trusted {
        float**[12] fields = [
            &x, &y, &h, &vx, &vy, &vh, &life, &maxLife, &size0, &size1, &gravity, &drag
        ];
        foreach (k; 0 .. 12) {
            *fields[k] = cast(float*)malloc(maxParticles * float.sizeof);
            if (*fields[k] is null)
                return false;
        }
        c0 = cast(SDL_FColor*)malloc(maxParticles * SDL_FColor.sizeof);
        c1 = cast(SDL_FColor*)malloc(maxParticles * SDL_FColor.sizeof);
        additive = cast(bool*)malloc(maxParticles);
        verts = cast(SDL_Vertex*)malloc(maxParticles * 4 * SDL_Vertex.sizeof);
        idx = cast(int*)malloc(maxParticles * 6 * int.sizeof);
        if (!c0 || !c1 || !additive || !verts || !idx)
            return false;
        // Soft dot: white, alpha falling off with a smooth curve.
        enum int n = 32;
        ubyte[n * n * 4] px;
        foreach (j; 0 .. n)
            foreach (i; 0 .. n) {
                immutable dx = (i + 0.5f) / n * 2 - 1, dy = (j + 0.5f) / n * 2 - 1;
                float a = 1 - sqrtf(dx * dx + dy * dy);
                a = a < 0 ? 0 : a * a * (3 - 2 * a);
                immutable o = (j * n + i) * 4;
                px[o] = px[o + 1] = px[o + 2] = 255;
                px[o + 3] = cast(ubyte)(a * 255);
            }
        dot = SDL_CreateTexture(r, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, n, n);
        if (dot is null || !SDL_UpdateTexture(dot, null, px.ptr, n * 4))
            return false;
        return true;
    }

    bool ready() const @nogc nothrow pure @safe {
        return dot !is null;
    }

    bool busy() const @nogc nothrow @safe {
        if (count > 0)
            return true;
        foreach (ref b; bolts)
            if (b.life > 0)
                return true;
        foreach (ref r; rings)
            if (r.life > 0)
                return true;
        return false;
    }

    /// Forgets every effect (a new map).
    void reset(ref const Game g) @nogc nothrow @trusted {
        count = 0;
        foreach (ref b; bolts)
            b.life = 0;
        foreach (ref r; rings)
            r.life = 0;
        numLey = 0;
        if (!g.active)
            return;
        const b = &g.board();
        foreach (i; 0 .. b.rect.cellCount)
            if (b.specialAt(i) == SpecialKind.leyStone && numLey < leyCells.length)
                leyCells[numLey++] = cast(int)i;
    }

    private float rnd() @nogc nothrow @safe {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return (rng >> 8) * (1.0f / 16_777_216.0f);
    }

    private float spread(float a) @nogc nothrow @safe {
        return (rnd() * 2 - 1) * a;
    }

    /// Spawns one particle. Speeds are in world units (or iso units for `vh`) per second.
    private void spawn(float px, float py, float ph, float pvx, float pvy, float pvh, float lt, float s0,
            float s1, SDL_FColor a, SDL_FColor b, bool add, float grav = 0, float drg = 0) @nogc nothrow @trusted {
        if (count == maxParticles)
            return;
        immutable i = count++;
        x[i] = px;
        y[i] = py;
        h[i] = ph;
        vx[i] = pvx;
        vy[i] = pvy;
        vh[i] = pvh;
        life[i] = maxLife[i] = lt;
        size0[i] = s0;
        size1[i] = s1;
        c0[i] = a;
        c1[i] = b;
        additive[i] = add;
        gravity[i] = grav;
        drag[i] = drg;
    }

    /// How many of `n` particles to really spawn at the current density.
    private int scaled(int n) @nogc nothrow @safe {
        immutable f = n * density;
        immutable k = cast(int)f;
        return k + (rnd() < f - k ? 1 : 0);
    }

    /// Burst of `n` particles flying out from a point.
    private void burst(float px, float py, float ph, int n, float speed, float up, float lt, float s0,
            float s1, SDL_FColor a, SDL_FColor b, bool add, float grav = 0, float drg = 0) @nogc nothrow @trusted {
        foreach (k; 0 .. scaled(n)) {
            immutable ang = rnd() * 6.2831853f, sp = speed * (0.35f + 0.65f * rnd());
            spawn(px, py, ph, cosf(ang) * sp, sinf(ang) * sp, up * (0.4f + 0.6f * rnd()),
                    lt * (0.6f + 0.4f * rnd()), s0 * (0.7f + 0.6f * rnd()), s1, a, b, add, grav, drg);
        }
    }

    private void ring(float px, float py, float r0, float r1, float lt, SDL_FColor col) @nogc nothrow @safe {
        foreach (ref r; rings)
            if (r.life <= 0) {
                r = Ring(px, py, r0, r1, lt, lt, col);
                return;
            }
    }

    private void bolt(float ax, float ay, float ah, float bx, float by, float bh, bool big) @nogc nothrow @safe {
        foreach (ref b; bolts)
            if (b.life <= 0) {
                b = Bolt(ax, ay, ah, bx, by, bh, 0.16f, 0.16f, rng, big);
                rng = rng * 1664525u + 1013904223u;
                return;
            }
    }

    /// Effects for one tick's events.
    void onEvents(const(SimEvent)[] events) @nogc nothrow @trusted {
        foreach (ref e; events)
            onEvent(e);
    }

    private void onEvent(ref const SimEvent e) @nogc nothrow @trusted {
        enum SDL_FColor clear = SDL_FColor(0, 0, 0, 0);
        immutable float ex = e.x, ey = e.y;
        final switch (e.kind) {
        case EventKind.fired:
            if (e.a == TowerKind.cannon) {
                burst(ex, ey, towerTop, 6, 500, 1.5f, 0.18f, 0.35f, 0.7f, SDL_FColor(1, 0.85f,
                        0.4f, 1), SDL_FColor(1, 0.3f, 0, 0), true);
                burst(ex, ey, towerTop, 5, 250, 1.2f, 0.9f, 0.3f, 0.8f, SDL_FColor(0.5f, 0.5f,
                        0.5f, 0.5f), SDL_FColor(0.4f, 0.4f, 0.4f, 0), false, 0, 2);
            } else if (e.a == TowerKind.frost)
                burst(ex, ey, towerTop, 5, 300, 0.8f, 0.3f, 0.18f, 0.05f, SDL_FColor(0.8f, 0.95f,
                        1, 1), SDL_FColor(0.4f, 0.7f, 1, 0), true);
            else if (e.a == TowerKind.arrow)
                burst(ex, ey, towerTop, 2, 150, 0.4f, 0.2f, 0.12f, 0.02f, SDL_FColor(1, 0.95f,
                        0.8f, 0.8f), clear, true);
            break;
        case EventKind.hit:
            burst(ex, ey, 0.35f, 5, 700, 1.5f, 0.25f, 0.1f, 0.02f, SDL_FColor(1, 0.9f, 0.6f, 1),
                    SDL_FColor(1, 0.5f, 0.1f, 0), true, -6);
            break;
        case EventKind.explode:
            explode(e);
            break;
        case EventKind.chain:
            immutable startH = e.b == 0 ? towerTop + 0.2f : 0.35f;
            bolt(ex, ey, startH, e.x2, e.y2, 0.35f, branchOf(cast(Stage)e.a) == 1);
            burst(e.x2, e.y2, 0.35f, branchOf(cast(Stage)e.a) == 1 ? 18 : 7, 900, 2, 0.25f, 0.14f,
                    0.02f, SDL_FColor(0.85f, 0.85f, 1, 1), SDL_FColor(0.4f, 0.4f, 1, 0), true, -8);
            if (e.b == 0)
                burst(ex, ey, towerTop + 0.2f, 4, 300, 1, 0.2f, 0.3f, 0.05f, SDL_FColor(0.8f,
                        0.8f, 1, 1), clear, true);
            break;
        case EventKind.frostPulse:
            ring(ex, ey, 200, e.value, 0.55f, SDL_FColor(0.7f, 0.92f, 1, 0.8f));
            foreach (k; 0 .. scaled(40)) {
                immutable ang = rnd() * 6.2831853f, d = sqrtf(rnd()) * e.value;
                spawn(ex + cosf(ang) * d, ey + sinf(ang) * d, 0.8f + rnd() * 1.2f, spread(40),
                        spread(40), -0.6f - rnd() * 0.6f, 1.2f, 0.12f, 0.05f, SDL_FColor(1, 1, 1,
                            0.95f), SDL_FColor(0.7f, 0.9f, 1, 0), true);
            }
            break;
        case EventKind.flame:
            flame(e);
            break;
        case EventKind.death:
            SDL_FColor body;
            final switch (cast(CreepKind)e.a) {
            case CreepKind.grunt:
                body = SDL_FColor(0.6f, 0.8f, 0.4f, 1);
                break;
            case CreepKind.runner:
                body = SDL_FColor(1, 0.85f, 0.35f, 1);
                break;
            case CreepKind.brute:
                body = SDL_FColor(0.6f, 0.5f, 0.45f, 1);
                break;
            case CreepKind.swarm:
                body = SDL_FColor(0.85f, 0.5f, 0.95f, 1);
                break;
            case CreepKind.boss:
                body = SDL_FColor(0.95f, 0.3f, 0.3f, 1);
                break;
            }
            immutable big = e.a == CreepKind.boss ? 4 : 1;
            burst(ex, ey, 0.3f, 10 * big, 600, 2.5f, 0.6f, 0.16f, 0.04f, body, SDL_FColor(body.r,
                    body.g, body.b, 0), false, -9, 1);
            burst(ex, ey, 0.3f, 6 * big, 250, 1, 0.8f, 0.3f, 0.9f, SDL_FColor(0.9f, 0.9f, 0.85f,
                    0.45f), clear, false, 0, 2);
            // Gold coins hop out.
            foreach (k; 0 .. (e.value > 8 ? 8 : e.value) * (big > 1 ? 3 : 1)) {
                spawn(ex, ey, 0.4f, spread(250), spread(250), 3 + rnd() * 2, 0.9f, 0.13f, 0.1f,
                        SDL_FColor(1, 0.88f, 0.25f, 1), SDL_FColor(1, 0.7f, 0.1f, 0), true, -10);
            }
            break;
        case EventKind.leak:
            ring(ex, ey, 100, 1400, 0.6f, SDL_FColor(1, 0.25f, 0.2f, 0.9f));
            burst(ex, ey, 0.5f, 16, 700, 3, 0.6f, 0.2f, 0.05f, SDL_FColor(1, 0.3f, 0.2f, 1), clear, true, -8);
            break;
        case EventKind.built:
            ring(ex, ey, 300, 900, 0.4f, SDL_FColor(0.9f, 0.8f, 0.6f, 0.7f));
            burst(ex, ey, 0.1f, 14, 400, 0.6f, 0.8f, 0.3f, 0.8f, SDL_FColor(0.75f, 0.65f, 0.5f,
                    0.6f), clear, false, 0, 2.5f);
            break;
        case EventKind.upgraded:
            ring(ex, ey, 200, 1100, 0.5f, SDL_FColor(1, 0.9f, 0.4f, 0.9f));
            foreach (k; 0 .. scaled(30)) {
                immutable ang = rnd() * 6.2831853f, d = rnd() * 450;
                spawn(ex + cosf(ang) * d, ey + sinf(ang) * d, rnd() * 0.5f, 0, 0, 1.2f + rnd() * 1.5f,
                        1.0f, 0.14f, 0.02f, SDL_FColor(1, 0.95f, 0.5f, 1), SDL_FColor(1, 0.7f, 0.2f, 0), true);
            }
            break;
        case EventKind.sold:
            burst(ex, ey, 0.5f, 20, 400, 4, 0.9f, 0.13f, 0.1f, SDL_FColor(1, 0.88f, 0.25f, 1),
                    SDL_FColor(1, 0.7f, 0.1f, 0), true, -10);
            burst(ex, ey, 0.1f, 12, 350, 0.6f, 0.9f, 0.35f, 0.9f, SDL_FColor(0.7f, 0.65f, 0.6f,
                    0.5f), clear, false, 0, 2);
            break;
        case EventKind.napalm:
            burst(ex, ey, 0.2f, 24, 500, 2, 0.6f, 0.3f, 0.1f, SDL_FColor(1, 0.75f, 0.2f, 1),
                    SDL_FColor(0.9f, 0.15f, 0, 0), true, -3);
            break;
        case EventKind.waveClear:
            if (e.a == TowerKind.mine)
                burst(ex, ey, 0.8f, 14, 300, 4, 1.0f, 0.15f, 0.1f, SDL_FColor(1, 0.88f, 0.25f,
                        1), SDL_FColor(1, 0.7f, 0.1f, 0), true, -9);
            break;
        case EventKind.waveStart:
        case EventKind.gameOver:
        case EventKind.victory:
        case EventKind.reveal:
            break;
        }
    }

    private void explode(ref const SimEvent e) @nogc nothrow @trusted {
        enum SDL_FColor clear = SDL_FColor(0, 0, 0, 0);
        immutable float ex = e.x, ey = e.y, r = e.value;
        immutable kind = cast(ProjKind)e.a;
        if (kind == ProjKind.shard) {
            ring(ex, ey, 100, r, 0.35f, SDL_FColor(0.75f, 0.95f, 1, 0.9f));
            burst(ex, ey, 0.4f, 16, r * 1.4f, 1.5f, 0.45f, 0.16f, 0.04f, SDL_FColor(0.9f, 0.98f, 1,
                    1), SDL_FColor(0.5f, 0.8f, 1, 0), true, -5, 1.5f);
            burst(ex, ey, 0.2f, 6, r * 0.4f, 0.3f, 0.9f, 0.4f, 0.8f, SDL_FColor(0.8f, 0.9f, 1,
                    0.35f), clear, false, 0, 2);
            return;
        }
        immutable s = kind == ProjKind.bomblet ? 0.55f : (r > 1300 ? 1.5f : 1.0f);
        // Flash, fireball, sparks, smoke, debris and a shock ring.
        spawn(ex, ey, 0.3f, 0, 0, 0, 0.12f, 1.2f * s, 1.6f * s, SDL_FColor(1, 0.95f, 0.75f, 1),
                SDL_FColor(1, 0.6f, 0.2f, 0), true);
        burst(ex, ey, 0.3f, cast(int)(12 * s), r * 0.9f, 1.2f, 0.4f, 0.45f * s, 0.15f, SDL_FColor(1,
                0.7f, 0.25f, 1), SDL_FColor(0.8f, 0.15f, 0, 0), true, 0, 3);
        burst(ex, ey, 0.3f, cast(int)(14 * s), r * 2.2f, 3, 0.5f, 0.1f, 0.02f, SDL_FColor(1, 0.9f,
                0.5f, 1), SDL_FColor(1, 0.4f, 0, 0), true, -9, 0.5f);
        burst(ex, ey, 0.4f, cast(int)(9 * s), r * 0.5f, 1.4f, 1.4f, 0.4f * s, 1.1f * s,
                SDL_FColor(0.35f, 0.33f, 0.32f, 0.6f), SDL_FColor(0.5f, 0.5f, 0.5f, 0), false, 0, 2);
        burst(ex, ey, 0.2f, cast(int)(8 * s), r * 1.3f, 3.5f, 0.8f, 0.09f, 0.08f, SDL_FColor(0.3f,
                0.25f, 0.2f, 1), SDL_FColor(0.3f, 0.25f, 0.2f, 0), false, -12, 0.5f);
        ring(ex, ey, r * 0.2f, r * 1.1f, 0.3f, SDL_FColor(1, 0.85f, 0.6f, 0.7f));
        cast(void)clear;
    }

    private void flame(ref const SimEvent e) @nogc nothrow @trusted {
        immutable float ex = e.x, ey = e.y;
        float dx = e.x2 - ex, dy = e.y2 - ey;
        immutable dl = sqrtf(dx * dx + dy * dy);
        if (dl < 1)
            return;
        dx /= dl;
        dy /= dl;
        immutable wide = branchOf(cast(Stage)e.a) == 0 ? 0.75f : 0.45f;
        immutable range = e.value;
        foreach (k; 0 .. scaled(14)) {
            immutable side = spread(wide);
            immutable fx = dx - dy * side, fy = dy + dx * side;
            immutable sp = range * (2.2f + rnd() * 0.8f);
            spawn(ex + dx * 300, ey + dy * 300, towerTop * 0.7f, fx * sp, fy * sp, -1.2f,
                    0.4f + rnd() * 0.1f, 0.15f, 0.55f, SDL_FColor(1, 0.9f, 0.45f, 1),
                    SDL_FColor(0.9f, 0.15f, 0.02f, 0), true, 0, 1.5f);
        }
        if (rnd() < 0.5f)
            spawn(e.x2 + spread(200), e.y2 + spread(200), 0.4f, 0, 0, 1.2f, 1.1f, 0.25f, 0.8f,
                    SDL_FColor(0.3f, 0.28f, 0.27f, 0.45f), SDL_FColor(0.4f, 0.4f, 0.4f, 0), false, 0, 1);
    }

    /// Steady emitters that follow game state rather than events: burning creeps, napalm patches
    /// and ley stones.
    void ambient(ref const Game g, float dt, float time) @nogc nothrow @trusted {
        if (!g.active)
            return;
        immutable rate = dt * density;
        foreach (ref c; g.creeps)
            if (c.alive && c.burnTicks > 0 && rnd() < 18 * rate)
                spawn(c.x + spread(150), c.y + spread(150), 0.4f, spread(40), spread(40), 1.6f,
                        0.45f, 0.16f, 0.03f, SDL_FColor(1, 0.75f, 0.2f, 1), SDL_FColor(1, 0.2f, 0, 0), true);
        foreach (ref p; g.patches)
            if (p.alive)
                foreach (k; 0 .. 3)
                    if (rnd() < 14 * rate) {
                        immutable ang = rnd() * 6.2831853f, d = sqrtf(rnd()) * p.radius;
                        spawn(p.x + cosf(ang) * d, p.y + sinf(ang) * d, 0.05f, 0, 0, 1.0f + rnd(),
                                0.5f, 0.28f, 0.05f, SDL_FColor(1, 0.7f, 0.2f, 0.9f),
                                SDL_FColor(0.9f, 0.1f, 0, 0), true);
                    }
        const b = &g.board();
        foreach (k; 0 .. numLey)
            if (rnd() < 3 * rate) {
                int wx, wy;
                immutable c = b.rect.cellAt(leyCells[k]);
                cellWorld(c, wx, wy);
                spawn(wx + spread(350), wy + spread(300), 0.2f, 0, 0, 0.7f, 1.6f, 0.12f, 0.02f,
                        SDL_FColor(0.5f, 1, 1, 0.9f), SDL_FColor(0.3f, 0.6f, 1, 0), true);
            }
        cast(void)time;
    }

    /// Ages and moves everything by `dt` seconds.
    void update(float dt) @nogc nothrow @trusted {
        int i = 0;
        while (i < count) {
            life[i] -= dt;
            if (life[i] <= 0) {
                // Swap-remove keeps the pool dense.
                immutable last = --count;
                x[i] = x[last];
                y[i] = y[last];
                h[i] = h[last];
                vx[i] = vx[last];
                vy[i] = vy[last];
                vh[i] = vh[last];
                life[i] = life[last];
                maxLife[i] = maxLife[last];
                size0[i] = size0[last];
                size1[i] = size1[last];
                c0[i] = c0[last];
                c1[i] = c1[last];
                additive[i] = additive[last];
                gravity[i] = gravity[last];
                drag[i] = drag[last];
                continue;
            }
            immutable damp = 1 - (drag[i] * dt > 0.9f ? 0.9f : drag[i] * dt);
            vx[i] *= damp;
            vy[i] *= damp;
            vh[i] = vh[i] * damp + gravity[i] * dt;
            x[i] += vx[i] * dt;
            y[i] += vy[i] * dt;
            h[i] += vh[i] * dt;
            // Bounce once off the ground, then settle.
            if (h[i] < 0) {
                h[i] = 0;
                vh[i] = -vh[i] * 0.35f;
                vx[i] *= 0.6f;
                vy[i] *= 0.6f;
            }
            i++;
        }
        foreach (ref b; bolts)
            if (b.life > 0)
                b.life -= dt;
        foreach (ref r; rings)
            if (r.life > 0)
                r.life -= dt;
    }

    void draw(SDL_Renderer* r, ref const Camera cam, ref const MapMesh mesh) @nogc nothrow @trusted {
        if (dot is null)
            return;
        immutable z = cam.zoom;
        // Rings and bolts: untextured geometry, additive.
        int nv = 0, ni = 0;
        enum int sides = 32;
        foreach (ref rg; rings) {
            if (rg.life <= 0 || nv + sides * 2 > maxParticles * 4 - 8)
                continue;
            immutable f = 1 - rg.life / rg.maxLife;
            immutable rad = rg.r0 + (rg.r1 - rg.r0) * (1 - (1 - f) * (1 - f));
            immutable c = worldToScreen(cam, mesh, rg.x, rg.y, 0.05f);
            immutable rx = rad * isoPerX * z, ry = rad * isoPerY * squash * z;
            immutable w = (0.18f * (1 - f) + 0.04f) * z + 1;
            SDL_FColor col = rg.color;
            col.a *= 1 - f;
            SDL_FColor inner = col;
            inner.a = 0;
            immutable base = nv;
            foreach (k; 0 .. sides) {
                immutable a = k * (6.2831853f / sides);
                immutable cx = cosf(a), sy = sinf(a);
                verts[nv++] = SDL_Vertex(SDL_FPoint(c.x + cx * rx, c.y + sy * ry), col, SDL_FPoint(0, 0));
                verts[nv++] = SDL_Vertex(SDL_FPoint(c.x + cx * (rx - w), c.y + sy * (ry - w * squash)),
                        inner, SDL_FPoint(0, 0));
            }
            foreach (k; 0 .. sides) {
                immutable a = base + 2 * k, b = base + 2 * ((k + 1) % sides);
                idx[ni++] = a;
                idx[ni++] = b;
                idx[ni++] = b + 1;
                idx[ni++] = a;
                idx[ni++] = b + 1;
                idx[ni++] = a + 1;
            }
        }
        foreach (ref bt; bolts) {
            if (bt.life <= 0)
                continue;
            immutable a = worldToScreen(cam, mesh, bt.x0, bt.y0, bt.h0), b = worldToScreen(cam,
                    mesh, bt.x1, bt.y1, bt.h1);
            immutable alpha = bt.life / bt.maxLife;
            // Re-jag every frame so the bolt crackles.
            uint s = bt.seed ^ cast(uint)(bt.life * 1000);
            float jit() {
                s = s * 1664525u + 1013904223u;
                return ((s >> 8) * (1.0f / 16_777_216.0f)) * 2 - 1;
            }

            enum int segs = 8;
            IsoPoint prev = a;
            immutable dx = b.x - a.x, dy = b.y - a.y;
            immutable len = sqrtf(dx * dx + dy * dy) + 1e-3f;
            immutable nx = -dy / len, ny = dx / len;
            foreach (k; 1 .. segs + 1) {
                immutable t = cast(float)k / segs;
                immutable off = k == segs ? 0 : jit() * len * 0.12f;
                immutable p = IsoPoint(a.x + dx * t + nx * off, a.y + dy * t + ny * off);
                foreach (pass; 0 .. 2) {
                    if (nv + 4 > maxParticles * 4 || ni + 6 > maxParticles * 6)
                        break;
                    immutable w = (pass == 0 ? (bt.big ? 0.32f : 0.2f) : (bt.big ? 0.1f : 0.06f)) * z + (pass == 0 ? 2
                            : 1);
                    immutable col = pass == 0 ? SDL_FColor(0.45f, 0.5f, 1, 0.45f * alpha) : SDL_FColor(0.95f,
                            0.95f, 1, alpha);
                    immutable sx = p.x - prev.x, sy = p.y - prev.y;
                    immutable sl = sqrtf(sx * sx + sy * sy) + 1e-3f;
                    immutable ox = -sy / sl * w * 0.5f, oy = sx / sl * w * 0.5f;
                    immutable base = nv;
                    verts[nv++] = SDL_Vertex(SDL_FPoint(prev.x + ox, prev.y + oy), col, SDL_FPoint(0, 0));
                    verts[nv++] = SDL_Vertex(SDL_FPoint(p.x + ox, p.y + oy), col, SDL_FPoint(0, 0));
                    verts[nv++] = SDL_Vertex(SDL_FPoint(p.x - ox, p.y - oy), col, SDL_FPoint(0, 0));
                    verts[nv++] = SDL_Vertex(SDL_FPoint(prev.x - ox, prev.y - oy), col, SDL_FPoint(0, 0));
                    idx[ni++] = base;
                    idx[ni++] = base + 1;
                    idx[ni++] = base + 2;
                    idx[ni++] = base;
                    idx[ni++] = base + 2;
                    idx[ni++] = base + 3;
                }
                prev = p;
            }
        }
        if (ni > 0) {
            SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_ADD);
            SDL_RenderGeometry(r, null, verts, nv, idx, ni);
            SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
        }
        // Particles: smoke and debris blended first, then glowing ones added on top.
        foreach (pass; 0 .. 2) {
            nv = ni = 0;
            immutable wantAdd = pass == 1;
            foreach (i; 0 .. count) {
                if (additive[i] != wantAdd)
                    continue;
                immutable f = 1 - life[i] / maxLife[i];
                immutable p = worldToScreen(cam, mesh, x[i], y[i], h[i]);
                immutable sz = (size0[i] + (size1[i] - size0[i]) * f) * z * 0.5f + 0.75f;
                immutable a = c0[i], b = c1[i];
                immutable col = SDL_FColor(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f,
                        a.b + (b.b - a.b) * f, a.a + (b.a - a.a) * f);
                immutable base = nv;
                verts[nv++] = SDL_Vertex(SDL_FPoint(p.x - sz, p.y - sz), col, SDL_FPoint(0, 0));
                verts[nv++] = SDL_Vertex(SDL_FPoint(p.x + sz, p.y - sz), col, SDL_FPoint(1, 0));
                verts[nv++] = SDL_Vertex(SDL_FPoint(p.x + sz, p.y + sz), col, SDL_FPoint(1, 1));
                verts[nv++] = SDL_Vertex(SDL_FPoint(p.x - sz, p.y + sz), col, SDL_FPoint(0, 1));
                idx[ni++] = base;
                idx[ni++] = base + 1;
                idx[ni++] = base + 2;
                idx[ni++] = base;
                idx[ni++] = base + 2;
                idx[ni++] = base + 3;
            }
            if (ni == 0)
                continue;
            SDL_SetTextureBlendMode(dot, wantAdd ? SDL_BLENDMODE_ADD : SDL_BLENDMODE_BLEND);
            SDL_RenderGeometry(r, dot, verts, nv, idx, ni);
        }
    }
}

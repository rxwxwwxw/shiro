// Noise-first terrain: a height field (fractal simplex noise with a falloff to the sea at the map
// edge) and a river field are sampled per cell before WFC runs. Each cell is then classed as
// water, shore or land of a target level (with or without river tiles allowed). Each class maps
// to the set of tile states it may collapse to, so hills, mountains, lakes and rivers follow the
// noise, while WFC still picks the exact tiles that join up. Headless Model.
module wfc.terrain;

import core.noise : SimplexNoise;
import core.stdc.stdlib : calloc, free;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.rules;
import wfc.tile_data;

struct TerrainParams {
    /// Shape terrain from noise (off = WFC's own unconstrained terrain).
    bool enabled = true;
    /// Height noise: cycles per cell and octaves.
    float frequency = 0.03f;
    int octaves = 4;
    /// Heights (0..1) below this are water.
    float seaLevel = 0.30f;
    /// Water-side band around the sea level that may be coast or low grass.
    float shoreBand = 0.06f;
    /// Cells within this many of the map edge sink toward the sea.
    int edgeFalloff = 5;
    /// Land above the sea is split into this many levels (1 .. levelsCount).
    int landLevels = levelsCount;
    /// Rivers run along the zero line of a second noise; cells within `riverWidth` of it may hold
    /// river tiles.
    float riverFrequency = 0.025f;
    float riverWidth = 0.05f;
    /// Land at or above this height is a mountain peak (impassable).
    float peakHeight = 0.86f;
}

/// Terrain classes.
enum TerrainClass : ubyte {
    water,
    shore,
    /// land + level (0 .. 4), and riverLand + level where river tiles are allowed.
    land,
    riverLand = land + levelsCount,
    count = riverLand + levelsCount
}

/// Per-cell terrain classes and peaks for one map.
struct TerrainField {
    MapRect rect;
    private ubyte* cls;
    private ubyte* peak;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(cls);
        free(peak);
    }

    bool allocated() const @nogc nothrow pure @safe {
        return cls !is null;
    }

    /// Samples the noise for every cell of `rect`.
    void build(const MapRect rect, const TerrainParams p, uint seed) @nogc nothrow @trusted {
        free(cls);
        free(peak);
        this.rect = rect;
        cls = cast(ubyte*)calloc(rect.cellCount, 1);
        peak = cast(ubyte*)calloc(rect.cellCount, 1);
        assert(cls !is null && peak !is null, "terrain allocation failed");
        auto height = SimplexNoise(seed ^ 0x7E44A1u);
        auto river = SimplexNoise(seed ^ 0x51E3B7u);
        immutable levels = p.landLevels < 1 ? 1 : (p.landLevels > levelsCount ? levelsCount : p.landLevels);
        foreach (i; 0 .. rect.cellCount) {
            immutable o = cubeToOffset(rect.cellAt(i));
            // Hex centers: columns are sqrt(3)/2 apart in units of the row step.
            immutable x = o.col + (o.row & 1) * 0.5f, z = o.row * 0.866f;
            float h = (height.fbm(x * p.frequency, z * p.frequency, p.octaves) + 1.0f) * 0.5f;
            int edge = o.col < o.row ? o.col : o.row;
            if (rect.cols - 1 - o.col < edge)
                edge = rect.cols - 1 - o.col;
            if (rect.rows - 1 - o.row < edge)
                edge = rect.rows - 1 - o.row;
            if (p.edgeFalloff > 0 && edge < p.edgeFalloff)
                h -= (p.edgeFalloff - edge) * 0.6f / p.edgeFalloff;
            ubyte c;
            if (h < p.seaLevel - p.shoreBand)
                c = TerrainClass.water;
            else if (h < p.seaLevel + p.shoreBand * 0.5f)
                c = TerrainClass.shore;
            else {
                float t = (h - p.seaLevel - p.shoreBand * 0.5f) / (1.0f - p.seaLevel - p.shoreBand * 0.5f);
                int lvl = cast(int)(t * levels);
                lvl = lvl < 0 ? 0 : (lvl >= levels ? levels - 1 : lvl);
                immutable r = river.fbm(x * p.riverFrequency, z * p.riverFrequency, 2);
                immutable wet = (r < 0 ? -r : r) < p.riverWidth;
                c = cast(ubyte)((wet ? TerrainClass.riverLand : TerrainClass.land) + lvl);
                peak[i] = h >= p.peakHeight;
            }
            cls[i] = c;
        }
        smooth();
    }

    /// Makes neighboring classes joinable by tiles: water never touches land (a shore cell sits
    /// between), and land steps at most one level between neighbors.
    private void smooth() @nogc nothrow @trusted {
        immutable n = rect.cellCount;
        foreach (i; 0 .. n) {
            if (cls[i] != TerrainClass.water)
                continue;
            immutable c = rect.cellAt(i);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                if (rect.contains(nc) && cls[rect.index(nc)] >= TerrainClass.land) {
                    cls[i] = TerrainClass.shore;
                    break;
                }
            }
        }
        foreach (pass; 0 .. levelsCount) {
            bool changed = false;
            foreach (i; 0 .. n) {
                immutable k = cast(TerrainClass)cls[i];
                if (k < TerrainClass.land)
                    continue;
                immutable c = rect.cellAt(i);
                int cap = levelsCount - 1;
                foreach (d; 0 .. numHexDirs) {
                    immutable nc = c.neighbor(cast(HexDir)d);
                    if (!rect.contains(nc))
                        continue;
                    immutable nk = cast(TerrainClass)cls[rect.index(nc)];
                    immutable lim = (nk < TerrainClass.land ? 0 : levelOf(nk)) + 1;
                    cap = lim < cap ? lim : cap;
                }
                if (levelOf(k) > cap) {
                    immutable base = k >= TerrainClass.riverLand ? TerrainClass.riverLand : TerrainClass.land;
                    cls[i] = cast(ubyte)(base + cap);
                    changed = true;
                }
            }
            if (!changed)
                break;
        }
    }

    TerrainClass classAt(const CubeCoord c) const @nogc nothrow @trusted {
        if (cls is null || !rect.contains(c))
            return TerrainClass.land;
        return cast(TerrainClass)cls[rect.index(c)];
    }

    bool isPeak(const CubeCoord c) const @nogc nothrow @trusted {
        return peak !is null && rect.contains(c) && peak[rect.index(c)] != 0;
    }

    /// Target level of a land class (0 for water and shore).
    static int levelOf(TerrainClass c) @nogc nothrow pure @safe {
        if (c >= TerrainClass.riverLand)
            return c - TerrainClass.riverLand;
        return c >= TerrainClass.land ? c - TerrainClass.land : 0;
    }
}

/// Tile-state sets allowed for each terrain class.
struct TerrainMasks {
    StateSet[TerrainClass.count] sets;

    static void build(ref TerrainMasks m, const(AdjacencyRules)* rules) @nogc nothrow @trusted {
        immutable waterTile = tileIdByName("WATER");
        foreach (ref s; m.sets)
            s = StateSet.init;
        foreach (id; 0 .. numStates) {
            immutable st = rules.states[id];
            const def = &tileList[st.tile];
            bool wet = false, river = false;
            int lo = int.max, hi = int.min;
            foreach (d; 0 .. numHexDirs) {
                immutable e = rules.stateEdges[id][d];
                wet |= e.type == EdgeType.water || e.type == EdgeType.coast;
                river |= e.type == EdgeType.river;
                lo = e.level < lo ? e.level : lo;
                hi = e.level > hi ? e.level : hi;
            }
            if (st.tile == waterTile) {
                m.sets[TerrainClass.water].set(id);
                m.sets[TerrainClass.shore].set(id);
                continue;
            }
            // Shore: coast pieces, river mouths and low grass, all at the bottom.
            if (lo == 0 && hi <= 1 && (wet || !def.isSlope || def.levelIncrement == 1))
                m.sets[TerrainClass.shore].set(id);
            // Land of level L: edges from two below to one above it, so neighbors and roads can step.
            // Low land may still take coast pieces, so a coastline can run past a shore cell.
            foreach (lvl; 0 .. levelsCount) {
                if (lo < lvl - 2 || hi > lvl + 2 || st.level > lvl || (wet && lvl > 1))
                    continue;
                if (!river)
                    m.sets[TerrainClass.land + lvl].set(id);
                m.sets[TerrainClass.riverLand + lvl].set(id);
            }
        }
    }

    const(StateSet)* forClass(TerrainClass c) const return @nogc nothrow pure @safe {
        return &sets[c];
    }
}

@nogc nothrow unittest {
    // Every class allows something; water is water only; land keeps rivers to river classes and
    // coast to the low levels; levels stay near their target.
    static AdjacencyRules rules;
    AdjacencyRules.build(rules);
    static TerrainMasks m;
    TerrainMasks.build(m, &rules);
    foreach (c; 0 .. TerrainClass.count)
        assert(m.sets[c].any);
    immutable water = tileIdByName("WATER");
    foreach (id; 0 .. numStates) {
        if (m.sets[TerrainClass.water].test(id))
            assert(rules.states[id].tile == water);
        foreach (lvl; 0 .. levelsCount)
            if (m.sets[TerrainClass.land + lvl].test(id)) {
                assert(rules.states[id].level <= lvl && rules.states[id].tile != water);
                foreach (d; 0 .. numHexDirs) {
                    assert(rules.stateEdges[id][d].type != EdgeType.river);
                    assert(lvl <= 1 || rules.stateEdges[id][d].type != EdgeType.water);
                    assert(rules.stateEdges[id][d].level + 2 >= lvl);
                }
            }
    }
}

@nogc nothrow unittest {
    // Deterministic, water at the edges, a mix of levels inside.
    TerrainParams p;
    TerrainField a, b;
    a.build(MapRect(96, 54), p, 7);
    b.build(MapRect(96, 54), p, 7);
    int[TerrainClass.count] hist;
    foreach (i; 0 .. a.rect.cellCount) {
        immutable c = a.rect.cellAt(i);
        assert(a.classAt(c) == b.classAt(c) && a.isPeak(c) == b.isPeak(c));
        hist[a.classAt(c)]++;
    }
    assert(a.classAt(offsetToCube(0, 0)) == TerrainClass.water);
    assert(a.classAt(offsetToCube(95, 53)) == TerrainClass.water);
    int levelsUsed = 0;
    foreach (lvl; 0 .. levelsCount)
        levelsUsed += hist[TerrainClass.land + lvl] + hist[TerrainClass.riverLand + lvl] > 0;
    assert(levelsUsed >= 3);
}

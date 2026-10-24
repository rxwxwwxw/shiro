// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Tile & prop look after the KayKit Medieval Hexagon Pack by Kay Lousberg. D port for the Shiro
// engine (View layer).
//
// Builds the pseudo-3D map mesh once per generation: flat triangles in projected iso space, in
// back-to-front row order so the painter's algorithm gives correct occlusion without a depth
// buffer. Each row is a separate chunk (row-local indices) so the renderer can cull and batch
// whole rows; the renderer expands visible rows into SDL_Vertex.
//
// Two looks share the row layout: flat-shaded procedural shapes (build with no model), or the
// Hex-Map-WFC terrain model (hex-terrain.glb) placed per cell, back-face culled, depth-sorted per
// instance and lit per vertex, to be drawn with the model's texture atlas.
module gfx.hex_mesh;

import core.math : cos, sin, sqrt;
import core.stdc.stdlib : calloc, free, malloc, qsort, realloc;
import core.stdc.string : memcpy;
import gfx.camera : Camera;
import gfx.glb;
import gfx.iso;
import td.defs : branchOf, linearLevels, maxTier, numStages, numTowerKinds, SpecialKind, Stage,
    stageAt, tierOf, TowerKind;
import td.game : Game, Tower;
import wfc.decorations : bridgeNames, buildingDefs, Decoration, DecoKind, mountainNames,
    numVillageProps, towerVariant, VillageProp, villagePropNames;
import wfc.hex;
import wfc.map_session : MapSession;
import wfc.reveal : Window;
import wfc.rules : EdgeInfo, TileState;
import wfc.tile_data;

struct MeshVert {
    float x, y;
    /// Packed 8-bit color, r in the low byte.
    uint rgba;
    /// Texture coordinates (textured meshes only).
    float u = 0, v = 0;
}

struct MeshOptions {
    bool decorations = true;
    bool outlines = false;
    /// Show the bevelled rim around each model tile top (the seams between tiles); off lights the
    /// rim like the flat top so tiles blend into a continuous surface.
    bool tileEdges = false;
    /// Debug view: color tops by elevation instead of terrain (the JS "Level Colors").
    bool levelColors = false;
    /// Use the terrain model's meshes and texture when a model is supplied to `build`.
    bool textured = true;
}

struct Rgb {
    float r, g, b;
}

uint pack(Rgb c, float shade = 1.0f, float alpha = 1.0f) @nogc nothrow pure @safe {
    static uint ch(float v) @nogc nothrow pure @safe {
        immutable x = cast(int)(v * 255.0f + 0.5f);
        return x < 0 ? 0 : (x > 255 ? 255 : x);
    }

    return ch(c.r * shade) | ch(c.g * shade) << 8 | ch(c.b * shade) << 16 | ch(alpha) << 24;
}

immutable Rgb[numEdgeTypes] edgeColor = [
    Rgb(0.50f, 0.72f, 0.33f), // grass
    Rgb(0.27f, 0.58f, 0.80f), // water
    Rgb(0.74f, 0.60f, 0.40f), // road (only used for bands)
    Rgb(0.38f, 0.70f, 0.90f), // river (only used for bands)
    Rgb(0.89f, 0.82f, 0.60f), // coast sand
];
immutable Rgb[levelsCount] levelColor = [
    Rgb(0.20f, 0.45f, 0.80f), Rgb(0.25f, 0.70f, 0.45f), Rgb(0.85f, 0.80f, 0.30f),
    Rgb(0.90f, 0.55f, 0.25f), Rgb(0.85f, 0.30f, 0.30f)
];
private enum Rgb dirt = Rgb(0.55f, 0.43f, 0.30f);
private enum Rgb waterWall = Rgb(0.20f, 0.42f, 0.60f);
private enum Rgb unsolved = Rgb(0.65f, 0.12f, 0.12f);
private enum Rgb outline = Rgb(0.08f, 0.10f, 0.08f);

/// Brighter with height, so ramps read as slopes.
float heightShade(float h) @nogc nothrow pure @safe {
    immutable s = 0.80f + 0.06f * h;
    return s > 1.04f ? 1.04f : s;
}

private struct BuildingStyle {
    float halfW, halfD, height, roof;
    Rgb wall, roofColor;
}

// Indexed like wfc.decorations.buildingDefs: home A, home B, church, tower, townhall, well,
// market, blacksmith.
private immutable BuildingStyle[8] buildingStyles = [
    BuildingStyle(0.36f, 0.30f, 0.9f, 0.8f, Rgb(0.93f, 0.86f, 0.62f), Rgb(0.78f, 0.36f, 0.25f)),
    BuildingStyle(0.42f, 0.32f, 1.1f, 0.8f, Rgb(0.93f, 0.86f, 0.62f), Rgb(0.70f, 0.30f, 0.22f)),
    BuildingStyle(0.40f, 0.34f, 1.8f, 1.2f, Rgb(0.88f, 0.86f, 0.80f), Rgb(0.38f, 0.42f, 0.58f)),
    BuildingStyle(0.26f, 0.26f, 2.2f, 1.0f, Rgb(0.72f, 0.70f, 0.66f), Rgb(0.45f, 0.36f, 0.55f)),
    BuildingStyle(0.52f, 0.38f, 1.5f, 1.0f, Rgb(0.95f, 0.88f, 0.60f), Rgb(0.30f, 0.45f, 0.65f)),
    BuildingStyle(0.20f, 0.20f, 0.5f, 0.4f, Rgb(0.62f, 0.62f, 0.62f), Rgb(0.55f, 0.35f, 0.22f)),
    BuildingStyle(0.44f, 0.30f, 0.7f, 0.6f, Rgb(0.80f, 0.65f, 0.42f), Rgb(0.90f, 0.75f, 0.35f)),
    BuildingStyle(0.38f, 0.30f, 0.9f, 0.7f, Rgb(0.60f, 0.55f, 0.50f), Rgb(0.30f, 0.28f, 0.28f)),
];

// Unit vectors of the pointy-top directions in (x, z), in HexDir order.
private immutable float[2][6] dirUnit = [
    [0.5f, -0.8660254f], [1.0f, 0.0f], [0.5f, 0.8660254f], [-0.5f, 0.8660254f], [-1.0f, 0.0f],
    [-0.5f, -0.8660254f]
];

/// Level of detail, finest last. Chosen from how many cells are on screen.
enum Lod : ubyte {
    /// One pixel per cell in a prebuilt image (gfx.overview); no mesh.
    overview,
    /// Flat shapes without decorations.
    plain,
    /// Flat shapes with decorations.
    flat,
    /// The Hex-Map-WFC terrain model.
    model
}

/// Cells per chunk along a row; chunks are built on demand and cached.
enum int blockCols = 32;

private struct Chunk {
    MeshVert* v;
    int* idx;
    uint nv, ni;
    /// Water sparkle layer, drawn with its own texture right after the chunk.
    MeshVert* ov;
    int* oi;
    uint nov, noi;
    uint lastFrame;
    bool built;
    /// Retained GPU copy of the chunk (owned by the GPU renderer), freed with `gpuFree`.
    void* gpu;
    void function(void*) @nogc nothrow gpuFree;
}

/// Cells on screen up to which each level of detail is used.
/// Vertical extent of a model tile's bevelled rim, below its top face.
private enum float rimDepth = 0.06f;
/// Texture offset from a tile's rim to its top face in hex-terrain.glb.
private immutable float[2] rimUv = [0.016f, -0.016f];
private enum float modelMaxCells = 8000, flatMaxCells = 12000, plainMaxCells = 30000;
/// Cached chunk geometry above this many bytes is trimmed to what the last frame drew.
/// Draw-call CPU time and whole-frame time the viewer tries to stay under, in ms (24 keeps 60 Hz
/// vsync well clear while catching software rendering).
private enum float drawBudgetMs = 10.0f, frameBudgetMs = 24.0f;
private enum uint recoverDelayFrames = 90;
private enum size_t cacheBudget = 160 << 20;

/// The map as drawable geometry. Nothing is built up front: a chunk of up to `blockCols` cells of
/// one row is generated the first time it is on screen, so memory follows the view, not the map.
struct MapMesh {
    private const(MapSession)* sess;
    /// Towers and special tiles drawn in place of decorations (null: none).
    private const(Game)* game_;
    private MeshOptions opts;
    private const(GlbModel)* glb;
    /// Purpose-built tower models (assets/models/td-towers.glb), or null to reuse village buildings.
    private const(GlbModel)* towerGlb;
    /// Village props (assets/models/village.glb), or null to use hex-terrain stand-ins.
    private const(GlbModel)* villageGlb;
    private TexSet ts;
    private bool[numTiles] cliff, isCoast;
    private int texVariants = 1;
    private Chunk* chunks;
    private int rowCount, colCount, blockCount;
    private Lod lod_ = Lod.flat;
    /// Scales the cell counts the detail levels allow; adapt() lowers it when frames run long.
    float quality = 1.0f;
    private float drawMsAvg = 0, frameMsAvg = 0;
    private uint frameNo, builtThisFrame, recoverAt;
    private size_t cacheVerts, cacheBytes;
    private MeshVert* verts;
    private int* indices;
    private size_t nVerts, capVerts, nIdx, capIdx;
    private MeshVert* oVerts;
    private int* oIndices;
    private size_t nOv, capOv, nOi, capOi;
    private size_t rowStart;
    private bool oom;
    /// Set while a tile top is added: rim vertices take the top's shading.
    private bool flatRim;
    private ModelVert* mv;
    private int* remap;
    private TriKey* order;
    private size_t capMv, capRemap, capTri;
    /// Projected bounds of the whole map.
    float minX = 0, minY = 0, maxX = 0, maxY = 0;
    /// Extent of a row's content above / below its center line at the current LOD, for culling.
    float rowAbove = 0, rowBelow = 0;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        clearCache();
        free(chunks);
        free(verts);
        free(indices);
        free(oVerts);
        free(oIndices);
        free(mv);
        free(remap);
        free(order);
    }

    int rows() const @nogc nothrow pure @safe {
        return rowCount;
    }

    int blocks() const @nogc nothrow pure @safe {
        return blockCount;
    }

    Lod lod() const @nogc nothrow pure @safe {
        return lod_;
    }

    /// Vertices and bytes of the geometry currently cached.
    size_t vertexCount() const @nogc nothrow pure @safe {
        return cacheVerts;
    }

    size_t bytes() const @nogc nothrow pure @safe {
        return cacheBytes;
    }

    /// Y of row r's center line in projected space (at height 0).
    static float rowY(int r) @nogc nothrow pure @safe {
        return r * rowPitch * squash;
    }

    /// Points the mesh at the session's current map (dropping everything cached). With a model and
    /// opt.textured the finest level of detail uses its meshes; `variants` is how many
    /// level-blended copies are stacked in its texture. Returns false if memory ran out.
    bool setup(ref const MapSession s, const MeshOptions opt, const(GlbModel)* model, int variants) @nogc nothrow @trusted {
        clearCache();
        free(chunks);
        chunks = null;
        // A new map starts from full detail: the old map's timings (or the stall of generating
        // this one) must not leave the adaptive quality pinned low.
        quality = 1.0f;
        drawMsAvg = frameMsAvg = 0;
        recoverAt = 0;
        sess = &s;
        opts = opt;
        glb = opt.textured ? model : null;
        texVariants = variants < 1 ? 1 : variants;
        ts = TexSet.init;
        if (glb !is null)
            ts.resolve(*glb);
        if (glb !is null && towerGlb !is null)
            ts.resolveTowers(*towerGlb);
        if (glb !is null && villageGlb !is null)
            ts.resolveVillage(*villageGlb);
        foreach (i, ref t; tileList)
            cliff[i] = t.name.length >= 11 && t.name[0 .. 11] == "GRASS_CLIFF";
        foreach (i, ref t; tileList)
            isCoast[i] = (t.name.length >= 5 && t.name[0 .. 5] == "COAST") || t.name == "RIVER_INTO_COAST";
        rowCount = s.tiles().rect.rows;
        colCount = s.tiles().rect.cols;
        blockCount = (colCount + blockCols - 1) / blockCols;
        chunks = cast(Chunk*)calloc(cast(size_t)rowCount * blockCount, Chunk.sizeof);
        minX = -1;
        maxX = colCount * 2 + 1;
        minY = -(levelsCount * levelStep + 1.0f);
        maxY = rowY(rowCount - 1) + hexRadius * squash + 1.0f;
        setRowExtents(lod_);
        return chunks !is null;
    }

    private void setRowExtents(Lod l) @nogc nothrow pure @safe {
        if (l == Lod.model) {
            rowAbove = 5.0f;
            rowBelow = hexRadius * squash + 1.4f;
        } else {
            // Tallest flat content: level 4 plus a mountain or tower; deepest: the slab below level 0.
            rowAbove = (levelsCount - 1 + 5.0f) * levelStep + hexRadius * squash;
            rowBelow = hexRadius * squash + 1.0f * levelStep;
        }
    }

    private void clearCache() @nogc nothrow @trusted {
        if (chunks !is null)
            foreach (i; 0 .. cast(size_t)rowCount * blockCount)
                freeChunk(chunks[i]);
        cacheVerts = cacheBytes = 0;
    }

    private void freeChunk(ref Chunk c) @nogc nothrow @trusted {
        if (!c.built)
            return;
        if (c.gpu !is null)
            c.gpuFree(c.gpu);
        free(c.v);
        free(c.idx);
        free(c.ov);
        free(c.oi);
        cacheVerts -= c.nv + c.nov;
        cacheBytes -= (c.nv + c.nov) * MeshVert.sizeof + (c.ni + c.noi) * int.sizeof;
        c = Chunk.init;
    }

    /// Picks the level of detail for the camera (with hysteresis against flicker at the
    /// thresholds) and drops the cache when it changes.
    Lod pick(ref const Camera cam) @nogc nothrow @trusted {
        immutable total = cast(float)rowCount * colCount;
        float visible = (cam.width / cam.zoom) * (cam.height / cam.zoom) / (2.0f * rowPitch * squash);
        visible = visible < total ? visible : total;
        immutable modelOk = glb !is null;
        Lod want(float scale) {
            scale *= quality;
            if (modelOk && visible <= modelMaxCells * scale)
                return Lod.model;
            if (visible <= flatMaxCells * scale)
                return Lod.flat;
            return visible <= plainMaxCells * scale ? Lod.plain : Lod.overview;
        }

        immutable a = want(1.0f), b = want(0.85f);
        Lod next = lod_;
        if (a < lod_)
            next = a;
        else if (b > lod_)
            next = b;
        if (next != lod_) {
            lod_ = next;
            setRowExtents(next);
            clearCache();
        }
        return lod_;
    }

    /// Feeds back how long the last frame took: `drawMs` is the CPU time of the draw call and
    /// `frameMs` the whole frame including present (where a software renderer rasterizes, and where
    /// vsync waits, hence its looser budget). Over budget the detail thresholds shrink (down to a
    /// two-hundred-fiftieth); with headroom they recover slowly, so a slow machine settles on the richest level
    /// of detail it can sustain.
    void adapt(float drawMs, float frameMs) @nogc nothrow pure @safe {
        // A frame that had to generate chunks is a one-off (panning, zooming, a new map), not what
        // the view costs to keep drawing, so it must not drag the quality down.
        if (builtThisFrame != 0)
            return;
        drawMsAvg = drawMsAvg * 0.85f + drawMs * 0.15f;
        frameMsAvg = frameMsAvg * 0.85f + frameMs * 0.15f;
        if (drawMsAvg > drawBudgetMs || frameMsAvg > frameBudgetMs) {
            quality = quality * 0.92f < 0.004f ? 0.004f : quality * 0.92f;
            // Richer levels cost more, so recovering right away would flap between two levels.
            recoverAt = frameNo + recoverDelayFrames;
        } else if (frameNo >= recoverAt && drawMsAvg < drawBudgetMs * 0.6f
                && frameMsAvg < frameBudgetMs * 0.75f && quality < 1.0f)
            quality = quality * 1.02f > 1.0f ? 1.0f : quality * 1.02f;
    }

    void beginFrame() @nogc nothrow pure @safe {
        frameNo++;
        builtThisFrame = 0;
    }

    /// Trims the cache to the chunks the finished frame used, if it grew over budget.
    void endFrame() @nogc nothrow @trusted {
        if (cacheBytes <= cacheBudget)
            return;
        foreach (i; 0 .. cast(size_t)rowCount * blockCount)
            if (chunks[i].built && chunks[i].lastFrame != frameNo)
                freeChunk(chunks[i]);
    }

    /// Geometry of one chunk (indices relative to its first vertex), built if not cached. False
    /// when out of memory.
    bool chunk(int row, int block, out const(MeshVert)[] v, out const(int)[] idx,
            out const(MeshVert)[] ov, out const(int)[] oidx) @nogc nothrow @trusted {
        assert(row >= 0 && row < rowCount && block >= 0 && block < blockCount);
        auto c = &chunks[cast(size_t)row * blockCount + block];
        if (!c.built && !buildChunk(row, block, *c))
            return false;
        c.lastFrame = frameNo;
        v = c.v[0 .. c.nv];
        idx = c.idx[0 .. c.ni];
        ov = c.ov[0 .. c.nov];
        oidx = c.oi[0 .. c.noi];
        return true;
    }

    /// Elevation level a cell's base sits at (0 for unsolved cells), the height of its footprint
    /// hexagon on screen. False for cells outside the map.
    bool cellLevel(int col, int row, out float level) const @nogc nothrow @trusted {
        level = 0;
        if (sess is null || col < 0 || row < 0 || col >= colCount || row >= rowCount)
            return false;
        immutable id = sess.tiles().get(offsetToCube(col, row));
        if (id >= 0)
            level = sess.rules.states[id].level;
        return true;
    }

    /// Draws `g`'s towers and special tiles with the map (call `invalidateCell` when one changes).
    void setGame(const(Game)* g) @nogc nothrow @trusted {
        game_ = g;
        clearCache();
    }

    /// True for cells still in the fog of a reveal game.
    bool fogged(int col, int row) const @nogc nothrow @trusted {
        return game_ !is null && game_.active && game_.board.plan.enabled
            && !game_.board.window.containsOffset(col, row);
    }

    private static uint fog(uint rgba) @nogc nothrow pure @safe {
        enum uint keep = 90; // of 256
        immutable r = (rgba & 0xFF) * keep >> 8, g = (rgba >> 8 & 0xFF) * keep >> 8;
        immutable b = (rgba >> 16 & 0xFF) * keep >> 8;
        return (rgba & 0xFF000000) | r | g << 8 | b << 16;
    }

    /// The visible window changed: every chunk is rebuilt with the new fog.
    void fogChanged() @nogc nothrow @trusted {
        clearCache();
    }

    /// Screen-space bounds of the cells of a window (as `minX` .. `maxY` are for the whole map).
    /// Headroom above the top row is only what the window's tallest cells need.
    void windowBounds(const Window w, out float x0, out float y0, out float x1, out float y1) const @nogc nothrow @trusted {
        x0 = w.col0 * 2 - 1;
        x1 = (w.col0 + w.cols) * 2 + 1;
        float top = 0;
        foreach (row; w.row0 .. w.row0 + w.rows)
            foreach (col; w.col0 .. w.col0 + w.cols) {
                float lvl;
                if (cellLevel(col, row, lvl)) {
                    immutable t = (lvl + 1) * levelStep - (rowY(row) - rowY(w.row0));
                    top = t > top ? t : top;
                }
            }
        y0 = rowY(w.row0) - top - hexRadius * squash;
        y1 = rowY(w.row0 + w.rows - 1) + hexRadius * squash + 1.0f;
    }

    /// Drops the cached chunk holding a cell so it is rebuilt (a tower was built, upgraded or sold).
    void invalidateCell(int col, int row) @nogc nothrow @trusted {
        if (chunks is null || col < 0 || row < 0 || col >= colCount || row >= rowCount)
            return;
        freeChunk(chunks[cast(size_t)row * blockCount + col / blockCols]);
    }

    /// The GPU copy of an already built chunk, or null.
    void* gpuHandle(int row, int block) @nogc nothrow @trusted {
        return chunks[cast(size_t)row * blockCount + block].gpu;
    }

    /// Hands a built chunk's GPU copy to the mesh, which frees it with `release` when the chunk goes.
    void attachGpu(int row, int block, void* handle, void function(void*) @nogc nothrow release) @nogc nothrow @trusted {
        auto c = &chunks[cast(size_t)row * blockCount + block];
        assert(c.built && c.gpu is null);
        c.gpu = handle;
        c.gpuFree = release;
    }

    private bool buildChunk(int row, int block, ref Chunk c) @nogc nothrow @trusted {
        builtThisFrame++;
        nVerts = nIdx = nOv = nOi = 0;
        rowStart = 0;
        oom = false;
        MeshOptions o = opts;
        o.decorations = opts.decorations && lod_ != Lod.plain;
        immutable col1 = (block + 1) * blockCols < colCount ? (block + 1) * blockCols : colCount;
        foreach (col; block * blockCols .. col1) {
            immutable v0 = nVerts, ov0 = nOv;
            if (lod_ == Lod.model)
                addCellTextured(*sess, offsetToCube(col, row), col, row, o, ts);
            else
                addCell(*sess, offsetToCube(col, row), col, row, o, cliff);
            if (!oom && fogged(col, row)) {
                foreach (ref mv; verts[v0 .. nVerts])
                    mv.rgba = fog(mv.rgba);
                foreach (ref mv; oVerts[ov0 .. nOv])
                    mv.rgba = fog(mv.rgba);
            }
        }
        if (oom)
            return false;
        c.nv = cast(uint)nVerts;
        c.ni = cast(uint)nIdx;
        c.nov = cast(uint)nOv;
        c.noi = cast(uint)nOi;
        c.v = cast(MeshVert*)malloc(nVerts * MeshVert.sizeof + 1);
        c.idx = cast(int*)malloc(nIdx * int.sizeof + 1);
        c.ov = cast(MeshVert*)malloc(nOv * MeshVert.sizeof + 1);
        c.oi = cast(int*)malloc(nOi * int.sizeof + 1);
        if (c.v is null || c.idx is null || c.ov is null || c.oi is null) {
            free(c.v);
            free(c.idx);
            free(c.ov);
            free(c.oi);
            c = Chunk.init;
            return false;
        }
        c.v[0 .. nVerts] = verts[0 .. nVerts];
        c.idx[0 .. nIdx] = indices[0 .. nIdx];
        c.ov[0 .. nOv] = oVerts[0 .. nOv];
        c.oi[0 .. nOi] = oIndices[0 .. nOi];
        c.built = true;
        cacheVerts += nVerts + nOv;
        cacheBytes += (nVerts + nOv) * MeshVert.sizeof + (nIdx + nOi) * int.sizeof;
        return true;
    }

    // ---- primitive emitters ------------------------------------------------------------------

    private int vert(IsoPoint p, uint rgba, float u = 0, float v = 0) @nogc nothrow @trusted {
        if (nVerts == capVerts) {
            immutable cap = capVerts ? capVerts * 2 : 1 << 16;
            auto nv = cast(MeshVert*)realloc(verts, cap * MeshVert.sizeof);
            if (nv is null) {
                oom = true;
                return 0;
            }
            verts = nv;
            capVerts = cap;
        }
        verts[nVerts] = MeshVert(p.x, p.y, rgba, u, v);
        minX = p.x < minX ? p.x : minX;
        maxX = p.x > maxX ? p.x : maxX;
        minY = p.y < minY ? p.y : minY;
        maxY = p.y > maxY ? p.y : maxY;
        return cast(int)(nVerts++ - rowStart);
    }

    private void tri(int a, int b, int c) @nogc nothrow @trusted {
        if (oom)
            return;
        if (nIdx + 3 > capIdx) {
            immutable cap = capIdx ? capIdx * 2 : 1 << 17;
            auto ni = cast(int*)realloc(indices, cap * int.sizeof);
            if (ni is null) {
                oom = true;
                return;
            }
            indices = ni;
            capIdx = cap;
        }
        indices[nIdx++] = a;
        indices[nIdx++] = b;
        indices[nIdx++] = c;
    }

    private void triangle(IsoPoint a, IsoPoint b, IsoPoint c, uint rgba) @nogc nothrow @safe {
        tri(vert(a, rgba), vert(b, rgba), vert(c, rgba));
    }

    private void quad(IsoPoint a, IsoPoint b, IsoPoint c, IsoPoint d, uint rgba) @nogc nothrow @safe {
        immutable ia = vert(a, rgba), ib = vert(b, rgba), ic = vert(c, rgba), id = vert(d, rgba);
        tri(ia, ib, ic);
        tri(ia, ic, id);
    }

    // ---- tiles -------------------------------------------------------------------------------

    private static float[7] heightsOf(ref const MapSession s, int id, const ref bool[numTiles] cliff) @nogc nothrow @safe {
        if (id < 0) {
            float[7] z = 0;
            return z;
        }
        const rules = s.rules;
        return cornerHeights(rules.stateEdges[id], cliff[rules.states[id].tile]);
    }

    private void addCell(ref const MapSession s, CubeCoord c, int col, int row, const MeshOptions opt,
            const ref bool[numTiles] cliff) @nogc nothrow @trusted {
        if (!s.inMap(c))
            return;
        const map = &s.tiles();
        immutable id = map.get(c);
        float cx, cz;
        cellCenter(col, row, cx, cz);
        immutable h = heightsOf(s, id, cliff);

        IsoPoint[6] corner;
        foreach (k; 0 .. 6)
            corner[k] = project(cx + cornerOffsets[k][0], cz + cornerOffsets[k][1], h[k]);
        immutable center = project(cx, cz, h[6]);

        // Front walls (SE, SW) drop to the neighbor's shared corners, or to the slab bottom.
        static immutable HexDir[2] front = [HexDir.SE, HexDir.SW];
        static immutable float[2] wallShade = [0.78f, 0.60f];
        foreach (i, d; front) {
            immutable n = c.neighbor(d);
            immutable inMap = s.inMap(n);
            immutable nh = inMap ? heightsOf(s, map.get(n), cliff) : h;
            immutable int a = d, b = (d + 1) % 6;
            immutable float ba = inMap ? nh[sharedCorner(d, a)] : -1.0f;
            immutable float bb = inMap ? nh[sharedCorner(d, b)] : -1.0f;
            if (ba >= h[a] && bb >= h[b])
                continue;
            immutable wallType = id >= 0 ? s.rules.stateEdges[id][d].type : EdgeType.grass;
            immutable col_ = wallType == EdgeType.water ? waterWall : dirt;
            immutable bottomA = project(cx + cornerOffsets[a][0], cz + cornerOffsets[a][1], ba < h[a] ? ba : h[a]);
            immutable bottomB = project(cx + cornerOffsets[b][0], cz + cornerOffsets[b][1], bb < h[b] ? bb : h[b]);
            quad(corner[a], corner[b], bottomB, bottomA, pack(col_, wallShade[i]));
        }

        if (id < 0) {
            // Unsolved cell: flag it loudly.
            immutable ic = vert(center, pack(unsolved));
            int[6] ik;
            foreach (k; 0 .. 6)
                ik[k] = vert(corner[k], pack(unsolved));
            foreach (k; 0 .. 6)
                tri(ic, ik[k], ik[(k + 1) % 6]);
        } else
            addTop(s.rules.stateEdges[id], h, corner, center, opt);

        if (opt.outlines)
            foreach (k; 0 .. 6)
                addLine(corner[k], corner[(k + 1) % 6], 0.035f, pack(outline, 1.0f, 0.45f));

        if (addStructureFlat(col, row, cx, cz, h[6]))
            return;
        if (opt.decorations) {
            immutable deco = s.decorations.get(c);
            if (deco.kind != DecoKind.none)
                addDecoration(deco, cx, cz, h[6]);
        }
    }

    private void addTop(const ref EdgeInfo[6] edges, const ref float[7] h, const ref IsoPoint[6] corner,
            IsoPoint center, const MeshOptions opt) @nogc nothrow @trusted {
        Rgb sextant(int d) {
            if (opt.levelColors)
                return levelColor[edges[d].level];
            immutable t = edges[d].type;
            return t == EdgeType.road || t == EdgeType.river ? edgeColor[EdgeType.grass] : edgeColor[t];
        }

        bool uniform = true;
        foreach (d; 1 .. 6)
            uniform &= sextant(d) == sextant(0);
        if (uniform) {
            immutable col = sextant(0);
            immutable ic = vert(center, pack(col, heightShade(h[6])));
            int[6] ik;
            foreach (k; 0 .. 6)
                ik[k] = vert(corner[k], pack(col, heightShade(h[k])));
            foreach (k; 0 .. 6)
                tri(ic, ik[k], ik[(k + 1) % 6]);
        } else {
            foreach (d; 0 .. 6) {
                immutable col = sextant(d);
                immutable k1 = (d + 1) % 6;
                tri(vert(center, pack(col, heightShade(h[6]))), vert(corner[d], pack(col,
                        heightShade(h[d]))), vert(corner[k1], pack(col, heightShade(h[k1]))));
            }
        }
        if (opt.levelColors)
            return;

        // Rivers first, then roads, so bridges' road bands sit on top of the water.
        static immutable EdgeType[2] bandTypes = [EdgeType.river, EdgeType.road];
        static immutable float[2] bandHalf = [0.26f, 0.20f];
        foreach (bi, bt; bandTypes) {
            bool any = false;
            immutable col = edgeColor[bt];
            foreach (d; 0 .. 6) {
                if (edges[d].type != bt)
                    continue;
                any = true;
                immutable k1 = (d + 1) % 6;
                immutable mx = (corner[d].x + corner[k1].x) * 0.5f;
                immutable my = (corner[d].y + corner[k1].y) * 0.5f;
                immutable mh = (h[d] + h[k1]) * 0.5f;
                // Perpendicular in the ground plane, then projected: (-dz, dx) * halfWidth.
                immutable px = -dirUnit[d][1] * bandHalf[bi];
                immutable pz = dirUnit[d][0] * bandHalf[bi] * squash;
                quad(IsoPoint(center.x + px, center.y + pz), IsoPoint(mx + px, my + pz),
                        IsoPoint(mx - px, my - pz), IsoPoint(center.x - px, center.y - pz), pack(col,
                            heightShade((h[6] + mh) * 0.5f)));
            }
            if (any) {
                // Hub so bands meet cleanly at the center.
                immutable ic = vert(center, pack(col, heightShade(h[6])));
                int[6] ik;
                foreach (k; 0 .. 6)
                    ik[k] = vert(IsoPoint(center.x + cornerOffsets[k][0] * bandHalf[bi] * 1.15f,
                            center.y + cornerOffsets[k][1] * bandHalf[bi] * 1.15f * squash),
                            pack(col, heightShade(h[6])));
                foreach (k; 0 .. 6)
                    tri(ic, ik[k], ik[(k + 1) % 6]);
            }
        }
    }

    private void addLine(IsoPoint a, IsoPoint b, float halfWidth, uint rgba) @nogc nothrow @safe {
        import core.math : sqrt;

        immutable dx = b.x - a.x, dy = b.y - a.y;
        immutable len = sqrt(dx * dx + dy * dy);
        if (len < 1e-6f)
            return;
        immutable nx = -dy / len * halfWidth, ny = dx / len * halfWidth;
        quad(IsoPoint(a.x + nx, a.y + ny), IsoPoint(b.x + nx, b.y + ny), IsoPoint(b.x - nx,
                b.y - ny), IsoPoint(a.x - nx, a.y - ny), rgba);
    }

    // ---- decorations -------------------------------------------------------------------------

    private void addDecoration(const Decoration deco, float cx, float cz, float hc) @nogc nothrow @safe {
        IsoPoint at(float dx, float dz, float dh) {
            return project(cx + dx, cz + dz, hc + dh);
        }

        final switch (deco.kind) {
        case DecoKind.none:
            break;
        case DecoKind.tree:
            static immutable float[2][4] spots = [
                [0.0f, 0.05f], [-0.42f, -0.25f], [0.40f, -0.20f], [0.05f, 0.42f]
            ];
            // Back-to-front within the cell: spots sorted by z at draw time.
            immutable count = deco.extra + 1 > 4 ? 4 : deco.extra + 1;
            int[4] order = [1, 2, 0, 3];
            foreach (i; order[0 .. 4]) {
                if (i >= count)
                    continue;
                addTree(at(spots[i][0], spots[i][1], 0), deco.variant, count > 1 ? 0.8f : 1.0f);
            }
            break;
        case DecoKind.building:
            immutable st = buildingStyles[deco.variant < buildingStyles.length ? deco.variant : 0];
            immutable extraHeight = deco.variant == towerVariant && deco.extra ? 0.8f : 0.0f;
            addHouse(cx, cz, hc, st.halfW, st.halfD, st.height + extraHeight, st.roof, st.wall, st.roofColor);
            break;
        case DecoKind.windmill:
            addHouse(cx, cz, hc, 0.24f, 0.24f, 2.4f, 0.7f, Rgb(0.90f, 0.86f, 0.75f), Rgb(0.60f, 0.30f, 0.22f));
            immutable hub = at(0, 0.24f, 2.2f);
            immutable blade = Rgb(0.55f, 0.42f, 0.30f);
            addLine(IsoPoint(hub.x - 0.7f, hub.y - 0.7f), IsoPoint(hub.x + 0.7f, hub.y + 0.7f), 0.07f, pack(blade));
            addLine(IsoPoint(hub.x - 0.7f, hub.y + 0.7f), IsoPoint(hub.x + 0.7f, hub.y - 0.7f), 0.07f, pack(blade));
            break;
        case DecoKind.bridge:
            immutable d = deco.facing;
            immutable ux = dirUnit[d][0], uz = dirUnit[d][1];
            immutable float w = 0.34f, l = 0.95f;
            immutable deck = Rgb(0.62f, 0.45f, 0.28f);
            quad(at(-ux * l - uz * w, -uz * l + ux * w, 0.25f), at(ux * l - uz * w, uz * l + ux * w,
                    0.25f), at(ux * l + uz * w, uz * l - ux * w, 0.25f), at(-ux * l + uz * w,
                    -uz * l - ux * w, 0.25f), pack(deck));
            addLine(at(-ux * l + uz * w, -uz * l - ux * w, 0.25f), at(ux * l + uz * w, uz * l - ux * w,
                    0.25f), 0.05f, pack(deck, 0.6f));
            addLine(at(-ux * l - uz * w, -uz * l + ux * w, 0.25f), at(ux * l - uz * w, uz * l + ux * w,
                    0.25f), 0.05f, pack(deck, 0.6f));
            break;
        case DecoKind.mountain:
            immutable top = 3.2f + deco.variant * 0.7f;
            immutable rock = Rgb(0.55f, 0.53f, 0.50f);
            immutable apex = at(0, 0, top);
            immutable l = at(-1.05f, 0, 0), rt = at(1.05f, 0, 0), bk = at(0, -0.9f, 0), fr = at(0, 0.9f, 0);
            triangle(l, bk, apex, pack(rock, 0.55f));
            triangle(bk, rt, apex, pack(rock, 0.70f));
            triangle(l, fr, apex, pack(rock, 0.85f));
            triangle(fr, rt, apex, pack(rock, 1.05f));
            // Snow cap: the top third of the front faces.
            immutable snow = Rgb(0.95f, 0.96f, 0.98f);
            IsoPoint lerp(IsoPoint a, float t) {
                return IsoPoint(apex.x + (a.x - apex.x) * t, apex.y + (a.y - apex.y) * t);
            }

            triangle(lerp(l, 0.33f), lerp(fr, 0.33f), apex, pack(snow, 0.85f));
            triangle(lerp(fr, 0.33f), lerp(rt, 0.33f), apex, pack(snow, 1.0f));
            break;
        case DecoKind.source:
            // Red spawn tower.
            addHouse(cx, cz, hc, 0.30f, 0.30f, 2.6f, 1.0f, Rgb(0.55f, 0.18f, 0.16f), Rgb(0.88f, 0.22f, 0.18f));
            break;
        case DecoKind.sink:
            // Blue goal keep.
            addHouse(cx, cz, hc, 0.46f, 0.42f, 1.9f, 1.2f, Rgb(0.88f, 0.88f, 0.92f), Rgb(0.20f, 0.36f, 0.85f));
            break;
        case DecoKind.village:
            if (deco.variant < numVillageProps)
                addVillageShape(cast(VillageProp)deco.variant, cx, cz, hc);
            break;
        case DecoKind.rock:
            immutable rtop = 1.2f + deco.variant * 0.3f;
            immutable stone = Rgb(0.50f, 0.48f, 0.46f);
            immutable rapex = at(0, 0, rtop);
            immutable rl = at(-0.8f, 0, 0), rr = at(0.8f, 0, 0), rb = at(0, -0.7f, 0), rf = at(0, 0.7f, 0);
            triangle(rl, rb, rapex, pack(stone, 0.55f));
            triangle(rb, rr, rapex, pack(stone, 0.70f));
            triangle(rl, rf, rapex, pack(stone, 0.85f));
            triangle(rf, rr, rapex, pack(stone, 1.05f));
            break;
        }
    }

    private void addTree(IsoPoint base, ubyte variant, float scale) @nogc nothrow @safe {
        immutable trunk = Rgb(0.45f, 0.32f, 0.20f);
        immutable s = 0.5f * scale;
        quad(IsoPoint(base.x - 0.05f * s, base.y), IsoPoint(base.x + 0.05f * s, base.y),
                IsoPoint(base.x + 0.05f * s, base.y - 0.35f * s), IsoPoint(base.x - 0.05f * s,
                    base.y - 0.35f * s), pack(trunk));
        if (variant == 0) {
            // Conifer: two stacked cones, left half in shade.
            immutable green = Rgb(0.20f, 0.48f, 0.28f);
            foreach (tier; 0 .. 2) {
                immutable y0 = base.y - (0.25f + tier * 0.45f) * s;
                immutable half = (0.42f - tier * 0.1f) * s;
                immutable apex = IsoPoint(base.x, y0 - 0.9f * s);
                triangle(IsoPoint(base.x - half, y0), IsoPoint(base.x, y0 + 0.08f * s), apex, pack(green, 0.75f));
                triangle(IsoPoint(base.x, y0 + 0.08f * s), IsoPoint(base.x + half, y0), apex, pack(green, 1.0f));
            }
        } else {
            // Broadleaf: a squat hexagonal crown.
            immutable green = Rgb(0.36f, 0.62f, 0.26f);
            immutable cy = base.y - 0.75f * s;
            immutable r = 0.42f * s;
            immutable IsoPoint c = IsoPoint(base.x, cy);
            foreach (k; 0 .. 6) {
                immutable a = cornerOffsets[k], b = cornerOffsets[(k + 1) % 6];
                immutable shade = k < 3 ? 1.0f : 0.75f;
                triangle(c, IsoPoint(base.x + b[1] * r, cy + b[0] * r), IsoPoint(base.x + a[1] * r,
                        cy + a[0] * r), pack(green, shade));
            }
        }
    }

    /// Box with a gabled roof whose ridge runs along x; only the visible faces are emitted.
    /// Flat-shape village prop for the untextured detail levels.
    private void addVillageShape(VillageProp p, float cx, float cz, float hc) @nogc nothrow @safe {
        static struct Shape {
            float halfW, halfD, height, roof;
            Rgb wall, roof_;
        }

        static immutable Shape[numVillageProps] shapes = [
            // stilt house: dark timber under a tall thatch roof
            Shape(0.42f, 0.34f, 1.1f, 1.0f, Rgb(0.45f, 0.30f, 0.18f), Rgb(0.80f, 0.66f, 0.38f)),
            // dinh hall: long, red-tiled
            Shape(0.62f, 0.40f, 1.0f, 0.9f, Rgb(0.70f, 0.52f, 0.34f), Rgb(0.72f, 0.24f, 0.18f)),
            // temple: tall stepped stone
            Shape(0.60f, 0.60f, 2.4f, 0.5f, Rgb(0.66f, 0.62f, 0.55f), Rgb(0.80f, 0.34f, 0.20f)),
            // gate: red pillars with a dark lintel
            Shape(0.50f, 0.10f, 1.6f, 0.3f, Rgb(0.75f, 0.20f, 0.15f), Rgb(0.30f, 0.20f, 0.15f)),
            // market stall
            Shape(0.34f, 0.26f, 0.7f, 0.4f, Rgb(0.60f, 0.44f, 0.28f), Rgb(0.90f, 0.75f, 0.35f)),
            // lantern
            Shape(0.06f, 0.06f, 0.9f, 0.2f, Rgb(0.35f, 0.22f, 0.14f), Rgb(0.95f, 0.30f, 0.15f)),
            // palm
            Shape(0.08f, 0.08f, 1.8f, 0.6f, Rgb(0.55f, 0.40f, 0.25f), Rgb(0.30f, 0.62f, 0.25f)),
            // banana
            Shape(0.10f, 0.10f, 1.0f, 0.7f, Rgb(0.45f, 0.55f, 0.25f), Rgb(0.40f, 0.72f, 0.30f)),
            // paddy dike
            Shape(0.70f, 0.08f, 0.15f, 0.05f, Rgb(0.50f, 0.42f, 0.30f), Rgb(0.45f, 0.60f, 0.30f)),
            // well
            Shape(0.22f, 0.22f, 0.4f, 0.3f, Rgb(0.60f, 0.58f, 0.55f), Rgb(0.45f, 0.30f, 0.20f))
        ];
        immutable sh = shapes[p];
        addHouse(cx, cz, hc, sh.halfW, sh.halfD, sh.height, sh.roof, sh.wall, sh.roof_);
    }

    private void addHouse(float cx, float cz, float hc, float halfW, float halfD, float height,
            float roof, Rgb wall, Rgb roofColor) @nogc nothrow @safe {
        immutable top = hc + height * 0.5f;
        immutable roofTop = top + roof * 0.5f;
        IsoPoint p(float dx, float dz, float hh) {
            return project(cx + dx, cz + dz, hh);
        }
        // Front face.
        quad(p(-halfW, halfD, hc), p(halfW, halfD, hc), p(halfW, halfD, top), p(-halfW, halfD,
                top), pack(wall, 0.85f));
        // Back slope, then front slope over it.
        quad(p(-halfW, -halfD, top), p(halfW, -halfD, top), p(halfW, 0, roofTop), p(-halfW, 0,
                roofTop), pack(roofColor, 0.7f));
        quad(p(-halfW, 0, roofTop), p(halfW, 0, roofTop), p(halfW, halfD, top), p(-halfW, halfD,
                top), pack(roofColor, 1.0f));
    }

    // ---- terrain model (Hex-Map-WFC hex-terrain.glb) ----------------------------------------

    /// Appends to the water sparkle layer; sets oom if memory ran out.
    private int overlayVert(IsoPoint p, uint rgba, float u, float v) @nogc nothrow @trusted {
        if (nOv == capOv) {
            immutable cap = capOv ? capOv * 2 : 1 << 12;
            auto nv = cast(MeshVert*)realloc(oVerts, cap * MeshVert.sizeof);
            if (nv is null) {
                oom = true;
                return 0;
            }
            oVerts = nv;
            capOv = cap;
        }
        oVerts[nOv] = MeshVert(p.x, p.y, rgba, u, v);
        return cast(int)nOv++;
    }

    private void overlayTri(int a, int b, int c) @nogc nothrow @trusted {
        if (nOi + 3 > capOi) {
            immutable cap = capOi ? capOi * 2 : 1 << 13;
            auto ni = cast(int*)realloc(oIndices, cap * int.sizeof);
            if (ni is null) {
                oom = true;
                return;
            }
            oIndices = ni;
            capOi = cap;
        }
        oIndices[nOi++] = a;
        oIndices[nOi++] = b;
        oIndices[nOi++] = c;
    }

    /// Caustic sparkle over a water hex, UVs in world space so the tiled texture runs seamlessly
    /// across cells (the reference's water plane scales world position by 0.09).
    private void addSparkle(float cx, float cz, float y) @nogc nothrow @trusted {
        if (oom)
            return;
        immutable rgba = pack(waterTint, 1.0f, sparkleOpacity);
        immutable lift = (y - 1.0f) * yLift;
        immutable first = overlayVert(IsoPoint(cx, cz * squash - lift), rgba, cx * sparkleFreq, cz * sparkleFreq);
        foreach (k; 0 .. 6) {
            immutable x = cx + cornerOffsets[k][0], z = cz + cornerOffsets[k][1];
            overlayVert(IsoPoint(x, z * squash - lift), rgba, x * sparkleFreq, z * sparkleFreq);
        }
        if (oom)
            return;
        foreach (k; 0 .. 6)
            overlayTri(first, first + 1 + k, first + 1 + (k + 1) % 6);
    }

    /// Water and foam inside a coast tile, drawn in the sparkle layer: the tile's flat water floor
    /// (model y -0.2) gets the same sheen as open water, and the beach ramp climbing from it towards
    /// the sand gets foam, so both follow the coastline of each tile exactly.
    private void addShoreFoam(ref const MeshRef m, float px, float py, float pz, float theta) @nogc nothrow @trusted {
        if (oom || !m.valid)
            return;
        immutable c = cos(theta), s = sin(theta);
        immutable water = pack(waterTint, 1.0f, sparkleOpacity), foam = pack(Rgb(1, 1, 1), 1.0f, foamOpacity);
        foreach (t; 0 .. m.nIdx / 3) {
            uint[3] vi;
            float lo = 9, hi = -9;
            foreach (k; 0 .. 3) {
                vi[k] = m.index(3 * t + k);
                immutable y = m.pos[3 * vi[k] + 1];
                lo = y < lo ? y : lo;
                hi = y > hi ? y : hi;
            }
            immutable flatWater = lo > -0.21f && hi < -0.19f;
            immutable ramp = lo > -0.21f && lo < -0.15f && hi > -0.12f && hi < -0.04f;
            if (!flatWater && !ramp)
                continue;
            int[3] o;
            foreach (k; 0 .. 3) {
                immutable x = m.pos[3 * vi[k]], z = m.pos[3 * vi[k] + 2];
                immutable wx = px + x * c + z * s, wz = pz - x * s + z * c;
                immutable wy = py + m.pos[3 * vi[k] + 1] + 0.02f;
                o[k] = overlayVert(IsoPoint(wx, wz * squash - (wy - 1.0f) * yLift), flatWater ? water
                        : foam, wx * sparkleFreq, wz * sparkleFreq);
            }
            if (oom)
                return;
            overlayTri(o[0], o[1], o[2]);
        }
    }

    /// Soft ground shadow of a decoration: a fan whose alpha fades to nothing at the rim, cast away
    /// from the light. Samples the atlas's darkest texel, so it rides along in the main layer.
    private void addShadow(ref const MeshRef m, float cx, float cz, float y, float scale) @nogc nothrow @trusted {
        if (oom || !m.valid)
            return;
        immutable rx = (m.hi[0] - m.lo[0]) * 0.5f * scale + 0.06f, rz = (m.hi[2] - m.lo[2]) * 0.5f * scale + 0.06f;
        immutable reach = m.hi[1] * scale * 0.3f;
        immutable ex = cx + (m.hi[0] + m.lo[0]) * 0.5f * scale + reach * shadowDir[0];
        immutable ez = cz + (m.hi[2] + m.lo[2]) * 0.5f * scale + reach * shadowDir[1];
        immutable lift = (y - 1.0f) * yLift;
        immutable u = 0.03f, v = 0.03f / texVariants;
        immutable ic = vert(IsoPoint(ex, ez * squash - lift), pack(Rgb(1, 1, 1), 1.0f, shadowAlpha), u, v);
        enum int sides = 10;
        int[sides] ring;
        foreach (k; 0 .. sides) {
            immutable a = k * (6.2831853f / sides);
            ring[k] = vert(IsoPoint(ex + cos(a) * rx * 1.1f, (ez + sin(a) * rz * 1.1f) * squash - lift),
                    pack(Rgb(1, 1, 1), 1.0f, 0.0f), u, v);
        }
        foreach (k; 0 .. sides)
            tri(ic, ring[k], ring[(k + 1) % sides]);
    }

    private bool growScratch(uint nv, uint nTris) @nogc nothrow @trusted {
        if (nv > capMv) {
            auto a = cast(ModelVert*)realloc(mv, nv * ModelVert.sizeof);
            if (a is null)
                return false;
            mv = a;
            capMv = nv;
        }
        immutable rn = cast(size_t)nv * texVariants;
        if (rn > capRemap) {
            auto b = cast(int*)realloc(remap, rn * int.sizeof);
            if (b is null)
                return false;
            remap = b;
            capRemap = rn;
        }
        if (nTris > capTri) {
            auto c = cast(TriKey*)realloc(order, nTris * TriKey.sizeof);
            if (c is null)
                return false;
            order = c;
            capTri = nTris;
        }
        return true;
    }

    /// Places `m` at world (px, py, pz), turned by `theta` about Y (three.js convention) and scaled.
    /// Triangles facing away are dropped and the rest are emitted far-to-near, so a later model
    /// in the same cell draws over this one. `level` and `slopeShift` give the elevation blend of
    /// the reference's shader: level / (levels - 1) plus (model y + slopeShift) / 2 picks which
    /// level-blended copy of the texture a triangle samples.
    private void addModel(ref const MeshRef m, float px, float py, float pz, float theta, float scale,
            float yScale, Rgb tint, float level = 0, float slopeShift = 0, bool topOnly = false) @nogc nothrow @trusted {
        if (oom || !m.valid)
            return;
        if (!growScratch(m.nVerts, m.nIdx / 3)) {
            oom = true;
            return;
        }
        immutable c = cos(theta), s = sin(theta);
        foreach (i; 0 .. m.nVerts) {
            immutable rim = flatRim && m.nrm[3 * i + 1] > 0.6f && m.nrm[3 * i + 1] < 0.8f
                && m.pos[3 * i + 1] > m.hi[1] - rimDepth;
            immutable x = m.pos[3 * i] * scale, y = m.pos[3 * i + 1] * scale * yScale, z = m.pos[3 * i + 2] * scale;
            mv[i].x = px + x * c + z * s;
            mv[i].y = py + y;
            mv[i].z = pz - x * s + z * c;
            mv[i].slope = (m.pos[3 * i + 1] + slopeShift) * 0.5f;
            mv[i].du = rim ? rimUv[0] : 0;
            mv[i].dv = rim ? rimUv[1] : 0;
            float mx = m.nrm[3 * i], my = m.nrm[3 * i + 1], mz = m.nrm[3 * i + 2];
            // The tile's 45 degree rim, within a hair of the top, is what shows as lines between tiles.
            if (rim) {
                mx = mz = 0;
                my = 1;
            }
            immutable nx = mx * c + mz * s;
            immutable nz = -mx * s + mz * c;
            float d = nx * lightDir[0] + my * lightDir[1] + nz * lightDir[2];
            d = d < 0 ? 0 : (d > lightFull ? 1 : d / lightFull);
            // Baked occlusion: surfaces low on a model (wall bottoms, creases at the foot of props) are
            // darker, a cheap stand-in for the reference's screen-space ambient occlusion.
            immutable low = m.pos[3 * i + 1] - m.lo[1];
            immutable ao = low >= 0.6f ? 1.0f : 0.86f + 0.14f * (low / 0.6f);
            mv[i].rgba = pack(tint, (0.58f + 0.42f * d) * ao);
        }
        foreach (i; 0 .. cast(size_t)m.nVerts * texVariants)
            remap[i] = -1;
        immutable levelBlend = level / (levelsCount - 1) + levelBias;
        immutable maxVariant = texVariants - 1;
        uint kept = 0;
        foreach (t; 0 .. m.nIdx / 3) {
            immutable a = m.index(3 * t), b = m.index(3 * t + 1), cc = m.index(3 * t + 2);
            immutable e1x = mv[b].x - mv[a].x, e1y = mv[b].y - mv[a].y, e1z = mv[b].z - mv[a].z;
            immutable e2x = mv[cc].x - mv[a].x, e2y = mv[cc].y - mv[a].y, e2z = mv[cc].z - mv[a].z;
            // Face normal (counter-clockwise front faces) against the direction towards the viewer.
            immutable ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
            if (ny * squash + nz * yLift <= 1e-9f)
                continue;
            if (topOnly) {
                // Flat water: keep only the upward-facing surface, not the rim that would show as
                // seams between neighboring cells (the reference hides it under its water plane).
                immutable nx = e1y * e2z - e1z * e2y;
                if (ny < 0.95f * sqrt(nx * nx + ny * ny + nz * nz))
                    continue;
            }
            immutable depth = (mv[a].z + mv[b].z + mv[cc].z) * (squash / 3) + (mv[a].y + mv[b].y + mv[cc].y) * (
                    yLift / 3);
            float blend = levelBlend + (mv[a].slope + mv[b].slope + mv[cc].slope) * (1.0f / 3);
            blend = blend < 0 ? 0 : (blend > 1 ? 1 : blend);
            order[kept++] = TriKey(depth, t, cast(ubyte)(blend * maxVariant + 0.5f));
        }
        qsort(order, kept, TriKey.sizeof, &cmpTriKey);
        immutable invVariants = 1.0f / texVariants;
        foreach (k; 0 .. kept) {
            immutable t = order[k].tri, variant = order[k].variant;
            int[3] out_;
            foreach (j; 0 .. 3) {
                immutable vi = m.index(3 * t + j);
                immutable slot = variant * m.nVerts + vi;
                if (remap[slot] < 0)
                    remap[slot] = vert(IsoPoint(mv[vi].x, mv[vi].z * squash - (mv[vi].y - 1.0f) * yLift),
                            mv[vi].rgba, m.uv[2 * vi] + mv[vi].du, (m.uv[2 * vi + 1] + mv[vi].dv + variant)
                            * invVariants);
                out_[j] = remap[slot];
            }
            tri(out_[0], out_[1], out_[2]);
        }
    }

    // ---- tower defense structures ---------------------------------------------------------

    /// Model, scale and tint of a tower: the kind picks the building, the stage its size and color.
    private static ref const(MeshRef) towerMesh(return ref const TexSet ts, TowerKind k) @nogc nothrow @safe {
        final switch (k) {
        case TowerKind.arrow:
            return ts.buildings[towerVariant];
        case TowerKind.cannon:
            return ts.fort.valid ? ts.fort : ts.buildings[7];
        case TowerKind.frost:
            return ts.henge.valid ? ts.henge : ts.buildings[2];
        case TowerKind.tesla:
            return ts.watchtower.valid ? ts.watchtower : ts.buildings[towerVariant];
        case TowerKind.flame:
            return ts.buildings[7];
        case TowerKind.mine:
            return ts.mine.valid ? ts.mine : ts.buildings[5];
        }
    }

    /// Uses td-towers.glb (built by scripts/blender/td_towers.py) for towers; call before `setup`.
    void setTowerModel(const(GlbModel)* model) @nogc nothrow @safe {
        towerGlb = model;
    }

    /// Uses village.glb (built by scripts/blender/village_props.py) for village props; call
    /// before `setup`.
    void setVillageModel(const(GlbModel)* model) @nogc nothrow @safe {
        villageGlb = model;
    }

    private static float towerScale(Stage s) @nogc nothrow pure @safe {
        return 0.82f + 0.045f * (tierOf(s) - 1);
    }

    /// True if a tower or special tile was drawn (the cell's decoration is then skipped).
    private bool addStructure(int col, int row, ref const TexSet ts, float cx, float cz, float baseY, float lvl) @nogc nothrow @trusted {
        if (game_ is null || !game_.active)
            return false;
        if (const t = game_.towerAt(col, row)) {
            // Modded kinds borrow the art of a built-in kind.
            immutable look = game_.catalog.towers[t.kind].look;
            immutable angle0 = dirAngle[(col * 7 + row * 3) % 6];
            // Own models carry their colors and a look per stage (the nearest lower stage on the
            // same path stands in for a missing one); size and a light tint wash add to it.
            immutable br = branchOf(t.stage) < 0 ? 0 : branchOf(t.stage);
            int tier = tierOf(t.stage);
            while (tier > 1 && !ts.td[look][stageAt(br, tier)].valid)
                --tier;
            ref const MeshRef own = ts.td[look][stageAt(br, tier)];
            if (own.valid) {
                immutable sc = 0.9f + 0.02f * (tierOf(t.stage) - 1);
                immutable k = towerTint(look, t.stage);
                immutable wash = Rgb(0.8f + 0.2f * k.r, 0.8f + 0.2f * k.g, 0.8f + 0.2f * k.b);
                addShadow(own, cx, cz, baseY, sc);
                addModel(own, cx, baseY, cz, angle0, sc, 1, wash, lvl);
                return true;
            }
            ref const MeshRef m = towerMesh(ts, look);
            immutable sc = towerScale(t.stage);
            immutable tint = towerTint(look, t.stage);
            immutable angle = dirAngle[(col * 7 + row * 3) % 6];
            addShadow(m, cx, cz, baseY, sc);
            addModel(m, cx, baseY, cz, angle, sc, 1, tint, lvl);
            if (look == TowerKind.arrow && t.stage != Stage.lv1)
                addModel(ts.towerTop, cx, baseY, cz, angle, sc, 1, tint, lvl);
            if (look == TowerKind.tesla && branchOf(t.stage) >= 0)
                addModel(ts.towerTop, cx, baseY + 0.25f, cz, angle, sc * 0.8f, 1, tint, lvl);
            return true;
        }
        immutable sp = game_.board.special(col, row);
        if (sp == SpecialKind.none)
            return false;
        ref const MeshRef r = sp == SpecialKind.goldVein ? ts.rockGold : ts.rockLey;
        immutable tint = specialTint(sp);
        // A small cluster of stones.
        static immutable float[3][3] spots = [
            [-0.3f, -0.2f, 1.0f], [0.32f, -0.05f, 0.8f], [0.0f, 0.3f, 0.7f]
        ];
        foreach (k, ref p; spots) {
            addModel(r, cx + p[0], baseY - r.lo[1] * p[2], cz + p[1], (col + k) * 1.3f, p[2], 1, tint, lvl);
        }
        return true;
    }

    /// Flat-shape look of the same: a colored keep per tower, crystals for special tiles.
    private bool addStructureFlat(int col, int row, float cx, float cz, float hc) @nogc nothrow @trusted {
        if (game_ is null || !game_.active)
            return false;
        if (const t = game_.towerAt(col, row)) {
            immutable look = game_.catalog.towers[t.kind].look;
            immutable sc = towerScale(t.stage);
            immutable tint = towerTint(look, t.stage);
            immutable roof = flatRoof[look];
            addHouse(cx, cz, hc, 0.30f * sc, 0.30f * sc, (look == TowerKind.mine ? 1.0f : 2.2f) * sc,
                    0.9f * sc, Rgb(0.80f * tint.r, 0.78f * tint.g, 0.74f * tint.b), roof);
            return true;
        }
        immutable sp = game_.board.special(col, row);
        if (sp == SpecialKind.none)
            return false;
        immutable c = specialTint(sp);
        foreach (k; 0 .. 3) {
            immutable ox = (k - 1) * 0.35f, oz = (k == 1 ? -0.15f : 0.15f);
            immutable top = project(cx + ox, cz + oz, hc + 1.4f - (k != 1) * 0.5f);
            immutable l = project(cx + ox - 0.16f, cz + oz, hc), rt = project(cx + ox + 0.16f, cz + oz, hc);
            immutable f = project(cx + ox, cz + oz + 0.12f, hc);
            triangle(l, f, top, pack(c, 0.75f));
            triangle(f, rt, top, pack(c, 1.0f));
        }
        return true;
    }

    private void addCellTextured(ref const MapSession s, CubeCoord c, int col, int row,
            const MeshOptions opt, ref const TexSet ts) @nogc nothrow @trusted {
        if (!s.inMap(c))
            return;
        immutable id = s.tiles().get(c);
        float cx, cz;
        cellCenter(col, row, cx, cz);
        enum Rgb white = Rgb(1, 1, 1);
        if (id < 0) {
            addModel(ts.grass, cx, 1.0f, cz, 0, 1, 1, unsolved);
            return;
        }
        immutable st = s.rules.states[id];
        immutable lvl = cast(float)st.level;
        immutable tileY = st.level * levelHeight;
        immutable theta = -cast(int)st.rotation * (3.14159265f / 3);
        if (st.level >= 1)
            addModel(ts.bottom, cx, tileY, cz, theta, 1, tileY, white, lvl);
        flatRim = !opt.tileEdges;
        addModel(ts.tile[st.tile], cx, tileSurface + tileY, cz, theta, 1, 1, opt.levelColors
                ? levelColor[st.level] : white, lvl, 0, st.tile == waterTile);
        flatRim = false;
        if (isCoast[st.tile] && opt.decorations)
            addShoreFoam(ts.tile[st.tile], cx, tileSurface + tileY, cz, theta);
        if (addStructure(col, row, ts, cx, cz, tileSurface + tileY, lvl))
            return;
        if (!opt.decorations)
            return;
        if (st.tile == waterTile)
            addSparkle(cx, cz, tileSurface + tileY - 0.2f);
        immutable deco = s.decorations.get(c);
        immutable h = hash2(cast(uint)col, cast(uint)row);
        immutable rnd0 = (h & 0xFFFF) / 65536.0f, rnd1 = (h >> 16) / 65536.0f;
        immutable baseY = tileSurface + tileY;
        final switch (deco.kind) {
        case DecoKind.none:
            addTerrainProp(st, ts, cx, cz, baseY, lvl, h);
            break;
        case DecoKind.tree:
            ref const MeshRef t = ts.trees[deco.variant & 1][deco.extra & 3];
            addShadow(t, cx + (rnd0 - 0.5f) * 0.4f, cz + (rnd1 - 0.5f) * 0.4f, baseY, 1.0f + rnd1 * 0.2f);
            addModel(t, cx + (rnd0 - 0.5f) * 0.4f, baseY - t.lo[1], cz + (rnd1 - 0.5f) * 0.4f,
                    rnd0 * 6.2831853f, 1.0f + rnd1 * 0.2f, 1, white, lvl, -t.lo[1]);
            break;
        case DecoKind.building:
            immutable angle = dirAngle[deco.facing];
            immutable b = deco.variant < ts.buildings.length ? deco.variant : 0;
            addShadow(ts.buildings[b], cx, cz, baseY, 1.0f);
            addModel(ts.buildings[b], cx, baseY, cz, angle, 1, 1, white, lvl);
            if (deco.variant == towerVariant && deco.extra)
                addModel(ts.towerTop, cx, baseY, cz, angle, 1, 1, white, lvl);
            break;
        case DecoKind.windmill:
            immutable angle = dirAngle[deco.facing];
            immutable ca = cos(angle), sa = sin(angle);
            addShadow(ts.windmill[0], cx, cz, baseY, 1.0f);
            addModel(ts.windmill[0], cx, baseY, cz, angle, 1, 1, white, lvl);
            // The top sits on the tower and the fan (a centered mesh) hangs off its front.
            addModel(ts.windmill[1], cx, baseY + windmillTop[1], cz, angle, 1, 1, white, lvl);
            immutable fx = windmillFan[0] * ca + windmillFan[2] * sa, fz = -windmillFan[0] * sa + windmillFan[2] * ca;
            const fan = &ts.windmill[2];
            addModel(*fan, cx + fx - (fan.lo[0] + fan.hi[0]) * 0.5f,
                    baseY + windmillFan[1] - (fan.lo[1] + fan.hi[1]) * 0.5f,
                    cz + fz - (fan.lo[2] + fan.hi[2]) * 0.5f, 0, 1, 1, white, lvl);
            break;
        case DecoKind.bridge:
            ref const MeshRef br = ts.bridges[deco.variant & 1];
            addModel(br, cx, tileY - br.lo[1], cz, theta, 1, 1, white, lvl, -br.lo[1]);
            break;
        case DecoKind.mountain:
            ref const MeshRef mt = ts.mountains[deco.variant % 3];
            addModel(mt, cx, baseY - mt.lo[1] - 0.5f, cz, (h % 6) * (3.14159265f / 3), 1, 1, white,
                    lvl, -mt.lo[1] - 0.5f);
            break;
        case DecoKind.source:
            // Spawn: a red-tinted tower facing its road.
            immutable sa = dirAngle[deco.facing];
            enum Rgb red = Rgb(1.0f, 0.45f, 0.40f);
            addShadow(ts.buildings[towerVariant], cx, cz, baseY, 1.0f);
            addModel(ts.buildings[towerVariant], cx, baseY, cz, sa, 1, 1, red, lvl);
            addModel(ts.towerTop, cx, baseY, cz, sa, 1, 1, red, lvl);
            break;
        case DecoKind.sink:
            // Goal: a blue-tinted town hall facing its road.
            immutable ka = dirAngle[deco.facing];
            enum Rgb blue = Rgb(0.55f, 0.70f, 1.0f);
            enum size_t townhall = 4;
            addShadow(ts.buildings[townhall], cx, cz, baseY, 1.0f);
            addModel(ts.buildings[townhall], cx, baseY, cz, ka, 1, 1, blue, lvl);
            break;
        case DecoKind.village:
            if (deco.variant >= numVillageProps)
                break;
            ref const MeshRef vm = ts.village[deco.variant];
            if (vm.valid) {
                immutable va = dirAngle[deco.facing];
                addShadow(vm, cx, cz, baseY, 1.0f);
                addModel(vm, cx, baseY - (vm.lo[1] < 0 ? vm.lo[1] : 0), cz, va, 1, 1, white, lvl);
            }
            break;
        case DecoKind.rock:
            ref const MeshRef hl = ts.hills[(deco.variant + h) % 6];
            addModel(hl, cx, baseY - hl.lo[1], cz, deco.facing * (3.14159265f / 3), 1, 1, white, lvl, -hl.lo[1]);
            break;
        }
    }

    /// The reference's hills and mountains: on cliffs (10%), river ends (70%) and top-level grass
    /// (10%), chosen by a hash of the cell so they need no stored state.
    private void addTerrainProp(const TileState st, ref const TexSet ts, float cx, float cz,
            float baseY, float lvl, uint h) @nogc nothrow @trusted {
        enum Rgb white = Rgb(1, 1, 1);
        const def = &tileList[st.tile];
        immutable cliffTile = def.levelIncrement != 0 && cliff[st.tile];
        immutable riverEnd = def.name == "RIVER_END";
        immutable highGrass = def.name == "GRASS" && st.level >= levelsCount - 1;
        if (!cliffTile && !riverEnd && !highGrass)
            return;
        immutable chance = riverEnd ? 0.7f : 0.1f;
        if ((h >> 3 & 0xFFFF) / 65536.0f > chance)
            return;
        immutable rot = (h >> 20) % 6 * (3.14159265f / 3);
        immutable pick = (h >> 8) % 6;
        if (highGrass || (cliffTile && def.levelIncrement >= 2)) {
            ref const MeshRef mt = ts.mountains[pick % 3];
            addModel(mt, cx, baseY - mt.lo[1] - 0.5f, cz, rot, 1, 1, white, lvl, -mt.lo[1] - 0.5f);
        } else {
            ref const MeshRef hl = ts.hills[pick];
            immutable lift = riverEnd ? -0.1f : 0.0f;
            addModel(hl, cx, baseY + lift - hl.lo[1], cz, rot, 1, 1, white, lvl, -hl.lo[1]);
        }
    }
}

// ---- terrain model support ---------------------------------------------------------------------

/// World height of one elevation level and of a tile's top above its level base (the reference's
/// LEVEL_HEIGHT and TILE_SURFACE).
private enum float levelHeight = 0.5f;
private enum float tileSurface = 1.0f;
/// Water sparkle: world-to-UV scale and opacity of the caustic layer (the reference's frequency
/// 0.9 * 0.1; its opacity is 0.1; kept close, the layer here is static).
private enum float sparkleFreq = 0.09f, sparkleOpacity = 0.30f;
/// Ground shadows: peak alpha and the ground direction (x, z) away from the light.
private enum float shadowAlpha = 0.34f;
/// Tint of the water sheen, chosen so open water lands on the reference screenshot's (56, 86, 132).
private enum Rgb waterTint = Rgb(0.74f, 0.88f, 1.0f);
/// Shoreline foam opacity (the sparkle layer's own sheen adds to it).
private enum float foamOpacity = 0.85f;
private immutable float[2] shadowDir = [0.62f, -0.78f];
/// Tile ID of plain water.
private enum size_t waterTile = 1;

/// The reference's default shift of the elevation blend towards the low texture.
private enum float levelBias = -0.3f;
/// Screen lift per world height unit; world y = tileSurface sits on the flat renderer's level 0.
private enum float yLift = levelStep / levelHeight;

/// Direction towards the light, and the n.l at which a face is fully lit (an upward face).
private immutable float[3] lightDir = [-0.35f, 0.85f, 0.40f];
private enum float lightFull = 0.85f;

/// Y rotation that turns a model's +Z front towards each HexDir (NE, E, SE, SW, W, NW).
private immutable float[6] dirAngle = [
    5 * 3.14159265f / 6, 3.14159265f / 2, 3.14159265f / 6, -3.14159265f / 6, -3.14159265f / 2,
    -5 * 3.14159265f / 6
];
private immutable float[3] windmillTop = [0, 0.685f, 0];
private immutable float[3] windmillFan = [0, 0.957f, 0.332f];

private struct ModelVert {
    float x, y, z;
    /// Elevation contribution of this vertex to the texture blend.
    float slope;
    uint rgba;
    /// Texture coordinate shift (a tile rim samples the texel next to the top's).
    float du, dv;
}

private struct TriKey {
    float depth;
    uint tri;
    ubyte variant;
}

private extern (C) int cmpTriKey(const(void)* a, const(void)* b) @nogc nothrow pure @trusted {
    immutable x = (cast(const(TriKey)*)a).depth, y = (cast(const(TriKey)*)b).depth;
    return x < y ? -1 : (x > y ? 1 : 0);
}

private uint hash2(uint a, uint b) @nogc nothrow pure @safe {
    uint x = a * 0x9E3779B1u ^ b * 0x85EBCA6Bu;
    x ^= x >> 15;
    x *= 0x2C1B3C6Du;
    x ^= x >> 12;
    return x;
}

/// Tile state -> model mesh names, as in the reference's TILE_LIST `mesh` field.
private immutable string[2][] tileMeshNames = [
    ["GRASS", "hex_grass"], ["WATER", "hex_water"], ["ROAD_A", "hex_road_A"], [
        "ROAD_B", "hex_road_B"
    ], ["ROAD_D", "hex_road_D"], ["ROAD_E", "hex_road_E"], ["ROAD_F", "hex_road_F"],
    ["ROAD_END", "hex_road_M"], ["RIVER_A", "hex_river_A"], ["RIVER_A_CURVY",
        "hex_river_A_curvy"], ["RIVER_B", "hex_river_B"], ["RIVER_D", "hex_river_D"],
    ["RIVER_E", "hex_river_E"], ["RIVER_F", "hex_river_F"], ["RIVER_END", "river_end"],
    ["COAST_A", "hex_coast_A"], ["COAST_B", "hex_coast_B"], ["COAST_C", "hex_coast_C"],
    ["COAST_D", "hex_coast_D"], ["COAST_E", "hex_coast_E"], ["COAST_SLOPE_A_LOW", "coast_slope_low"],
    ["COAST_SLOPE_A_HIGH", "coast_slope_high"], ["RIVER_A_SLOPE_LOW", "river_slope_low"],
    ["RIVER_INTO_COAST", "river_coast"], ["RIVER_CROSSING_A", "hex_river_crossing_A"],
    ["RIVER_CROSSING_B", "hex_river_crossing_B"], ["GRASS_SLOPE_HIGH", "hex_grass_sloped_high"],
    ["ROAD_A_SLOPE_HIGH", "hex_road_A_sloped_high"], ["GRASS_CLIFF", "hex_grass"],
    ["GRASS_CLIFF_C", "hex_grass"], ["GRASS_SLOPE_LOW", "hex_grass_sloped_low"],
    ["ROAD_A_SLOPE_LOW", "hex_road_A_sloped_low"], ["GRASS_CLIFF_LOW", "hex_grass"],
    ["GRASS_CLIFF_LOW_C", "hex_grass"]
];

/// Every mesh the builder places, looked up once per build.
private struct TexSet {
    MeshRef[numTiles] tile;
    MeshRef grass, bottom, towerTop;
    MeshRef[4][2] trees;
    MeshRef[buildingDefs.length] buildings;
    MeshRef[3] windmill;
    MeshRef[2] bridges;
    MeshRef[3] mountains;
    MeshRef[6] hills;
    MeshRef fort, henge, watchtower, mine, rockGold, rockLey;
    /// td-towers.glb per tower kind: levels 1-2, branch A, branch B.
    MeshRef[numStages][numTowerKinds] td;
    /// Per VillageProp: village.glb when loaded, else the hex-terrain stand-in (may be empty).
    MeshRef[numVillageProps] village;

    void resolveVillage(ref const GlbModel g) @nogc nothrow @trusted {
        foreach (i, ref n; villagePropNames) {
            MeshRef m;
            if (g.find(n[0], m))
                village[i] = m;
        }
    }

    void resolveTowers(ref const GlbModel g) @nogc nothrow @trusted {
        // Node td_<kind>_<stage>: td_arrow_1 .. td_arrow_3, then td_arrow_a1 .. a4 and b1 .. b4.
        static immutable string[numTowerKinds] kinds = [
            "arrow", "cannon", "frost", "tesla", "flame", "mine"
        ];
        static immutable string[numStages] stages = [
            "1", "2", "3", "a1", "a2", "a3", "a4", "b1", "b2", "b3", "b4"
        ];
        foreach (k; 0 .. numTowerKinds)
            foreach (s; 0 .. numStages) {
                char[32] buf = void;
                immutable n = 3 + kinds[k].length + 1 + stages[s].length;
                buf[0 .. 3] = "td_";
                buf[3 .. 3 + kinds[k].length] = kinds[k];
                buf[3 + kinds[k].length] = '_';
                buf[4 + kinds[k].length .. n] = stages[s];
                g.find(buf[0 .. n], td[k][s]);
            }
    }

    void resolve(ref const GlbModel g) @nogc nothrow @trusted {
        foreach (i, ref t; tileList)
            foreach (ref pair; tileMeshNames)
                if (pair[0] == t.name)
                    g.find(pair[1], tile[i]);
        g.find("hex_grass", grass);
        g.find("hex_grass_bottom", bottom);
        g.find("building_tower_A_top_yellow", towerTop);
        static immutable string[4][2] treeNames = [
            ["tree_single_A", "trees_A_small", "trees_A_medium", "trees_A_large"],
            ["tree_single_B", "trees_B_small", "trees_B_medium", "trees_B_large"]
        ];
        foreach (a; 0 .. 2)
            foreach (b; 0 .. 4)
                g.find(treeNames[a][b], trees[a][b]);
        foreach (i, ref d; buildingDefs)
            g.find(d.name, buildings[i]);
        static immutable string[3] windmillNames = [
            "building_windmill_yellow", "building_windmill_top_yellow",
            "building_windmill_top_fan_yellow"
        ];
        foreach (i, n; windmillNames)
            g.find(n, windmill[i]);
        foreach (i, n; bridgeNames)
            g.find(n, bridges[i]);
        foreach (i, n; mountainNames)
            g.find(n, mountains[i]);
        static immutable string[6] hillNames = [
            "hills_A", "hills_A_trees", "hills_B", "hills_B_trees", "hills_C", "hills_C_trees"
        ];
        foreach (i, n; hillNames)
            g.find(n, hills[i]);
        g.find("fort", fort);
        g.find("henge", henge);
        if (!g.find("building_watchtower_yellow", watchtower))
            g.find("building_watchtower", watchtower);
        if (!g.find("building_mine_yellow", mine))
            g.find("mine", mine);
        g.find("rock_single_A", rockGold);
        g.find("rock_single_E", rockLey);
        foreach (i, ref n; villagePropNames)
            if (n[1].length)
                g.find(n[1], village[i]);
    }
}

/// Tower colors: the kind's base tint, washed out at Lv1, full at Lv2, and a distinct accent for
/// each specialization so A and B read apart at a glance.
private immutable Rgb[numTowerKindsView] kindTint = [
    Rgb(1.00f, 0.95f, 0.85f), // arrow: warm stone
    Rgb(0.85f, 0.80f, 0.78f), // cannon: grey iron
    Rgb(0.70f, 0.88f, 1.00f), // frost: ice
    Rgb(0.82f, 0.72f, 1.00f), // tesla: violet
    Rgb(1.00f, 0.66f, 0.45f), // flame: ember
    Rgb(1.00f, 0.88f, 0.55f), // mine: gold
];
private enum int numTowerKindsView = 6;
private immutable Rgb[2][numTowerKindsView] branchTint = [
    [Rgb(0.75f, 0.95f, 0.60f), Rgb(1.00f, 0.80f, 0.50f)], // Longbow, Volley
    [Rgb(1.00f, 0.70f, 0.55f), Rgb(0.65f,
                0.65f, 0.75f)], // Cluster, Siege
    [Rgb(0.60f, 0.95f, 1.00f), Rgb(0.80f, 0.80f, 1.00f)], // Blizzard, Shatter
    [Rgb(0.65f, 0.75f, 1.00f), Rgb(1.00f,
                0.90f, 0.55f)], // Storm, Overload
    [Rgb(1.00f, 0.50f, 0.35f), Rgb(1.00f, 0.75f, 0.30f)], // Inferno, Napalm
    [Rgb(1, 1, 1), Rgb(1, 1, 1)]
];
private immutable Rgb[numTowerKindsView] flatRoof = [
    Rgb(0.45f, 0.62f, 0.30f), Rgb(0.30f, 0.30f, 0.34f), Rgb(0.45f, 0.75f, 0.95f),
    Rgb(0.55f, 0.40f, 0.85f), Rgb(0.90f, 0.40f, 0.20f), Rgb(0.85f, 0.70f, 0.25f)
];

Rgb towerTint(TowerKind k, Stage s) @nogc nothrow pure @safe {
    immutable b = kindTint[k];
    immutable br = branchOf(s);
    if (br < 0) {
        // Pale at Lv1, the kind's own color by Lv3.
        immutable f = 0.12f * (linearLevels - 1 - s) / (linearLevels - 1);
        return Rgb((1 - f) * b.r + f, (1 - f) * b.g + f, (1 - f) * b.b + f);
    }
    // The specialization's tint deepens a little with each level on the branch.
    immutable a = branchTint[k][br];
    immutable d = 1.0f - 0.05f * (tierOf(s) - linearLevels - 1);
    return Rgb(b.r * a.r * d, b.g * a.g * d, b.b * a.b * d);
}

Rgb specialTint(SpecialKind k) @nogc nothrow pure @safe {
    return k == SpecialKind.goldVein ? Rgb(1.0f, 0.80f, 0.25f) : Rgb(0.45f, 0.95f, 1.0f);
}

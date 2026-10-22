// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Tile & prop look after the KayKit Medieval Hexagon Pack by Kay Lousberg. D port for the Shiro
// engine (View layer).
//
// Builds the pseudo-3D map mesh once per generation: flat triangles in projected iso space, in
// back-to-front row order so the painter's algorithm gives correct occlusion without a depth
// buffer. Each row is a separate chunk (row-local indices) so the renderer can cull and batch
// whole rows. Vertices are 12 bytes; the renderer expands visible rows into SDL_Vertex.
module gfx.hex_mesh;

import core.stdc.stdlib : free, realloc;
import gfx.iso;
import wfc.decorations : Decoration, DecoKind, towerVariant;
import wfc.hex;
import wfc.map_session : MapSession;
import wfc.rules : EdgeInfo;
import wfc.tile_data;

struct MeshVert {
    float x, y;
    /// Packed 8-bit color, r in the low byte.
    uint rgba;
}

struct MeshOptions {
    bool decorations = true;
    bool outlines = false;
    /// Debug view: color tops by elevation instead of terrain (the JS "Level Colors").
    bool levelColors = false;
}

private struct Rgb {
    float r, g, b;
}

private uint pack(Rgb c, float shade = 1.0f, float alpha = 1.0f) @nogc nothrow pure @safe {
    static uint ch(float v) @nogc nothrow pure @safe {
        immutable x = cast(int)(v * 255.0f + 0.5f);
        return x < 0 ? 0 : (x > 255 ? 255 : x);
    }

    return ch(c.r * shade) | ch(c.g * shade) << 8 | ch(c.b * shade) << 16 | ch(alpha) << 24;
}

private immutable Rgb[numEdgeTypes] edgeColor = [
    Rgb(0.50f, 0.72f, 0.33f), // grass
    Rgb(0.27f, 0.58f, 0.80f), // water
    Rgb(0.74f, 0.60f, 0.40f), // road (only used for bands)
    Rgb(0.38f, 0.70f, 0.90f), // river (only used for bands)
    Rgb(0.89f, 0.82f, 0.60f), // coast sand
];
private immutable Rgb[levelsCount] levelColor = [
    Rgb(0.20f, 0.45f, 0.80f), Rgb(0.25f, 0.70f, 0.45f), Rgb(0.85f, 0.80f, 0.30f),
    Rgb(0.90f, 0.55f, 0.25f), Rgb(0.85f, 0.30f, 0.30f)
];
private enum Rgb dirt = Rgb(0.55f, 0.43f, 0.30f);
private enum Rgb waterWall = Rgb(0.20f, 0.42f, 0.60f);
private enum Rgb unsolved = Rgb(0.65f, 0.12f, 0.12f);
private enum Rgb outline = Rgb(0.08f, 0.10f, 0.08f);

/// Brighter with height, so ramps read as slopes.
private float heightShade(float h) @nogc nothrow pure @safe {
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

struct MapMesh {
    private MeshVert* verts;
    private int* indices;
    private size_t nVerts, capVerts, nIdx, capIdx;
    /// rowVert[r] .. rowVert[r + 1] are row r's vertices; same for rowIdx. rows + 1 entries.
    private size_t* rowVert;
    private size_t* rowIdx;
    private int rowCount;
    private size_t rowStart;
    private bool oom;
    /// Projected bounds of everything in the mesh.
    float minX = 0, minY = 0, maxX = 0, maxY = 0;
    /// Largest per-row vertex / index counts (sizes the renderer's scratch buffers).
    size_t maxRowVerts, maxRowIdx;
    /// Extent of the content of a row above / below its center line, for culling.
    float rowAbove = 0, rowBelow = 0;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(verts);
        free(indices);
        free(rowVert);
        free(rowIdx);
    }

    int rows() const @nogc nothrow pure @safe {
        return rowCount;
    }

    size_t vertexCount() const @nogc nothrow pure @safe {
        return nVerts;
    }

    size_t bytes() const @nogc nothrow pure @safe {
        return capVerts * MeshVert.sizeof + capIdx * int.sizeof + 2 * (rowCount + 1) * size_t.sizeof;
    }

    /// Row r's chunk: vertices plus indices relative to the first of those vertices.
    void row(int r, out const(MeshVert)[] v, out const(int)[] idx) const @nogc nothrow @trusted {
        assert(r >= 0 && r < rowCount);
        v = verts[rowVert[r] .. rowVert[r + 1]];
        idx = indices[rowIdx[r] .. rowIdx[r + 1]];
    }

    /// Y of row r's center line in projected space (at height 0).
    static float rowY(int r) @nogc nothrow pure @safe {
        return r * rowPitch * squash;
    }

    /// Rebuilds the mesh for the session's current map. Returns false if memory ran out.
    bool build(ref const MapSession s, const MeshOptions opt) @nogc nothrow @trusted {
        const map = &s.tiles();
        rowCount = map.rect.rows;
        nVerts = nIdx = 0;
        maxRowVerts = maxRowIdx = 0;
        oom = false;
        rowVert = cast(size_t*)realloc(rowVert, (rowCount + 1) * size_t.sizeof);
        rowIdx = cast(size_t*)realloc(rowIdx, (rowCount + 1) * size_t.sizeof);
        if (rowVert is null || rowIdx is null)
            return false;
        minX = minY = float.max;
        maxX = maxY = -float.max;

        bool[numTiles] cliff;
        foreach (i, ref t; tileList)
            cliff[i] = t.name.length >= 11 && t.name[0 .. 11] == "GRASS_CLIFF";

        foreach (r; 0 .. rowCount) {
            rowVert[r] = rowStart = nVerts;
            rowIdx[r] = nIdx;
            foreach (col; 0 .. map.rect.cols)
                addCell(s, offsetToCube(col, r), col, r, opt, cliff);
            immutable rv = nVerts - rowVert[r], ri = nIdx - rowIdx[r];
            maxRowVerts = rv > maxRowVerts ? rv : maxRowVerts;
            maxRowIdx = ri > maxRowIdx ? ri : maxRowIdx;
        }
        rowVert[rowCount] = nVerts;
        rowIdx[rowCount] = nIdx;
        // Tallest content: level 4 plus a mountain or tower; deepest: the slab below level 0.
        rowAbove = (levelsCount - 1 + 5.0f) * levelStep + hexRadius * squash;
        rowBelow = hexRadius * squash + 1.0f * levelStep;
        if (nVerts == 0)
            minX = minY = maxX = maxY = 0;
        return !oom;
    }

    // ---- primitive emitters ------------------------------------------------------------------

    private int vert(IsoPoint p, uint rgba) @nogc nothrow @trusted {
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
        verts[nVerts] = MeshVert(p.x, p.y, rgba);
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
}

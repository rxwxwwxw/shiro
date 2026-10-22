// Translucent hexagon fill plus a thick outline, drawn over the map with the 2D renderer (so it
// works the same on the GPU and classic paths). View layer.
module gfx.highlight;

import bindings.sdl3.sdl;

struct Marker {
    SDL_FColor fill, line;
    /// Outline thickness in render units.
    float width = 2;
}

/// Draws the hexagon with corners `pts` (screen positions, in order around it).
void drawHexMarker(SDL_Renderer* r, ref const float[2][6] pts, ref const Marker m) @nogc nothrow @trusted {
    // Center + 6 corners for the fill, then 6 quads (4 vertices each) for the outline.
    SDL_Vertex[7 + 24] v;
    int[18 + 36] idx;
    float cx = 0, cy = 0;
    foreach (k; 0 .. 6) {
        cx += pts[k][0] * (1.0f / 6);
        cy += pts[k][1] * (1.0f / 6);
    }
    v[0] = SDL_Vertex(SDL_FPoint(cx, cy), m.fill, SDL_FPoint(0, 0));
    foreach (k; 0 .. 6) {
        v[1 + k] = SDL_Vertex(SDL_FPoint(pts[k][0], pts[k][1]), m.fill, SDL_FPoint(0, 0));
        idx[3 * k] = 0;
        idx[3 * k + 1] = 1 + k;
        idx[3 * k + 2] = 1 + (k + 1) % 6;
    }
    // Each edge becomes a quad pushed `width` inwards.
    foreach (k; 0 .. 6) {
        immutable a = pts[k], b = pts[(k + 1) % 6];
        immutable ax = cx - a[0], ay = cy - a[1], bx = cx - b[0], by = cy - b[1];
        immutable al = sqrtf(ax * ax + ay * ay), bl = sqrtf(bx * bx + by * by);
        immutable f = al > 0 ? m.width / al : 0, g = bl > 0 ? m.width / bl : 0;
        immutable base = 7 + 4 * k;
        v[base] = SDL_Vertex(SDL_FPoint(a[0], a[1]), m.line, SDL_FPoint(0, 0));
        v[base + 1] = SDL_Vertex(SDL_FPoint(b[0], b[1]), m.line, SDL_FPoint(0, 0));
        v[base + 2] = SDL_Vertex(SDL_FPoint(b[0] + bx * g, b[1] + by * g), m.line, SDL_FPoint(0, 0));
        v[base + 3] = SDL_Vertex(SDL_FPoint(a[0] + ax * f, a[1] + ay * f), m.line, SDL_FPoint(0, 0));
        immutable o = 18 + 6 * k;
        idx[o] = base;
        idx[o + 1] = base + 1;
        idx[o + 2] = base + 2;
        idx[o + 3] = base;
        idx[o + 4] = base + 2;
        idx[o + 5] = base + 3;
    }
    SDL_RenderGeometry(r, null, v.ptr, cast(int)v.length, idx.ptr, cast(int)idx.length);
}

private extern (C) float sqrtf(float) @nogc nothrow pure;

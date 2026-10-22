// Screen point -> map cell, and the on-screen outline of a cell. View layer (no SDL here, so the
// picking math is testable headlessly).
module gfx.pick;

import gfx.camera;
import gfx.iso;

/// Cell whose top face is under screen point (sx, sy), preferring the one drawn in front. A cell's
/// top is its hexagon squashed by `squash` and lifted by its height (in levels) times `levelStep`;
/// `heightOf(col, row)` gives that height at the cell center. False if no cell is hit.
bool pickCell(ref const Camera cam, float sx, float sy, int cols, int rows, float maxHeight,
        scope float delegate(int col, int row) @nogc nothrow heightOf, out int col, out int row) @nogc nothrow {
    immutable w = cam.toWorld(sx, sy);
    // Row r's center sits at z * squash - height * levelStep and its hexagon spans hexRadius * squash
    // either side, so only rows within the lift range of the point can contain it.
    immutable reach = hexRadius * squash;
    immutable lo = (w.y - reach) / squash / rowPitch;
    immutable hi = (w.y + maxHeight * levelStep + reach) / squash / rowPitch;
    int r0 = cast(int)(lo < 0 ? 0 : lo), r1 = cast(int)(hi + 1);
    r1 = r1 >= rows ? rows - 1 : r1;
    // Rows further down the screen are drawn later, so test those first.
    for (int r = r1; r >= r0; r--) {
        immutable odd = r & 1;
        int c0 = cast(int)((w.x - 1.0f - odd) * 0.5f - 1), c1 = cast(int)((w.x + 1.0f - odd) * 0.5f + 1);
        c0 = c0 < 0 ? 0 : c0;
        c1 = c1 >= cols ? cols - 1 : c1;
        foreach (c; c0 .. c1 + 1) {
            float cx, cz;
            cellCenter(c, r, cx, cz);
            immutable dx = w.x - cx;
            immutable dz = (w.y - (cz * squash - heightOf(c, r) * levelStep)) / squash;
            immutable ax = dx < 0 ? -dx : dx, az = dz < 0 ? -dz : dz;
            // Pointy-top hexagon: |dx| <= 1 and |dz| <= R - |dx| R / 2.
            if (ax <= 1.0f && az <= hexRadius - ax * (hexRadius * 0.5f)) {
                col = c;
                row = r;
                return true;
            }
        }
    }
    return false;
}

/// Screen positions of the six corners of a cell's footprint hexagon at `level`.
void cellOutline(ref const Camera cam, int col, int row, float level, out float[2][6] pts) @nogc nothrow {
    float cx, cz;
    cellCenter(col, row, cx, cz);
    foreach (k; 0 .. 6) {
        immutable p = project(cx + cornerOffsets[k][0], cz + cornerOffsets[k][1], level);
        immutable s = cam.toScreen(p.x, p.y);
        pts[k][0] = s.x;
        pts[k][1] = s.y;
    }
}

@nogc nothrow unittest {
    Camera cam;
    cam.zoom = 20;
    cam.setViewport(0, 800, 600);
    cam.cx = 10;
    cam.cy = 5;
    scope float delegate(int, int) @nogc nothrow flat = (int c, int r) => 0.0f;
    // The center of a flat cell picks that cell.
    static immutable int[2][4] cells = [[3, 2], [4, 3], [0, 0], [7, 5]];
    foreach (cell; cells) {
        float cx, cz;
        cellCenter(cell[0], cell[1], cx, cz);
        immutable s = cam.toScreen(cx, cz * squash);
        int c, r;
        assert(pickCell(cam, s.x, s.y, 12, 8, 0, flat, c, r));
        assert(c == cell[0] && r == cell[1]);
    }
    // Far outside the map nothing is hit.
    int c, r;
    assert(!pickCell(cam, -500, -500, 12, 8, 0, flat, c, r));
    // A raised cell is picked where its lifted top is drawn, and hides the cell behind it.
    scope float delegate(int, int) @nogc nothrow raised = (int c, int r) => (c == 3 && r == 2) ? 4.0f : 0.0f;
    float cx, cz;
    cellCenter(3, 2, cx, cz);
    immutable s = cam.toScreen(cx, cz * squash - 4.0f * levelStep);
    assert(pickCell(cam, s.x, s.y, 12, 8, 4, raised, c, r) && c == 3 && r == 2);
}

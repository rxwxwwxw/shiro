// 2D camera over the projected iso plane: pan, zoom about a point, fit to bounds. View layer.
module gfx.camera;

import gfx.iso : IsoPoint;

struct Camera {
    /// Iso-space point at the center of the viewport.
    float cx = 0, cy = 0;
    /// Screen units per iso unit.
    float zoom = 20;
    /// Viewport in screen units (render coordinates); x0 skips the side panel.
    float x0 = 0, width = 1, height = 1;

    enum float minZoom = 0.5f, maxZoom = 400;

    IsoPoint toScreen(float x, float y) const @nogc nothrow pure @safe {
        return IsoPoint((x - cx) * zoom + x0 + width * 0.5f, (y - cy) * zoom + height * 0.5f);
    }

    IsoPoint toWorld(float sx, float sy) const @nogc nothrow pure @safe {
        return IsoPoint((sx - x0 - width * 0.5f) / zoom + cx, (sy - height * 0.5f) / zoom + cy);
    }

    void setViewport(float x0_, float w, float h) @nogc nothrow pure @safe {
        x0 = x0_;
        width = w > 1 ? w : 1;
        height = h > 1 ? h : 1;
    }

    void pan(float dxScreen, float dyScreen) @nogc nothrow pure @safe {
        cx -= dxScreen / zoom;
        cy -= dyScreen / zoom;
    }

    /// Multiplies the zoom, keeping the world point under (sx, sy) fixed on screen.
    void zoomAt(float factor, float sx, float sy) @nogc nothrow pure @safe {
        immutable before = toWorld(sx, sy);
        zoom *= factor;
        zoom = zoom < minZoom ? minZoom : (zoom > maxZoom ? maxZoom : zoom);
        immutable after = toWorld(sx, sy);
        cx += before.x - after.x;
        cy += before.y - after.y;
    }

    /// Centers the bounds and zooms so they fill the viewport with a small margin.
    void fit(float minX, float minY, float maxX, float maxY) @nogc nothrow pure @safe {
        immutable w = maxX - minX > 1e-3f ? maxX - minX : 1e-3f;
        immutable h = maxY - minY > 1e-3f ? maxY - minY : 1e-3f;
        immutable zx = width / w, zy = height / h;
        zoom = (zx < zy ? zx : zy) * 0.94f;
        zoom = zoom < minZoom ? minZoom : (zoom > maxZoom ? maxZoom : zoom);
        cx = (minX + maxX) * 0.5f;
        cy = (minY + maxY) * 0.5f;
    }

    /// Centers the bounds and zooms so their height fills the viewport; wider bounds run off the
    /// sides (pan to see them).
    void fitHeight(float minX, float minY, float maxX, float maxY) @nogc nothrow pure @safe {
        immutable h = maxY - minY > 1e-3f ? maxY - minY : 1e-3f;
        zoom = height / h * 0.98f;
        zoom = zoom < minZoom ? minZoom : (zoom > maxZoom ? maxZoom : zoom);
        cx = (minX + maxX) * 0.5f;
        cy = (minY + maxY) * 0.5f;
    }
}

@nogc nothrow pure @safe unittest {
    Camera c;
    c.setViewport(100, 800, 600);
    c.cx = 10;
    c.cy = 5;
    c.zoom = 4;
    // The camera center lands at the middle of the viewport, and the transforms round-trip.
    immutable s = c.toScreen(10, 5);
    assert(s.x == 500 && s.y == 300);
    immutable w = c.toWorld(123, 456);
    immutable back = c.toScreen(w.x, w.y);
    assert(back.x > 122.99f && back.x < 123.01f && back.y > 455.99f && back.y < 456.01f);
    // Zooming keeps the point under the cursor fixed.
    immutable p = c.toWorld(200, 100);
    c.zoomAt(2.5f, 200, 100);
    immutable q = c.toScreen(p.x, p.y);
    assert(q.x > 199.9f && q.x < 200.1f && q.y > 99.9f && q.y < 100.1f && c.zoom == 10);
    // Fit: bounds centered and fully visible.
    c.fit(0, 0, 80, 30);
    immutable a = c.toScreen(0, 0), b = c.toScreen(80, 30);
    assert(a.x >= 100 && b.x <= 900 && a.y >= 0 && b.y <= 600);
    assert(c.cx == 40 && c.cy == 15);
}

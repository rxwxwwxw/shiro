# Builds the village hub props, a medieval Vietnamese village crossed with Aztec stonework (the
# style of td_towers.py), as low-poly meshes colored through the Hex-Map-WFC palette atlas, and
# exports them:
#
#   blender -b --python scripts/blender/village_props.py -- OUT.glb [PREVIEW.png PALETTE.png]
#
# OUT.glb defaults to assets/models/village.glb; PALETTE.png is the Hex-Map-WFC palette
# (third-party/Hex-Map-WFC/public/assets/textures/default.png), only needed for the preview.
# Units match hex-terrain.glb and td-towers.glb: a hex tile is 2 wide across its flats (corners on
# +-x), its top at height 0, and every prop fits on one tile. Node names are village_<prop>. +x is
# east: the gate's passage runs west-east; doors and stairs face -y, towards the viewer.
import bpy, bmesh, math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lowpoly import *  # noqa: E402,F401,F403

TAU = 2 * math.pi
HEX = math.pi / 6  # rotation that puts a 6-sided cylinder's flats on the hex tile's flats
TILE_R = 1.1547  # hex tile corner radius (gfx.iso hexRadius)


def curved_roof(b, w, d, h, sw, m=at(), curl=0.12, thick=0.03, shade=0.0):
    """Vietnamese hip roof: concave slopes rising to a ridge, eave corners swept up."""
    g = bmesh.ops.create_grid(b.bm, x_segments=8, y_segments=8, size=1.0)
    vs = g["verts"]
    ridge = max(0.0, 1.0 - d / w)  # longer than deep: a ridge along x
    for v in vs:
        u, t = v.co.x, v.co.y
        du = max(0.0, abs(u) - ridge) / (1 - ridge)
        k = max(du, abs(t))
        v.co.z = h * (1 - k) ** 1.7 + curl * (abs(u) * abs(t)) ** 4
        v.co.x *= w / 2
        v.co.y *= d / 2
    faces = list({f for v in vs for f in v.link_faces})
    res = bmesh.ops.solidify(b.bm, geom=faces, thickness=thick)
    allv = list({v for f in res["geom"] if isinstance(f, bmesh.types.BMFace) for v in f.verts} | set(vs))
    b._place(allv, m, sw, shade)
    b.box(w * ridge + 0.04, 0.05, 0.04, sw, m @ at(0, 0, h - 0.01), shade=0.6)
    return w * ridge / 2  # half length of the ridge, for finials


def thatch(b, w, d, h, sw, m=at(), ridge=0.45, shade=0.0):
    """Steep straight-sloped thatch hip roof (ridge along x) with a thick fringe at the eaves."""
    bm = b.bm
    e = [bm.verts.new(p) for p in ((-w / 2, -d / 2, 0), (w / 2, -d / 2, 0), (w / 2, d / 2, 0),
                                   (-w / 2, d / 2, 0))]
    r = [bm.verts.new((-w * ridge / 2, 0, h)), bm.verts.new((w * ridge / 2, 0, h))]
    for f in ((e[0], e[1], r[1], r[0]), (e[2], e[3], r[0], r[1]), (e[1], e[2], r[1]),
              (e[3], e[0], r[0]), (e[3], e[2], e[1], e[0])):
        bm.faces.new(f)
    b._place(e + r, m, sw, shade)
    b.box(w + 0.03, d + 0.03, 0.06, sw, m @ at(0, 0, -0.05), shade=shade + 0.4, taper=0.96)
    b.box(w * ridge + 0.06, 0.07, 0.05, DARKWOOD, m @ at(0, 0, h - 0.03))  # ridge binding
    return w * ridge / 2


def tiers(b, widths, step, sw, m=at(), trim=None):
    """Aztec talud-tablero platform: battered (talud) tiers each with a framed panel (tablero)."""
    z = 0.0
    for i, w in enumerate(widths):
        b.box(w, w, step, sw, m @ at(0, 0, z), taper=0.88, shade=0.1 * i)
        if trim:
            b.box(w * 0.91, w * 0.91, step * 0.3, trim, m @ at(0, 0, z + step * 0.66))
        z += step
    return z


def stairs(b, width, height, run, sw, m=at(), n=5):
    """Front stair (towards +x) climbing `height` over `run`, flanked by balustrades."""
    for i in range(n):
        f = (i + 1) / n
        b.box(run / n, width, height * f, sw, m @ at(run * (1 - (i + 0.5) / n), 0, 0), shade=0.15)
    for s in (1, -1):
        # Balustrade along the slope, high end at x = 0.
        b.box(math.hypot(height, run), 0.06, 0.06, SLATE, m @ at(run / 2, s * width / 2, height / 2)
              @ rot(math.atan2(height, run), "Y") @ at(0, 0, -0.02))


def serpent(b, sw, m=at()):
    """Feathered-serpent head (Quetzalcoatl) at the foot of a stair, facing +x."""
    b.box(0.12, 0.1, 0.08, sw, m)
    b.box(0.07, 0.11, 0.03, RED, m @ at(0.05, 0, 0.0))  # open jaw
    for s in (1, -1):
        b.ball(0.015, BLACK, m @ at(0.03, s * 0.045, 0.07))
        b.spike(0.025, 0.08, JADE, m @ at(-0.04, s * 0.04, 0.07) @ rot(-0.7, "Y"), seg=3, prism=0)


def glyph(b, s, m=at(), sw=JADE, ink=RED):
    """Carved Aztec day-sign panel of size `s` on a wall facing local +x: frame, step-fret, eye."""
    with b.xf(m @ rot(math.pi / 2, "Y")):  # local z now points out of the wall
        b.box(s, s, 0.012, sw)
        b.box(s * 0.8, s * 0.8, 0.02, sw, shade=0.45)
        for k in range(3):  # stepped fret (xicalcoliuhqui) climbing across the panel
            b.box(s * 0.18, s * 0.18 * (k + 1), 0.03, ink, at(s * (0.22 - k * 0.2), s * (0.09 * k - 0.24), 0))
        b.cyl(s * 0.12, s * 0.12, 0.035, SNOW, at(-s * 0.18, s * 0.2, 0), seg=6)
        b.cyl(s * 0.06, s * 0.06, 0.04, BLACK, at(-s * 0.18, s * 0.2, 0), seg=6)


def footing(b, x, y, r=0.06):
    b.cyl(r, r * 1.2, 0.05, ROCK, at(x, y, 0), seg=6, shade=0.2)


# ---- nhà sàn: timber stilt house under a steep thatch roof ---------------------------------
def stilt_house(b):
    floor = 0.42
    for x in (-0.52, -0.17, 0.17, 0.52):
        for y in (-0.3, 0.3):
            footing(b, x, y)
            b.cyl(0.035, 0.032, floor, DARKWOOD, at(x, y, 0.04), seg=6)
    b.box(1.22, 0.74, 0.06, WOOD, at(-0.04, 0, floor))  # floor
    b.box(0.32, 0.74, 0.04, WOOD, at(0.68, 0, floor), shade=0.2)  # open veranda to the east
    for y in (-0.36, 0.36):
        b.box(0.32, 0.03, 0.12, DARKWOOD, at(0.68, y, floor + 0.04))
    b.box(0.03, 0.74, 0.12, DARKWOOD, at(0.83, 0, floor + 0.04))
    with b.xf(at(-0.1, 0, floor + 0.06)):  # woven bamboo walls in a timber frame
        b.box(0.98, 0.6, 0.34, SAND, shade=0.1)
        for x in (-0.49, 0.49):
            for y in (-0.3, 0.3):
                b.box(0.05, 0.05, 0.36, DARKWOOD, at(x, y, 0))
        for z in (0.0, 0.32):
            b.box(1.0, 0.62, 0.04, DARKWOOD, at(0, 0, z))
        b.box(0.2, 0.03, 0.26, DARKWOOD, at(0.18, -0.3, 0.02))  # door
        for x in (-0.3, -0.06):
            b.box(0.12, 0.03, 0.1, BLACK, at(x, -0.3, 0.14))  # shuttered windows
            b.box(0.14, 0.035, 0.02, DARKWOOD, at(x, -0.3, 0.24))
    # Ladder down from the door to the yard.
    with b.xf(at(0.18, -0.48, 0)):
        for x in (-0.07, 0.07):
            b.box(0.025, 0.025, 0.5, WOOD, at(x, 0, 0) @ rot(-0.38, "X"))
        for k in range(4):
            b.box(0.16, 0.02, 0.02, WOOD, at(0, 0.03 + k * 0.045, 0.1 + k * 0.1))
    half = thatch(b, 1.5, 1.0, 0.5, TAN, at(-0.04, 0, floor + 0.38), ridge=0.4)
    for s in (1, -1):  # crossed gable horns at the ridge ends
        for t in (1, -1):
            b.spike(0.025, 0.2, DARKWOOD, at(-0.04 + s * half, 0, floor + 0.84)
                    @ rot(s * 0.5, "Y") @ rot(t * 0.5, "X"), seg=4, prism=0.3)
    # Rice jars and a firewood stack between the stilts.
    for (x, y) in ((-0.38, -0.05), (-0.26, 0.1)):
        b.cyl(0.07, 0.05, 0.14, CLAY, at(x, y, 0), seg=7)
    b.box(0.26, 0.12, 0.1, WOOD, at(0.3, 0.08, 0), shade=0.3)


# ---- đình: communal hall with sweeping upturned eaves --------------------------------------
def dinh_hall(b):
    b.box(1.56, 1.1, 0.1, ROCK, shade=0.2)  # stone plinth
    b.box(1.46, 1.0, 0.04, SAND, at(0, 0, 0.1))
    for k in range(3):  # front steps (towards -y)
        b.box(0.5, 0.08, 0.1 - k * 0.033, SAND, at(0, -0.58 - k * 0.07, 0), shade=0.2)
    z = 0.14
    for x in (-0.6, -0.2, 0.2, 0.6):
        for y in (-0.38, 0.0, 0.38):
            b.cyl(0.04, 0.035, 0.44, BRICK, at(x, y, z), seg=8)
            b.cyl(0.055, 0.055, 0.03, STONE, at(x, y, z), seg=8)
    # Lattice back wall and solid side walls; the front stays open to the yard.
    b.box(1.2, 0.04, 0.38, DARKWOOD, at(0, 0.38, z))
    for x in (-0.36, -0.12, 0.12, 0.36):
        b.box(0.03, 0.05, 0.38, WOOD, at(x, 0.36, z))
    for x in (-0.6, 0.6):
        b.box(0.04, 0.76, 0.32, WOOD, at(x, 0, z), shade=0.2)
    b.box(0.3, 0.2, 0.18, RED, at(0, 0.24, z))  # altar
    b.box(0.32, 0.22, 0.03, GOLD, at(0, 0.24, z + 0.18))
    b.cyl(0.03, 0.04, 0.06, AMBER, at(0, 0.24, z + 0.21), seg=6)  # incense urn
    b.box(1.34, 0.9, 0.06, DARKWOOD, at(0, 0, z + 0.44))  # tie beams
    top = z + 0.5
    # Lower skirt roof, then the main roof with dramatic curled corners.
    curved_roof(b, 1.8, 1.32, 0.12, CLAY, at(0, 0, top - 0.02), curl=0.16, shade=0.25)
    half = curved_roof(b, 1.62, 1.1, 0.46, CLAY, at(0, 0, top + 0.06), curl=0.34)
    ridge = top + 0.06 + 0.46
    b.box(half * 2 + 0.1, 0.08, 0.07, BRICK, at(0, 0, ridge - 0.03))
    for s in (1, -1):  # rồng: dragon finials curling up at the ridge ends
        with b.xf(at(s * (half + 0.04), 0, ridge)):
            b.spike(0.05, 0.24, JADE, rot(s * 0.6, "Y"), seg=5, prism=0.4)
            b.spike(0.03, 0.12, JADE, at(s * 0.06, 0, 0.12) @ rot(-s * 0.9, "Y"), seg=4, prism=0)
    b.ball(0.06, GOLD, at(0, 0, ridge + 0.05))  # pearl between the dragons
    b.cyl(0.02, 0.02, 0.05, GOLD, at(0, 0, ridge), seg=4)


# ---- teocalli: talud-tablero stepped pyramid crowned by a shrine ---------------------------
def temple(b):
    widths = [1.52, 1.22, 0.94, 0.68]
    deck = tiers(b, widths, 0.18, STONE, trim=RED)
    with b.xf(rot(-math.pi / 2, "Z")):  # stair and serpents face -y
        stairs(b, 0.3, deck, 0.46, SAND, at(0.3, 0, 0), n=8)
        for s in (1, -1):
            serpent(b, JADE, at(0.8, s * 0.2, 0))
    with b.xf(at(0, 0.04, deck)):
        b.box(0.5, 0.42, 0.3, SAND)
        b.box(0.18, 0.03, 0.22, BLACK, at(0, -0.21, 0))  # doorway
        for s in (1, -1):
            b.box(0.04, 0.04, 0.26, RED, at(s * 0.11, -0.21, 0))
            glyph(b, 0.11, at(s * 0.18, -0.215, 0.16) @ rot(-math.pi / 2, "Z"), sw=SAND, ink=JADE)
        b.box(0.54, 0.46, 0.06, RED, at(0, 0, 0.3))
        b.box(0.5, 0.42, 0.12, JADE, at(0, 0, 0.36), taper=0.85)
        for k in range(5):  # roof crest of stepped merlons
            b.box(0.07, 0.05, 0.12, SAND, at(-0.2 + k * 0.1, 0, 0.48), taper=0.6)
            b.ball(0.025, GOLD, at(-0.2 + k * 0.1, 0, 0.62))
    for s in (1, -1):  # braziers on the top platform
        with b.xf(at(s * 0.26, -0.24, deck)):
            b.cyl(0.04, 0.06, 0.06, AMBER, seg=6)
            b.spike(0.04, 0.12, FIRE, at(0, 0, 0.06), seg=5)
    for i, w in enumerate(widths[:-1]):  # glyph panels on the east and west faces
        for s in (1, -1):
            glyph(b, 0.12, at(s * (w * 0.455 + 0.006), 0, 0.18 * i + 0.1) @ rot(0 if s > 0 else math.pi, "Z"))


# ---- cổng làng: village gate, an arch between glyph-carved pillars ---------------------------
def gate(b):
    with b.xf(rot(math.pi / 2, "Z")):  # built along x, then turned so the passage runs west-east
        h = 0.86
        for s in (1, -1):
            x = s * 0.44
            b.box(0.3, 0.3, 0.06, ROCK, at(x, 0, 0), shade=0.2)
            b.box(0.22, 0.22, h, SAND, at(x, 0, 0.06), taper=0.94)
            for k in range(3):
                z = 0.18 + k * 0.22
                for f in (1, -1):  # carved faces looking along the passage
                    glyph(b, 0.15, at(x, f * 0.104, 0.06 + z) @ rot(f * math.pi / 2, "Z"))
                glyph(b, 0.15, at(x + s * 0.104, 0, 0.06 + z) @ rot(0 if s > 0 else math.pi, "Z"))
            # Stepped Aztec capital and a lotus bud.
            b.box(0.26, 0.26, 0.05, STONE, at(x, 0, 0.06 + h))
            b.box(0.2, 0.2, 0.05, RED, at(x, 0, 0.11 + h))
            # Low wing wall to the tile's edge.
            b.box(0.3, 0.12, 0.34, SAND, at(s * 0.72, 0, 0), shade=0.15)
            curved_roof(b, 0.36, 0.2, 0.06, CLAY, at(s * 0.72, 0, 0.34), curl=0.04)
        # Masonry arch: voussoirs round from pillar to pillar, a spandrel block above.
        n = 9
        for i in range(n):
            a = math.pi * (i + 0.5) / n
            b.box(0.09, 0.2, 0.06, STONE, at(0.33 * math.cos(a), 0, 0.5 + 0.22 * math.sin(a))
                  @ rot(math.pi / 2 - a, "Y"), shade=0.1 * (i % 2))
        b.box(0.74, 0.2, 0.16, SAND, at(0, 0, 0.72))
        for f in (1, -1):  # name plaques over the passage
            b.box(0.34, 0.02, 0.1, GOLD, at(0, f * 0.105, 0.75))
            b.box(0.3, 0.025, 0.07, RED, at(0, f * 0.11, 0.765))
        top = 0.88
        curved_roof(b, 1.3, 0.42, 0.16, CLAY, at(0, 0, top), curl=0.2)
        b.box(0.42, 0.18, 0.14, SAND, at(0, 0, top + 0.12))
        curved_roof(b, 0.78, 0.3, 0.16, CLAY, at(0, 0, top + 0.26), curl=0.14)
        b.ball(0.045, GOLD, at(0, 0, top + 0.44))


# ---- chợ: market stall under a striped awning ----------------------------------------------
def market_stall(b):
    for (x, y, h) in ((0.38, -0.26, 0.56), (-0.38, -0.26, 0.56), (0.38, 0.26, 0.7), (-0.38, 0.26, 0.7)):
        b.cyl(0.025, 0.025, h, DARKWOOD, at(x, y, 0), seg=5)
    with b.xf(at(0, 0, 0.63) @ rot(-math.atan2(0.14, 0.56), "X")):  # awning sloping towards -y
        for k in range(6):
            b.box(0.16, 0.66, 0.025, RED if k % 2 else CREAM, at(-0.4 + k * 0.16, 0, 0))
        for k in range(6):  # scalloped valance
            b.box(0.15, 0.02, 0.06, RED if k % 2 else CREAM, at(-0.4 + k * 0.16, -0.33, -0.06))
    b.box(0.8, 0.36, 0.26, WOOD, at(0, -0.04, 0))
    b.box(0.86, 0.42, 0.03, DARKWOOD, at(0, -0.04, 0.26))
    fruit = ((ORANGE, -0.27), (LIME, -0.08), (CORAL, 0.11), (AMBER, 0.3))
    for sw, x in fruit:
        b.cyl(0.08, 0.06, 0.05, TAN, at(x, -0.06, 0.29), seg=8, shade=0.3)  # flat baskets
        for (dx, dy) in ((0, 0), (0.035, 0.03), (-0.035, 0.03), (0.0, -0.035), (0.0, 0.0)):
            b.ball(0.03, sw, at(x + dx, -0.06 + dy, 0.35 + (0.03 if (dx, dy) == (0.0, 0.0) else 0)))
    for k in range(4):  # banana hand hanging from the awning
        b.spike(0.015, 0.09, AMBER, at(0.24 + k * 0.02, -0.2, 0.5) @ rot(math.pi + 0.3 * (k - 1.5), "X"),
                seg=4, prism=0.6)
    b.ball(0.05, RED, at(-0.26, -0.22, 0.48), sq=(1, 1, 1.3))  # paper lantern
    b.cyl(0.02, 0.02, 0.025, GOLD, at(-0.26, -0.22, 0.53), seg=6)
    for (x, y) in ((0.52, -0.32), (0.56, -0.15)):  # clay pots and a stool out front
        b.cyl(0.06, 0.045, 0.12, CLAY, at(x, y, 0), seg=7)
    b.cyl(0.06, 0.06, 0.1, DARKWOOD, at(-0.5, -0.36, 0), seg=6)
    b.cyl(0.11, 0.09, 0.1, TAN, at(-0.12, -0.4, 0), seg=9, shade=0.2)  # rice basket
    b.ball(0.08, SNOW, at(-0.12, -0.4, 0.1), sq=(1, 1, 0.4))


# ---- đèn lồng: lantern post with a pair of silk lanterns -----------------------------------
def lantern(b):
    b.cyl(0.14, 0.16, 0.06, ROCK, rot(HEX, "Z"), seg=6, shade=0.2)
    b.box(0.1, 0.1, 0.12, SAND, at(0, 0, 0.06), taper=0.8)
    glyph(b, 0.07, at(0.045, 0, 0.08))
    b.cyl(0.03, 0.025, 0.86, DARKWOOD, at(0, 0, 0.18), seg=6)
    b.box(0.5, 0.04, 0.04, DARKWOOD, at(0, 0, 0.94))  # cross arm
    for s in (1, -1):
        b.spike(0.02, 0.06, DARKWOOD, at(s * 0.25, 0, 0.96) @ rot(s * 1.2, "Y"), seg=4, prism=0)
        with b.xf(at(s * 0.2, 0, 0.94)):
            b.cyl(0.003, 0.003, 0.06, BLACK, at(0, 0, -0.06), seg=3)
            b.cyl(0.03, 0.03, 0.02, GOLD, at(0, 0, -0.08), seg=8)
            b.ball(0.08, RED, at(0, 0, -0.17), sub=2, sq=(1, 1, 0.95), shade=0.1)
            for k in range(3):  # ribs
                b.cyl(0.082, 0.082, 0.006, AMBER, at(0, 0, -0.2 + k * 0.03), seg=10)
            b.cyl(0.03, 0.03, 0.02, GOLD, at(0, 0, -0.26), seg=8)
            b.spike(0.012, 0.09, RED, at(0, 0, -0.27) @ rot(math.pi, "X"), seg=4, prism=0.8)  # tassel
    b.ball(0.04, GOLD, at(0, 0, 1.04))


# ---- trees --------------------------------------------------------------------------------
def frond(b, length, droop, sw, m, segs=4):
    """Palm frond: a chain of flat tapered blades bending down from its base along +x."""
    with b.xf(m):
        for i in range(segs):
            l = length / segs
            with b.xf(rot(droop * (i + 1) / segs, "Y")):
                w = 0.13 * (1 - 0.18 * i)
                b.box(l, w, 0.012, sw, at(l / 2, 0, 0), shade=0.1 * i, taper=0.7)
            b.stack[-1] = b.stack[-1] @ rot(droop * (i + 1) / segs, "Y") @ at(l, 0, 0)


def palm(b):
    b.cyl(0.14, 0.16, 0.04, SAND, seg=7, shade=0.3)
    x = 0.0
    z = 0.02
    n = 8
    for i in range(n):  # curved, ringed trunk
        t = (i + 1) / n
        nx = 0.22 * t * t
        r = 0.065 - 0.025 * t
        b.cyl(r, r * 0.85, 0.19, UMBER if i % 2 else TAUPE, at(x, 0, z) @ rot(math.atan2(nx - x, 0.19), "Y"),
              seg=6)
        x, z = nx, z + 0.185
    with b.xf(at(x, 0, z)):
        b.ball(0.07, LEAF, shade=0.4)
        for i in range(9):
            a = i * TAU / 9 + 0.2
            frond(b, 0.6 + 0.06 * (i % 2), 0.75, LEAF if i % 2 else LIME,
                  rot(a, "Z") @ rot(-0.45, "Y"))
        for i in range(3):
            a = i * TAU / 3 + 0.8
            b.ball(0.05, DARKWOOD, at(0.07 * math.cos(a), 0.07 * math.sin(a), -0.07))


def banana(b):
    b.cyl(0.2, 0.22, 0.03, UMBER, seg=7, shade=0.3)
    stems = ((0.0, 0.0, 0.62), (0.14, 0.1, 0.46), (-0.12, 0.08, 0.38))
    for j, (x, y, h) in enumerate(stems):
        b.cyl(0.05, 0.035, h, LEAF, at(x, y, 0.02), seg=6, shade=0.25)
        with b.xf(at(x, y, h)):
            for i in range(5):
                a = i * TAU / 5 + j * 0.9
                with b.xf(rot(a, "Z") @ rot(-0.4 - 0.15 * (i % 2), "Y")):
                    # A broad paddle leaf drooping away from the stem, with a dark midrib.
                    b.ball(0.11, LIME if (i + j) % 2 else LEAF, at(0.3, 0, -0.04) @ rot(0.35, "Y"),
                           sq=(2.9, 1.0, 0.12))
                    b.box(0.6, 0.015, 0.02, LEAF, at(0.3, 0, -0.03) @ rot(0.35, "Y"), shade=0.6)
    # Purple heart and a bunch of green bananas hanging from the tallest stem.
    with b.xf(at(0.06, -0.06, 0.5)):
        b.cyl(0.008, 0.008, 0.12, LEAF, rot(2.6, "X"), seg=4)
        for k in range(6):
            a = k * TAU / 6
            b.spike(0.015, 0.08, LIME, at(0.03 * math.cos(a), 0.03 * math.sin(a) - 0.04, -0.04)
                    @ rot(math.pi - 0.4, "X"), seg=4, prism=0.6)
        b.spike(0.035, 0.1, CORAL, at(0, -0.06, -0.12) @ rot(math.pi, "X"), seg=5, prism=0.4, shade=0.4)


# ---- ruộng: flooded rice paddy ringed by earth dikes ----------------------------------------
def paddy_dike(b):
    r = TILE_R * 0.98
    b.cyl(r * 0.96, r * 0.96, 0.03, ICE, rot(HEX, "Z"), seg=6, shade=0.35)  # flooded field
    b.cyl(r * 0.93, r * 0.93, 0.01, LEAF, at(0, 0, 0.0) @ rot(HEX, "Z"), seg=6, shade=0.6)  # mud under
    wall = 0.12
    for k in range(6):  # a dike along every tile edge
        a = HEX + k * TAU / 6
        d = r * math.cos(HEX) - wall / 2
        b.box(wall, r + 0.04, 0.08, SAND, at(d * math.cos(a), d * math.sin(a), 0) @ rot(a, "Z"),
              taper=0.7)
    b.box(r * 2 * math.cos(HEX) - 0.1, 0.1, 0.07, SAND, rot(math.pi / 3, "Z"), taper=0.7)  # cross dike
    # Rows of rice seedlings in the water either side of the cross dike.
    rows = []
    for i in range(-3, 4):
        for j in range(-3, 4):
            x = i * 0.2 + (j % 2) * 0.1
            y = j * 0.19
            if math.hypot(x, y) > r * 0.74:
                continue
            # Skip the cross dike (along 60 degrees).
            if abs(-math.sin(math.pi / 3) * x + math.cos(math.pi / 3) * y) < 0.1:
                continue
            rows.append((x, y))
    for n, (x, y) in enumerate(rows):
        for k in range(3):
            a = k * TAU / 3 + n
            b.spike(0.012, 0.13 + 0.03 * (k % 2), LIME if n % 3 else LEAF,
                    at(x + 0.015 * math.cos(a), y + 0.015 * math.sin(a), 0.02)
                    @ rot(0.25, "Y") @ rot(0, "X"), seg=3, prism=0)


MAKERS = dict(stilt_house=stilt_house, dinh_hall=dinh_hall, temple=temple, gate=gate,
              market_stall=market_stall, lantern=lantern, palm=palm, banana=banana,
              paddy_dike=paddy_dike)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[0] if argv else "assets/models/village.glb"
    preview = argv[1] if len(argv) > 1 else None
    palette = argv[2] if len(argv) > 2 else None
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mat = atlas_material(palette)
    obs = []
    for kind, fn in MAKERS.items():
        b = Builder()
        fn(b)
        obs.append(b.finish(f"village_{kind}", mat))
    bpy.ops.object.select_all(action="DESELECT")
    for ob in obs:
        ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=True, export_apply=True,
                              export_materials="NONE", export_yup=True)
    for ob in obs:
        print(f"{ob.name}: {len(ob.data.polygons)} faces, {tuple(round(d, 2) for d in ob.dimensions)}")
    if preview:
        render_preview(obs, preview)


def render_preview(obs, path):
    sc = bpy.context.scene
    for i, ob in enumerate(obs):
        ob.location = ((i % 5) * 2.4, -(i // 5) * 2.4, 0)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 12.5
    cam.location = (4.8 + 9, -1.2 - 9, 9.5)
    cam.rotation_euler = (math.radians(55), 0, math.radians(45))
    sc.camera = cam
    light_scene(sc)
    sc.render.resolution_x, sc.render.resolution_y = 1600, 1000
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


main()

# Builds the tower defense structures, Aztec stonework crossed with medieval Vietnamese timber,
# as faceted meshes colored through the Hex-Map-WFC palette atlas, and exports them:
#
#   blender -b --python scripts/blender/td_towers.py -- OUT.glb [PREVIEW.png PALETTE.png]
#
# Units match hex-terrain.glb: a hex tile is 2 wide, its top at height 0. Every upgrade stage has
# its own model; node names are what gfx.hex_mesh looks up: td_<kind>_1 .. td_<kind>_3 for the
# levels before the branch, td_<kind>_a1 .. a4 and td_<kind>_b1 .. b4 for the two branches (the
# mine climbs 1 .. 3, a1 .. a4).
import bpy, bmesh, math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lowpoly import *  # noqa: E402,F401,F403
from mathutils import Matrix  # noqa: E402

TAU = 2 * math.pi
HEX = math.pi / 6  # rotation that puts a 6-sided cylinder's flats on the hex tile's flats


class DetailBuilder(Builder):
    """Builder with more geometry than the village props: round parts get twice the segments,
    balls one more subdivision, and boxes a small chamfer so edges catch the light."""

    def cyl(self, r1, r2, h, sw, m=Matrix.Identity(4), seg=8, shade=0.0, caps=True):
        return super().cyl(r1, r2, h, sw, m, seg=seg * 2 if seg >= 8 else seg, shade=shade, caps=caps)

    def ball(self, r, sw, m=Matrix.Identity(4), sub=1, shade=0.0, sq=(1, 1, 1)):
        return super().ball(r, sw, m, sub=sub + 1, shade=shade, sq=sq)

    def box(self, sx, sy, sz, sw, m=Matrix.Identity(4), shade=0.0, taper=1.0):
        before = set(self.bm.verts)
        vs = bmesh.ops.create_cube(self.bm, size=1.0)["verts"]
        if taper != 1.0:
            for v in vs:
                if v.co.z > 0:
                    v.co.x *= taper
                    v.co.y *= taper
        bmesh.ops.transform(self.bm, matrix=scale(sx, sy, sz), verts=vs)
        if min(sx, sy) > 0.15 and sz > 0.04:
            edges = list({e for v in vs for e in v.link_edges})
            bmesh.ops.bevel(self.bm, geom=list(vs) + edges, offset=min(0.012, min(sx, sy, sz) * 0.15),
                            segments=1, affect="EDGES", profile=0.5)
            vs = [v for v in self.bm.verts if v not in before]
        return self._place(vs, m @ at(0, 0, sz / 2), sw, shade)


def curved_roof(b, w, d, h, sw, m=at(), curl=0.12, thick=0.03, shade=0.0):
    """Vietnamese hip roof: concave slopes rising to a ridge, eave corners swept up."""
    g = bmesh.ops.create_grid(b.bm, x_segments=16, y_segments=16, size=1.0)
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
    # Ridge ends and the very top get a darker cap.
    b.box(w * ridge + 0.04, 0.05, 0.04, sw, m @ at(0, 0, h - 0.01), shade=0.6)


def pillars(b, r, h, n, sw, m=at(), rad=0.03, phase=math.pi / 4):
    for i in range(n):
        a = phase + i * TAU / n
        b.cyl(rad, rad, h, sw, m @ at(r * math.cos(a), r * math.sin(a), 0), seg=6)


def tiers(b, widths, step, sw, m=at(), trim=None):
    """Aztec stepped platform: battered (talud) tiers with a lip (tablero) band on each."""
    z = 0.0
    for i, w in enumerate(widths):
        b.box(w, w, step, sw, m @ at(0, 0, z), taper=0.9, shade=0.1 * i)
        if trim:
            b.box(w * 0.92, w * 0.92, step * 0.25, trim, m @ at(0, 0, z + step * 0.7))
        z += step
    return z


def stairs(b, width, height, run, sw, m=at(), n=5):
    """Front stair (towards +x) climbing `height` over `run`, flanked by balustrades."""
    for i in range(n):
        f = (i + 1) / n
        b.box(run / n, width, height * f, sw, m @ at(run * (1 - (i + 0.5) / n), 0, 0), shade=0.15)
    for s in (1, -1):
        b.box(run, 0.05, 0.06, SLATE, m @ at(run / 2, s * width / 2, 0) @ rot(-math.atan2(height, run), "Y"))


def serpent(b, sw, m=at()):
    """Feathered-serpent head (Quetzalcoatl) at the foot of a stair, facing +x."""
    b.box(0.12, 0.1, 0.08, sw, m)
    b.box(0.07, 0.11, 0.03, RED, m @ at(0.05, 0, 0.0))  # open jaw
    for s in (1, -1):
        b.ball(0.015, BLACK, m @ at(0.03, s * 0.045, 0.07))
        b.spike(0.025, 0.08, JADE, m @ at(-0.04, s * 0.04, 0.07) @ rot(-0.7, "Y"), seg=3, prism=0)


def sun_disc(b, r, m=at(), rays=12):
    """Gold sun stone standing upright, facing +x."""
    with b.xf(m @ rot(math.pi / 2, "Y")):
        b.cyl(r, r, 0.04, GOLD, seg=16)
        b.cyl(r * 0.55, r * 0.55, 0.06, AMBER, seg=12)
        b.cyl(r * 0.22, r * 0.22, 0.08, JADE, seg=8)
        for i in range(rays):
            a = i * TAU / rays
            b.spike(0.03, r * 0.35, GOLD, at(r * math.cos(a), r * math.sin(a), 0.02) @ rot(a, "Z")
                    @ rot(math.pi / 2, "Y"), seg=3, prism=0)


def crossbow(b, size, m=at()):
    """Nỏ thần: a heavy crossbow on a post, aimed along +x."""
    with b.xf(m):
        b.cyl(0.03, 0.03, 0.12 * size, DARKWOOD, seg=5)
        with b.xf(at(0, 0, 0.12 * size)):
            b.box(0.42 * size, 0.06 * size, 0.05 * size, BRICK, at(0.04 * size, 0, 0))  # stock
            b.box(0.05 * size, 0.56 * size, 0.04 * size, DARKWOOD, at(0.22 * size, 0, 0.0))  # prod
            for s in (1, -1):
                b.box(0.03 * size, 0.06 * size, 0.05 * size, GOLD, at(0.22 * size, s * 0.28 * size, 0))
            b.spike(0.02 * size, 0.18 * size, IRON, at(0.22 * size, 0, 0.03 * size) @ rot(math.pi / 2, "Y"),
                    seg=4, prism=0.6)  # bolt


def plinth(b, r=0.56):
    """Shared footing: a hexagonal stone step so every tower reads as built on the tile."""
    b.cyl(r, r * 0.94, 0.08, ROCK, rot(HEX, "Z"), seg=6, shade=0.2)
    b.cyl(r * 0.88, r * 0.84, 0.06, SAND, at(0, 0, 0.08) @ rot(HEX, "Z"))
    return 0.14


def regalia(b, tier, top, accent, r=0.5):
    """Marks of rank shared by every tower: posts round the plinth from Lv2 (lanterns on them from
    Lv4, gilded from Lv6), banners from Lv3 (four from Lv5), a gold finial at Lv6, a halo at Lv7."""
    if tier >= 2:
        ph = 0.08 + 0.02 * tier
        for i in range(6):
            a = i * TAU / 6
            x, y = r * math.cos(a), r * math.sin(a)
            b.cyl(0.03, 0.024, ph, STONE, at(x, y, 0.14), seg=6, shade=0.1)
            if tier >= 4:
                b.ball(0.03, GOLD if tier >= 6 else accent, at(x, y, 0.14 + ph + 0.025))
    if tier >= 3:
        angles = (0.75, 1.25) if tier < 5 else (0.6, 0.9, 1.1, 1.4)
        pole = 0.5 + 0.05 * tier
        for f in angles:
            a = f * math.pi
            x, y = r * 0.86 * math.cos(a), r * 0.86 * math.sin(a)
            b.cyl(0.012, 0.012, pole, DARKWOOD, at(x, y, 0.14), seg=6)
            b.box(0.012, 0.13, 0.2, accent, at(x, y + 0.07 * (1 if y >= 0 else -1), 0.14 + pole - 0.22))
            b.box(0.014, 0.13, 0.025, GOLD, at(x, y + 0.07 * (1 if y >= 0 else -1), 0.14 + pole - 0.24))
            b.spike(0.018, 0.06, GOLD, at(x, y, 0.14 + pole), seg=4, prism=0)
    if tier >= 6:
        b.spike(0.035, 0.2, GOLD, at(0, 0, top), seg=8, prism=0.3)
    if tier >= 7:
        for i in range(12):  # floating halo of gold beads
            a = i * TAU / 12
            b.ball(0.022, GOLD, at(0.26 * math.cos(a), 0.26 * math.sin(a), top + 0.12))
        for i in range(3):
            a = i * TAU / 3 + 0.4
            with b.xf(at(0.36 * math.cos(a), 0.36 * math.sin(a), top - 0.1)):
                b.spike(0.03, 0.08, accent, rot(math.pi, "X"), seg=6, prism=0)
                b.spike(0.03, 0.1, accent, seg=6, prism=0)


# ---- arrow: lacquered watch pavilion with crossbows ----------------------------------------
def arrow(b, variant, tier):
    k = tier - 4  # level on the branch, 0 .. 3
    z = plinth(b)
    if variant == "b" or tier >= 3:
        widths = [0.82, 0.66] if variant != "b" or k < 2 else [0.86, 0.72, 0.58]
        z += tiers(b, widths, 0.1 if variant == "" else 0.12, SAND, at(0, 0, z), trim=BRICK)
    h = (0.5 + 0.06 * tier) if variant == "" else (0.8 + 0.03 * k if variant == "a" else 0.62 + 0.04 * k)
    n = 4 if variant != "a" or k < 2 else 6
    pillars(b, 0.28, h, n, BRICK, at(0, 0, z), rad=0.035)
    if tier >= 2:
        b.box(0.66, 0.66, 0.04, DARKWOOD, at(0, 0, z + h * 0.45))  # lower rail
    top = z + h
    b.box(0.72, 0.72, 0.06, DARKWOOD, at(0, 0, top))
    for s in (1, -1):  # balcony rail
        b.box(0.72, 0.03, 0.09, BRICK, at(0, s * 0.35, top + 0.06))
        b.box(0.03, 0.72, 0.09, BRICK, at(s * 0.35, 0, top + 0.06))
    if variant == "a":
        # Longbow: a pagoda that gains a storey every other level over a great crossbow.
        crossbow(b, 1.3 + 0.1 * k, at(0, 0, top + 0.06))
        pillars(b, 0.3, 0.32, 4, BRICK, at(0, 0, top + 0.06), rad=0.025)
        z2, w = top + 0.38, 0.95
        for i in range(2 + (k + 1) // 2):
            curved_roof(b, w, w, 0.18, CLAY if k < 3 else JADE, at(0, 0, z2), curl=0.1)
            b.box(w * 0.36, w * 0.36, 0.12, BRICK, at(0, 0, z2 + 0.12))
            z2, w = z2 + 0.24, w * 0.72
        b.ball(0.05, GOLD, at(0, 0, z2 + 0.02))
        return z2 + 0.06
    if variant == "b":
        # Volley: crossbows fanned out under an open sky, one more each level.
        nb = 3 + k
        for i in range(nb):
            a = i * TAU / nb
            crossbow(b, 0.8 + 0.04 * k, at(0.14 * math.cos(a), 0.14 * math.sin(a), top + 0.06) @ rot(a, "Z"))
        ns = 4 + 2 * k
        for i in range(ns):
            a = math.pi / 4 + i * TAU / ns
            b.spike(0.04, 0.22 + 0.02 * k, RED, at(0.34 * math.cos(a), 0.34 * math.sin(a), top + 0.12),
                    seg=3, prism=0.5)
        return top + 0.4
    crossbow(b, 0.8 + 0.05 * tier, at(0, 0, top + 0.06))
    pillars(b, 0.3, 0.26, 4, BRICK, at(0, 0, top + 0.06), rad=0.025)
    curved_roof(b, 0.9, 0.9, 0.2, CLAY, at(0, 0, top + 0.32), curl=0.12)
    if tier >= 3:
        b.box(0.3, 0.3, 0.1, BRICK, at(0, 0, top + 0.46))
        curved_roof(b, 0.58, 0.58, 0.18, CLAY, at(0, 0, top + 0.54), curl=0.1)
        b.ball(0.04, GOLD, at(0, 0, top + 0.73))
        return top + 0.77
    b.ball(0.04, GOLD, at(0, 0, top + 0.53))
    return top + 0.57


# ---- cannon: bronze bombard on a stepped temple platform -----------------------------------
def cannon(b, variant, tier):
    k = tier - 4
    z = plinth(b, 0.6)
    if variant == "a":
        widths = [0.98, 0.82, 0.66] if k < 2 else [0.98, 0.84, 0.7, 0.58]
    elif variant == "b":
        widths = [0.98, 0.8] if k < 2 else [0.98, 0.84, 0.7]
    else:
        widths = [0.98] if tier == 1 else [0.98, 0.8]
    deck = z + tiers(b, widths, 0.16, STONE, at(0, 0, z), trim=JADE if tier >= 2 else None)
    stairs(b, 0.26, deck - z, 0.22, SAND, at(widths[0] / 2 - 0.2, 0, z))
    if tier >= 2:
        serpent(b, JADE, at(widths[0] / 2 + 0.04, 0.17, z))
        serpent(b, JADE, at(widths[0] / 2 + 0.04, -0.17, z))
    w = widths[-1]
    nm = 4 if tier < 5 else 8
    for i in range(nm):  # merlons, stepped like Mesoamerican crenels
        a = math.pi / 4 + i * TAU / nm
        r = w * 0.62
        b.box(0.1, 0.1, 0.12, SAND, at(r * math.cos(a) * 0.72, r * math.sin(a) * 0.72, deck), taper=0.6)
    if variant == "b":
        barrels = [-0.13, 0.13] if k < 2 else [-0.18, 0.0, 0.18]
        rad = 0.08 + 0.008 * k
    else:
        barrels = [0.0]
        rad = 0.1 + 0.01 * k if variant == "a" else 0.07 + 0.007 * tier
    bands = 3 if tier < 3 else 4
    for oy in barrels:
        # Bronze barrel with bands, cocked up on a lacquered carriage, pointing +x.
        for s in (1, -1):
            b.box(0.24, 0.03, 0.12, BRICK, at(-0.02, oy + s * 0.09, deck))
        with b.xf(at(-0.12, oy, deck + 0.12) @ rot(math.radians(68), "Y")):
            b.cyl(rad, rad * 0.85, 0.5, AMBER, seg=8, shade=0.1)
            for i in range(bands):
                b.cyl(rad * 1.12, rad * 1.12, 0.03, GOLD, at(0, 0, 0.06 + i * 0.4 / bands), seg=8)
            b.cyl(rad * 1.2, rad * 1.1, 0.05, GOLD, at(0, 0, 0.45), seg=8)
        b.ball(rad * 1.2, AMBER, at(-0.14, oy, deck + 0.12))
    if variant == "a":
        # Đông Sơn bronze drums beside the gun, and a pyramid of bomblets.
        for i in range(1 + k // 2):
            y = 0.2 - 0.4 * i
            b.cyl(0.11, 0.09, 0.12, AMBER, at(-0.18, y, deck), seg=10)
            b.cyl(0.115, 0.115, 0.02, GOLD, at(-0.18, y, deck + 0.12), seg=10)
        if k >= 1:
            for (x, y, zz) in ((0.12, 0.2, 0), (0.2, 0.2, 0), (0.16, 0.13, 0), (0.16, 0.17, 0.06)):
                b.ball(0.04, IRON, at(x, y, deck + 0.04 + zz))
    if variant == "b" and k >= 3:
        for s in (1, -1):  # bronze mantlets
            b.box(0.04, 0.2, 0.22, AMBER, at(0.15, s * 0.32, deck), taper=0.8)
    return deck + 0.5


# ---- frost: one-pillar lotus pagoda holding a jade-ice crystal ------------------------------
def frost(b, variant, tier):
    k = tier - 4
    z = plinth(b)
    b.cyl(0.46, 0.46, 0.05, ICE, at(0, 0, z) @ rot(HEX, "Z"), seg=6, shade=0.3)  # pond
    for i in range(5 + (tier >= 3) * 2):  # lotus pads
        a = i * TAU / (5 + (tier >= 3) * 2) + 0.3
        b.cyl(0.07, 0.07, 0.015, LEAF, at(0.34 * math.cos(a), 0.34 * math.sin(a), z + 0.05), seg=8)
    ph = 0.32 + 0.05 * tier if variant == "" else 0.42 + 0.04 * k
    b.cyl(0.07, 0.06, ph, BRICK, at(0, 0, z + 0.05), seg=8)  # the one pillar
    top = z + 0.05 + ph
    # Lotus bracket: petals fanning out under the shrine floor.
    np_ = 8 if tier < 4 else 12
    for i in range(np_):
        a = i * TAU / np_
        b.spike(0.05, 0.22, CORAL, at(0.05 * math.cos(a), 0.05 * math.sin(a), top - 0.16)
                @ rot(a, "Z") @ rot(0.9, "Y"), seg=3, prism=0.3, shade=0.2)
    b.box(0.5, 0.5, 0.05, DARKWOOD, at(0, 0, top))
    for s in (1, -1):
        b.box(0.5, 0.03, 0.06, BRICK, at(0, s * 0.24, top + 0.05))
        b.box(0.03, 0.5, 0.06, BRICK, at(s * 0.24, 0, top + 0.05))
    if variant == "a":
        big, shards = 0.55 + 0.06 * k, 2
    elif variant == "b":
        big, shards = 0.42 + 0.04 * k, 4 + 2 * k
    else:
        big, shards = 0.33 + 0.03 * tier, 2 if tier < 3 else 3
    b.spike(0.09, big, ICE, at(0, 0, top + 0.05), seg=6, prism=0.65)
    for i in range(shards):
        a = i * TAU / shards + 0.7
        b.spike(0.05, big * 0.55, SKY, at(0.08 * math.cos(a), 0.08 * math.sin(a), top + 0.05)
                @ rot(a, "Z") @ rot(0.45, "Y"), seg=6)
    pillars(b, 0.22, big + 0.05, 4, BRICK, at(0, 0, top + 0.05), rad=0.02)
    rz = top + big + 0.1
    curved_roof(b, 0.72, 0.72, 0.16, JADE, at(0, 0, rz), curl=0.14, shade=0.2)
    if variant == "a" and k >= 2:
        b.box(0.24, 0.24, 0.1, BRICK, at(0, 0, rz + 0.12))
        rz += 0.2
        curved_roof(b, 0.5, 0.5, 0.14, JADE, at(0, 0, rz), curl=0.12, shade=0.2)
    b.ball(0.035, GOLD, at(0, 0, rz + 0.17))
    if variant == "a":
        nh = 5 + 2 * k
        for i in range(nh):  # halo of floating shards
            a = i * TAU / nh
            b.spike(0.03, 0.14 + 0.02 * k, SKY, at(0.42 * math.cos(a), 0.42 * math.sin(a), top + 0.1), seg=4)
    if variant == "b" and k >= 1:
        for i in range(6 + 2 * k):  # ice teeth breaking through the pond
            a = i * TAU / (6 + 2 * k) + 0.2
            b.spike(0.04, 0.12 + 0.03 * k, ICE, at(0.42 * math.cos(a), 0.42 * math.sin(a), z + 0.05)
                    @ rot(a, "Z") @ rot(0.3, "Y"), seg=5, prism=0.5)
    return rz + 0.21


# ---- tesla: sun-stone stele that throws lightning ------------------------------------------
def tesla(b, variant, tier):
    k = tier - 4
    z = plinth(b)
    widths = [0.7, 0.54] if tier >= 2 else [0.7]
    if variant == "b" and k >= 2:
        widths = [0.74, 0.6, 0.46]
    z += tiers(b, widths, 0.12, STONE, at(0, 0, z), trim=RED)
    if variant == "a":
        h, r = 0.62 + 0.06 * k, 0.3 + 0.02 * k
    elif variant == "b":
        h, r = 0.5 + 0.03 * k, 0.24 + 0.01 * k
    else:
        h, r = 0.42 + 0.04 * tier, 0.2 + 0.02 * tier
    b.box(0.22, 0.16, h, SAND, at(0, 0, z), taper=0.85)  # stele
    for i in range(3 + (tier >= 5)):  # carved glyph bands
        b.box(0.23, 0.17, 0.03, JADE, at(0, 0, z + 0.1 + i * h * 0.22))
    top = z + h
    sun_disc(b, r, at(0.02, 0, top + r - 0.04), rays=12 if tier < 4 else 16)
    # Charged turquoise orb crowned with quetzal plumes.
    orb = 0.08 if variant != "b" else 0.09 + 0.015 * k
    oz = top + 2 * r + 0.02
    b.ball(orb, SKY, at(0, 0, oz), sub=2)
    np_ = 5 if tier < 4 else 7
    for i in range(np_):
        a = (i - (np_ - 1) / 2) * 0.3
        b.spike(0.025, 0.24, JADE, at(-0.02, 0, oz + 0.02) @ rot(a, "X") @ rot(-0.25, "Y"), seg=3, prism=0.2)
    if variant == "a" and k >= 1:
        for i in range(k + 1):  # satellite orbs the arcs hop between
            a = i * TAU / (k + 1)
            b.cyl(0.015, 0.015, 0.3, IRON, at(0.34 * math.cos(a), 0.34 * math.sin(a), 0.14), seg=6)
            b.ball(0.05, SKY, at(0.34 * math.cos(a), 0.34 * math.sin(a), 0.48))
    if variant == "b":
        # Serpent pylons arcing to the stele: two, then four.
        n = 2 if k < 2 else 4
        for i in range(n):
            a = math.pi / 2 + i * TAU / n
            x, y = 0.3 * math.cos(a) - 0.05, 0.3 * math.sin(a)
            ph = 0.55 + 0.04 * k
            b.cyl(0.04, 0.03, ph, STONE, at(x, y, z), seg=6)
            serpent(b, JADE, at(x, y, z + ph) @ rot(a + math.pi, "Z"))
            b.ball(0.04, SKY, at(x, y, z + ph + 0.15))
    return oz + 0.3


# ---- flame: fire temple with a sacred brazier ----------------------------------------------
def flame(b, variant, tier):
    k = tier - 4
    z = plinth(b)
    base = z
    if variant == "":
        widths = [0.86, 0.68] if tier < 3 else [0.86, 0.68, 0.5]
    elif variant == "a" and k >= 2:
        widths = [0.9, 0.74, 0.58, 0.44]
    else:
        widths = [0.86, 0.68, 0.5]
    z += tiers(b, widths, 0.13, BRICK, at(0, 0, z), trim=SAND)
    stairs(b, 0.22, z - base, 0.26 + 0.04 * (len(widths) - 3), SAND, at(0.34, 0, base))
    if tier >= 2:
        serpent(b, SAND, at(0.62, 0.14, base))
        serpent(b, SAND, at(0.62, -0.14, base))
    # Bronze brazier bowl on a short drum.
    b.cyl(0.13, 0.11, 0.08, AMBER, at(0, 0, z), seg=8)
    b.cyl(0.12, 0.26, 0.14, AMBER, at(0, 0, z + 0.08), seg=10)
    b.cyl(0.27, 0.27, 0.03, GOLD, at(0, 0, z + 0.22), seg=10)
    if variant == "a":
        tall, tongues = 1.25 + 0.15 * k, 5 + 2 * k
    elif variant == "b":
        tall, tongues = 1.0 + 0.05 * k, 5
    else:
        tall, tongues = 0.8 + 0.1 * tier, 5
    b.spike(0.12, 0.6 * tall, FIRE, at(0, 0, z + 0.16), seg=6)
    for i in range(tongues):
        a = i * TAU / tongues + 0.3
        b.spike(0.07, (0.32 + 0.08 * (i % 2)) * tall, AMBER if i % 2 else ORANGE,
                at(0.13 * math.cos(a), 0.13 * math.sin(a), z + 0.18) @ rot(a, "Z") @ rot(0.35, "Y"), seg=5)
    if variant == "b":
        # Lacquered lantern-braziers on the lower tier: two, then four; pools of burning oil.
        spots = [(-0.26, 0.3), (-0.26, -0.3)] + ([(0.1, 0.36), (0.1, -0.36)] if k >= 2 else [])
        for (x, y) in spots:
            with b.xf(at(x, y, base + 0.13)):
                b.cyl(0.04, 0.04, 0.24, BRICK, seg=6)
                b.cyl(0.05, 0.1, 0.06, AMBER, at(0, 0, 0.24), seg=6)
                b.spike(0.06, 0.24 + 0.03 * k, FIRE, at(0, 0, 0.27), seg=5)
        for i in range(k):
            a = 2.4 + i * 0.7
            b.cyl(0.09, 0.09, 0.012, FIRE, at(0.5 * math.cos(a), 0.5 * math.sin(a), 0.14), seg=10)
    return z + 0.16 + 0.6 * tall


# ---- mine: shaft under a little tiled pavilion, gold cart on rails --------------------------
def mine(b, variant, tier):
    z = plinth(b, 0.62)
    roof = GOLD if tier >= 6 else CLAY
    b.cyl(0.2, 0.2, 0.02, BLACK, at(-0.08, 0, z), seg=8)  # shaft mouth
    ph = 0.46 + 0.03 * (tier - 1)
    pillars(b, 0.24, ph, 4, BRICK, at(-0.08, 0, z), rad=0.03)
    b.box(0.08, 0.5, 0.06, DARKWOOD, at(-0.08, 0, z + ph - 0.04))
    b.cyl(0.07, 0.07, 0.4, DARKWOOD, at(-0.08, -0.2, z + ph - 0.11) @ rot(-math.pi / 2, "X"), seg=8)  # windlass
    curved_roof(b, 0.7, 0.55, 0.18, roof, at(-0.08, 0, z + ph + 0.02), curl=0.12)
    top = z + ph + 0.2
    if tier >= 4:
        b.box(0.24, 0.2, 0.1, BRICK, at(-0.08, 0, z + ph + 0.14))
        curved_roof(b, 0.46, 0.38, 0.15, roof, at(-0.08, 0, z + ph + 0.24), curl=0.1)
        top += 0.22
    rail = 0.66 if tier < 3 else 0.8
    for s in (1, -1):  # rails
        b.box(rail, 0.03, 0.02, IRON, at(0.18 + (rail - 0.66) / 2, s * 0.1, z))
    carts = [(0.32, 1.0)] + ([(0.62, 0.8)] if tier >= 2 else [])
    for cx, cs in carts:
        with b.xf(at(cx, 0, z + 0.05) @ scale(cs, cs, cs)):
            b.box(0.3, 0.24, 0.15, DARKWOOD, taper=1.15)
            for (x, y) in ((-0.06, -0.06), (0.04, 0.05), (0.0, -0.02), (0.08, -0.07), (-0.05, 0.06)):
                b.ball(0.06, GOLD, at(x, y, 0.17))
            for (x, y) in ((-0.1, -0.13), (-0.1, 0.13), (0.1, -0.13), (0.1, 0.13)):
                b.cyl(0.045, 0.045, 0.03, IRON, at(x, y, 0.0) @ rot(math.pi / 2, "X"), seg=8)
    if tier >= 3:  # heap of ore
        for i in range(4 + tier):
            a = i * 2.39
            rr = 0.05 + 0.012 * (i % 3)
            b.ball(rr, GOLD if i % 2 else AMBER, at(-0.36 + 0.1 * math.cos(a), -0.32 + 0.08 * math.sin(a), z + rr * 0.6))
    if tier >= 5:  # timber hoist over the shaft
        b.cyl(0.025, 0.02, 0.9, DARKWOOD, at(0.0, 0.3, z) @ rot(-0.25, "X"), seg=6)
        b.box(0.04, 0.04, 0.3, DARKWOOD, at(0.0, 0.12, z + 0.82) @ rot(math.pi / 2 - 0.25, "X"))
    # Paper lanterns on poles: one, then a row.
    for i in range(1 if tier < 7 else 3):
        x = -0.4 + 0.2 * i
        b.cyl(0.02, 0.02, 0.5, DARKWOOD, at(x, 0.34, z), seg=4)
        b.ball(0.07, RED, at(x, 0.34, z + 0.48), sq=(1, 1, 1.3))
    return top


MAKERS = dict(arrow=arrow, cannon=cannon, frost=frost, tesla=tesla, flame=flame, mine=mine)
ACCENT = dict(arrow=RED, cannon=JADE, frost=SKY, tesla=TEAL, flame=ORANGE, mine=GOLD)
# (node suffix, branch variant, level) of every stage, in gfx order.
STAGES = [("1", "", 1), ("2", "", 2), ("3", "", 3)] + [
    (f"{v}{i}", v, 3 + i) for v in ("a", "b") for i in range(1, 5)]


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[0] if argv else "assets/models/td-towers.glb"
    preview = argv[1] if len(argv) > 1 else None
    palette = argv[2] if len(argv) > 2 else None
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mat = atlas_material(palette)
    obs = []
    for kind, fn in MAKERS.items():
        for suffix, v, tier in STAGES:
            if kind == "mine" and v == "b":
                continue
            b = DetailBuilder()
            top = fn(b, "" if kind == "mine" else v, tier)
            regalia(b, tier, top, ACCENT[kind], r=0.52 if kind != "mine" else 0.56)
            obs.append(b.finish(f"td_{kind}_{suffix}", mat))
    bpy.ops.object.select_all(action="DESELECT")
    for ob in obs:
        ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=True, export_apply=True,
                              export_materials="NONE", export_yup=True)
    total = 0
    for ob in obs:
        total += len(ob.data.polygons)
        print(f"{ob.name}: {len(ob.data.polygons)} faces, {tuple(round(d, 2) for d in ob.dimensions)}")
    print(f"{len(obs)} models, {total} faces")
    if preview:
        render_preview(obs, preview)


def render_preview(obs, path):
    sc = bpy.context.scene
    # One row per kind, stages left to right.
    order = list(MAKERS)
    suffixes = [st[0] for st in STAGES]
    for ob in obs:
        _, kind, suffix = ob.name.split("_")
        ob.location = (suffixes.index(suffix) * 1.6, -order.index(kind) * 1.6, 0)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 17.5
    cam.location = (8.0 + 9, -4.0 - 9, 9.5)
    cam.rotation_euler = (math.radians(55), 0, math.radians(45))
    sc.camera = cam
    light_scene(sc)
    sc.render.resolution_x, sc.render.resolution_y = 2000, 1300
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


main()

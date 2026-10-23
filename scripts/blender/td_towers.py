# Builds the tower defense structures, Aztec stonework crossed with medieval Vietnamese timber,
# as low-poly meshes colored through the Hex-Map-WFC palette atlas, and exports them:
#
#   blender -b --python scripts/blender/td_towers.py -- OUT.glb [PREVIEW.png PALETTE.png]
#
# Units match hex-terrain.glb: a hex tile is 2 wide, its top at height 0. Node names are what
# gfx.hex_mesh looks up: td_<kind> for levels 1 and 2, td_<kind>_a / td_<kind>_b for the branches.
import bpy, bmesh, math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lowpoly import *  # noqa: E402,F401,F403

TAU = 2 * math.pi
HEX = math.pi / 6  # rotation that puts a 6-sided cylinder's flats on the hex tile's flats


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


# ---- arrow: lacquered watch pavilion with crossbows ----------------------------------------
def arrow(b, variant):
    z = plinth(b)
    if variant == "b":
        z += tiers(b, [0.82, 0.66], 0.12, SAND, at(0, 0, z), trim=BRICK)
    h = 0.62 if variant != "a" else 0.85
    pillars(b, 0.28, h, 4, BRICK, at(0, 0, z), rad=0.035)
    b.box(0.66, 0.66, 0.04, DARKWOOD, at(0, 0, z + h * 0.45))  # lower rail
    top = z + h
    b.box(0.72, 0.72, 0.06, DARKWOOD, at(0, 0, top))
    for s in (1, -1):  # balcony rail
        b.box(0.72, 0.03, 0.09, BRICK, at(0, s * 0.35, top + 0.06))
        b.box(0.03, 0.72, 0.09, BRICK, at(s * 0.35, 0, top + 0.06))
    if variant == "a":
        # Longbow: a two-tier pagoda over a great crossbow.
        crossbow(b, 1.3, at(0, 0, top + 0.06))
        pillars(b, 0.3, 0.32, 4, BRICK, at(0, 0, top + 0.06), rad=0.025)
        curved_roof(b, 0.95, 0.95, 0.18, CLAY, at(0, 0, top + 0.38), curl=0.1)
        b.box(0.34, 0.34, 0.12, BRICK, at(0, 0, top + 0.5))
        curved_roof(b, 0.6, 0.6, 0.2, CLAY, at(0, 0, top + 0.62), curl=0.08)
        b.ball(0.05, GOLD, at(0, 0, top + 0.84))
    elif variant == "b":
        # Volley: three crossbows fanned out under an open sky.
        for i in range(3):
            crossbow(b, 0.8, at(0.12 * math.cos(i * TAU / 3), 0.12 * math.sin(i * TAU / 3), top + 0.06)
                     @ rot(i * TAU / 3, "Z"))
        for i in range(4):
            a = math.pi / 4 + i * math.pi / 2
            b.spike(0.04, 0.22, RED, at(0.34 * math.cos(a), 0.34 * math.sin(a), top + 0.12), seg=3, prism=0.5)
    else:
        crossbow(b, 0.9, at(0, 0, top + 0.06))
        pillars(b, 0.3, 0.26, 4, BRICK, at(0, 0, top + 0.06), rad=0.025)
        curved_roof(b, 0.9, 0.9, 0.2, CLAY, at(0, 0, top + 0.32), curl=0.12)
        b.ball(0.04, GOLD, at(0, 0, top + 0.53))


# ---- cannon: bronze bombard on a stepped temple platform -----------------------------------
def cannon(b, variant):
    z = plinth(b, 0.6)
    widths = [0.98, 0.82, 0.66] if variant == "a" else [0.98, 0.8]
    deck = z + tiers(b, widths, 0.16, STONE, at(0, 0, z), trim=JADE)
    stairs(b, 0.26, deck - z, 0.22, SAND, at(widths[0] / 2 - 0.2, 0, z))
    serpent(b, JADE, at(widths[0] / 2 + 0.04, 0.17, z))
    serpent(b, JADE, at(widths[0] / 2 + 0.04, -0.17, z))
    w = widths[-1]
    for i in range(4):  # corner merlons, stepped like Mesoamerican crenels
        a = math.pi / 4 + i * math.pi / 2
        r = w * 0.62
        b.box(0.1, 0.1, 0.12, SAND, at(r * math.cos(a) * 0.72, r * math.sin(a) * 0.72, deck), taper=0.6)
    barrels = [0.0] if variant != "b" else [-0.13, 0.13]
    rad = 0.1 if variant == "a" else 0.08
    for oy in barrels:
        # Bronze barrel with bands, cocked up on a lacquered carriage, pointing +x.
        for s in (1, -1):
            b.box(0.24, 0.03, 0.12, BRICK, at(-0.02, oy + s * 0.09, deck))
        with b.xf(at(-0.12, oy, deck + 0.12) @ rot(math.radians(68), "Y")):
            b.cyl(rad, rad * 0.85, 0.5, AMBER, seg=8, shade=0.1)
            for k in range(3):
                b.cyl(rad * 1.12, rad * 1.12, 0.03, GOLD, at(0, 0, 0.08 + k * 0.17), seg=8)
            b.cyl(rad * 1.2, rad * 1.1, 0.05, GOLD, at(0, 0, 0.45), seg=8)
        b.ball(rad * 1.2, AMBER, at(-0.14, oy, deck + 0.12))
    if variant == "a":
        # Đông Sơn bronze drum beside the gun.
        b.cyl(0.11, 0.09, 0.12, AMBER, at(-0.18, 0.2, deck), seg=10)
        b.cyl(0.115, 0.115, 0.02, GOLD, at(-0.18, 0.2, deck + 0.12), seg=10)


# ---- frost: one-pillar lotus pagoda holding a jade-ice crystal ------------------------------
def frost(b, variant):
    z = plinth(b)
    b.cyl(0.46, 0.46, 0.05, ICE, at(0, 0, z) @ rot(HEX, "Z"), seg=6, shade=0.3)  # pond
    for i in range(5):  # lotus pads
        a = i * TAU / 5 + 0.3
        b.cyl(0.07, 0.07, 0.015, LEAF, at(0.34 * math.cos(a), 0.34 * math.sin(a), z + 0.05), seg=6)
    b.cyl(0.07, 0.06, 0.42, BRICK, at(0, 0, z + 0.05), seg=8)  # the one pillar
    top = z + 0.47
    # Lotus bracket: petals fanning out under the shrine floor.
    for i in range(8):
        a = i * TAU / 8
        b.spike(0.05, 0.22, CORAL, at(0.05 * math.cos(a), 0.05 * math.sin(a), top - 0.16)
                @ rot(a, "Z") @ rot(0.9, "Y"), seg=3, prism=0.3, shade=0.2)
    b.box(0.5, 0.5, 0.05, DARKWOOD, at(0, 0, top))
    for s in (1, -1):
        b.box(0.5, 0.03, 0.06, BRICK, at(0, s * 0.24, top + 0.05))
        b.box(0.03, 0.5, 0.06, BRICK, at(s * 0.24, 0, top + 0.05))
    big = 0.55 if variant == "a" else 0.42
    b.spike(0.09, big, ICE, at(0, 0, top + 0.05), seg=6, prism=0.65)
    shards = 4 if variant == "b" else 2
    for i in range(shards):
        a = i * TAU / shards + 0.7
        b.spike(0.05, big * 0.55, SKY, at(0.08 * math.cos(a), 0.08 * math.sin(a), top + 0.05)
                @ rot(a, "Z") @ rot(0.45, "Y"), seg=6)
    pillars(b, 0.22, big + 0.05, 4, BRICK, at(0, 0, top + 0.05), rad=0.02)
    curved_roof(b, 0.72, 0.72, 0.16, JADE, at(0, 0, top + big + 0.1), curl=0.14, shade=0.2)
    b.ball(0.035, GOLD, at(0, 0, top + big + 0.27))
    if variant == "a":
        for i in range(5):  # halo of floating shards
            a = i * TAU / 5
            b.spike(0.03, 0.14, SKY, at(0.42 * math.cos(a), 0.42 * math.sin(a), top + 0.1), seg=4)


# ---- tesla: sun-stone stele that throws lightning ------------------------------------------
def tesla(b, variant):
    z = plinth(b)
    z += tiers(b, [0.7, 0.54], 0.12, STONE, at(0, 0, z), trim=RED)
    h = 0.5 if variant != "a" else 0.62
    b.box(0.22, 0.16, h, SAND, at(0, 0, z), taper=0.85)  # stele
    for k in range(3):  # carved glyph bands
        b.box(0.23, 0.17, 0.03, JADE, at(0, 0, z + 0.1 + k * h * 0.28))
    top = z + h
    r = 0.24 if variant != "a" else 0.3
    sun_disc(b, r, at(0.02, 0, top + r - 0.04))
    # Charged turquoise orb crowned with quetzal plumes.
    b.ball(0.08, SKY, at(0, 0, top + 2 * r + 0.02), sub=2)
    for i in range(5):
        a = (i - 2) * 0.35
        b.spike(0.025, 0.24, JADE, at(-0.02, 0, top + 2 * r + 0.04) @ rot(a, "X") @ rot(-0.25, "Y"),
                seg=3, prism=0.2)
    if variant == "b":
        # Twin serpent pylons arcing to the stele.
        for s in (1, -1):
            b.cyl(0.04, 0.03, 0.55, STONE, at(-0.05, s * 0.3, z), seg=6)
            serpent(b, JADE, at(-0.05, s * 0.3, z + 0.55) @ rot(-s * 0.6, "Z"))
            b.ball(0.04, SKY, at(-0.0, s * 0.3, z + 0.7))


# ---- flame: fire temple with a sacred brazier ----------------------------------------------
def flame(b, variant):
    z = plinth(b)
    base = z
    z += tiers(b, [0.86, 0.68, 0.5], 0.13, BRICK, at(0, 0, z), trim=SAND)
    stairs(b, 0.22, z - base, 0.26, SAND, at(0.34, 0, base))
    serpent(b, SAND, at(0.62, 0.14, base))
    serpent(b, SAND, at(0.62, -0.14, base))
    # Bronze brazier bowl on a short drum.
    b.cyl(0.13, 0.11, 0.08, AMBER, at(0, 0, z), seg=8)
    b.cyl(0.12, 0.26, 0.14, AMBER, at(0, 0, z + 0.08), seg=10)
    b.cyl(0.27, 0.27, 0.03, GOLD, at(0, 0, z + 0.22), seg=10)
    tall = 1.25 if variant == "a" else 1.0
    b.spike(0.12, 0.6 * tall, FIRE, at(0, 0, z + 0.16), seg=6)
    for i in range(5):
        a = i * TAU / 5 + 0.3
        b.spike(0.07, (0.32 + 0.08 * (i % 2)) * tall, AMBER if i % 2 else ORANGE,
                at(0.13 * math.cos(a), 0.13 * math.sin(a), z + 0.18) @ rot(a, "Z") @ rot(0.35, "Y"), seg=5)
    if variant == "b":
        # Twin lacquered lantern-braziers on the lower tier.
        for s in (1, -1):
            with b.xf(at(-0.26, s * 0.3, base + 0.13)):
                b.cyl(0.04, 0.04, 0.24, BRICK, seg=6)
                b.cyl(0.05, 0.1, 0.06, AMBER, at(0, 0, 0.24), seg=6)
                b.spike(0.06, 0.24, FIRE, at(0, 0, 0.27), seg=5)


# ---- mine: shaft under a little tiled pavilion, gold cart on rails --------------------------
def mine(b, variant):
    z = plinth(b, 0.62)
    b.cyl(0.2, 0.2, 0.02, BLACK, at(-0.08, 0, z), seg=8)  # shaft mouth
    pillars(b, 0.24, 0.46, 4, BRICK, at(-0.08, 0, z), rad=0.03)
    b.box(0.08, 0.5, 0.06, DARKWOOD, at(-0.08, 0, z + 0.42))
    b.cyl(0.07, 0.07, 0.4, DARKWOOD, at(-0.08, -0.2, z + 0.35) @ rot(-math.pi / 2, "X"), seg=8)  # windlass
    curved_roof(b, 0.7, 0.55, 0.18, CLAY, at(-0.08, 0, z + 0.48), curl=0.12)
    for s in (1, -1):  # rails
        b.box(0.66, 0.03, 0.02, IRON, at(0.18, s * 0.1, z))
    with b.xf(at(0.32, 0, z + 0.05)):
        b.box(0.3, 0.24, 0.15, DARKWOOD, taper=1.15)
        for (x, y) in ((-0.06, -0.06), (0.04, 0.05), (0.0, -0.02), (0.08, -0.07), (-0.05, 0.06)):
            b.ball(0.06, GOLD, at(x, y, 0.17))
        for (x, y) in ((-0.1, -0.13), (-0.1, 0.13), (0.1, -0.13), (0.1, 0.13)):
            b.cyl(0.045, 0.045, 0.03, IRON, at(x, y, 0.0) @ rot(math.pi / 2, "X"), seg=6)
    # Paper lantern on a pole.
    b.cyl(0.02, 0.02, 0.5, DARKWOOD, at(-0.4, 0.34, z), seg=4)
    b.ball(0.07, RED, at(-0.4, 0.34, z + 0.48), sq=(1, 1, 1.3))


MAKERS = dict(arrow=arrow, cannon=cannon, frost=frost, tesla=tesla, flame=flame, mine=mine)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[0] if argv else "assets/models/td-towers.glb"
    preview = argv[1] if len(argv) > 1 else None
    palette = argv[2] if len(argv) > 2 else None
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mat = atlas_material(palette)
    obs = []
    for kind, fn in MAKERS.items():
        for v in ("", "a", "b"):
            if kind == "mine" and v:
                continue
            b = Builder()
            fn(b, v)
            obs.append(b.finish(f"td_{kind}" + (f"_{v}" if v else ""), mat))
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
    order = list(MAKERS)
    for ob in obs:
        parts = ob.name.split("_")
        var = 0 if len(parts) == 2 else (1 if parts[2] == "a" else 2)
        ob.location = (order.index(parts[1]) * 1.6, -var * 1.6, 0)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 10.5
    cam.location = (4.0 + 9, -1.6 - 9, 9.5)
    cam.rotation_euler = (math.radians(55), 0, math.radians(45))
    sc.camera = cam
    light_scene(sc)
    sc.render.resolution_x, sc.render.resolution_y = 1600, 1000
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


main()

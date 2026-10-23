# Models the tower defense creeps and renders them to a sprite atlas for gfx.td_overlay:
#
#   blender -b --python scripts/blender/td_creeps.py -- ATLAS.png PALETTE.png
#
# PALETTE.png is the Hex-Map-WFC palette (textures/default.png). The atlas holds, for each creep
# kind (td.defs.CreepKind order), 8 facings x 4 walk frames: sprite i = (kind * 8 + facing) * 4 +
# frame, at column i % COLS and row i / COLS of CELL-pixel squares. Facing f looks at angle f * 45
# degrees counter-clockwise from +x on the ground, +y being away from the viewer (up the screen).
# Each square spans SPAN iso units, with the creep's ground point at its horizontal center, ANCHOR
# of the way down. The camera matches gfx.iso: ground depth squashed by 0.62.
import bpy, math, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lowpoly import *  # noqa: E402,F401,F403

CELL, COLS, SPAN, ANCHOR = 128, 16, 2.0, 0.75
FACINGS, FRAMES = 8, 4
KINDS = ["grunt", "runner", "brute", "swarm", "boss"]


def legs(b, phase, hip, length, r, sw, spread, foot=None, n=2):
    """Pair of swinging legs hanging from hip height (forward is +x)."""
    for i, side in enumerate((1, -1)[:n]):
        swing = 0.55 * math.sin(phase + i * math.pi)
        with b.xf(at(0, side * spread, hip) @ rot(swing, "Y") @ at(0, 0, -length)):
            b.box(r * 2, r * 2, length, sw, taper=1.15)
            if foot:
                b.box(r * 3.2, r * 2.2, r * 1.2, foot, at(r * 0.6, 0, 0))


def bob(phase, amount):
    return amount * abs(math.cos(phase))


def grunt(b, phase):
    """Goblin raider with a spear and a round hide shield."""
    legs(b, phase, 0.26, 0.24, 0.045, DARKWOOD, 0.08, foot=UMBER)
    with b.xf(at(0, 0, 0.24 + bob(phase, 0.03))):
        b.box(0.22, 0.26, 0.24, WOOD, taper=0.8)  # tunic
        b.box(0.24, 0.28, 0.05, UMBER, at(0, 0, 0.0))  # belt
        with b.xf(at(0.02, 0, 0.30)):
            b.ball(0.13, LEAF, sub=1, sq=(1, 1.05, 0.95))
            for s in (1, -1):  # ears
                b.spike(0.04, 0.16, LEAF, at(-0.02, s * 0.1, 0.03) @ rot(-s * 1.35, "X"), seg=4, prism=0)
                b.ball(0.025, BLACK, at(0.11, s * 0.05, 0.02))  # eyes
            b.spike(0.03, 0.08, LEAF, at(0.12, 0, -0.02) @ rot(1.6, "Y"), seg=4, prism=0)  # nose
        swing = 0.5 * math.sin(phase)
        # Spear arm (right, -y) and shield arm (left, +y).
        with b.xf(at(0, -0.17, 0.2) @ rot(-swing, "Y")):
            b.box(0.06, 0.06, 0.16, LEAF, at(0, 0, -0.14))
            with b.xf(at(0.02, 0, -0.1) @ rot(-0.35, "Y")):
                b.cyl(0.015, 0.015, 0.62, WOOD, at(0, 0, -0.18), seg=4)
                b.spike(0.035, 0.12, STONE, at(0, 0, 0.44), seg=4, prism=0.2)
        with b.xf(at(0.08, 0.17, 0.1) @ rot(math.pi / 2, "X") @ rot(0.25, "Y")):
            b.cyl(0.13, 0.13, 0.04, TAN, seg=10)
            b.cyl(0.04, 0.04, 0.06, IRON, seg=6)


def runner(b, phase):
    """Lean raptor: body pitched forward, long counterweight tail, quick legs."""
    legs(b, phase * 1.0, 0.24, 0.22, 0.035, AMBER, 0.07, foot=UMBER)
    with b.xf(at(0, 0, 0.26 + bob(phase, 0.04)) @ rot(-0.15, "Y")):
        b.ball(0.13, AMBER, sub=1, sq=(1.6, 0.85, 0.85))
        b.spike(0.07, 0.3, AMBER, at(-0.16, 0, 0.02) @ rot(-1.45, "Y"), seg=5, prism=0)
        for k in range(3):  # back stripes
            b.box(0.03, 0.2, 0.03, UMBER, at(-0.1 + k * 0.09, 0, 0.09))
        with b.xf(at(0.18, 0, 0.08) @ rot(0.6, "Y")):
            b.cyl(0.05, 0.04, 0.16, AMBER, seg=5)  # neck
            with b.xf(at(0.0, 0, 0.16) @ rot(-0.9, "Y")):
                b.box(0.14, 0.09, 0.08, AMBER, taper=0.85)
                for s in (1, -1):
                    b.ball(0.018, BLACK, at(0.03, s * 0.045, 0.05))
                b.spike(0.03, 0.08, RED, at(-0.02, 0, 0.07) @ rot(-0.8, "Y"), seg=4, prism=0)  # crest
        for s in (1, -1):  # little arms
            b.box(0.03, 0.03, 0.08, AMBER, at(0.12, s * 0.07, -0.08) @ rot(0.6, "Y"))


def brute(b, phase):
    """Hulking stone-armored ogre: broad shoulders, big fists, short thick legs."""
    legs(b, phase, 0.22, 0.2, 0.07, UMBER, 0.12, foot=SLATE)
    with b.xf(at(0, 0, 0.2 + bob(phase, 0.025)) @ rot(0.12, "Y")):
        b.box(0.32, 0.42, 0.34, TAUPE, taper=1.25)  # torso
        b.box(0.36, 0.30, 0.18, SLATE, at(0.02, 0, 0.12), taper=0.9)  # breastplate
        for s in (1, -1):
            b.ball(0.12, SLATE, at(0, s * 0.27, 0.34), sq=(1, 1, 0.75))  # pauldrons
            swing = 0.45 * math.sin(phase + (0 if s > 0 else math.pi))
            with b.xf(at(0, s * 0.3, 0.3) @ rot(swing, "Y")):
                b.box(0.1, 0.1, 0.24, TAUPE, at(0, 0, -0.26))
                b.ball(0.08, ROCK, at(0.02, 0, -0.3))  # fist
        with b.xf(at(0.07, 0, 0.36)):
            b.ball(0.09, TAUPE, sq=(1, 1, 0.9))
            b.box(0.1, 0.16, 0.06, IRON, at(0.02, 0, 0.03))  # brow guard
            for s in (1, -1):
                b.ball(0.016, FIRE, at(0.085, s * 0.04, 0.0))
                b.spike(0.02, 0.07, BONE, at(0.07, s * 0.04, -0.05), seg=4, prism=0)  # tusks


def swarm(b, phase):
    """Scuttling beetle: domed shell, tripod gait on six legs."""
    with b.xf(at(0, 0, 0.06 + bob(phase * 2, 0.012))):
        for k in range(3):
            for s in (1, -1):
                swing = 0.5 * math.sin(phase + (k + (s > 0)) * math.pi)
                with b.xf(at(0.08 - k * 0.08, s * 0.08, 0.02) @ rot(swing, "Z") @ rot(s * 1.1, "X")):
                    b.box(0.025, 0.025, 0.13, BLACK)
        b.ball(0.14, DEEP, sub=2, sq=(1.25, 1.0, 0.7), shade=0.45)  # shell
        b.box(0.24, 0.012, 0.03, FIRE, at(-0.02, 0, 0.095))  # wing seam
        with b.xf(at(0.16, 0, 0.0)):
            b.ball(0.06, BLACK, sq=(1, 1.1, 0.8))
            for s in (1, -1):
                b.spike(0.012, 0.1, FIRE, at(0.03, s * 0.03, 0.03) @ rot(1.0, "Y") @ rot(s * -0.4, "X"),
                        seg=3, prism=0)  # antennae
                b.ball(0.014, LIME, at(0.05, s * 0.03, 0.01))


def boss(b, phase):
    """Horned war-chief in black lamellar with a gold crown and a jagged club."""
    legs(b, phase, 0.42, 0.4, 0.08, BLACK, 0.15, foot=IRON)
    with b.xf(at(0, 0, 0.4 + bob(phase, 0.04))):
        b.box(0.40, 0.56, 0.44, RED, taper=1.2)  # torso (skin)
        b.box(0.44, 0.58, 0.28, BLACK, at(0, 0, -0.02), taper=1.05)  # lamellar skirt / chest
        for k in range(4):
            b.box(0.46, 0.6, 0.02, GOLD, at(0, 0, 0.03 + k * 0.07))
        for s in (1, -1):
            b.spike(0.12, 0.22, IRON, at(0, s * 0.33, 0.42) @ rot(s * -0.6, "X"), seg=5, prism=0.4)
            swing = 0.4 * math.sin(phase + (0 if s > 0 else math.pi))
            with b.xf(at(0, s * 0.38, 0.38) @ rot(swing, "Y")):
                b.box(0.13, 0.13, 0.32, RED, at(0, 0, -0.34))
                b.ball(0.09, RED, at(0.02, 0, -0.38))
                if s < 0:  # club
                    with b.xf(at(0.04, 0, -0.38) @ rot(-1.1, "Y")):
                        b.cyl(0.03, 0.06, 0.5, DARKWOOD, seg=6)
                        for k in range(4):
                            b.spike(0.025, 0.08, STONE, at(0, 0, 0.32 + k * 0.05) @
                                    rot(math.pi / 2, "X") @ rot(k * 1.6, "Y"), seg=3, prism=0)
        with b.xf(at(0.06, 0, 0.46)):
            b.ball(0.15, RED, sq=(1, 1, 0.95))
            b.box(0.06, 0.2, 0.08, BLACK, at(0.12, 0, -0.08))  # jaw
            for s in (1, -1):
                b.ball(0.025, AMBER, at(0.14, s * 0.06, 0.03))
                b.spike(0.045, 0.3, BONE, at(0.0, s * 0.11, 0.08) @ rot(s * -0.9, "X") @ rot(-0.4, "Y"),
                        seg=5, prism=0)  # horns
            with b.xf(at(-0.01, 0, 0.11)):
                b.cyl(0.13, 0.15, 0.06, GOLD, seg=8)
                for k in range(5):
                    a = k * 2 * math.pi / 5
                    b.spike(0.03, 0.1, GOLD, at(0.13 * math.cos(a), 0.13 * math.sin(a), 0.05), seg=3, prism=0)


MAKERS = dict(grunt=grunt, runner=runner, brute=brute, swarm=swarm, boss=boss)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    out, palette = argv[0], argv[1]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    light_scene(sc)
    sc.render.film_transparent = True
    sc.render.resolution_x = sc.render.resolution_y = CELL
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    mat = atlas_material(palette)

    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = SPAN
    # Ground depth on screen is sin(pitch) = 0.62, as gfx.iso's squash.
    pitch = math.asin(0.62)
    cam.rotation_euler = (math.pi / 2 - pitch, 0, 0)
    cam.location = (0, -20 * math.cos(pitch), 20 * math.sin(pitch))
    cam.data.shift_y = ANCHOR - 0.5

    import numpy as np
    total = len(KINDS) * FACINGS * FRAMES
    rows = (total + COLS - 1) // COLS
    sheet = np.zeros((rows * CELL, COLS * CELL, 4), dtype=np.float32)
    tmp = tempfile.mkdtemp()
    for k, kind in enumerate(KINDS):
        for fr in range(FRAMES):
            b = Builder()
            MAKERS[kind](b, fr * 2 * math.pi / FRAMES)
            ob = b.finish(f"{kind}_{fr}", mat)
            for f in range(FACINGS):
                ob.rotation_euler = (0, 0, f * math.pi / 4)
                path = os.path.join(tmp, f"{kind}_{f}_{fr}.png")
                sc.render.filepath = path
                bpy.ops.render.render(write_still=True)
                img = bpy.data.images.load(path)
                px = np.array(img.pixels[:], dtype=np.float32).reshape(CELL, CELL, 4)
                bpy.data.images.remove(img)
                i = (k * FACINGS + f) * FRAMES + fr
                # Blender images are bottom-up; the sheet is built bottom-up too, row 0 at the top.
                r, c = i // COLS, i % COLS
                y0 = (rows - 1 - r) * CELL
                sheet[y0:y0 + CELL, c * CELL:(c + 1) * CELL] = px
            bpy.data.objects.remove(ob)
    atlas = bpy.data.images.new("creeps", COLS * CELL, rows * CELL, alpha=True)
    atlas.pixels.foreach_set(sheet.ravel())
    atlas.filepath_raw = out
    atlas.file_format = "PNG"
    atlas.save()
    print(f"wrote {out}: {COLS * CELL} x {rows * CELL}, {total} sprites")


main()

# Models the village hub characters and renders their walk sheet, dialogue portraits and standing
# figures:
#
#   blender -b --python scripts/blender/village_chars.py -- PALETTE.png [ASSETS_DIR]
#
# PALETTE.png is the Hex-Map-WFC palette (third-party/Hex-Map-WFC/public/assets/textures/default.png);
# ASSETS_DIR defaults to assets/. Characters, in sheet order: player, elder (Bà Lan), priestess
# (Itzel), smith (Chú Tư), child (Ngọc), guard. It writes:
#
#   sprites/villagers.png   walk sheet with the layout and camera of td_creeps.py's creeps.png: for
#                           each character 8 facings x 4 walk frames, sprite i = (kind * 8 + facing)
#                           * 4 + frame at column i % COLS and row i / COLS of CELL-pixel squares.
#                           Facing f looks at f * 45 degrees counter-clockwise from +x on the ground;
#                           each square spans SPAN iso units with the ground point at its horizontal
#                           center, ANCHOR of the way down.
#   portraits/<id>_<expr>.png  PORTRAIT-pixel square bust shots from a front perspective camera, for
#                           expr in neutral, happy, worried (brow and mouth geometry).
#   figures/<id>.png        FIG_W x FIG_H full-body figures in a front 3/4 view. All figures share
#                           one scale (FIG_SPAN world units of height fill FIG_H pixels) with the feet
#                           FIG_FOOT of the way up from the bottom, so the child stands shorter.
#
# Every PNG has a transparent background.
import bpy, math, os, sys, tempfile
from collections import namedtuple
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lowpoly import *  # noqa: E402,F401,F403

CELL, COLS, SPAN, ANCHOR = 128, 16, 2.0, 0.75
FACINGS, FRAMES = 8, 4
KINDS = ["player", "elder", "priestess", "smith", "child", "guard"]
EXPRS = ["neutral", "happy", "worried"]
PORTRAIT = 256
FIG_W, FIG_H, FIG_SPAN, FIG_FOOT = 384, 512, 1.32, 0.03
TAU = 2 * math.pi

# Walk phase, swing amplitude (0 stands still) and facial expression.
Pose = namedtuple("Pose", "phase amp expr")


def swing(pose, off=0.0):
    return pose.amp * math.sin(pose.phase + off)


def bob(pose, amount):
    return amount * abs(math.cos(pose.phase)) if pose.amp else 0.0


def legs(b, pose, hip, length, r, sw, spread, foot=None):
    """Pair of swinging legs hanging from hip height (forward is +x, side +1 is the left, +y)."""
    for i, side in enumerate((1, -1)):
        with b.xf(at(0, side * spread, hip) @ rot(swing(pose, i * math.pi), "Y") @ at(0, 0, -length)):
            b.box(r * 2, r * 2.1, length, sw, taper=1.15)
            if foot:
                b.box(r * 3, r * 2.2, r * 1.1, foot, at(r * 0.6, 0, 0))


def arm(b, pose, side, sh, length, r, sleeve, hand, lift=0.0, amp=1.0, hold=None):
    """Arm hanging from shoulder point `sh`, swinging against its leg; `lift` raises it forward.
    `hold` builds an item in a frame at the hand that stays upright whatever the arm does."""
    a = -swing(pose, 0 if side > 0 else math.pi) * amp - lift
    with b.xf(at(*sh) @ rot(a, "Y") @ rot(side * 0.08, "X")):
        b.box(r * 2, r * 2, length, sleeve, at(0, 0, -length), taper=1.2)
        b.ball(r * 1.15, hand, at(0, 0, -length - r * 0.5))
        if hold:
            with b.xf(at(0, 0, -length - r * 0.5) @ rot(-side * 0.08, "X") @ rot(-a, "Y")):
                hold(b)


def face(b, r, P, expr):
    """Eyes, brows, nose and mouth on the +x side of a head of radius r."""
    lift, tilt = dict(neutral=(0.0, 0.0), happy=(0.08, 0.12), worried=(0.06, 0.5))[expr]
    for s in (1, -1):
        b.ball(r * 0.13, BLACK, at(r * 0.8, s * r * 0.36, r * 0.06), sq=(0.6, 0.9, 1.3))
        b.ball(r * 0.04, SNOW, at(r * 0.87, s * r * 0.33, r * 0.12))  # catch light
        b.box(r * 0.12, r * 0.32, r * 0.08, P["brow"],
              at(r * 0.76, s * r * 0.36, r * (0.34 + lift)) @ rot(-s * tilt, "X"))
    b.spike(r * 0.1, r * 0.16, P["skin"], at(r * 0.84, 0, -r * 0.14) @ rot(math.pi / 2, "Y"), seg=4,
            prism=0, shade=0.15)
    # Mouth: a centre bar and two corners, curled up (happy) or down and parted (worried).
    corner, dz, gap = dict(neutral=(0.1, 0.0, 0.0), happy=(0.6, -0.03, 0.06), worried=(-0.5, 0.02, 0.05))[expr]
    zm = -r * (0.44 + dz)
    lips = P.get("lips", RED)
    if gap:
        b.ball(r * 0.11, BLACK, at(r * 0.76, 0, zm - r * 0.02), sq=(0.6, 1.4 if corner > 0 else 1.0, gap * 9))
    b.box(r * 0.1, r * 0.2, r * 0.05, lips, at(r * 0.8, 0, zm), shade=0.4)
    for s in (1, -1):
        b.box(r * 0.1, r * 0.16, r * 0.05, lips,
              at(r * 0.77, s * r * 0.16, zm + r * 0.06 * math.sin(corner)) @ rot(s * corner, "X"), shade=0.4)
        if expr == "happy":
            b.ball(r * 0.1, CORAL, at(r * 0.74, s * r * 0.5, -r * 0.18), sq=(0.4, 1.2, 0.8), shade=0.2)


def head(b, z, r, P, expr, x=0.0, neck=True):
    with b.xf(at(x, 0, z)):
        b.head = (b.stack[-1] @ Vector((0, 0, 0)), r)
        if neck:
            b.cyl(r * 0.36, r * 0.4, r * 0.6, P["skin"], at(-r * 0.05, 0, -r * 1.3), seg=6, shade=0.3)
        b.ball(r, P["skin"], sub=2, sq=(0.95, 0.92, 1.05))
        for s in (1, -1):
            b.ball(r * 0.18, P["skin"], at(-r * 0.05, s * r * 0.9, 0), sq=(0.6, 0.5, 1.0), shade=0.2)  # ears
        face(b, r, P, expr)


def hair_cap(b, r, sw, back=0.3, sq=(0.95, 0.98, 0.95), shade=0.2):
    """Hair over the crown and back of the head, leaving the face clear."""
    b.ball(r * 1.06, sw, at(-r * back, 0, r * 0.12), sub=2, sq=sq, shade=shade)


# ---- characters (forward is +x; each records its head in b.head) --------------------------
def player(b, pose):
    """Young traveller: indigo áo bà ba, red neck scarf, satchel, topknot."""
    P = dict(skin=SAND, brow=BLACK, lips=CORAL)
    legs(b, pose, 0.34, 0.32, 0.042, TAN, 0.065, foot=UMBER)
    with b.xf(at(0, 0, 0.32 + bob(pose, 0.025))):
        b.box(0.17, 0.26, 0.3, DEEP, taper=1.1, shade=0.1)  # shirt
        b.box(0.19, 0.28, 0.05, RED, at(0, 0, 0.02))  # sash
        b.box(0.03, 0.05, 0.22, DEEP, at(0.085, 0, 0.06), shade=0.5)  # placket
        b.box(0.2, 0.06, 0.03, DARKWOOD, at(0, 0, 0.18) @ rot(0.75, "X"))  # satchel strap
        b.box(0.12, 0.05, 0.11, WOOD, at(-0.02, -0.16, -0.02))  # satchel
        b.cyl(0.08, 0.07, 0.05, RED, at(0.0, 0, 0.29), seg=8)  # scarf
        b.spike(0.03, 0.12, RED, at(-0.06, 0.04, 0.3) @ rot(2.7, "Y"), seg=4, prism=0.5)
        for s in (1, -1):
            arm(b, pose, s, (0, s * 0.16, 0.28), 0.25, 0.032, DEEP, P["skin"])
        r = 0.105
        head(b, 0.45, r, P, pose.expr)
        with b.xf(at(0, 0, 0.45)):
            hair_cap(b, r, BLACK)
            b.ball(r * 0.4, BLACK, at(-r * 0.5, 0, r * 1.0))  # topknot
            b.cyl(r * 0.3, r * 0.3, r * 0.15, RED, at(-r * 0.5, 0, r * 0.75), seg=6)


def elder(b, pose):
    """Bà Lan: elderly woman in a teal áo dài and black khăn vấn, leaning on a cane."""
    P = dict(skin=BONE, brow=GREY, lips=TAUPE)
    pose = pose._replace(amp=pose.amp * 0.6)  # a slow shuffle
    legs(b, pose, 0.3, 0.29, 0.04, SNOW, 0.06, foot=BLACK)

    def cane(b):
        b.cyl(0.012, 0.012, 0.33, WOOD, at(0.0, 0, -0.29), seg=5)
        b.box(0.08, 0.025, 0.025, WOOD, at(0.02, 0, 0.03))

    with b.xf(at(0, 0, 0.28 + bob(pose, 0.015)) @ rot(0.16, "Y")):
        b.box(0.16, 0.24, 0.28, TEAL, taper=1.05)  # áo dài bodice
        for x in (0.07, -0.07):  # front and back panels falling past the knees
            b.box(0.015, 0.17, 0.36, TEAL, at(x, 0, -0.3), shade=0.25, taper=1.2)
        b.box(0.03, 0.08, 0.04, GOLD, at(0.08, -0.06, 0.2))  # brooch
        b.cyl(0.055, 0.06, 0.05, TEAL, at(0, 0, 0.27), seg=8)  # high collar
        arm(b, pose, 1, (0, 0.15, 0.26), 0.23, 0.03, TEAL, P["skin"], lift=0.25)
        arm(b, pose, -1, (0, -0.15, 0.26), 0.23, 0.03, TEAL, P["skin"], lift=0.45, amp=0.3, hold=cane)
        b.cyl(0.035, 0.035, 0.015, JADE, at(0.08, -0.17, 0.05), seg=6)  # jade bangle hint
        r = 0.1
        head(b, 0.42, r, P, pose.expr)
        with b.xf(at(0, 0, 0.42)):
            hair_cap(b, r, GREY, back=0.35)
            # Khăn vấn: a thick black turban band wound round the crown.
            b.cyl(r * 1.08, r * 1.0, r * 0.45, BLACK, at(-r * 0.12, 0, r * 0.3) @ rot(-0.25, "Y"), seg=12)
            b.cyl(r * 0.85, r * 0.6, r * 0.2, BLACK, at(-r * 0.25, 0, r * 0.7) @ rot(-0.25, "Y"), seg=10,
                  shade=0.3)


def priestess(b, pose):
    """Itzel: Aztec temple keeper in a banded huipil, quetzal-feather headdress, jade staff."""
    P = dict(skin=CLAY, brow=BLACK, lips=BRICK)
    legs(b, pose, 0.3, 0.3, 0.038, CLAY, 0.055, foot=GOLD)

    def staff(b):
        b.cyl(0.013, 0.013, 0.8, DARKWOOD, at(0, 0, -0.28), seg=5)
        b.ball(0.035, JADE, at(0, 0, 0.54))
        for k in range(3):
            b.spike(0.015, 0.1, RED if k % 2 else JADE, at(0, 0, 0.55) @ rot(-0.5 + k * 0.5, "X"), seg=3, prism=0)

    with b.xf(at(0, 0, 0.32 + bob(pose, 0.02))):
        b.cyl(0.12, 0.16, 0.26, ORANGE, at(0, 0, -0.2), seg=8, shade=0.2)  # wrapped skirt
        b.cyl(0.161, 0.161, 0.03, JADE, at(0, 0, -0.2), seg=8)
        b.box(0.17, 0.25, 0.3, CREAM, taper=1.05)  # huipil
        for k, sw in enumerate((RED, JADE, RED)):
            b.box(0.175, 0.255, 0.025, sw, at(0, 0, 0.04 + k * 0.05))
        for k in range(7):  # jade bead collar
            a = (k - 3) * 0.4
            b.ball(0.017, JADE if k % 2 else GOLD, at(0.08 * math.cos(a), 0.11 * math.sin(a), 0.27))
        arm(b, pose, 1, (0, 0.15, 0.28), 0.24, 0.03, P["skin"], P["skin"], amp=0.4, lift=0.35, hold=staff)
        arm(b, pose, -1, (0, -0.15, 0.28), 0.24, 0.03, P["skin"], P["skin"])
        for s in (1, -1):
            b.cyl(0.034, 0.034, 0.03, GOLD, at(0, s * 0.165, 0.12), seg=6)  # arm cuffs
        r = 0.1
        head(b, 0.44, r, P, pose.expr)
        with b.xf(at(0, 0, 0.44)):
            hair_cap(b, r, BLACK, back=0.32)
            b.box(r * 0.5, r * 1.6, r * 3.0, BLACK, at(-r * 0.6, 0, -r * 2.4), taper=0.8)  # long hair
            for s in (1, -1):
                b.ball(r * 0.14, GOLD, at(-r * 0.05, s * r * 0.95, -r * 0.35))  # ear spools
            # Gold brow band with a jade disc, quetzal plumes fanned out behind.
            b.cyl(r * 1.02, r * 1.02, r * 0.22, GOLD, at(-r * 0.05, 0, r * 0.35), seg=12)
            b.cyl(r * 0.2, r * 0.2, r * 0.08, JADE, at(r * 0.98, 0, r * 0.45) @ rot(math.pi / 2, "Y"), seg=8)
            for k in range(9):
                a = (k - 4) * 0.3
                sw = JADE if k % 2 == 0 else (RED if k % 4 == 1 else AMBER)
                b.spike(r * 0.16, r * (3.2 if k % 2 == 0 else 2.6), sw,
                        at(-r * 0.5, 0, r * 0.45) @ rot(a, "X") @ rot(-0.35, "Y"), seg=4, prism=0.6)


def smith(b, pose):
    """Chú Tư: stocky blacksmith, bare arms, leather apron, red headband, hammer in hand."""
    P = dict(skin=SAND, brow=BLACK, lips=BRICK)

    def hammer(b):
        b.box(0.022, 0.022, 0.2, DARKWOOD, at(0.03, 0, -0.15) @ rot(0.4, "Y"))
        b.box(0.1, 0.055, 0.055, IRON, at(0.09, 0, -0.17) @ rot(0.4, "Y"))

    legs(b, pose, 0.32, 0.3, 0.05, SLATE, 0.075, foot=BLACK)
    with b.xf(at(0, 0, 0.3 + bob(pose, 0.025))):
        b.box(0.21, 0.31, 0.3, GREY, taper=1.15)  # vest
        b.box(0.03, 0.26, 0.42, UMBER, at(0.11, 0, -0.16), taper=1.1)  # leather apron
        b.box(0.22, 0.32, 0.04, UMBER, at(0, 0, 0.02))  # apron tie
        for s in (1, -1):
            b.box(0.03, 0.025, 0.2, UMBER, at(0.1, s * 0.09, 0.12))  # bib straps
        arm(b, pose, 1, (0, 0.19, 0.27), 0.25, 0.04, P["skin"], P["skin"])
        arm(b, pose, -1, (0, -0.19, 0.27), 0.25, 0.04, P["skin"], P["skin"], amp=0.6, hold=hammer)
        r = 0.105
        head(b, 0.43, r, P, pose.expr)
        with b.xf(at(0, 0, 0.43)):
            hair_cap(b, r, BLACK, back=0.38, sq=(0.95, 0.98, 0.85))
            b.cyl(r * 1.0, r * 1.0, r * 0.2, RED, at(-r * 0.08, 0, r * 0.38), seg=12)  # headband
            b.spike(r * 0.12, r * 0.6, RED, at(-r * 0.95, -r * 0.2, r * 0.45) @ rot(-2.2, "Y"), seg=3, prism=0.4)
            b.box(r * 0.12, r * 0.5, r * 0.08, BLACK, at(r * 0.82, 0, -r * 0.33) @ rot(0, "X"))  # moustache
            b.box(r * 0.25, r * 0.8, r * 0.3, BLACK, at(r * 0.45, 0, -r * 0.95), shade=0.4)  # stubbled jaw


def child(b, pose):
    """Ngọc: little girl in a yellow áo bà ba, twin hair buns tied with red ribbon."""
    P = dict(skin=SAND, brow=BLACK, lips=CORAL)
    legs(b, pose, 0.2, 0.19, 0.032, CORAL, 0.05, foot=RED)
    with b.xf(at(0, 0, 0.19 + bob(pose, 0.03))):
        b.box(0.14, 0.2, 0.19, AMBER, taper=1.05)
        b.box(0.02, 0.04, 0.15, ORANGE, at(0.07, 0, 0.02))
        for s in (1, -1):
            arm(b, pose, s, (0, s * 0.12, 0.18), 0.16, 0.025, AMBER, P["skin"], amp=1.2)
        r = 0.1
        head(b, 0.31, r, P, pose.expr)
        with b.xf(at(0, 0, 0.31)):
            hair_cap(b, r, BLACK, back=0.28)
            b.box(r * 0.4, r * 1.4, r * 0.35, BLACK, at(r * 0.6, 0, r * 0.55), shade=0.3)  # fringe
            for s in (1, -1):
                b.ball(r * 0.38, BLACK, at(-r * 0.15, s * r * 0.75, r * 0.85))
                b.spike(r * 0.12, r * 0.4, RED, at(-r * 0.15, s * r * 0.55, r * 0.75) @ rot(s * 2.2, "X"),
                        seg=3, prism=0)


def guard(b, pose):
    """Gate guard: red tunic with gold trim, nón lá, spear with a red tassel."""
    P = dict(skin=TAN, brow=BLACK, lips=BRICK)

    def spear(b):
        b.cyl(0.013, 0.013, 1.0, WOOD, at(0, 0, -0.32), seg=5)
        b.spike(0.026, 0.12, STONE, at(0, 0, 0.68), seg=4, prism=0.2)
        for k in range(4):
            b.spike(0.012, 0.09, RED, at(0, 0, 0.67) @ rot(math.pi + 0.3 * (k - 1.5), "X"), seg=3, prism=0)

    legs(b, pose, 0.34, 0.32, 0.043, DEEP, 0.065, foot=BLACK)
    with b.xf(at(0, 0, 0.32 + bob(pose, 0.02))):
        b.box(0.18, 0.27, 0.3, RED, taper=1.1)  # tunic
        b.box(0.19, 0.25, 0.14, RED, at(0, 0, -0.12), taper=0.9, shade=0.3)  # skirt flaps
        b.box(0.2, 0.28, 0.04, BLACK, at(0, 0, 0.02))  # belt
        b.box(0.02, 0.06, 0.27, GOLD, at(0.09, 0, 0.02))  # trim
        b.ball(0.06, GOLD, at(0.09, 0, 0.18), sq=(0.3, 1, 1))  # medallion
        arm(b, pose, 1, (0, 0.16, 0.28), 0.25, 0.034, RED, P["skin"])
        arm(b, pose, -1, (0, -0.16, 0.28), 0.25, 0.034, RED, P["skin"], lift=0.3, amp=0.3, hold=spear)
        r = 0.105
        head(b, 0.45, r, P, pose.expr)
        with b.xf(at(0, 0, 0.45)):
            hair_cap(b, r, BLACK, back=0.4)
            # Nón lá: a wide shallow cone of palm leaf with a chin strap.
            b.cyl(r * 2.4, r * 0.1, r * 1.05, SAND, at(0, 0, r * 0.55), seg=14, shade=0.1)
            b.cyl(r * 2.42, r * 2.4, r * 0.06, TAN, at(0, 0, r * 0.52), seg=14, shade=0.4)
            for s in (1, -1):
                b.box(r * 0.08, r * 0.06, r * 1.0, GOLD, at(r * 0.1, s * r * 0.82, -r * 0.5))


MAKERS = dict(player=player, elder=elder, priestess=priestess, smith=smith, child=child, guard=guard)


def build(kind, pose, mat):
    b = Builder()
    b.head = None
    MAKERS[kind](b, pose)
    hd = b.head
    return b.finish(f"{kind}", mat), hd


def render_png(sc, path):
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def walk_sheet(sc, mat, cam, out):
    import numpy as np
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = SPAN
    # Ground depth on screen is sin(pitch) = 0.62, as gfx.iso's squash.
    pitch = math.asin(0.62)
    cam.rotation_euler = (math.pi / 2 - pitch, 0, 0)
    cam.location = (0, -20 * math.cos(pitch), 20 * math.sin(pitch))
    cam.data.shift_y = ANCHOR - 0.5
    sc.render.resolution_x = sc.render.resolution_y = CELL
    total = len(KINDS) * FACINGS * FRAMES
    rows = (total + COLS - 1) // COLS
    sheet = np.zeros((rows * CELL, COLS * CELL, 4), dtype=np.float32)
    tmp = tempfile.mkdtemp()
    for k, kind in enumerate(KINDS):
        for fr in range(FRAMES):
            ob, _ = build(kind, Pose(fr * TAU / FRAMES, 0.55, "neutral"), mat)
            for f in range(FACINGS):
                ob.rotation_euler = (0, 0, f * math.pi / 4)
                path = os.path.join(tmp, f"{kind}_{f}_{fr}.png")
                render_png(sc, path)
                img = bpy.data.images.load(path)
                px = np.array(img.pixels[:], dtype=np.float32).reshape(CELL, CELL, 4)
                bpy.data.images.remove(img)
                i = (k * FACINGS + f) * FRAMES + fr
                # Blender images are bottom-up; the sheet is built bottom-up too, row 0 at the top.
                r, c = i // COLS, i % COLS
                y0 = (rows - 1 - r) * CELL
                sheet[y0:y0 + CELL, c * CELL:(c + 1) * CELL] = px
            bpy.data.objects.remove(ob)
    atlas = bpy.data.images.new("villagers", COLS * CELL, rows * CELL, alpha=True)
    atlas.pixels.foreach_set(sheet.ravel())
    atlas.filepath_raw = out
    atlas.file_format = "PNG"
    atlas.save()
    print(f"wrote {out}: {COLS * CELL} x {rows * CELL}, {total} sprites")


def turn_to_camera(ob, yaw):
    """Turn a character (built facing +x) to face the camera on -y, then by `yaw` to its left."""
    ob.rotation_euler = (0, 0, -math.pi / 2 + yaw)
    bpy.context.view_layer.update()


def portraits(sc, mat, cam, outdir):
    cam.data.type = "PERSP"
    cam.data.lens, cam.data.sensor_fit, cam.data.sensor_width = 50, "AUTO", 36
    cam.data.shift_y = 0.0
    half_fov = math.atan(18 / 50)
    sc.render.resolution_x = sc.render.resolution_y = PORTRAIT
    for kind in KINDS:
        for expr in EXPRS:
            ob, (hc, r) = build(kind, Pose(0.0, 0.0, expr), mat)
            turn_to_camera(ob, 0.0)
            hc = ob.matrix_world @ hc
            # Bust framing: crown to upper chest; the headdress gets more headroom.
            frame, up = (6.4, 0.9) if kind == "priestess" else (4.8, -0.35)
            d = frame * r / 2 / math.tan(half_fov)
            cam.location = (hc.x, hc.y - d, hc.z + up * r + 0.05 * d)
            cam.rotation_euler = (math.pi / 2 - math.atan2(0.05 * d, d), 0, 0)
            render_png(sc, os.path.join(outdir, f"{kind}_{expr}.png"))
            bpy.data.objects.remove(ob)


def figures(sc, mat, cam, outdir):
    cam.data.type = "PERSP"
    cam.data.lens, cam.data.sensor_fit, cam.data.sensor_height = 85, "VERTICAL", 24
    half_fov = math.atan(12 / 85)
    d = FIG_SPAN / 2 / math.tan(half_fov)
    cam.location = (0, -d, FIG_SPAN * (0.5 - FIG_FOOT))
    cam.rotation_euler = (math.pi / 2, 0, 0)
    cam.data.shift_y = 0.0
    sc.render.resolution_x, sc.render.resolution_y = FIG_W, FIG_H
    for kind in KINDS:
        ob, _ = build(kind, Pose(0.0, 0.0, "neutral"), mat)
        turn_to_camera(ob, 0.6)
        render_png(sc, os.path.join(outdir, f"{kind}.png"))
        bpy.data.objects.remove(ob)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    palette = argv[0]
    root = argv[1] if len(argv) > 1 else "assets"
    for sub in ("sprites", "portraits", "figures"):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    light_scene(sc)
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    mat = atlas_material(palette)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    portraits(sc, mat, cam, os.path.join(root, "portraits"))
    figures(sc, mat, cam, os.path.join(root, "figures"))
    walk_sheet(sc, mat, cam, os.path.join(root, "sprites", "villagers.png"))


main()

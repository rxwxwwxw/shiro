# Shared helpers for the Blender asset scripts: low-poly primitives whose faces are colored by
# pointing their UVs into the Hex-Map-WFC palette atlas (8 x 4 vertical gradient swatches), so the
# assets pick up the same palette and level blending as the terrain.
import bpy, bmesh, math
from contextlib import contextmanager
from mathutils import Matrix

# Swatches as (column, row from the top) of the atlas.
BLACK, SNOW, STONE, SLATE, IRON = (0, 0), (1, 0), (2, 0), (3, 0), (4, 0)
CLAY, BRICK, EMBER = (5, 0), (6, 0), (7, 0)
ICE, DEEP, WOOD, GOLD, LEAF = (0, 1), (1, 1), (2, 1), (3, 1), (4, 1)
SAND, ROCK, DARKWOOD = (5, 1), (6, 1), (7, 1)
LIME, JADE, GREY, TAN, CREAM, FIRE, CORAL = (0, 2), (1, 2), (2, 2), (3, 2), (5, 2), (6, 2), (7, 2)
SKY, RED, AMBER, TEAL, ORANGE, BONE, TAUPE, UMBER = (0, 3), (1, 3), (2, 3), (3, 3), (4, 3), (5, 3), (6, 3), (7, 3)


def swatch_uv(sw, t):
    """Blender UV of a swatch, `t` 0 = top (light) .. 1 = bottom (dark) of its gradient."""
    c, r = sw
    t = 0.08 + 0.84 * min(max(t, 0.0), 1.0)
    return ((c + 0.5) / 8.0, 1.0 - (r + t) / 4.0)


def rot(angle, axis):
    return Matrix.Rotation(angle, 4, axis)


def at(x=0.0, y=0.0, z=0.0):
    return Matrix.Translation((x, y, z))


def scale(sx, sy, sz):
    return Matrix.Diagonal((sx, sy, sz, 1))


class Builder:
    """Accumulates parts into one bmesh. Placement nests with `xf` (e.g. a limb about its joint)."""

    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.stack = [Matrix.Identity(4)]

    @contextmanager
    def xf(self, m):
        self.stack.append(self.stack[-1] @ m)
        try:
            yield
        finally:
            self.stack.pop()

    def _place(self, vs, local, sw, shade):
        bmesh.ops.transform(self.bm, matrix=self.stack[-1] @ local, verts=vs)
        faces = {f for v in vs for f in v.link_faces}
        zs = [v.co.z for v in vs]
        lo, hi = min(zs), max(zs)
        span = max(hi - lo, 1e-4)
        for f in faces:
            for l in f.loops:
                # Lighter at the top of each part, darker below; `shade` biases the whole part.
                l[self.uv].uv = swatch_uv(sw, shade + 0.55 * (hi - l.vert.co.z) / span)
        return vs

    def cyl(self, r1, r2, h, sw, m=Matrix.Identity(4), seg=8, shade=0.0, caps=True):
        """Frustum standing on its base at the local origin."""
        vs = bmesh.ops.create_cone(self.bm, cap_ends=caps, segments=seg, radius1=r1, radius2=r2,
                                   depth=h)["verts"]
        return self._place(vs, m @ at(0, 0, h / 2), sw, shade)

    def box(self, sx, sy, sz, sw, m=Matrix.Identity(4), shade=0.0, taper=1.0):
        """Box standing on its base at the local origin; `taper` scales the top face."""
        vs = bmesh.ops.create_cube(self.bm, size=1.0)["verts"]
        if taper != 1.0:
            for v in vs:
                if v.co.z > 0:
                    v.co.x *= taper
                    v.co.y *= taper
        return self._place(vs, m @ scale(sx, sy, sz) @ at(0, 0, 0.5), sw, shade)

    def ball(self, r, sw, m=Matrix.Identity(4), sub=1, shade=0.0, sq=(1, 1, 1)):
        vs = bmesh.ops.create_icosphere(self.bm, subdivisions=sub, radius=r)["verts"]
        return self._place(vs, m @ scale(*sq), sw, shade)

    def spike(self, r, h, sw, m=Matrix.Identity(4), seg=6, prism=0.7, shade=0.0):
        """Prism of height h * prism capped by a point (crystals, flames, horns, leaves)."""
        if prism <= 0:
            return self.cyl(r, 0.0, h, sw, m, seg=seg, shade=shade)
        vs = list(bmesh.ops.create_cone(self.bm, cap_ends=True, segments=seg, radius1=r, radius2=r,
                                        depth=h * prism)["verts"])
        bmesh.ops.translate(self.bm, verts=vs, vec=(0, 0, h * prism / 2))
        top = [v for v in vs if v.co.z > h * prism * 0.75]
        caps = [f for f in {f for v in top for f in v.link_faces} if all(v in top for v in f.verts)]
        ring = list(caps[0].verts)
        bmesh.ops.delete(self.bm, geom=caps, context="FACES_ONLY")
        apex = self.bm.verts.new((0, 0, h))
        for i in range(len(ring)):
            self.bm.faces.new((ring[i], ring[(i + 1) % len(ring)], apex))
        vs.append(apex)
        return self._place(vs, m, sw, shade)

    def finish(self, name, mat=None):
        bmesh.ops.remove_doubles(self.bm, verts=self.bm.verts, dist=1e-5)
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        me = bpy.data.meshes.new(name)
        self.bm.to_mesh(me)
        self.bm.free()
        for p in me.polygons:
            p.use_smooth = False
        if mat is not None:
            me.materials.append(mat)
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob


def atlas_material(atlas_png):
    """Unlit-leaning material showing the palette atlas (for preview and sprite renders)."""
    mat = bpy.data.materials.new("atlas")
    if not atlas_png:
        return mat
    mat.use_nodes = True
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(atlas_png)
    tex.interpolation = "Closest"
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.9
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def light_scene(sc, ambient=0.8, sun=3.5):
    """Sun from the upper left (as the map's light), soft sky fill, Standard view transform."""
    s = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    s.data.energy = sun
    s.rotation_euler = (math.radians(40), math.radians(15), math.radians(-30))
    sc.collection.objects.link(s)
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.6, 0.65, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = ambient
    sc.world = w
    sc.render.engine = "BLENDER_EEVEE"
    sc.view_settings.view_transform = "Standard"

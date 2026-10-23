// Minimal glTF binary (.glb) reader for the Hex-Map-WFC terrain model: JSON header (core.json) plus
// named-mesh lookup into the binary chunk. Only what the viewer needs: node name -> triangle
// mesh (positions, normals, UVs, indices) and the embedded base color image. View layer; load is
// a cold path, lookups are @nogc and allocation-free.
module gfx.glb;

import core.result : EngineError;
import core.stdc.stdio : FILE, SEEK_END, SEEK_SET, fclose, fopen, fread, fseek, ftell;
import core.json;
import core.stdc.stdlib : free, malloc;

// ---- GLB -------------------------------------------------------------------------------------

/// A triangle mesh inside the GLB; pointers stay valid for the life of the owning GlbModel.
struct MeshRef {
    const(float)* pos;
    const(float)* nrm;
    const(float)* uv;
    const(ubyte)* idx;
    /// 1, 2 or 4.
    ubyte idxBytes;
    uint nVerts, nIdx;
    /// Position bounds.
    float[3] lo = 0, hi = 0;

    bool valid() const @nogc nothrow pure @safe {
        return pos !is null && nIdx >= 3;
    }

    uint index(uint i) const @nogc nothrow @trusted {
        final switch (idxBytes) {
        case 1:
            return idx[i];
        case 2:
            return (cast(const(ushort)*)idx)[i];
        case 4:
            return (cast(const(uint)*)idx)[i];
        }
    }
}

private struct NamedMesh {
    const(char)[] name;
    MeshRef mesh;
}

struct GlbModel {
    private ubyte* data;
    private size_t size;
    private Json json;
    private NamedMesh* named;
    private size_t nNamed;
    private const(ubyte)[] bin;
    private const(ubyte)[] image_;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(named);
        free(data);
    }

    bool loaded() const @nogc nothrow pure @safe {
        return data !is null;
    }

    /// The embedded base color image (PNG), or empty.
    const(ubyte)[] image() const @nogc nothrow pure @safe {
        return image_;
    }

    size_t meshCount() const @nogc nothrow pure @safe {
        return nNamed;
    }

    /// Mesh of the first node called `name`; false if absent.
    bool find(const(char)[] name, out MeshRef m) const @nogc nothrow @trusted {
        foreach (i; 0 .. nNamed)
            if (named[i].name == name) {
                m = named[i].mesh;
                return m.valid;
            }
        return false;
    }

    EngineError load(const(char)* path) @nogc nothrow @trusted {
        FILE* f = fopen(path, "rb");
        if (f is null)
            return EngineError.ResourceNotFound;
        scope (exit)
            fclose(f);
        if (fseek(f, 0, SEEK_END) != 0)
            return EngineError.ResourceNotFound;
        immutable len = ftell(f);
        if (len < 28 || len > (1 << 30) || fseek(f, 0, SEEK_SET) != 0)
            return EngineError.ResourceNotFound;
        auto buf = cast(ubyte*)malloc(len);
        if (buf is null)
            return EngineError.InitializationFailed;
        if (fread(buf, 1, len, f) != len) {
            free(buf);
            return EngineError.ResourceNotFound;
        }
        free(data);
        data = buf;
        size = len;
        immutable err = index();
        if (err != EngineError.None) {
            free(data);
            data = null;
        }
        return err;
    }

    private static uint le32(const(ubyte)* p) @nogc nothrow pure @trusted {
        return p[0] | p[1] << 8 | p[2] << 16 | cast(uint)p[3] << 24;
    }

    /// Splits chunks, parses the JSON and resolves every named mesh node.
    private EngineError index() @nogc nothrow @trusted {
        enum EngineError bad = EngineError.InitializationFailed;
        if (le32(data) != 0x46546C67 || le32(data + 4) != 2 || le32(data + 8) > size)
            return bad;
        size_t p = 12;
        const(char)[] jsonText;
        bin = null;
        while (p + 8 <= size) {
            immutable clen = le32(data + p), ctype = le32(data + p + 4);
            p += 8;
            if (clen > size - p)
                return bad;
            if (ctype == 0x4E4F534A)
                jsonText = (cast(const(char)*)data + p)[0 .. clen];
            else if (ctype == 0x004E4942 && bin.length == 0)
                bin = (data + p)[0 .. clen];
            p += (clen + 3) & ~3u;
        }
        if (jsonText.length == 0 || !json.parse(jsonText))
            return bad;

        immutable nodes = json.get(0, "nodes"), meshes = json.get(0, "meshes");
        immutable accessors = json.get(0, "accessors"), views = json.get(0, "bufferViews");
        immutable nodeCount = json.length(nodes);
        named = cast(NamedMesh*)malloc((nodeCount ? nodeCount : 1) * NamedMesh.sizeof);
        if (named is null)
            return EngineError.InitializationFailed;
        nNamed = 0;
        foreach (n; 0 .. nodeCount) {
            immutable node = json.at(nodes, n);
            immutable mi = json.get(node, "mesh"), nm = json.get(node, "name");
            if (mi < 0 || nm < 0)
                continue;
            immutable prim = json.at(json.get(json.at(meshes, json.integer(mi)), "primitives"), 0);
            if (prim < 0)
                continue;
            NamedMesh e;
            e.name = json.str(nm);
            if (!meshOf(prim, accessors, views, e.mesh))
                continue;
            named[nNamed++] = e;
        }

        immutable img = json.at(json.get(0, "images"), 0);
        immutable vi = json.get(img, "bufferView");
        if (vi >= 0) {
            immutable view = json.at(views, json.integer(vi));
            immutable off = json.integer(json.get(view, "byteOffset")), len = json.integer(json.get(view,
                    "byteLength"));
            if (off >= 0 && len > 0 && cast(size_t)off + len <= bin.length)
                image_ = bin[off .. off + len];
        }
        return nNamed > 0 ? EngineError.None : bad;
    }

    /// Resolves an accessor to a pointer into the BIN chunk; null if it is not tightly packed.
    private const(ubyte)* accessor(int acc, int accessors, int views, out uint count, out int component,
            ref const Json js, out int accTok) const @nogc nothrow @trusted {
        accTok = js.at(accessors, acc);
        if (accTok < 0)
            return null;
        count = cast(uint)js.integer(js.get(accTok, "count"));
        component = js.integer(js.get(accTok, "componentType"));
        immutable view = js.at(views, js.integer(js.get(accTok, "bufferView"), -1));
        if (view < 0 || js.get(view, "byteStride") >= 0)
            return null;
        immutable off = js.integer(js.get(view, "byteOffset")) + js.integer(js.get(accTok, "byteOffset"));
        immutable len = js.integer(js.get(view, "byteLength"));
        if (off < 0 || cast(size_t)off + len > bin.length || (off & 3))
            return null;
        return bin.ptr + off;
    }

    private bool meshOf(int prim, int accessors, int views, out MeshRef m) const @nogc nothrow @trusted {
        immutable attrs = json.get(prim, "attributes");
        uint n;
        int comp, t;
        const ap = accessor(json.integer(json.get(attrs, "POSITION"), -1), accessors, views, n, comp, json, t);
        if (ap is null || comp != 5126)
            return false;
        m.pos = cast(const(float)*)ap;
        m.nVerts = n;
        foreach (k; 0 .. 3) {
            m.lo[k] = cast(float)json.num(json.at(json.get(t, "min"), k));
            m.hi[k] = cast(float)json.num(json.at(json.get(t, "max"), k));
        }
        uint c2;
        const np = accessor(json.integer(json.get(attrs, "NORMAL"), -1), accessors, views, c2, comp, json, t);
        m.nrm = np !is null && comp == 5126 && c2 == n ? cast(const(float)*)np : null;
        const up = accessor(json.integer(json.get(attrs, "TEXCOORD_0"), -1), accessors, views, c2, comp, json, t);
        m.uv = up !is null && comp == 5126 && c2 == n ? cast(const(float)*)up : null;
        const ip = accessor(json.integer(json.get(prim, "indices"), -1), accessors, views, m.nIdx, comp, json, t);
        if (ip is null || m.nIdx % 3 != 0 || m.nrm is null || m.uv is null)
            return false;
        switch (comp) {
        case 5121:
            m.idxBytes = 1;
            break;
        case 5123:
            m.idxBytes = 2;
            break;
        case 5125:
            m.idxBytes = 4;
            break;
        default:
            return false;
        }
        m.idx = ip;
        foreach (i; 0 .. m.nIdx)
            if (m.index(i) >= n)
                return false;
        return true;
    }
}

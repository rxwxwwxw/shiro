// Whole-file reads into an owned malloc'd buffer (RAII), for cold-path data loading such as story
// scripts. Portable C stdio only.
module core.file;

import core.result : EngineError;
import core.stdc.stdio : SEEK_END, SEEK_SET, fclose, fopen, fread, fseek, ftell;
import core.stdc.stdlib : free, malloc;

struct FileBytes {
    private char* data;
    private size_t len;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(data);
    }

    /// Reads `path` (NUL-terminated); replaces any earlier contents.
    EngineError load(const(char)* path) @nogc nothrow @trusted {
        free(data);
        data = null;
        len = 0;
        auto f = fopen(path, "rb");
        if (f is null)
            return EngineError.ResourceNotFound;
        scope (exit)
            fclose(f);
        if (fseek(f, 0, SEEK_END) != 0)
            return EngineError.ResourceNotFound;
        immutable size = ftell(f);
        if (size < 0 || fseek(f, 0, SEEK_SET) != 0)
            return EngineError.ResourceNotFound;
        data = cast(char*)malloc(size + 1);
        if (data is null)
            return EngineError.BufferOverflow;
        if (fread(data, 1, size, f) != cast(size_t)size) {
            free(data);
            data = null;
            return EngineError.ResourceNotFound;
        }
        data[size] = 0;
        len = size;
        return EngineError.None;
    }

    const(char)[] text() const return @nogc nothrow @trusted {
        return data is null ? null : data[0 .. len];
    }
}

@nogc nothrow unittest {
    FileBytes f;
    assert(f.load("definitely/not/here.txt") == EngineError.ResourceNotFound && f.text is null);
    assert(f.load("src/core/file.d") == EngineError.None);
    assert(f.text.length > 100 && f.text[0 .. 2] == "//");
}

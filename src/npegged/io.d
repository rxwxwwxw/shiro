/** Scoped C I/O for npegged (Boost Software License 1.0). */
module npegged.io;
import core.stdc.stdio : FILE, fopen, fclose, fread, fwrite, ferror, fflush;
import npegged.storage : Arena, Buffer, Status;

struct File {
    private FILE* handle;
    private Status _status = Status.ioError;
    @property Status status() const @nogc nothrow {
        return _status;
    }

    @disable this(this);
    @disable this(ref File);
    static File open(scope string path, bool write = false) @nogc nothrow {
        File result;
        foreach (c; path)
            if (c == 0) {
                result._status = Status.invalidInput;
                return result;
            }
        Arena temporary;
        auto name = temporary.allocate!char(path.length + 1);
        if (!name.length) {
            result._status = temporary.status;
            return result;
        }
        name[0 .. path.length] = path[];
        name[$ - 1] = 0;
        result.handle = fopen(name.ptr, write ? "wb" : "rb");
        result._status = result.handle is null ? Status.ioError : Status.ok;
        return result;
    }

    ~this() @nogc nothrow {
        if (handle !is null)
            fclose(handle);
    }

    @property bool valid() const @nogc nothrow {
        return handle !is null;
    }

    Status write(scope const(char)[] data) @nogc nothrow {
        if (!valid)
            return _status;
        return fwrite(data.ptr, 1, data.length, handle) == data.length && fflush(handle) == 0 ? Status.ok
            : Status.ioError;
    }

    Status read(ref Buffer!char output) @nogc nothrow {
        if (!valid)
            return _status;
        char[4096] block;
        for (;;) {
            auto count = fread(block.ptr, 1, block.length, handle);
            if (!output.put(block[0 .. count]))
                return output.status;
            if (count < block.length)
                return ferror(handle) ? Status.ioError : Status.ok;
        }
    }
}

@nogc nothrow unittest {
    auto missing = File.open("/npegged/nonexistent/file");
    assert(!missing.valid);
    assert(missing.write("x") == Status.ioError);
    Buffer!char data;
    assert(missing.read(data) == Status.ioError);
    auto empty = File.open("/dev/null");
    assert(empty.valid && empty.read(data) == Status.ok);
    auto output = File.open("/dev/null", true);
    assert(output.write("hello") == Status.ok);
    auto full = File.open("/dev/full", true);
    assert(full.write("hello") == Status.ioError);
}

@nogc nothrow unittest {
    auto readOnly = File.open("/dev/zero");
    assert(readOnly.valid);
    Buffer!char limited;
    limited.memoryLimit = 16;
    assert(readOnly.read(limited) == Status.resourceLimit);
    assert(readOnly.write("data") == Status.ioError);
    auto writeOnly = File.open("/dev/null", true);
    Buffer!char data;
    assert(writeOnly.read(data) == Status.ioError);
}

@nogc nothrow unittest {
    auto invalid = File.open("ignored\0suffix");
    assert(!invalid.valid && invalid.status == Status.invalidInput);
    assert(invalid.write("data") == Status.invalidInput);
}

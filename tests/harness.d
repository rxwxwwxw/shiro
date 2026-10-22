// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Shared helpers for headless integration tests: a wall-clock timeout, a peak-memory ceiling,
// and a tiny pass/fail reporter. No Phobos, no exceptions.
module tests.harness;

import core.stdc.stdio : printf, fflush, stdout;
import core.stdc.stdlib : exit;

version (Posix) {
    import core.sys.posix.signal : signal, SIGALRM;
    import core.sys.posix.sys.time : timeval;
    import core.sys.posix.unistd : alarm, write, _exit;

    // druntime's rusage omits ru_maxrss on some platforms; the first three fields are identical on
    // Linux and Darwin. ru_maxrss is KiB on Linux and bytes on Darwin.
    private struct RUsage {
        timeval ru_utime;
        timeval ru_stime;
        long ru_maxrss;
        long[13] rest;
    }

    private extern (C) int getrusage(int who, RUsage* usage) @nogc nothrow;

    /// Peak resident set size of this process in MiB (0 if unavailable).
    size_t peakRssMiB() @nogc nothrow @trusted {
        RUsage ru;
        if (getrusage(0, &ru) != 0)
            return 0;
        version (OSX)
            return cast(size_t)(ru.ru_maxrss / (1024 * 1024));
        else
            return cast(size_t)(ru.ru_maxrss / 1024);
    }

    private extern (C) void onTimeout(int) @nogc nothrow {
        static immutable msg = "TIMEOUT: integration test exceeded its wall-clock limit\n";
        write(2, msg.ptr, msg.length);
        _exit(124);
    }

    /// Kills the process (exit code 124) if it runs longer than `seconds`.
    void setTimeout(uint seconds) @nogc nothrow @trusted {
        signal(SIGALRM, &onTimeout);
        alarm(seconds);
    }
} else {
    size_t peakRssMiB() @nogc nothrow {
        return 0;
    }

    void setTimeout(uint seconds) @nogc nothrow {
    }
}

struct Report {
    size_t passed;
    size_t failed;

    void check(bool ok, const(char)* what) @nogc nothrow {
        if (ok) {
            passed++;
        } else {
            failed++;
            printf("  FAIL: %s\n", what);
        }
    }
}

/// Fails the run if peak memory exceeds the ceiling.
bool withinMemory(size_t ceilingMiB, const(char)* suite) @nogc nothrow {
    immutable used = peakRssMiB();
    if (used > ceilingMiB) {
        printf("  FAIL: %s peak RSS %d MiB exceeds ceiling %d MiB\n", suite, cast(int)used, cast(int)ceilingMiB);
        return false;
    }
    return true;
}

void flush() @nogc nothrow @trusted {
    fflush(stdout);
}

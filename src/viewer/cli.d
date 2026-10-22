// Command-line parsing for the map viewer (no Phobos: hand-rolled flag and number parsing).
module viewer.cli;

import core.result;
import wfc.grid_connector : MapRect;
import wfc.map_session : GenParams, Layout;

enum CliError : int {
    none,
    /// --help was given; not a failure, the caller prints usage and exits 0.
    help,
    unknownFlag,
    missingValue,
    badNumber,
    badLayout,
    pathTooLong
}

struct ViewerConfig {
    GenParams params;
    int width = 1440, height = 900;
    /// Non-empty: render one frame to this BMP and exit. NUL-terminated.
    char[1024] screenshot = 0;
    bool hasScreenshot;
}

immutable string usage = "usage: shiro_viewer [options]
  --layout rect|island   map layout (default rect)
  --cols N --rows N      rectangle size in cells (default 96 x 54)
  --cells N              rectangle of about N cells, see --aspect
  --aspect W:H           aspect ratio for --cells (default 16:9)
  --radius N             WFC grid radius in cells (default 8)
  --rings N              island rings of grids (default 2 = 19 grids)
  --seed N               random seed (default 1)
  --width N --height N   window size (default 1440 x 900)
  --screenshot PATH      render one frame to a BMP and exit
";

private bool parseInt(const(char)[] s, out int v) @nogc nothrow pure @safe {
    if (s.length == 0 || s.length > 10)
        return false;
    long acc = 0;
    foreach (ch; s) {
        if (ch < '0' || ch > '9')
            return false;
        acc = acc * 10 + (ch - '0');
    }
    if (acc > int.max)
        return false;
    v = cast(int)acc;
    return true;
}

unittest {
    int v;
    assert(parseInt("0", v) && v == 0);
    assert(parseInt("2147483647", v) && v == int.max);
    assert(!parseInt("2147483648", v));
    assert(!parseInt("", v) && !parseInt("-3", v) && !parseInt("12a", v));
}

Result!(ViewerConfig, CliError) parseArgs(const string[] args) @nogc nothrow @trusted {
    alias R = Result!(ViewerConfig, CliError);
    ViewerConfig cfg;
    int cells = 0, aw = 16, ah = 9;
    for (size_t i = 0; i < args.length; i++) {
        immutable a = args[i];
        if (a == "--help" || a == "-h")
            return R.err(CliError.help);
        if (i + 1 >= args.length)
            return R.err(a.length > 2 && a[0 .. 2] == "--" ? CliError.missingValue : CliError.unknownFlag);
        immutable val = args[++i];
        int n;
        bool num() {
            return parseInt(val, n);
        }

        switch (a) {
        case "--layout":
            if (val == "rect")
                cfg.params.layout = Layout.rect;
            else if (val == "island")
                cfg.params.layout = Layout.island;
            else
                return R.err(CliError.badLayout);
            break;
        case "--cols":
            if (!num())
                return R.err(CliError.badNumber);
            cfg.params.cols = n;
            break;
        case "--rows":
            if (!num())
                return R.err(CliError.badNumber);
            cfg.params.rows = n;
            break;
        case "--cells":
            if (!num() || n < 1)
                return R.err(CliError.badNumber);
            cells = n;
            break;
        case "--aspect":
            size_t colon = 0;
            while (colon < val.length && val[colon] != ':')
                colon++;
            if (colon == val.length || !parseInt(val[0 .. colon], aw)
                    || !parseInt(val[colon + 1 .. $], ah) || aw < 1 || ah < 1)
                return R.err(CliError.badNumber);
            break;
        case "--radius":
            if (!num())
                return R.err(CliError.badNumber);
            cfg.params.radius = n;
            break;
        case "--rings":
            if (!num())
                return R.err(CliError.badNumber);
            cfg.params.rings = n;
            break;
        case "--seed":
            if (!num())
                return R.err(CliError.badNumber);
            cfg.params.seed = n;
            break;
        case "--width":
            if (!num() || n < 64)
                return R.err(CliError.badNumber);
            cfg.width = n;
            break;
        case "--height":
            if (!num() || n < 64)
                return R.err(CliError.badNumber);
            cfg.height = n;
            break;
        case "--screenshot":
            if (val.length + 1 > cfg.screenshot.length)
                return R.err(CliError.pathTooLong);
            cfg.screenshot[0 .. val.length] = val[];
            cfg.screenshot[val.length] = 0;
            cfg.hasScreenshot = val.length > 0;
            break;
        default:
            return R.err(CliError.unknownFlag);
        }
    }
    if (cells > 0) {
        immutable rect = MapRect.withAspect(cells, aw, ah);
        cfg.params.cols = rect.cols;
        cfg.params.rows = rect.rows;
    }
    return R.ok(cfg);
}

@nogc nothrow @safe unittest {
    // Defaults.
    immutable string[0] none;
    auto d = parseArgs(none[]);
    assert(d.isOk && d.value.params.cols == 96 && d.value.params.layout == Layout.rect);
    assert(!d.value.hasScreenshot && d.value.width == 1440);

    immutable string[12] a = [
        "--layout", "island", "--radius", "6", "--rings", "1", "--seed", "77", "--screenshot",
        "out.bmp", "--width", "800"
    ];
    auto r = parseArgs(a[]);
    assert(r.isOk);
    immutable c = r.value;
    assert(c.params.layout == Layout.island && c.params.radius == 6 && c.params.rings == 1);
    assert(c.params.seed == 77 && c.width == 800 && c.hasScreenshot);
    assert(c.screenshot[0 .. 8] == "out.bmp\0");
}

@nogc nothrow @safe unittest {
    // --cells with --aspect sizes the rectangle like MapRect.withAspect.
    immutable string[4] a = ["--cells", "1500", "--aspect", "16:9"];
    auto r = parseArgs(a[]);
    immutable rect = MapRect.withAspect(1500, 16, 9);
    assert(r.isOk && r.value.params.cols == rect.cols && r.value.params.rows == rect.rows);
}

@nogc nothrow @safe unittest {
    // Errors.
    immutable string[1] help = ["--help"];
    assert(parseArgs(help[]).error == CliError.help);
    immutable string[2] unk = ["--bogus", "1"];
    assert(parseArgs(unk[]).error == CliError.unknownFlag);
    immutable string[1] miss = ["--cols"];
    assert(parseArgs(miss[]).error == CliError.missingValue);
    immutable string[2] bad = ["--cols", "x9"];
    assert(parseArgs(bad[]).error == CliError.badNumber);
    immutable string[2] lay = ["--layout", "torus"];
    assert(parseArgs(lay[]).error == CliError.badLayout);
    immutable string[2] asp = ["--aspect", "169"];
    assert(parseArgs(asp[]).error == CliError.badNumber);
}

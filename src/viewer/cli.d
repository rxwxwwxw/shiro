// Command-line parsing for the map viewer (no Phobos: hand-rolled flag and number parsing).
module viewer.cli;

import core.result;
import wfc.grid_connector : MapRect;
import wfc.map_session : GenParams, Layout;
import wfc.placement : maxSinks, maxSources;
import wfc.reveal : maxStages;

enum CliError : int {
    none,
    /// --help was given; not a failure, the caller prints usage and exits 0.
    help,
    unknownFlag,
    missingValue,
    badNumber,
    badLayout,
    pathTooLong,
    badScene
}

struct ViewerConfig {
    GenParams params;
    int width = 1440, height = 900;
    /// Non-empty: render one frame to this BMP and exit. NUL-terminated.
    char[1024] screenshot = 0;
    bool hasScreenshot;
    /// Start with the flat-shaded procedural look instead of the terrain model.
    bool flat;
    /// Use SDL's default 2D renderer and CPU-expanded geometry instead of the GPU renderer.
    bool classic;
    /// Screen pixels per world unit to start at (0 = fit the map).
    int zoom;
    /// Cell to select at start (--select COL,ROW), -1 = none; with --zoom the view centers on it.
    int selCol = -1, selRow = -1;
    /// Frames for the --bench frame-time run (0 = normal viewer).
    int bench;
    /// Multiplies measured draw times before quality adaptation, to try a slower machine.
    float slow = 1.0f;
    /// Directory holding models/hex-terrain.glb. NUL-terminated.
    char[1024] assets = 0;
    bool hasAssets;
    /// Let the scripted bot play the tower defense game.
    bool bot;
    /// Simulation ticks to run before the first frame (with --screenshot: a mid-game picture).
    int ticks;
    /// Start in the village hub (the story); false: straight into tower defense as before.
    bool village = true;
    /// Story file (NUL-terminated); empty: assets/story/village.json.
    char[1024] story = 0;
    bool hasStory;
    /// Open a conversation with this villager (a speaker id) at start, for screenshots.
    char[32] talk = 0;
    bool hasTalk;
}

immutable string usage = "usage: shiro_viewer [options]
  --layout rect|island   map layout (default rect)
  --cols N --rows N      rectangle size in cells (default 96 x 54)
  --cells N              rectangle of about N cells, see --aspect
  --aspect W:H           aspect ratio for --cells (default 16:9)
  --radius N             WFC grid radius in cells (default 8)
  --rings N              island rings of grids (default 2 = 19 grids)
  --seed N               random seed (default 1)
  --sources N --sinks N  creep sources and sinks, 1..16 each (default 0 = from the map size)
  --no-roads             plain terrain without sources, sinks and roads
  --stages N             uncover the map in N stages, 2..8 (default 4; rect layout)
  --no-reveal            play the whole map from the first wave
  --width N --height N   window size (default 1440 x 900)
  --screenshot PATH      render one frame to a BMP and exit
  --assets DIR           Hex-Map-WFC assets directory (default third-party/Hex-Map-WFC/public/assets)
  --zoom N               start zoomed to N pixels per world unit (default: fit the map)
  --select COL,ROW       start with that cell selected (centered when --zoom is given)
  --bench N              time N still and N panning frames (ms), print, exit
  --slow N               pretend draws take N times longer (tests the quality adaptation)
  --classic              default SDL 2D renderer, CPU-expanded geometry (for comparison)
  --flat                 flat-shaded shapes instead of the Hex-Map-WFC models
  --bot                  let the scripted bot build and upgrade towers
  --ticks N              advance the game N ticks (30 per second) before the first frame
  --scene village|td     start in the village hub (default) or straight in tower defense
  --story PATH           story file for the village (default assets/story/village.json)
  --talk ID              open a conversation with villager ID at start (e.g. elder)
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
    cfg.params.reveal.enabled = true;
    int cells = 0, aw = 16, ah = 9;
    for (size_t i = 0; i < args.length; i++) {
        immutable a = args[i];
        if (a == "--help" || a == "-h")
            return R.err(CliError.help);
        if (a == "--no-reveal") {
            cfg.params.reveal.enabled = false;
            continue;
        }
        if (a == "--flat") {
            cfg.flat = true;
            continue;
        }
        if (a == "--classic") {
            cfg.classic = true;
            continue;
        }
        if (a == "--bot") {
            cfg.bot = true;
            continue;
        }
        if (a == "--no-roads") {
            cfg.params.routes.enabled = false;
            continue;
        }
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
        case "--ticks":
            if (!num())
                return R.err(CliError.badNumber);
            cfg.ticks = n;
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
        case "--sources":
            if (!num() || n > maxSources)
                return R.err(CliError.badNumber);
            cfg.params.routes.place.sources = n;
            break;
        case "--sinks":
            if (!num() || n > maxSinks)
                return R.err(CliError.badNumber);
            cfg.params.routes.place.sinks = n;
            break;
        case "--stages":
            if (!num() || n < 2 || n > maxStages)
                return R.err(CliError.badNumber);
            cfg.params.reveal.stages = n;
            break;
        case "--zoom":
            if (!num() || n < 1)
                return R.err(CliError.badNumber);
            cfg.zoom = n;
            break;
        case "--bench":
            if (!num() || n < 1)
                return R.err(CliError.badNumber);
            cfg.bench = n;
            break;
        case "--slow":
            if (!num() || n < 1)
                return R.err(CliError.badNumber);
            cfg.slow = n;
            break;
        case "--select":
            size_t comma = val.length;
            foreach (k, ch; val)
                if (ch == ',') {
                    comma = k;
                    break;
                }
            int col, row;
            if (comma >= val.length || !parseInt(val[0 .. comma], col)
                    || !parseInt(val[comma + 1 .. $], row) || col < 0 || row < 0)
                return R.err(CliError.badNumber);
            cfg.selCol = col;
            cfg.selRow = row;
            break;
        case "--scene":
            if (val == "village")
                cfg.village = true;
            else if (val == "td")
                cfg.village = false;
            else
                return R.err(CliError.badScene);
            break;
        case "--story":
            if (val.length + 1 > cfg.story.length)
                return R.err(CliError.pathTooLong);
            cfg.story[0 .. val.length] = val[];
            cfg.story[val.length] = 0;
            cfg.hasStory = val.length > 0;
            break;
        case "--talk":
            if (val.length + 1 > cfg.talk.length)
                return R.err(CliError.pathTooLong);
            cfg.talk[0 .. val.length] = val[];
            cfg.talk[val.length] = 0;
            cfg.hasTalk = val.length > 0;
            break;
        case "--assets":
            if (val.length + 1 > cfg.assets.length)
                return R.err(CliError.pathTooLong);
            cfg.assets[0 .. val.length] = val[];
            cfg.assets[val.length] = 0;
            cfg.hasAssets = val.length > 0;
            break;
        default:
            return R.err(CliError.unknownFlag);
        }
    }
    // The frame-time benchmark measures tower defense maps.
    if (cfg.bench > 0)
        cfg.village = false;
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
    const c = r.value;
    assert(c.params.layout == Layout.island && c.params.radius == 6 && c.params.rings == 1);
    assert(c.params.seed == 77 && c.width == 800 && c.hasScreenshot);
    assert(c.screenshot[0 .. 8] == "out.bmp\0");
}

@nogc nothrow @safe unittest {
    // Source and sink counts, range-checked; --no-roads takes no value.
    immutable string[5] a = ["--sources", "5", "--sinks", "3", "--no-roads"];
    auto r = parseArgs(a[]);
    assert(r.isOk && r.value.params.routes.place.sources == 5 && r.value.params.routes.place.sinks == 3);
    assert(!r.value.params.routes.enabled);
    immutable string[2] bad = ["--sinks", "-1"];
    assert(parseArgs(bad[]).error == CliError.badNumber);
    immutable string[2] big = ["--sources", "17"];
    assert(parseArgs(big[]).error == CliError.badNumber);
}

@nogc nothrow @safe unittest {
    // --flat takes no value; --assets does.
    immutable string[3] a = ["--flat", "--assets", "some/dir"];
    auto r = parseArgs(a[]);
    assert(r.isOk && r.value.flat && r.value.hasAssets && r.value.assets[0 .. 9] == "some/dir\0");
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

@nogc nothrow @safe unittest {
    // The viewer reveals the map in stages unless told not to.
    immutable string[2] a = ["--stages", "3"];
    auto r = parseArgs(a[]);
    assert(r.isOk && r.value.params.reveal.enabled && r.value.params.reveal.stages == 3);
    immutable string[1] off = ["--no-reveal"];
    assert(!parseArgs(off[]).value.params.reveal.enabled);
    immutable string[2] bad = ["--stages", "9"];
    assert(parseArgs(bad[]).error == CliError.badNumber);
}

@nogc nothrow @safe unittest {
    // The village is the default scene; --scene td boots straight into tower defense.
    immutable string[0] none;
    assert(parseArgs(none[]).value.village);
    immutable string[6] a = ["--scene", "td", "--story", "my/story.json", "--talk", "elder"];
    auto r = parseArgs(a[]);
    assert(r.isOk && !r.value.village && r.value.hasStory && r.value.story[0 .. 14] == "my/story.json\0");
    assert(r.value.hasTalk && r.value.talk[0 .. 6] == "elder\0");
    immutable string[2] bad = ["--scene", "moon"];
    assert(parseArgs(bad[]).error == CliError.badScene);
    immutable string[2] bench = ["--bench", "10"];
    assert(!parseArgs(bench[]).value.village);
}

// Microbenchmark: earthworks on a large battlefield. Each barricade rebuilds the creep distance
// field and checks every source still reaches a sink; raising ground refreshes the towers' range
// bonuses. Fails (exit 1) when the 95th-percentile edit exceeds its budget.
module benchmarks.bench_terraform;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import td.board;
import td.defs;
import td.game;
import wfc.map_session;

enum double budgetUs = 3000;

int main() @nogc nothrow {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 128;
    p.rows = 72;
    p.radius = 8;
    p.seed = 3;
    p.routes.place.sources = 4;
    p.routes.place.sinks = 2;
    p.reveal.enabled = false;
    if (!s.regenerate(p).isOk)
        return 1;
    Game g;
    g.start(*s, 5);
    g.startPlanning();
    enum int maxEdits = 400;
    static double[maxEdits] us;
    int n = 0, refused = 0;
    foreach (row; 0 .. g.board.rect.rows)
        foreach (col; 0 .. g.board.rect.cols) {
            if (n == maxEdits)
                break;
            immutable i = cast(size_t)row * g.board.rect.cols + col;
            immutable f = g.board.flagsAt(i);
            immutable op = (f & CellFlag.road) ? TerraOp.barricade : TerraOp.raise;
            if (op == TerraOp.raise && (n % 7 != 0 || !(f & CellFlag.buildable)))
                continue;
            if (op == TerraOp.barricade && (f & (CellFlag.source | CellFlag.sink)))
                continue;
            g.gold = 1_000_000;
            immutable t0 = MonoTime.currTime;
            immutable err = g.apply(GameCommand(CommandType.terraform, TowerKind.arrow, op, col, row));
            us[n++] = (MonoTime.currTime - t0).total!"nsecs" / 1000.0;
            refused += err != CommandError.none;
        }
    // Insertion sort is plenty for a few hundred samples.
    foreach (i; 1 .. n)
        for (int j = cast(int)i; j > 0 && us[j - 1] > us[j]; j--) {
            immutable t = us[j];
            us[j] = us[j - 1];
            us[j - 1] = t;
        }
    immutable p95 = us[n * 95 / 100];
    printf("terraform: %d edits on %d x %d (%d refused), p50 %.1f us, p95 %.1f us (budget %.0f us)\n",
            n, g.board.rect.cols, g.board.rect.rows, refused, us[n / 2], p95, budgetUs);
    return p95 <= budgetUs ? 0 : 1;
}

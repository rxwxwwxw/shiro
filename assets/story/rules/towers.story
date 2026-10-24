# Tower kinds: the rules a tower defense run is played by (read by src/story/catalog_load.d).
#
# A tower is a behavior (how it attacks: projectile, shell, shard, chain, cone, income) plus
# eleven stages: Lv1, Lv2, Lv3, then specializations A1..A4 and B1..B4 (the upgrade at Lv3
# picks a path; `branches: false` climbs path A only). Keys are the fields of TowerStats in
# src/td/defs.d; missing keys are 0 (targets, splashEdge and chainKeep default to 1, 100, 100).
# `look` names the built-in kind whose model a new kind borrows; `hp` is what it takes from siege
# creeps before it is wrecked (each level adds a quarter of it).
#
# Only four stages per kind are written out; `tower_line` grows the rest from them, the way the
# hand-tuned anchors always have.

data roman = ["", "", " II", " III", " IV", " V", " VI", " VII"]

def copy(m):
    r = {}
    for k in m:
        r[k] = m[k]
    return r

# v grown by p percent n times, rounding down each time.
def pct(v, p, n):
    x = v
    for i in range(n):
        x = floor(x * p / 100)
    return x

# `b` made stronger by `steps` levels: more damage, range and effect for more gold, renamed.
def grow(b, steps, name, blurb):
    if steps == 0:
        return b
    t = copy(b)
    t.name = name
    t.cost = pct(b.cost, 130, steps)
    t.range = pct(b.range, 104, steps)
    t.cooldown = pct(b.cooldown, 95, steps)
    if t.cooldown < 4 and b.cooldown > 0:
        t.cooldown = 4
    t.damage = pct(b.damage, 135, steps)
    t.splash = pct(b.splash, 104, steps)
    if b.slowPct:
        t.slowPct = min(b.slowPct + 3 * steps, 75)
    t.slowTicks = pct(b.slowTicks, 110, steps)
    if b.chains:
        t.chains = b.chains + steps
    t.burnDmg = pct(b.burnDmg, 135, steps)
    if b.targets > 1:
        t.targets = b.targets + floor(steps / 2)
    if b.pierce:
        t.pierce = min(b.pierce + 5 * steps, 90)
    if b.shred:
        t.shred = b.shred + 2 * steps
    if b.chillPct:
        t.chillPct = b.chillPct + 5 * steps
    if b.stunTicks:
        t.stunTicks = b.stunTicks + 5 * steps
    if b.bomblets:
        t.bomblets = b.bomblets + floor((steps + 1) / 2)
    t.patchTicks = pct(b.patchTicks, 115, steps)
    t.income = pct(b.income, 140, steps)
    t.blurb = blurb
    return t

# All eleven stages from [Lv1, Lv2, first of A, first of B].
def tower_line(a):
    s = [a[0], a[1], grow(a[1], 1, a[0].name + roman[3], a[1].blurb + ", stronger")]
    for br in range(2):
        first = a[2 + br]
        for i in range(4):
            append(s, grow(first, i, first.name + roman[1 + i], first.blurb + ", stronger"))
    return s

# A building without specializations: path A keeps growing from Lv2, path B stays empty.
def income_line(a):
    s = [a[0], a[1], grow(a[1], 1, a[0].name + roman[3], a[1].blurb + ", stronger")]
    for i in range(4):
        append(s, grow(a[1], 2 + i, a[0].name + roman[4 + i], a[1].blurb + ", stronger"))
    for i in range(4):
        append(s, {})
    return s

data towers = [
    # Arrow: cheap, fast, single target.
    {id: "arrow", hp: 220, behavior: :projectile, look: :arrow, stages: tower_line([
        {name: "Arrow", cost: 50, range: 2800, cooldown: 20, damage: 12, type: :physical, projSpeed: 320,
         blurb: "Fast single shots"},
        {name: "Arrow II", cost: 60, range: 3000, cooldown: 16, damage: 20, type: :physical, projSpeed: 340,
         blurb: "Faster, harder"},
        {name: "Longbow", cost: 140, range: 4600, cooldown: 24, damage: 64, type: :physical, projSpeed: 420,
         pierce: 60, blurb: "Huge range, pierces armor"},
        {name: "Volley", cost: 130, range: 3000, cooldown: 15, damage: 22, type: :physical, projSpeed: 340,
         targets: 3, blurb: "Three arrows at once"},
    ])},
    # Cannon: slow shells that splash.
    {id: "cannon", hp: 300, behavior: :shell, look: :cannon, stages: tower_line([
        {name: "Cannon", cost: 80, range: 2600, cooldown: 50, damage: 30, type: :physical, projSpeed: 110,
         splash: 900, splashEdge: 40, blurb: "Explosive splash"},
        {name: "Cannon II", cost: 90, range: 2700, cooldown: 48, damage: 50, type: :physical, projSpeed: 115,
         splash: 1100, splashEdge: 40, blurb: "Bigger blast"},
        {name: "Cluster", cost: 170, range: 2800, cooldown: 48, damage: 45, type: :physical, projSpeed: 115,
         splash: 1000, splashEdge: 40, bomblets: 4, blurb: "Scatters 4 bomblets"},
        {name: "Siege", cost: 190, range: 3100, cooldown: 72, damage: 150, type: :physical, projSpeed: 100,
         splash: 1500, splashEdge: 50, shred: 10, blurb: "Massive blast, shreds armor"},
    ])},
    # Frost: chilling shards that slow.
    {id: "frost", hp: 220, behavior: :shard, look: :frost, stages: tower_line([
        {name: "Frost", cost: 70, range: 2400, cooldown: 35, damage: 6, type: :magic, projSpeed: 220,
         splash: 700, slowPct: 35, slowTicks: 60, blurb: "Slows a small area"},
        {name: "Frost II", cost: 80, range: 2500, cooldown: 32, damage: 10, type: :magic, projSpeed: 230,
         splash: 800, slowPct: 45, slowTicks: 75, blurb: "Deeper slow"},
        {name: "Blizzard", cost: 160, range: 2600, cooldown: 45, damage: 8, type: :magic,
         slowPct: 55, slowTicks: 60, pulse: true, blurb: "Pulses: slows all in range"},
        {name: "Shatter", cost: 150, range: 2600, cooldown: 32, damage: 18, type: :magic, projSpeed: 240,
         splash: 900, slowPct: 40, slowTicks: 75, chillPct: 40, chillTicks: 90,
         blurb: "Chilled take +40% damage"},
    ])},
    # Tesla: instant chain lightning, ignores armor.
    {id: "tesla", hp: 240, behavior: :chain, look: :tesla, stages: tower_line([
        {name: "Tesla", cost: 100, range: 2600, cooldown: 40, damage: 22, type: :magic,
         chains: 2, chainRange: 1800, chainKeep: 85, blurb: "Chain lightning"},
        {name: "Tesla II", cost: 110, range: 2700, cooldown: 38, damage: 34, type: :magic,
         chains: 3, chainRange: 1900, chainKeep: 85, blurb: "Longer chains"},
        {name: "Storm", cost: 200, range: 2800, cooldown: 36, damage: 30, type: :magic,
         chains: 8, chainRange: 2200, chainKeep: 90, blurb: "Arcs through 9 creeps"},
        {name: "Overload", cost: 220, range: 3000, cooldown: 60, damage: 170, type: :magic,
         stunTicks: 30, blurb: "One huge bolt that stuns"},
    ])},
    # Flame: short-range cone that sets creeps alight.
    {id: "flame", hp: 260, behavior: :cone, look: :flame, stages: tower_line([
        {name: "Flame", cost: 90, range: 1900, cooldown: 12, damage: 4, type: :fire,
         burnDmg: 3, burnTicks: 60, coneCos: 70, blurb: "Burning cone"},
        {name: "Flame II", cost: 100, range: 2000, cooldown: 12, damage: 6, type: :fire,
         burnDmg: 5, burnTicks: 60, coneCos: 70, blurb: "Hotter flames"},
        {name: "Inferno", cost: 190, range: 2300, cooldown: 10, damage: 7, type: :fire,
         burnDmg: 7, burnTicks: 120, coneCos: 45, blurb: "Wide cone, long burn"},
        {name: "Napalm", cost: 180, range: 2100, cooldown: 12, damage: 6, type: :fire, splash: 750,
         burnDmg: 5, burnTicks: 60, coneCos: 70, patchTicks: 150, blurb: "Leaves burning ground"},
    ])},
    # Mine: gold income per cleared wave, only on gold veins.
    {id: "mine", hp: 160, behavior: :income, look: :mine, vein: true, branches: false, stages: income_line([
        {name: "Mine", cost: 120, income: 25, blurb: "+25 gold per wave"},
        {name: "Mine II", cost: 150, income: 60, blurb: "+60 gold per wave"},
    ])},
]

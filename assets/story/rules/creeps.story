# Creep kinds and how waves are made of them (read by src/story/catalog_load.d).
#
# `stats` are the fields of CreepStats in src/td/defs.d: hp (wave 1; it compounds per wave, see
# economy.hpGrowthPct), speed (step progress per tick, 1024 = one cell), armor (percent of physical
# damage blocked), bounty (gold), leak (lives lost at a sink), cost (wave budget points), gap
# (ticks before the next spawn) and slowResist (percent of slows and stuns shrugged off).
# A wave picks kinds unlocked by its number by `pickWeight`, in runs of `pack` (0: 1 to 3);
# a `boss` comes alone every economy.bossEvery waves.
# Siege creeps (siegeDamage) strike the nearest tower within siegeRange every siegeCooldown ticks
# as they walk; a wrecked tower stops firing, and its crew may be hurt.

data creeps = [
    {id: "grunt", look: :grunt, unlockWave: 1, pickWeight: 5,
     stats: {name: "Grunt", hp: 60, speed: 34, bounty: 5, leak: 1, cost: 10, gap: 18}},
    {id: "runner", look: :runner, unlockWave: 3, pickWeight: 3,
     stats: {name: "Runner", hp: 35, speed: 62, bounty: 5, leak: 1, cost: 10, gap: 12}},
    {id: "brute", look: :brute, unlockWave: 6, pickWeight: 2,
     stats: {name: "Brute", hp: 200, speed: 22, armor: 45, bounty: 10, leak: 2, cost: 30, gap: 30, slowResist: 20}},
    {id: "swarm", look: :swarm, unlockWave: 4, pickWeight: 2, pack: 5,
     stats: {name: "Swarmling", hp: 18, speed: 44, bounty: 1, leak: 1, cost: 3, gap: 6}},
    {id: "boss", look: :boss, boss: true,
     stats: {name: "Boss", hp: 1500, speed: 16, armor: 30, bounty: 150, leak: 5, gap: 60, slowResist: 50}},
    {id: "sapper", look: :runner, unlockWave: 7, pickWeight: 1,
     stats: {name: "Sapper", hp: 45, speed: 40, armor: 10, bounty: 8, leak: 1, cost: 15, gap: 20,
             siegeDamage: 6, siegeRange: 1300, siegeCooldown: 60}},
    {id: "ram", look: :brute, unlockWave: 11, pickWeight: 1,
     stats: {name: "Battering ram", hp: 320, speed: 18, armor: 55, bounty: 20, leak: 2, cost: 45, gap: 40,
             slowResist: 60, siegeDamage: 20, siegeRange: 1100, siegeCooldown: 120}},
]

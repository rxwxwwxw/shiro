# Run-wide numbers (the fields of Economy in src/td/catalog.d). Durations are ticks (30 a second).

data economy = {
    startGold: 300, startLives: 20, totalWaves: 30,
    firstWaveDelay: 900, waveBreak: 450,
    sellPercent: 70,
    clearBase: 30, clearPerWave: 3,
    leyDamagePct: 25, highGroundPctPerLevel: 12, highGroundCapPct: 36,
    hpGrowthPct: 111,
    budgetBase: 60, budgetLinear: 25, budgetQuad: 2, bossEvery: 10,
}

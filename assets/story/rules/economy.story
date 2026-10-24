# Run-wide numbers (the fields of Economy in src/td/catalog.d). Durations are ticks (30 a second).

data economy = {
    startGold: 300, startLives: 20, totalWaves: 30,
    firstWaveDelay: 900, waveBreak: 450,
    sellPercent: 70,
    clearBase: 30, clearPerWave: 3,
    leyDamagePct: 25, highGroundPctPerLevel: 12, highGroundCapPct: 36,
    hpGrowthPct: 111,
    budgetBase: 60, budgetLinear: 25, budgetQuad: 2, bossEvery: 10,
    # Percent chance a crew is hurt when their tower drops below half, and when it is wrecked;
    # repairs cost this percent of the tower's worth, in proportion to the damage.
    injuryAtHalfPct: 20, injuryAtWreckPct: 60, repairPct: 50,
}

# Story language (`.story`)

Story content lives in `assets/story/`. The game compiles `main.story` (or `--story PATH`) and
everything it imports at startup; errors and warnings print as `file:line:col: message`.

Code: grammar `src/story/syntax.d` (npegged, generated at compile time), compiler
`src/story/compile.d`, runner `src/story/vm.d`, values `src/story/value.d`, state `src/story/state.d`.

## Files and blocks

- One statement per line; indentation (spaces, tab = 4) makes blocks, like Python.
- `# comment` lines are ignored. Trailing `# ...` works on statement lines, **not** on text lines
  (text runs to end of line).
- `import "other.story"` (top level, path relative to the importing file). Each file loads once.

## Declarations (top level)

```
type Bond:                                  # a record type
    affection = 50 in 0..100                # field: default, optional clamp range
    trust = 50 in 0..100
    disposition => (affection + trust) / 2  # derived, read-only, computed on read

character elder "Bà Lan":                   # speaker; portrait/figure default to the id
    portrait elder
    figure elder
    sprite 1
    home plaza wander 2                     # lives in the village
    mood = 0 in -10..10                     # fields: elder.mood
    bond: Bond                              # nested record: elder.bond.trust

place smithy "Chú Tư's Forge":              # building interior (landmark id)
    image smithy
    host smith
    look: Heat rolls off the coals.
    ware "Iron caltrops" 12 -> has_caltrops: Scatter them on the road.
    topic "What are you forging?": Arrowheads, mostly.

var coins = 40                              # starting value (run on every new game)
var town: Town                              # a record variable
```

`elder.name` reads the display name.

## Triggers

```
on start once -> intro
on talk elder if not met_elder -> elder_hi
on enter temple once:                       # inline body instead of a label
    Copal smoke curls up the stepped stones.
on return won:                              # return takes won / lost / nothing (either)
    clear elder_heard
    -> return_won
```

Kinds: `start`, `talk <character>`, `enter <zone>`, `return [won|lost]`. The first matching
trigger in file order (imports inlined where they appear) fires.

## Scenes

```
label elder_hi:
    elder (worried): Ah, you came, {player_name}.   # speaker line; (mood) picks the portrait
    Morning mist lifts off the terraces.          # narration
    : lower-case narration needs a leading colon
.ask:                                             # local label elder_hi.ask (any indent)
    elder: Will you hold the west road?           # a line followed by choices shows them
    * I will hold it.
        set gate_open
        -> open_gate
    * What is out there?  if not asked_west       # condition: ` if <expr>` at end of line
        set asked_west
        -> .ask
    * "Quoted {caption}" if coins > 5
    if elder.bond.trust >= 60:
        elder: I trust you.
    elif td_runs > 2:
        elder: Again, then.
    else:
        call blessing                             # call/return
```

Statements: `-> label` / `jump label` (`.sub` = local), `call label`, `return` (ends the
conversation when nothing called), `end`, `set x`, `set x = e`, `clear x`, `x = e`,
`x += e` (`-= *= /= %=`), `event name [number]`, `show who [mood]`, `hide who`, `scene name`,
`play music|sound "path"`, `stop music|sound`, `battle [name]`. Presentation commands and events
reach the controller as `StoryEvent`s. A label falls off its end as `return`.

A lower-case first word must be a statement or a speaker, so typos are errors, not narration.

## Values and expressions

nil, booleans, numbers (IEEE doubles), strings. nil acts as 0 / false / "". Records are static:
`elder.bond.trust` is one variable slot, resolved at compile time.

- `or and not` (also `!`), `== != < <= > >=`, `+ - * / %` (floored modulo), unary `-`, parens.
- `+` joins when either side is a string. Strings compare by content, everything else as numbers.
- Built-ins: `min max abs floor ceil round clamp(x, lo, hi) len str rand() rand(n) rand(a, b)`
  (`rand` uses the seeded story RNG).
- `"..."` strings take `\n \t \" \\`; `{expr}` interpolates in strings and in text lines;
  `{{` / `}}` are literal braces.
- Plain names are created on first use. Reading a name nothing ever sets is a warning.

## Lists, maps and loops

```
citizens = [{"name": "Ada", "health": {"food": 5}}, {name: "Bo", health: {food: 8}}]
for citizen in citizens:                  # list elements; maps iterate their keys in order
    citizen.health.food -= 1              # `.key` reads/writes map entries
    Checking {citizen.name} ({citizen.health["food"]})
xs = []
append(xs, 3)                             # a call on its own line runs for its effect
xs[-1] += 1                               # negative indexes count from the end
remove(stats, "z")
for i in range(3):                        # range(n) / range(a, b)
    total += i
```

- Lists and maps are references: `alias = citizens[0]` shares the same map.
- Map keys are strings (`{name: 1}` and `{"name": 1}` are the same); keys keep insertion order.
- Reading a missing index or key gives nil; assigning a new map key adds it, a list index
  must already exist (use `append`).
- Built-ins: `len append remove keys has range`. A collection is always true; test `len(xs) > 0`.
- Collections display as `[1, two]` / `{a: 1}`. Unreachable ones are reclaimed between statements.
- `.name` on a record (character, `type`) is a static field; on any other variable it is a map key.

## Diagnostics

Errors: syntax, unknown label / speaker / field / type, assigning a derived or read-only field,
too many choices (6), bad ranges. Warnings: labels never used, variables read but never set
(variables the game interns before compiling, like `td_result`, count as set).

## Not carried over from the old `src/script` interpreter

Translation ids, the `.tebc` bytecode cache, video playback,
hard-coded relationship rules (use bounded fields and `=>` derived fields instead).

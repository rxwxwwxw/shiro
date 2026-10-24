# Villagers on the towers (read by src/campaign/crews.d).
#
# Before each battle, and on the battlefield midweek, the game asks `crew_buff(npc, tower)` what a
# villager adds to the tower they man: percent changes to damage, range and reload time (cooldown;
# negative is faster). The closer you are to someone, the harder they fight for you; a knack for
# a kind of tower adds to it. `can_crew(npc)` says who may serve at all.

# How close each villager is to you, 0..100.
var bonds = {elder: 50, priestess: 40, smith: 45, child: 25, guard: 55}

# Knacks: tower kinds a villager is good with, and how good (1..3).
data skills = {
    elder: {frost: 1},
    priestess: {tesla: 2},
    smith: {cannon: 2, flame: 1},
    child: {arrow: 1},
    guard: {arrow: 2, cannon: 1},
}

# A tower nobody mans fires late and wide.
data crew_rules = {unmanned: {damage: -25, cooldown: 20}}

# Villagers who cannot serve: the week they are back on their feet.
var away = {}

def crew_buff(npc, tower):
    b = bonds[npc]
    knack = skills[npc][tower]
    # A stranger barely helps; a friend makes the tower sing.
    return {damage: floor((b - 20) / 3) + 8 * knack, range: floor(b / 25) + 2 * knack, cooldown: -floor(b / 10) - 3 * knack}

def can_crew(npc):
    return not (away[npc] and away[npc] > week)

# Hurt on the walls: out for the next week, and a little shaken in their trust.
def on_injury(npc):
    away[npc] = week + 2
    befriend(npc, -10)

def befriend(npc, amount):
    bonds[npc] = clamp(bonds[npc] + amount, 0, 100)

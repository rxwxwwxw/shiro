# The week loop (read by src/campaign/campaign.d).
#
# Each day has six slots: dawn, morning, midday, afternoon, evening, night. Important actions
# spend slots; talking and shopping are free unless a scene says `spend N`. Saturday afternoon
# the attack comes; Wednesday night the enemy sizes up your defenses.

data campaign = {weeks: 6, wavesPerBattle: 5}

# Slots each action costs.
data actions = {
    rest: 1,
    field: 1,
    dig: 1,
}

on day mon:
    : A new week begins in Làng Sương. Week {week}.

on day sat:
    : Saturday. Drums from the west road: the attack comes this afternoon.

on slot night if today == :wed:
    : Wednesday night. Out on the west road, something counts your towers.

# Chú Tư at the forge: fire pots or coin, and a bonus after a win.

on talk smith if td_result == 1 and not smith_bonus -> smith_won
on talk smith if not smith_done -> smith_hi
on talk smith -> smith_after

label smith_hi:
    smith: Hah! Going to fight them with your bare hands? Let me help, I owe the elder that much.
    smith: I have fire pots, if you like things burning. Or I give you coin from the forge, and you buy what you need.
    * Fire pots.
        set unlock_flame
        set smith_done
        smith (happy): Good choice. Flame towers will be yours to build. Stand back when they go off.
    * The coin.
        td_gold += 60
        set smith_done
        smith (happy): Sixty silver. Spend it on stone and arrows, not on rice wine.
    * I am just looking.
        smith: Look all you like, the anvil does not bite.

label smith_after:
    smith: The forge stays hot. Bring me back something interesting.

label smith_won:
    td_gold += 20
    set smith_bonus
    smith (happy): You came back in one piece! Here, a little more coin for the next road.

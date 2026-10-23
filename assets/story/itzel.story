# Itzel keeps the temple: one favor of the old gods (lightning or mist), and one more after a loss.

on talk priestess if td_result == 2 and not itzel_second -> itzel_lost
on talk priestess if not itzel_done -> itzel_hi
on talk priestess -> itzel_after
on enter temple once:
    Copal smoke curls up the temple's stepped stones. Carved serpents watch the road from every ledge.

label itzel_hi:
    priestess: The smoke turned west at dawn. The Feathered Serpent sees what is coming; it always has.
    priestess: I can ask one favor of the old gods for you. Which do you want?
    * The serpent's lightning.
        set unlock_tesla
        set itzel_done
        -> itzel_storm
    * Mist to weaken them.
        td_hp_pct -= 15
        set itzel_done
        -> itzel_mist
    * I will come back.
        priestess: The gods are patient. I am not so patient, but I can wait.

label itzel_lost:
    priestess (worried): The gods heard you fall. I can ask once more, but it costs: they will not give their mist and their lightning twice to the same hands.
    * Ask anyway.  if not unlock_tesla
        set unlock_tesla
        set itzel_second
        -> itzel_storm
    * Ask for more mist.  if td_hp_pct > -15
        td_hp_pct -= 15
        set itzel_second
        -> itzel_mist
    * Keep your offering.
        -> itzel_after

label itzel_storm:
    priestess (happy): Then the sky will answer you. Look for the storm towers when you build.

label itzel_mist:
    priestess (happy): The mist will follow them and drink their strength. They will come at you weaker.

label itzel_after:
    priestess: I keep the copal burning for you. Go carefully.

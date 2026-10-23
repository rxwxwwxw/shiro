# Arrivals: the first morning, and every walk home from the west road.

on start once -> intro

on return won:
    clear elder_heard
    clear child_heard
    -> return_won

on return lost:
    clear elder_heard
    clear child_heard
    -> return_lost

label intro:
    Morning mist lifts off the rice terraces of Làng Sương. Drums sound from the đình hall: the river road to the west has gone quiet, and quiet roads are never good news.
    Bà Lan, the village elder, waits for you in the plaza. (WASD to walk, E to talk.)

label return_won:
    The gate creaks shut behind you. Lanterns are already being lit along the road, and someone has started the drums.

label return_lost:
    You limp back through the gate. Smoke rises from the lower terraces, but the village still stands.

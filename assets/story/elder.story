# Bà Lan, the village elder: she opens the west gate.

on talk elder if not met_elder -> elder_hi
on talk elder if td_result == 1 and not elder_heard -> elder_won
on talk elder if td_result == 2 and not elder_heard -> elder_lost
on talk elder if not gate_open -> elder_ready
on talk elder -> elder_go

label elder_hi:
    set met_elder
    elder (worried): Ah, you came. Sit, child. The scouts have not come back from the river road.
    elder: Something walks out of the jungle at night. It tramples the paddies and it does not stop at fences.
.ask:
    elder: Will you hold the west road for us?
    * I will hold it.
        -> open_gate
    * What is out there?  if not asked_west
        set asked_west
        elder (worried): Our grandmothers called them the hungry ones. Builders of nothing, eaters of everything. They follow the old roads, so towers on the roads will stop them.
        -> .ask
    * Let me prepare first.
        elder: Wise. Itzel keeps the temple to the east, and Chú Tư's forge is by the road. Come back when you are ready.

label elder_ready:
    elder: Are you ready to go west?
    * Open the gate.
        -> open_gate
    * Not yet.

label open_gate:
    set gate_open
    event gate_open
    elder (happy): Then go with the ancestors. I will tell the guard to open the gate. Do not let them reach the village.

label elder_go:
    elder: The gate is open. If you have not seen Itzel and Chú Tư, do so. Their gifts may save you.

label elder_won:
    set elder_heard
    elder (happy): The drums are playing for you tonight. The river road is ours again, for now.
    * They will come back.
        elder (worried): They always do. Rest, then hold the road again when the gate drums call.
    * I am tired, bà.
        elder (happy): Then rest. There is rice and fish in the hall, and no one will ask anything of you until morning.

label elder_lost:
    set elder_heard
    elder (worried): They broke through the lower terraces. We lost the harvest there, but no one was hurt. You are alive; that matters more.
    elder: Go back when you are ready. Talk to Itzel: the temple may lend you more strength.

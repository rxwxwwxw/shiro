# Ngọc, who wants a hungry one's tooth.

on talk child if td_result == 1 and not child_heard -> child_won
on talk child if td_result == 2 and not child_heard -> child_lost
on talk child if td_runs == 0 and not child_met:
    set child_met
    -> child_hi
on talk child -> child_after

label child_hi:
    child: Are you going out the west gate? Mama says nobody goes out the west gate.
    * I am. Someone has to.
        child (happy): Bring me back a hungry one's tooth! I will keep it under my mat.
    * Only if Bà Lan says so.
        child: Bà Lan says so about everything.

label child_after:
    child: I am practicing with my slingshot. For when they come.

label child_won:
    set child_heard
    child (happy): You did it! You did it! I told everyone you would!

label child_lost:
    set child_heard
    child (worried): Are they coming here now? I hid my slingshot under the house, in case.

# The gate guard keeps the west gate shut until the elder sends word.

on talk guard if not gate_open -> guard_wait
on talk guard -> guard_go
on enter gate_locked -> guard_shut

label guard_wait:
    guard: No one goes out this gate without Bà Lan's word. Not with what is on the road.

label guard_shut:
    guard (worried): Hold on! The gate stays shut until the elder sends you.

label guard_go:
    guard (happy): Bà Lan sent word. The gate is open: walk west when you are ready. I will keep the lanterns lit for you.

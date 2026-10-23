# Building interiors: what the player finds on stepping inside. Wares cost `coins` and set their
# flag once bought, so scenes can test what the player owns.

place smithy "Chú Tư's Forge":
    image smithy
    host smith
    look: Heat rolls off the coals. Hammers, tongs and half-finished blades hang from the rafters, and the anvil still rings faintly.
    ware "Iron caltrops" 12 -> has_caltrops: Scatter them on the road; the hungry ones limp.
    ware "Whetstone" 6 -> has_whetstone: Keeps a tower's bolts keen.
    ware "Bronze bell" 25 -> has_bell: Rung at the gate, it rallies the village.
    topic "What are you forging?": Arrowheads, mostly. The towers eat them faster than rice.
    topic "Where does the iron come from?": River sand, washed and smelted. Hard work, honest iron.
    topic "Any advice for the road?": Build where the road bends. Creeps slow on the turns.

place temple "Temple of the Jade Mist":
    image temple
    host priestess
    look: Incense curls past red lacquer pillars. Offerings of fruit and rice sit before a calm stone face.
    ware "Incense bundle" 5 -> has_incense: Burn it before a run for the ancestors' favor.
    ware "Jade charm" 20 -> has_charm: Cool to the touch. Said to turn aside misfortune.
    topic "Who do you pray to?": To the mist, to the river, and to everyone who stood here before us.
    topic "Are the hungry ones spirits?": No. Spirits remember. These only want.

place home "Ngọc's Family Home":
    image home
    host child
    look: A low hearth, sleeping mats rolled against the wall, and a wooden buffalo toy left in the middle of the floor.
    ware "Rice cakes" 2 -> has_ricecake: Ngọc's mother insists. They are very good.
    topic "Where are your parents?": In the paddies! They come home when the frogs start singing.
    topic "Is that your buffalo?": His name is Mập. He is the bravest buffalo in Làng Sương.

place hall "The Đình Hall":
    image hall
    host elder
    look: The communal hall. Carved dragons coil along the beams over the long council tables.
    topic "What is this hall for?": Councils, festivals, and arguments about water. Mostly arguments about water.
    topic "Who carved the dragons?": My grandfather's grandfather. He said they keep the roof dry.

place market "Covered Market":
    image market
    look: Stalls stand shuttered; baskets are stacked and covered. Everyone is at the walls or in the fields today.

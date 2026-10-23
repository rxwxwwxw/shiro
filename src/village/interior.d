// Building interiors: what the player finds on stepping inside a landmark building (a title, a
// backdrop image name, a description, who keeps the place, wares for sale, things to ask about),
// read from the story's `place` declarations. Strings are slices of the compiled program, which
// must outlive the table. Purchases spend the story variable "coins" and set the ware's flag, so the
// story's conditions can see what the player owns. Model layer: no SDL, @nogc nothrow.
module village.interior;

import story.program : StoryError, StoryProgram;
import story.state;
import village.plan : Landmark, landmarkByName, numLandmarks;

enum int maxWares = 6;
enum int maxTopics = 6;
/// Story variable holding the player's money.
enum string varCoins = "coins";

struct Ware {
    const(char)[] name, desc;
    int price;
    /// Story flag set once bought.
    int flag = -1;
}

struct Topic {
    const(char)[] ask, answer;
}

struct Interior {
    bool present;
    const(char)[] title, image, look;
    /// Speaker who keeps the place, or -1 for an empty building.
    int host = -1;
    Ware[maxWares] wares;
    int numWares;
    Topic[maxTopics] topics;
    int numTopics;

    const(Ware)[] wareList() const return @nogc nothrow pure @safe {
        return wares[0 .. numWares];
    }

    const(Topic)[] topicList() const return @nogc nothrow pure @safe {
        return topics[0 .. numTopics];
    }
}

enum BuyResult : ubyte {
    none,
    bought,
    tooPoor,
    owned
}

struct Interiors {
    Interior[numLandmarks] at;
    int coinsVar = -1;

    /// The interior of landmark `l`, or null when it has none.
    const(Interior)* of(int l) const return @nogc nothrow pure @safe {
        return l >= 0 && l < numLandmarks && at[l].present ? &at[l] : null;
    }

    /// Copies the story's places, interning the coins variable into `st` (its starting value
    /// comes from the story's `var coins = ...`). Returns the number of interiors, or -1 when a
    /// place is not a village landmark.
    int load(ref const StoryProgram db, ref StoryState st) @nogc nothrow @trusted {
        at[] = Interior.init;
        coinsVar = st.intern(varCoins);
        foreach (ref pl; db.places) {
            immutable l = landmarkByName(pl.id);
            if (l < 0)
                return -1;
            auto it = &at[l];
            it.present = true;
            it.title = pl.title;
            it.image = pl.image;
            it.look = pl.look;
            it.host = pl.host;
            foreach (ref w; db.wares(pl))
                if (it.numWares < maxWares)
                    it.wares[it.numWares++] = Ware(w.name, w.desc, w.price, w.flag);
            foreach (ref t; db.topics(pl))
                if (it.numTopics < maxTopics)
                    it.topics[it.numTopics++] = Topic(t.ask, t.answer);
        }
        return cast(int)db.places.length;
    }

    /// Buys ware `index` of landmark `l`'s interior.
    BuyResult buy(int l, int index, ref StoryState st) const @nogc nothrow @safe {
        const it = of(l);
        if (it is null || index < 0 || index >= it.numWares || coinsVar < 0)
            return BuyResult.none;
        const w = &it.wares[index];
        if (w.flag >= 0 && st.flag(w.flag))
            return BuyResult.owned;
        if (st.get(coinsVar) < w.price)
            return BuyResult.tooPoor;
        st.add(coinsVar, -w.price);
        if (w.flag >= 0)
            st.set(w.flag, 1);
        return BuyResult.bought;
    }
}

@nogc nothrow unittest {
    import story.compile : compileText;
    import story.vm : initialize;

    immutable text = `
character smith "Smith"
var coins = 10
place smithy "Forge":
    image smithy
    host smith
    look: Hot.
    ware "Nails" 4 -> has_nails: Sharp.
    ware "Anvil" 50 -> has_anvil: Heavy.
    topic "Work?": Always.
place hall "Hall":
    look: Empty.
`;
    StoryState st;
    StoryProgram db;
    assert(compileText(db, st, text) == StoryError.none);
    initialize(db, st);
    Interiors ins;
    assert(ins.load(db, st) == 2);
    const f = ins.of(Landmark.smithy);
    assert(f !is null && f.title == "Forge" && f.host == 0 && f.numWares == 2 && f.topics[0].answer == "Always.");
    assert(ins.of(Landmark.hall).host == -1 && ins.of(Landmark.market) is null);
    assert(st.named(varCoins) == 10);
    assert(ins.buy(Landmark.smithy, 1, st) == BuyResult.tooPoor);
    assert(ins.buy(Landmark.smithy, 0, st) == BuyResult.bought && st.named(varCoins) == 6);
    assert(st.named("has_nails") == 1 && ins.buy(Landmark.smithy, 0, st) == BuyResult.owned);
    assert(ins.buy(Landmark.hall, 0, st) == BuyResult.none);

    StoryProgram moon;
    assert(compileText(moon, st, "place moon:\n    look: Far.\n") == StoryError.none);
    Interiors bad;
    assert(bad.load(moon, st) == -1);
}

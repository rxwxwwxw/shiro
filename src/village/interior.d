// Building interiors: what the player finds on stepping inside a landmark building (a title, a
// backdrop image name, a description, who keeps the place, wares for sale, things to ask about),
// read from the story file's "interiors" list. Strings are slices of the story text, which must
// outlive the table. Purchases spend the story variable "coins" and set the ware's flag, so the
// story's conditions can see what the player owns. Model layer: no SDL, @nogc nothrow.
module village.interior;

import core.json;
import story.dialogue : DialogueDb;
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

    /// Reads "interiors" and "coins" (starting money) from the story file, interning ware flags
    /// and the coins variable into `st`. Returns the number of interiors, or -1 on an unknown
    /// place or host.
    int load(const(char)[] storyJson, ref const DialogueDb db, ref StoryState st) @nogc nothrow @trusted {
        at[] = Interior.init;
        Json j;
        if (!j.parse(storyJson))
            return -1;
        coinsVar = st.intern(varCoins);
        immutable start = j.get(0, "coins");
        if (start >= 0)
            st.set(coinsVar, j.integer(start));
        immutable list = j.get(0, "interiors");
        foreach (i; 0 .. j.length(list)) {
            immutable o = j.at(list, i);
            immutable l = landmarkByName(j.str(j.get(o, "place")));
            if (l < 0)
                return -1;
            auto it = &at[l];
            it.present = true;
            it.title = j.str(j.get(o, "title"));
            it.image = j.str(j.get(o, "image"));
            it.look = j.str(j.get(o, "look"));
            immutable h = j.get(o, "host");
            if (h >= 0) {
                it.host = db.findSpeaker(j.str(h));
                if (it.host < 0)
                    return -1;
            }
            immutable wares = j.get(o, "wares");
            foreach (k; 0 .. j.length(wares)) {
                if (it.numWares == maxWares)
                    break;
                immutable w = j.at(wares, k);
                auto ware = &it.wares[it.numWares++];
                ware.name = j.str(j.get(w, "name"));
                ware.desc = j.str(j.get(w, "desc"));
                ware.price = j.integer(j.get(w, "price"));
                ware.flag = st.intern(j.str(j.get(w, "flag")));
            }
            immutable topics = j.get(o, "topics");
            foreach (k; 0 .. j.length(topics)) {
                if (it.numTopics == maxTopics)
                    break;
                immutable t = j.at(topics, k);
                it.topics[it.numTopics++] = Topic(j.str(j.get(t, "ask")), j.str(j.get(t, "answer")));
            }
        }
        return j.length(list);
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
    immutable text = `{
      "speakers": [{"id": "smith", "name": "Smith"}],
      "nodes": [{"id": "a", "text": "hi"}],
      "coins": 10,
      "interiors": [
        {"place": "smithy", "title": "Forge", "image": "smithy", "look": "Hot.", "host": "smith",
         "wares": [{"name": "Nails", "desc": "Sharp.", "price": 4, "flag": "has_nails"},
                   {"name": "Anvil", "price": 50, "flag": "has_anvil"}],
         "topics": [{"ask": "Work?", "answer": "Always."}]},
        {"place": "hall", "title": "Hall", "look": "Empty."}
      ]
    }`;
    StoryState st;
    DialogueDb db;
    assert(db.load(text, st) == 0);
    Interiors ins;
    assert(ins.load(text, db, st) == 2);
    const f = ins.of(Landmark.smithy);
    assert(f !is null && f.title == "Forge" && f.host == 0 && f.numWares == 2 && f.topics[0].answer == "Always.");
    assert(ins.of(Landmark.hall).host == -1 && ins.of(Landmark.market) is null);
    assert(st.named(varCoins) == 10);
    assert(ins.buy(Landmark.smithy, 1, st) == BuyResult.tooPoor);
    assert(ins.buy(Landmark.smithy, 0, st) == BuyResult.bought && st.named(varCoins) == 6);
    assert(st.named("has_nails") == 1 && ins.buy(Landmark.smithy, 0, st) == BuyResult.owned);
    assert(ins.buy(Landmark.hall, 0, st) == BuyResult.none);

    Interiors bad;
    assert(bad.load(`{"interiors": [{"place": "moon"}]}`, db, st) == -1);
}

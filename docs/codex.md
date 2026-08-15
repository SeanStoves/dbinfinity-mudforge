# DB Infinity Codex

A searchable record of the mobs and items you have met, built entirely out of
what the MUD says in passing. Nothing here is typed in by hand: walk into a
room, scan something, run `analyze` on a piece of gear, or look at a shop's
stock, and it is recorded.

- Mobs by area, name and power level, with the rooms they were found in
- Items with every field `analyze` printed, including labels nothing has a rule
  for yet
- Where an item came from: area, then what dropped it, then the rooms
- Shop stock, off `list`, without buying anything
- Auction prices — what players actually paid, not what a shopkeeper asks
- A search box over all of it, and a query channel other plugins can use

## What counts as a record

**A power level is what makes a mob worth keeping.** Walking past something
records a sighting so the panel can offer you a `[scan]` link beside its name,
and that sighting lasts exactly as long as you stand in the room with it. Leave
without scanning and it is forgotten. Otherwise every corridor ever walked
leaves a row behind and the panel fills with things nobody asked about.

Scan it and it becomes a record, with the room it was read in, and it stays.

**A mob is area + name + power level.** That matters more than it sounds: "An
elite warrior" stands in a dozen rooms of one area and they are not all the same
power, so scanning one says nothing about the others. Each room is worth its own
reading, and two readings at two powers are two records, correctly.

Rooms are stored as vnums rather than names. The map's name for a room has come
back damaged from upstream before, and a number does not rot — anything that
wants a name can ask the mapper for one.

## Commands

```
dbdex                    show the panel
dbdex hide
dbdex mobs | items       switch the list
dbdex here | all         this area, or everywhere
dbdex find <text>        filter; searches names, areas and every item field
dbdex clear              drop the filter
dbdex sales [name]       auction prices, dearest average first
dbdex link on|off        the [[scan]] link beside an unread mob's name
dbdex forget             drop everything
dbdex diag               what it thinks it knows, entry by entry
```

## The panel

Two tabs, mobs and items. The header says what you are looking at — an area
name, `All`, or the text you searched for.

Clicking a mob's room walks you there. Clicking an item opens its detail: every
named field, then everything else `analyze` printed under **also**, then
**found on** as a tree (area, then what dropped it, then the rooms) which stays
shut until you ask for it, then the block exactly as the MUD wrote it.

The list paginates to whatever height you have dragged the panel to.

## Reading a mob's line in the scroll

A mob you have already read gets its power level put on the end of its line as
it scrolls past, in the MUD's own colours. One you have not gets a clickable
`[scan]` instead, offered once per mob per room so a corridor of nine elite
warriors does not print nine invitations.

`dbdex link off` turns the rewriting off; the panel keeps its own button.

## Auction prices

The auction channel calls a settled price:

```
Auction: [TCG] Thirteen Booster Pack [DBI] sold to Zodion for 25,000.
```

That becomes price, buyer and timestamp against the item, up to forty deep, and
the detail screen grows a **sold at auction for** section with the low, high and
average. Bids and going-once calls are ignored on purpose — only a sale is a
price.

## Asking from another plugin

Codex answers a REST-shaped envelope over the event bus, so another plugin can
ask questions without knowing how any of this is stored.

```lua
emit("dbi.request", {
    id     = "whatever",
    to     = "codex",
    method = "GET",
    path   = "/mobs",
    query  = { q = "elite", area = "The Ginyu Base" },
    reply  = "myplugin.reply",
})

on("myplugin.reply", function(res)
    -- { id, from = "codex", status = 200, body = <the route's answer> }
end)
```

| method | path | query | body |
|---|---|---|---|
| GET | `/mobs` | `q`, `area` | matching mob records |
| GET | `/mobs/<name>` | — | a list; a name is not unique |
| GET | `/items` | `q` | matching item records |
| GET | `/items/<name>` | — | one item |
| GET | `/sales` | `q` | name, count, min, max, avg per item |
| GET | `/sales/<name>` | — | the item, with its price history |
| GET | `/areas` | — | `{ area, mobs }` per area |
| GET | `/stats` | — | counts and version |

Everything handed back is a copy. The records inside are live and edited in
place, so a caller holding one would watch it change underneath them.

To be told as things are learned rather than asking:

```lua
on("dbi-codex.learned", function(e)
    -- e.kind == "mob"  -> e.mob
    -- e.kind == "item" -> e.item
end)
```

That fires when something is **learned**, not on every sighting — walking past
the same mob nine times is not nine events.

## Storage

Everything is written and flushed on every change rather than on a timer. What
this records is learned once and not repeated — a scan reading, an analyze
block, a shop's stock — so the next chance to write it may be an hour away or
never, and a client closed outright runs no shutdown hook at all.

The store is global rather than per character: a MUD's mobs are the same for
every alt.

## If you install this twice

Two copies of one plugin share a storage namespace, both run their own line
readers, and both draw into a widget whose id they also share. That has cost
this plugin a data loss already. Check your plugins folder for a second file
before concluding anything else is wrong; a banner printing twice on load is
the other tell.

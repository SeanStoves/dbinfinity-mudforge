# DB Infinity Map Alterer

Moves ranges of rooms on the map, by hand, with an undo.

`dbalter`

## What it is for

The client's automapper lays rooms out from their exits. That is right far more
often than not, and when it is wrong it tends to be wrong about a whole run of
rooms at once — a corridor bent through a wall, a wing overlapping the one
beside it.

The client's own nudge is drag-and-drop on **one** room, which is the right
tool for one room and a long afternoon for twelve. This does the same thing to
a range.

## The panel

    rooms  [from] [to]  by [n]

    n  ne  e  se  s  sw  w  nw  u  d

    undo last     close

Type a vnum range and how many squares, then press a direction. Every room of
**the area you are standing in** whose vnum falls inside the range moves that
way.

`undo last` puts the most recent move back. It walks backwards through the
session one move at a time.

## From the command line

    dbalter                        show the panel
    dbalter hide                   hide it
    dbalter 11170-11180 e 2        move a range two squares east
    dbalter 11170-11180 north      long names work too
    dbalter undo                   put the last move back
    dbalter diag                   what it can see

## It saves nothing

No settings, no stored data, no room user data. The map edits themselves are
the whole product, and they belong to the client's map — which persists them,
exports them, and is the thing you were editing in the first place.

The undo lives in memory and goes when the client does. That is deliberate
rather than a shortcut: it can put back what **this session** moved, and makes
no claim about anything else.

## Two limits, and why

**One area at a time.** Only rooms of the area you are standing in are touched,
even if the vnum range covers more. A range that strays into the next block
would drag somebody else's rooms sideways, and there is no way to see that
happen or to work out afterwards what moved.

**Eight squares at most.** This is straightening a map by hand. Anything past a
few squares is a mistake with a long walk back.

## Notes

North is *up*, so it lowers a room's `y`. That is the convention the client
draws with.

Nothing here is specific to Dragonball Infinity beyond the name — it uses the
client's own map API and works on any world.

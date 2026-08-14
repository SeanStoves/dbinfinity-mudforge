# DB Infinity Mapper

Builds a map of the MUD from what it prints, and draws a panel that follows you
around it.

MudForge's own automapper needs GMCP or MSDP room data. Dragonball Infinity
sends neither — it answers a `Core.Hello` with a local map picture, which has no
room ids, names or exits in it. So the map is built from the room output
instead, and written into the client's own map database. Pathfinding, areas,
room notes and the map file all come for free from that; only the drawing is
ours.

## Getting started

```
config -supermap -autocompass
```

Stops the server drawing its map into the output stream. Without it the map
appears twice.

Then walk. Rooms, exits, doors and terrain record themselves.

```
dbmap            what the commands are
dbmap diag       what it has recorded so far
```

The panel opens on its own. `dbmap hide` closes it, `dbmap show` brings it back.

## Reading the panel

| | |
|---|---|
| `@` | the room you are in |
| `?` | an exit seen but never walked, in the direction it leads |
| `U` / `D` | stairs up and down, in the room's corners; red where unwalked |
| 🚪 / 🔒 | a closed or locked door on the connection between two rooms |

Rooms are coloured by terrain, using **the MUD's own palette**. `Map.Definition`
names a colour for all fifty-one of its styles — a green field, a grey city, a
yellow road — so a room that is green on the server's local map is green here
rather than in some second scheme invented for this panel. The border takes the
colour as the server gives it and the fill takes it faded, because those are
full-saturation terminal colours and a panel full of `#00ff00` boxes is not
readable.

Terrain is recorded for the room you are standing in, as the server draws it. So
colour arrives as you walk: rooms already on your map from before stay plain
until you next pass through them, and a room the server never gave a sector for
stays plain for good rather than being guessed at.

Hovering a room gives its name, vnum, area, every exit and where it goes, the
exits still unwalked, and any doors.

Clicking a room walks you to it. Clicking a door cycles it: closed, locked,
gone — doors are recorded automatically and only ever removed by hand.

**An open door is not drawn.** The server's local map uses one style for an open
door and for a doorway that never had a door in it, so "open" was never
something it told us — it was what the map assumed when a door it had recorded
read back as a plain exit. A single bad reading then decayed into a permanent
faded doorway instead of going away. Doors are only ever recorded upward now:
closed or locked, or nothing.

`+` and `−` zoom. Clicking the area name in the footer opens a searchable list
of every area the MUD's `areas` command knows, with the power range for each,
so you can switch to somewhere before walking a single room of it.

## Finding your way

```
dbmap find barracks     search; results are clickable
dbmap goto 10043        walk there
dbmap path 10043        the route as a speedwalk you can send
```

`path` prints the MUD's own encoding — `speedwalk nnqyu`, with `q r t y` for the
diagonals — and splits it where a door is in the way:

```
speedwalk eets ; open east ; speedwalk en
```

`dbmap autodoor on` collapses that back into one walk if you have
`config +autodoor` set, since bumping a door opens it.

## When the map looks wrong

A MUD's geography does not always fit on a flat grid. A ring of rooms can
enclose fewer squares than its interior needs; corridors that loop can come back
to a square already taken. The map says so rather than drawing a tidy lie, and
these fix it:

```
dbmap nudge e s          move the room east of you, south
dbmap nudge 10014 s 2    or by vnum, further
dbmap nudge 10014 reset  put it back
dbmap stretch n 2        push everything north of you outward
dbmap relayout           lay the area out again from its exits
dbmap respace fit        take the slack out of a stretched map
dbmap distance e 3       how far apart rooms sit, per axis
```

A nudge is remembered on the room, so a later relayout keeps it.

## Areas

The MUD never says which area you are in, so it is worked out. Crossing a
special exit starts a provisional one; name it properly when you know.

```
dbmap area <name>        new rooms go here
dbmap rename <name>      this area was never called that; brings its rooms
dbmap take 4 go          pull the last 4 rooms into this area
dbmap moveto <area> go   move whatever 'find' just listed
```

## Travel that is not a direction

```
dbgo enter ship
```

Sends the command and maps where it lands as a special exit. Only `dbgo` can
create one — a mapper that guesses which commands travel will decide that
`kill captain` is a teleporter, and this one did, once.

Dying and being sent home are recognised on their own.

## Tidying up

```
dbmap audit              exits pointing nowhere, rooms sharing a square
dbmap clean              special exits nothing declared as travel
dbmap forget 10018 go    one room
dbmap forget found go    everything the last search listed
dbmap drop <area> go     an area and its rooms
dbmap clear all confirm  start over
```

Everything destructive is a dry run until `go`, and names what it will touch
first.

## What travels with the map

Rooms, exits, doors, stubs, terrain and areas all live in the client's own map
database, so they export with `exportMapJson` and load into someone else's
client. The vnum block each area allocates from, the travel verbs and your
manual nudges live there too — hand someone the map and their copy behaves like
yours, without copying a single setting.

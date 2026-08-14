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

**Terrain colour needs Scouter installed and enabled.** It comes out of the
server's `Map.Snapshot`, and the Mapper never asks for that package itself —
Scouter owns that handshake, and two plugins negotiating the same one is how the
map stayed empty for a week. Without it rooms and exits still record; the
terrain colours below simply never arrive. `dbmap doors` says so when no
snapshot has turned up.

Doors are less fussy, because they have three ways in. The snapshot is one, but
walking into a closed door and being told so is another — the MUD's own `The
door is closed` is a plainer signal than working the geometry out of the local
map's cells — and clicking one on the panel is the third. So doors still record
without Scouter; they just record as you bump into them.

```
dbmap            what the commands are
dbmap diag       what it has recorded so far
dbmap on         follow and record. Where it starts out
dbmap follow     follow, but write nothing down
dbmap off        neither
```

**`follow` is the one to reach for in an area you have already mapped.** The
panel keeps up with you and the `@` keeps moving, but nothing new is written —
no rooms, no exits, no stubs, no doors, no terrain. `off` used to be the only
way to stop a map growing, and it also stopped the panel being any use.

Walk somewhere unmapped while following and it says so rather than leaving the
`@` on the last room it did know. It cannot follow you to a room it has never
seen, and a confident wrong answer is worse than an empty one.

The mode is remembered, so a `dbmap off` you forgot about is still off next
login and the map quietly stops growing. `dbmap mode` says which one you are in.

The panel opens on its own. `dbmap hide` closes it, `dbmap show` brings it back.

It draws one of two pictures. `dbmap view area` plots the area at its stored
coordinates — the whole thing at once, which is what you want for getting your
bearings. `dbmap view local` ignores those coordinates and lays the
neighbourhood out fresh by walking exits from the room you are standing in:
always readable, because a small neighbourhood almost never contradicts itself,
but it only shows what is near you. `dbmap view` on its own says which is up.

## Reading the panel

| | |
|---|---|
| `@` | the room you are in |
| `?` | an exit seen but never walked, in the direction it leads |
| `U` / `D` | stairs up and down, in the room's corners; red where unwalked |
| ▬ | a door: a bar across the connection, square to it. Amber if it is locked |

Rooms are coloured by terrain, using **the MUD's own palette**. `Map.Definition`
names a colour for all fifty-one of its styles — a green field, a grey city, a
yellow road — so a room that is green on the server's local map is green here
rather than in some second scheme invented for this panel. The border takes the
colour as the server gives it and the fill takes it faded, because those are
full-saturation terminal colours and a panel full of `#00ff00` boxes is not
readable.

**Sectors are read from the rooms around you, not the one you are in.** The
server spends your own square saying "you are here" — its style is `current`, not
a sector — so a room learns its ground while you are standing next door. There
is nowhere else the information comes from.

Colour therefore arrives one step behind you, and fills in as you walk. A cell
showing something other than ground — a lift, a mob, an item — is telling you
about its contents rather than its sector, so nothing is recorded for it and the
room stays plain until a later look says otherwise. Plain rather than guessed.

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

`+` and `−` zoom, and the gear between them swaps the map for a settings page:
view mode, zoom, both distances, whether recording is on, the current area and
how many rooms are in it, the totals recorded and the travel verbs. It is a
readout — nothing on it changes anything yet, so the commands are still how you
set them. Clicking the area name in the footer opens a searchable list of every
area the MUD's `areas` command knows, with the power range for each, so you can
switch to somewhere before walking a single room of it.

## Floors, and looking somewhere else

The map is three-dimensional and always was: going up or down records the new
room a floor above or below rather than beside, and the panel draws one floor at
a time. Which is the right answer while you are walking, and no help at all when
you are standing in a basement wondering what is above you.

Drag the map to move the view off yourself, the same as pulling a paper one
across a desk. On an area with more than one floor, **▲** and **▼** appear in the
top bar and step to the next floor that exists, not the next number: a tower
with a basement and a roof and nothing between them is one press each way.

The drag redraws once per room crossed rather than once per pixel — every redraw
is a round trip out to the plugin and back — so a short pull inside one room's
width does nothing, and then it steps. Grabbing the top or bottom bar does not
start a drag, so the buttons there still press.

While the view is off you, a marker in the corner says which floor you are
looking at and that you have panned — click it to come home. Walking snaps it
back on its own, because following you is what the panel is for; looking around
is something you do while standing still.

The `@` is only drawn where it actually is. Move the view to another floor and
it goes, rather than following you into a picture you are not in.

Both are area view only. `dbmap view local` lays the neighbourhood out by
walking exits outward from where you are standing, so there are no coordinates
to offset and no floor to step to, and the controls stay away.

## Colours and symbols

The gear opens the settings readout; **colours and symbols** on it opens the
editor.

Sector colours come with a picker each, and every one starts at the colour the
MUD itself uses — `Map.Definition` names all forty-one. That palette is also
compiled into the plugin, so the defaults are right before the server has said
anything and stay right on an install without Scouter, which is what fetches it.
A live definition always wins over the compiled copy.

**Every sector is listed, walked or not.** The MUD has forty-one and the list is
compiled in, so you can set a colour for somewhere before you have been there,
and the page works on an install that never sees a GMCP packet. The ones your
current area actually contains are marked `here`, and anything the server names
that is not in the compiled list is added rather than hidden.

**Reset means reset.** A colour input cannot be blank, so each row carries its
own `reset`, and there is a `back to the MUD's colours` for the lot. Either one
*deletes* the override rather than writing today's value — so a sector you have
not touched keeps following the server, and one you reset goes back to doing so.

Saving stores only what you actually changed. The form submits every row whether
you looked at it or not, so a value that still equals the server's is stored as
nothing at all — otherwise opening this page once and pressing save would pin
every colour and the map would quietly stop following the MUD.

Flags get a glyph and a colour on the same page. The two are saved together
because defining a flag replaces its whole definition; changing only the glyph
would otherwise take the colour off with it.

All of it lives in the map rather than in plugin settings. Plugin preferences do
not survive a reinstall — the client keys them by a runtime id — and these are
meant to outlast updates, so they go where the rooms go and travel with a map
export.

## Room flags

A flag is a tag on a room — `healing`, `quest`, `pk`, whatever you find worth
marking. They are the client's own subsystem rather than anything this plugin
invented, so they live on the room, travel with a map export, and are searchable
without a plugin at all.

**This MUD flags some rooms in the name itself.** `(H) Healing Chamber` is one,
and the `H` is the healing flag, so walking into it tags it — no typing. Only
letters whose meaning is actually known are read; an unrecognised prefix is left
alone rather than given a name it may not have. As more are confirmed they get
added.

Everything else is by hand:

```
dbmap flag quest         tag this room; the same command takes it off again
dbmap unflag quest       take it off whatever it was
dbmap flags              this room's tags, and every flag the map knows
```

A flag does not have to be defined before you use it. An undefined tag is still
kept and still searchable — it simply draws nothing until someone gives it a
look, which you can do from **Map Settings → Room Flags…** without touching the
plugin. A defined flag tints the room and can carry a glyph or a small icon.

On the panel, a flag colour paints over the terrain colour, which is the order
the client's own map uses. A flag's glyph only shows in a room that has nothing
of its own to show, so it never replaces the `@`.

## Finding your way

```
dbmap here              this room's vnum and hash
dbmap find barracks     search; results are clickable
dbmap goto 10043        walk there
dbmap path 10043        the route as a speedwalk you can send
```

`path` prints the MUD's own encoding — `speedwalk nnqyu`, with `q r t y` for the
diagonals — and splits it where a door is in the way:

```
speedwalk eets ; open east ; speedwalk en
```

The split is not optional. Every closed door on the route gets an `open <dir>`
in front of it, a locked one an `unlock <dir>` before that, and there is no
setting to leave them out.

## When the map looks wrong

A MUD's geography does not always fit on a flat grid. A ring of rooms can
enclose fewer squares than its interior needs; corridors that loop can come back
to a square already taken. The map says so rather than drawing a tidy lie, and
these fix it:

```
dbmap nudge w            move the room you are in, west
dbmap nudge w 3          or further -- useful after a teleport drops you
                         on top of somewhere already mapped
dbmap nudge e s          move the room east of you, south
dbmap nudge 10014 s 2    or by vnum, further
dbmap nudge 10014 reset  put it back
dbmap stretch n 2        push everything north of you outward
dbmap relayout           lay the area out again from its exits
dbmap respace <2-8>      spread out a map drawn at the old spacing
dbmap respace fit        take the slack out of a stretched map
dbmap distance e 3       how far apart rooms sit, per axis
```

A nudge is remembered on the room, so a later relayout keeps it.

`dbmap view local` sidesteps the whole business — it reads no stored coordinate
at all, so nothing in it can collide — but it only ever draws what is near you.

## Areas — set this first

The one thing the mapper cannot work out for itself. This MUD sends no room
package, so nothing in the output says which area a room belongs to; rooms are
filed under whichever area is current, and it has to be told what that is.

A new map starts in **LEGENDE**, the MUD's own level-one area, because that is
where a new character actually is. It is a starting guess and nothing more, and
the plugin says so the first time it runs on an empty map rather than letting it
pass for knowledge. Left alone, everything you walk piles into that one name —
which is easy not to notice until there are two hundred rooms under it.

```
dbmap area <name>        new rooms go here
dbmap rename <name>      this area was never called that; brings its rooms
dbmap take 4 go          pull the last 4 rooms into this area
dbmap moveto <area> go   move whatever 'find' just listed
```

Clicking the area name at the foot of the panel opens the same list, searchable,
with the power range for each — so you can switch to somewhere before walking a
single room of it. That list is compiled into the plugin, captured from the
MUD's `areas` output on the day it was built, so it is full the first time you
open it. Nothing here reads `areas` off the stream; typing it changes nothing.

Crossing a special exit starts a provisional area; name it properly when you
know what it is.

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

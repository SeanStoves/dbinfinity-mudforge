# DB Infinity Scouter

<img src="../img/scouter.png" alt="The Scouter panel: a green phosphor lens showing the local map, with a scan reading for a wild boar underneath" width="229" align="right">

The local map as a scouter readout, driven by Dragonball Infinity's GMCP `Map`
module rather than by scraping the output.

Colours come from the server's own style table, so sectors, mobs, exits, doors
and your own position keep the meaning the MUD gave them — 51 styles, including
terrain by type and a separate colour for aggressive mobs.

- Fits itself to the panel, and re-fits when you resize it
- Follows your terminal's font and size rather than imposing its own
- Adjustable transparency, so it can sit over your main output and stay readable
- `scan <target>` puts the target and its power level under the map: steady for
  ten seconds, pulsing, then gone at thirty

## Set this up first

The MUD draws its map into the output stream **and** sends it over GMCP. The
panel uses the GMCP copy, so leaving both on means reading the same map twice:

```
config -supermap
config -autocompass
```

Scouter says so once on its own if it notices you haven't.

You don't need to enable GMCP anywhere. The server advertises only CHARSET and
never offers GMCP, so MudForge — correctly — never offers it either. Scouter
sends `Core.Hello` on connect, which is what gets the server talking. That's
also why this map works in Mudlet with no setup: Mudlet greets unprompted.

## Commands

## The comms row

Under the title bar: **TX**, **RCV** and the channel.

The scouter is a radio as well as a lens, and the MUD keeps that state itself —
`scouter display` prints it:

```
Energy Detection Capacity: 100,000,000,000
Channel Frequency: 624
Transmit Function: Active
Receive Function: Active
Encrypt Function: Not Installed
```

The panel reads that block wherever it appears and shows what it said. It is one
row and stays one row: a second line of chrome above a 15x15 lens is most of the
panel. A button
lights only when the MUD has actually reported `Active`; before the block has
been seen once they read `tx ?` and `rcv ?` rather than drawing a switch in a
position nobody has confirmed. Encryption is the padlock — closed when it is
active, open when it is not. It is drawn rather than written, in the panel's own
phosphor, because the words took a whole second row to say nothing most
characters need.

Clicking **TX** or **RCV** asks the MUD to flip it and then asks what it did —
the switch belongs to the game, and the panel does not keep a second copy of it
that could drift. Typing a number in the channel field and pressing the **tick**
sends `scouter frequency <n>`; anything that is not digits is refused here
rather than sent, since it is field text going out as a command.

The tick lights while you are in the channel field. It cannot tell whether you
actually changed the number — no script runs inside a widget, so there is
nothing to compare the field against — but being in the field is the same moment
in practice.

`dbscout comms` asks for the block without touching the panel.

## The lens

```
dbscout lens          what it is now, and what else there is
dbscout lens blue     change it
```

Green because that is what a scouter looks like. The rest are the colours this
MUD uses for its own text — red, blue, cyan, yellow, orange, purple, pink,
white, grey — and each one moves the whole panel together: the map, the dim
labels and the bright edges, not just the text.

That set is not arbitrary. The MUD describes a scouter by its lens — *a scouter
with a blue-crystal lens* — and colours those words with the same tokens. So the
panel can eventually just be the colour of the one you are wearing; picking it
by hand is the first half of that.

| command | does |
|---|---|
| `dbscout` | the command list |
| `dbscout zoom fit` / `dbscout zoom <6-34>` | fill the panel, or lock a size |
| `dbscout font +` / `dbscout font -` | nudge the locked size a step |
| `dbscout opacity <0-100>` | `0` reads straight through it |
| `dbscout frame` | keep or drop the server's own map border |
| `dbscout gag` | keep the scouter's ASCII art out of the terminal |
| `dbscout header` | the title bar |
| `dbscout scan` | scanlines |
| `dbscout show` / `dbscout hide` | the panel |
| `dbscout redraw` | repaint now |
| `dbscout enable` | ask the server for the Map module again |
| `dbscout hello` | send another `Core.Hello` |
| `dbscout diag` | what the plugin currently sees |
| `dbscout raw` / `dbscout packages` | the GMCP payloads, and every package held |
| `dbscout comms` | read TX, RCV and the channel back off the MUD |
| `dbscout lens <colour>` | what shade the panel glows |
| `dbscout api [filter]` | every function bound in `_G`, optionally filtered |
| `dbscout debug` | what a `scan` parsed, plus the skipped-hello note |

The `-` and `+` buttons in the panel's bar lock a size; `dbscout zoom fit` hands
it back to the fitter. `dbscout font +` and `dbscout font -` are the same nudge
from the keyboard. `dbscout font <6-32>` is not — it writes the fallback
declaration that the container-query rule overrides, so it moves a number
nothing on screen reads. Use `zoom` for a size that sticks.

## If the panel stays empty

`dbscout diag` answers most of it:

- `negotiated=false` with `attempts=8/8` — the server never answered and the
  tick has given up. Check you're connected, then `dbscout enable`: it's the
  only thing that resets the counter and starts the schedule over.
  `dbscout hello` sends another greeting but leaves the tick parked, so no
  further `Core.Supports.Add` follows it.
- `negotiated=true` but `cached definitions=0` — GMCP is up but the `Map`
  module isn't sending. `dbscout enable`.
- `source=none` with a definition cached — the snapshot hasn't arrived yet;
  move a room.

`lastError` carries anything the renderer threw.

## Credits

The `Map.Definition` / `Map.Snapshot` protocol is Penguin's, from the Mudlet
GMCPMap package.

Bo wrote the first MudForge implementation, which is where the parsing came
from — rejecting `NaN` from `tonumber`, treating a missing GMCP field as
`undefined` rather than `nil`, and copying every packet on arrival because the
client reuses the object once the callback returns. All three were found the
hard way and all three are still load-bearing.

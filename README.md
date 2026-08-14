# Dragonball Infinity plugins for MudForge

Panels for [Dragonball Infinity](telnet://dbinfinity.bounceme.net:4000).

Most of them read the MUD's output. Only the Scouter and the Portrait ask for
anything over GMCP, and both of those scrape lines as well. The Mapper reads the
map packets the Scouter's handshake brings in — that is where the doors and the
terrain colours come from — but the map itself has to be built out of the room
text, because this server sends no room package at all.

## Install

In MudForge, open **Settings → Plugins → Repositories**, add this and sync:

```
https://github.com/SeanStoves/dbinfinity-mudforge
```

The plugins then appear in the plugin browser.

## Plugins

Every plugin answers its own name with a list of what it does, so the command
below is all you need to remember.

| plugin | command | what it does |
|---|---|---|
| **[DB Infinity Scouter](docs/scouter.md)** (`dbi-map`) | `dbscout` | The local map as a scouter readout, with `scan` power levels under it |
| **[DB Infinity Mapper](docs/mapper.md)** (`dbi-mapper`) | `dbmap`, `dbgo` | A map of the whole world, built as you walk it, with pathfinding and speedwalks |
| **[DB Infinity Portrait](docs/portrait.md)** (`dbi-portrait`) | `dbchar` | Your character: avatar, vitals, power level, transformations, and the full score sheet |
| **[DB Infinity Chat](docs/chat.md)** (`dbi-chat`) | `dbchat` | Channel traffic split into tabs, with captures you define |
| **[Transcript](docs/transcript.md)** (`mudlog`) | `mudlog` | Plain-text session logs on disk, for any MUD. Needs the File System Access permission |

Scouter and Mapper are not the same thing and do not overlap: Scouter draws the
server's own local map, the fifteen squares around you, exactly as it sends it.
Mapper builds a persistent world map out of the rooms you walk through.

## Before you start

Dragonball Infinity draws its map into the output stream **and** sends it over
GMCP. These panels use the GMCP copy, so leaving both on means reading the same
map twice. In the game:

```
config -supermap
config -autocompass
```

You don't need to enable GMCP anywhere — the Scouter and the Portrait do it for
you. The server advertises only CHARSET and never offers GMCP, so MudForge
correctly never offers it either; those two send `Core.Hello` on connect, which
is what gets the server talking.

The Mapper never negotiates for itself. It reads whatever that handshake brought
in, so installed on its own it never sees a `Map.Snapshot` and its doors and
terrain colours silently never appear. `dbmap doors` says so when that happens.
Keep the Scouter or the Portrait installed alongside it.

## Credits

The `Map.Definition` / `Map.Snapshot` protocol is Penguin's, from the Mudlet
GMCPMap package. Bo wrote the first MudForge implementation of it, which is
where the hard-won parts of the parsing came from.

MIT licensed.

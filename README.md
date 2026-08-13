# Dragonball Infinity plugins for MudForge

Panels for [Dragonball Infinity](telnet://dbinfinity.bounceme.net:4000), driven
by the MUD's GMCP data rather than by scraping its output.

## Install

In MudForge, open **Settings → Plugins → Repositories**, add this and sync:

```
https://github.com/SeanStoves/dbinfinity-mudforge
```

The plugins then appear in the plugin browser.

## Plugins

| plugin | what it does |
|---|---|
| **[DB Infinity Scouter](docs/scouter.md)** (`dbi-map`) | The local map as a scouter readout, with `scan` power levels under it |
| **[DB Infinity Portrait](docs/portrait.md)** (`dbi-portrait`) | Your character: avatar, vitals, power level, and the full score sheet |
| **[DB Infinity Chat](docs/chat.md)** (`dbi-chat`) | Channel traffic split into tabs, with captures you define |
| **[Transcript](docs/transcript.md)** (`mudlog`) | Plain-text session logs on disk, for any MUD. Needs the File System Access permission |

## Before you start

Dragonball Infinity draws its map into the output stream **and** sends it over
GMCP. These panels use the GMCP copy, so leaving both on means reading the same
map twice. In the game:

```
config -supermap
config -autocompass
```

You don't need to enable GMCP anywhere — the plugins handle that themselves.
The server advertises only CHARSET and never offers GMCP, so MudForge correctly
never offers it either; the plugin sends `Core.Hello` on connect, which is what
gets the server talking.

## Credits

The `Map.Definition` / `Map.Snapshot` protocol is Penguin's, from the Mudlet
GMCPMap package. Bo wrote the first MudForge implementation of it, which is
where the hard-won parts of the parsing came from.

MIT licensed.

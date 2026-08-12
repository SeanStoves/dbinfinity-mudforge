# Dragonball Infinity plugins for MudForge

Panels for [Dragonball Infinity](telnet://dbinfinity.bounceme.net:4000), driven
by the MUD's GMCP data rather than by scraping its output.

## Install

In MudForge, open **Settings → Plugins → Repositories**, add this URL, and sync:

```
https://raw.githubusercontent.com/SeanStoves/dbinfinity-mudforge/main/github.com
```

The plugins then appear in the plugin browser.

## Set this up first

Dragonball Infinity draws its map into the output stream *and* sends it over
GMCP. The panel uses the GMCP copy, so leaving both on means you read the same
map twice. In the game:

```
config -supermap
config -autocompass
```

That stops the server drawing it and leaves the panel as the only place it
appears. Scouter says so once on its own if it notices you haven't.

You do not need to enable GMCP anywhere. The server advertises only CHARSET and
never offers GMCP, so MudForge — correctly — never offers it either. The plugin
sends `Core.Hello` on connect, which is what gets the server talking. That is
also why the map works in Mudlet without any of this: Mudlet greets the server
unprompted.

## Plugins

### Scouter (`dbi-map`)

The local map as a scouter readout. Colours come from the server's own style
table, so sectors, mobs, exits, doors and your own position keep their meaning.

- Fits itself to the panel and re-fits when you resize it
- Follows your terminal's font and size rather than imposing one
- Adjustable transparency, so it can sit over your main output and stay readable
- `scan <target>` puts the target and its power level under the map — steady for
  ten seconds, pulsing, then gone at thirty

| command | does |
|---|---|
| `dbmap` | the command list |
| `dbmap zoom fit\|<6-34>` | fill the panel, or lock a size |
| `dbmap opacity <0-100>` | `0` to read straight through it |
| `dbmap frame` | keep or drop the server's own map border |
| `dbmap gag` | keep the scouter's ASCII art out of the terminal |
| `dbmap header` / `dbmap scan` | title bar, scanlines |
| `dbmap show` / `dbmap hide` | the panel |
| `dbmap diag` | what the plugin currently sees |
| `dbmap enable` / `dbmap hello` | ask the server for the Map module again |

If the panel stays empty, `dbmap diag` reports whether GMCP negotiated and how
many attempts it took. `negotiated=false` after eight attempts means the server
never answered; anything else is in there too.

## Credits

The `Map.Definition` / `Map.Snapshot` protocol is Penguin's, from the Mudlet
GMCPMap package. Bo wrote the first MudForge implementation of it, which is
where the hard-won parts of the parsing came from — the NaN checks, the
`undefined` handling, and copying every packet on arrival because the client
reuses the object once the callback returns.

MIT licensed.

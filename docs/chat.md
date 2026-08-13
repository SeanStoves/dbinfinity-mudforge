# DB Infinity Chat

Channel traffic split into tabs, with the MUD's own colours kept intact.

Dragonball Infinity puts everything down one pipe — OOC, race talk, auctions,
events, tells, the lot — and by the time you notice someone spoke to you it has
scrolled. This routes each line to a tab as it arrives and marks the tabs you
haven't read.

Nothing is hidden from your main window unless you ask for it.

## Tabs

Nine to start with: **All**, **Pers**, **OOC**, **Chat**, **Race**, **Auct**,
**Hard**, **Event** and **Cust**. All carries everything and labels each line
with the channel it came from; the rest carry only their own.

Turn any of them off under **setup**, or add your own:

```
chat tab guild My Guild
```

## Captures

The built-in routing covers the channels this MUD ships with. Anything else you
want split out, you define:

```
chat capture senzu auction senzu bean
chat capture mytell personal re:^Someone tells you
```

Plain text matches anywhere in the line. Prefix the pattern with `re:` for a
regular expression — that's JavaScript regex, not a Lua pattern.

Captures show up under **setup** with a `del` beside each one, and they survive
a restart.

## Routing

Every rule, built-in or yours, is in one of three modes, set from the dropdown
beside it under **setup**:

| mode | does |
|---|---|
| `widget` | routes to its tab |
| `both` | routes to its tab, and stays in the main window |
| `off` | ignored entirely |

**Hide routed lines** under setup is the master switch: with it on, anything in
`widget` mode is taken out of the main window, so the panel becomes the only
place chat appears. Off by default, because a chat panel that silently eats
your output is worse than one you have to look at twice.

## Commands

| command | does |
|---|---|
| `chat` | the command list |
| `chat show` / `chat hide` | the panel |
| `chat setup` | the settings tab |
| `chat clear` | empty every buffer |
| `chat capture <name> <tab> <text>` | route a line |
| `chat capture <name> <tab> re:<regex>` | the same, as a regex |
| `chat tab <id> <Label>` | a tab of your own |
| `chat diag` | what the plugin currently sees |

Everything else is on the **setup** tab: which tabs are shown, what each rule
does, the master gag, the text size, the backdrop and the panel opacity.

**Backdrop image** under setup takes any `http`/`https` URL, or blank for the
one that ships with the plugin. It is checked rather than cleaned: the URL ends
up inside a CSS `url()`, so anything carrying a quote, bracket or backslash is
refused outright and the bundled image is used instead.

Setup is one form with a **Save** at the bottom, and nothing applies until you
press it. That is deliberate. Every control used to apply on click, and applying
meant repainting the panel, and repainting put the scroll back at the top — so
changing anything below the first screenful bounced you away from what you were
doing. A checkbox or a dropdown changes in the browser without telling the
plugin, so now nothing moves until you say so.

Deleting a capture is still a single click, because removing a row changes the
shape of the list and has to redraw anyway. It sits below the Save button so
nothing above it shifts.

## Notes

Links in chat are clickable. Only `http` and `https` are ever linked — chat is
the most attacker-influenced text a plugin handles here, so nothing else gets
turned into something you can click.

The panel follows your terminal's font until you tell it not to. **Text size**
under setup nudges it a point at a time between 8 and 28; the first nudge starts
from whatever the terminal is currently at, so nothing jumps. It keeps 400 lines
per tab.

## Credits

The routing — which line belongs to which channel — is Bo's, from the DBZ Chat
plugin, carried over wholesale. Those thirty-odd patterns are real research into
this MUD's channels and there was no reason to rediscover them.

Everything else is new: HTML rather than canvas, so wrapping, scrolling and
selection come from the browser instead of from hand-rolled font arithmetic,
and captures can be added while you play rather than living in the source.

MIT licensed.

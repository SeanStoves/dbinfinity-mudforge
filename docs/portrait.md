# DB Infinity Portrait

Your character, drawn from three sources because none of them is enough alone.

`char.vitals` arrives over GMCP and is pushed, so the Lifeforce and Energy bars
stay honest while you fight. `score` carries race, sex, age, stats, armour,
kills and the rest, but only when you ask for it — so it's parsed once and kept.
Where the two overlap, GMCP wins, because `score` is a snapshot from whenever
you last typed it.

`look self` is the third, and nothing sends it for you. Type it once and the
sheet gains your description — build, height, weight, hair, eyes — and the full
list of what you are wearing. It is saved with the rest of the sheet.

The `score` block stays in your scroll exactly as the MUD sent it. The only line
that can be hidden is the stat prompt, and only if you ask — see `dbchar gag`.

## Two views

**Portrait** — the avatar, your first name, rank, race, sex and age, the two
bars, power level against base, the four stats, zeni and alignment, plus a pill
for your position and another when current power has drifted off base.

**Sheet** — behind the gear, everything `score` reports: the stats again,
armour, position, carry weight, the full kill and spar record, crits, tokens,
session gains and your EQ bonus. Type `look self` and your description and worn
equipment join it.

## The power level box

It reads as a single figure — your base power level, what you are worth at rest
— with current shown against it as a bar underneath. At rest that bar sits at
100%, drained it falls, boosted it runs past and marks the overflow.

Click the box to swap to the two figures side by side, `Base PL | Curr PL`, for
when the ratio is not the point. `dbchar pl` does the same from the command
line, and the choice is remembered.

## The enemy

GMCP carries nothing at all about your opponent, so their lifeforce is read off
your fight prompt as it goes past:

```
(LifeForce:<89.26> Enemy:<41.37> KI:<611>)
```

`Enemy` is what this MUD's own fight prompt calls it; a modified `fprompt` may
say `Foe`. Both are read, in either bracket style, so this works on the stock
prompt without changing anything.

The bar appears when a fight starts and clears when a prompt comes back with no
opponent on it, with a ten second timeout behind that for a fight that ends
without another prompt. `dbchar diag` shows what it is currently reading.

## It remembers

The sheet comes from `score`, and `score` only arrives when you ask for it, so
the panel used to open blank after a restart. It is saved now and comes back
straight away — **saved per character**, so an alt does not open wearing the
last one's face, race and power level. Your avatar is kept per character too.

Whoever was on last is what loads. If you swapped characters since, type
`score` once and it corrects itself.

The bars are a partial exception. The raw vitals are not kept — GMCP pushes them
within a second or two of connecting, and a two-day-old packet is worth nothing.
But `score` reports LifeForce and Energy of its own, so the bars open reading
whatever the saved sheet says and correct themselves the moment vitals arrive.

## The avatar

![Every bundled avatar](../img/avatar-set.png)

Picked automatically from race and sex — all sixteen races, both sexes, plus a
generic silhouette for anything unrecognised. If there's no art for your race yet you
get a plain frame rather than a broken image, and you can always point it at
your own:

```
dbchar avatar https://example.com/me.png
dbchar avatar clear
```

**It has to be a URL, not a file on your disk.** A local file cannot be shown in
a widget by this client at all — its own helper converts a path to
`asset://localhost/...` rather than `file://`, and that protocol is not enabled
in the build, so there is no scheme the webview will fetch a local image over.
The File System Access permission does not change it, and neither does putting
the file in `~/MudForge/plugin-files`: that folder scopes `io.open`, which is a
different question.

Upload it anywhere that serves `https` — an image host, a gist, a repo — and use
that URL. It is how the bundled avatars load, and it follows you to another
machine rather than living on one disk.

**A share page works too.** An imgur album link is a web page rather than a
picture, so it would otherwise load markup and show nothing. Hand one over and
the plugin fetches it once and reads the image the page advertises:

```
dbchar avatar https://imgur.com/a/Ih3oyvz
```

The first request to a new host asks your permission — that is the client, once
per domain, and it is remembered. A link that already ends in `.png`, `.jpg`,
`.gif` or `.webp` is used directly and costs no request at all.

The URL is checked rather than cleaned. It ends up inside a CSS `url()`, so
anything carrying a quote, a bracket, a backslash or a space is refused and the
previous avatar is kept.

## Transformations

Tie a form to the line the MUD prints when you enter it, and the portrait wears
that form's art while you are in it:

```
dbchar form ssj https://example.com/ssj.png Your hair stands on end and burns golden!
dbchar form normal base You power back down.
```

The name comes first, then the image, then the text to watch for — the text is
last because it is the only part with spaces in it. A URL of `base` means
back-to-normal: matching that form drops the override and the usual avatar
returns.

Matching is a plain substring, case-insensitive, and nothing is gagged — the
announcement stays in your scroll where it belongs. The active form also shows
as a pill on the portrait, so there is no doubt about which one is on.

```
dbchar forms              what is set, and which is active
dbchar unform ssj         drop one
dbchar base               back to normal by hand
```

Forms are kept **per character**, alongside the sheet and the avatar — a
Saiyan's transformation line means nothing on a Namekian, and an alt should not
transform on someone else's text. A session always starts in base form.

Form URLs go through the same check as the avatar, for the same reason: they end
up inside a CSS `url()`.

## Commands

| command | does |
|---|---|
| `dbchar` | the command list |
| `dbchar show` / `dbchar hide` | the panel |
| `dbchar sheet` / `dbchar portrait` | switch view without the gear |
| `dbchar pl` | single figure, or base and current side by side |
| `dbchar avatar <url>` / `clear` | your own image, or back to the race one |
| `dbchar form <name> <url\|base> <text>` | a transformation portrait |
| `dbchar forms` / `unform <name>` / `base` | list, drop, or reset by hand |
| `dbchar name <name>` / `clear` | correct the name, or back to what `score` says |
| `dbchar font +` / `-` / `<50-200>` | text size, over whatever the terminal uses |
| `dbchar gag on` / `off` | hide the stat prompt line from the main window |
| `dbchar opacity <0-100>` | `0` reads straight through it |
| `dbchar diag` | what the plugin currently sees |
| `dbchar probe` | every GMCP package and MSDP variable, raw |

## Hiding the prompt

The stat prompt exists for the widgets rather than for reading, so once the
panel is up it is mostly noise. `dbchar gag on` takes it out of the main window.

It is **off by default** — it is still the line most people watch, and turning it
off should be a decision rather than something a plugin does on your behalf.

What the prompt looks like is learned rather than configured. This MUD's default
draws `(LifeForce:<100.00> Ki:<8,955>)`; a modified `fprompt` may use `LF:[`
instead. The gag matches whichever label your session actually prints, and
re-arms itself if you change prompts mid-session.

One limit worth knowing: a gag only works on a line the MUD has finished
sending. The stock prompt here is two lines, and only the first one closes —
game output glues straight onto the tail of the second. So the `LifeForce` line
goes and the `PowerLevel` line stays. Nothing can hide an unterminated line, and
trying eats the echo of whatever you typed.

## Setup

None beyond what [Scouter](scouter.md) already needs. `Core.Supports.Add
["Map 1"]` turns on character stats as well as the map, so whichever of the two
plugins connects first does the handshake and the other stays quiet. Either
works installed on its own.

Portrait sends `score` once shortly after you log in, to fill the panel. After
that it reads whatever you type yourself.

## Getting the name right

The second line of `score` is `<first> <last> <title>` with nothing between
them — `Solao Bajiuik says no.` The first two capitalised words are the name and
the rest is your title. If that splits your name wrong, `dbchar name <name>`
fixes it for good.

## Credits

A remake of the Portrait panel from [Solao's Aardwolf
plugins](https://github.com/SeanStoves/aardwolf-mudforge), rebuilt for
Dragonball Infinity's data. The shape is the same — an avatar picked from what
the MUD knows about your character, a compact portrait, and the full sheet a
click away — but everything under it is new: this MUD has no `char.base`, its
stats live in a fixed-format `score` block, and the vitals it pushes are a
different set.

The bundled avatars are AI-generated original artwork, not screencaps. They're
race archetypes in the style of the genre rather than any character's likeness.

MIT licensed.

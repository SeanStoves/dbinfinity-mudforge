# Transcript

Plain-text session logs on disk, appended as you play.

MudForge's own logging keeps entries in IndexedDB, caps them, and hands them
back only through an export. This writes a flat file, so `grep`, `sed` and `awk`
work on it the way they do on a Mudlet or MushClient transcript.

Nothing in this plugin is specific to any MUD. It ships in this repository
because this is the repository that exists.

## It needs a permission, and it fails quietly without one

**Desktop app only**, and the plugin's **File System Access** permission has to
be on — plugin settings, Permissions tab.

Without it, `io.open` still succeeds. It just writes to a pseudo-file inside the
world file instead of to your disk.

The plugin checks rather than assumes. On the first write it creates a
throwaway file and deletes it again — `os.remove` returns true only with real
filesystem access — and says so if the answer is no:

```
[Transcript] File System Access is OFF -- nothing is reaching your disk.
```

`mudlog status` reports the same thing as `realFilesystem=`. If that says `no`,
no other number in the status output means anything.

## Where the files go

```
~/MudForge/plugin-files/mudlog/mudLogs/2026-08-13-Dragonball Infinity.txt
```

The `~/MudForge/plugin-files/mudlog` part is fixed — it is where the client puts
a relative path, and the plugin cannot write outside it. The rest is yours:

| setting | default | |
|---|---|---|
| folder | `mudLogs` | `mudlog folder <dir>` |
| name | `{date}-{world}.txt` | `mudlog name <pattern>` |

`{date}`, `{time}`, `{world}` and `{char}` are substituted. Anything else in the
pattern is literal. A world named `../../etc` becomes a filename, not a path.

The file opens on the first line rather than at load, because the world name is
part of the path and isn't knowable until you connect.

## What lands in it

Everything in the stream: output as it arrives, and the commands you typed,
prefixed so they read back as input. Commands are captured before aliases
rewrite them, so the transcript matches the session you actually played rather
than what the client expanded it into.

Escape codes are stripped by default. `mudlog colour` keeps them if you want the
colour back for a replay.

## Commands

| command | does |
|---|---|
| `mudlog` | the command list |
| `mudlog on` / `off` | logging |
| `mudlog status` | where it's writing, how, and how much |
| `mudlog flush` | force the buffer out now |
| `mudlog folder <dir>` | where the files go |
| `mudlog name <pattern>` | the filename pattern |
| `mudlog open` | the folder, in your file manager |
| `mudlog colour` | keep or strip escape codes |
| `mudlog stamp` | per-line timestamps |
| `mudlog config` | the settings panel |

## If something looks wrong

`mudlog status` reports the resolved path, the handle it actually got, and the
mode it opened in. That last one matters: append mode isn't in the client's API
documentation, so the plugin tries three ways to open a file and tells you which
one worked.

| mode | means |
|---|---|
| `append` | what it wants |
| `append (flattened, no subdirectory)` | relative subdirectories aren't being created, so the folder name became part of the filename |
| `rewrite (no append mode)` | no append at all; the existing file was read forward once and the handle held open for the session |

A surprise being visible beats a surprise being silent, which is why the mode is
reported rather than assumed.

## Notes

`savePluginFile` and `appendPluginFile` are not used here. They route through the
storage engine whether the permission is on or not, which is the thing being
avoided.

MIT licensed.

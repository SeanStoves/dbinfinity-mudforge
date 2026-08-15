#!/usr/bin/env python3
"""
pack.py — build the repository index from the Lua sources in src/.

Sean Stoves, 2026-08-15

The client installs from an index, not from a loose .lua, so this emits what it
actually fetches:

    dist/<id>.json          the plugin, script inlined
    plugins.json            the index the client reads
    github.com/plugins.json the same index again

src/<id>.lua is the source of truth. Edit one -- here, or on github.com
directly -- and this turns it back into a bundle.

Versions are YYYY.MM.DD.NNN, per plugin, independent of each other. A plugin
gets a new one only when its script actually changed, so a run that touches
nothing rewrites nothing:

    first change today          -> 2026.08.15.000
    second change today         -> 2026.08.15.001
    first change tomorrow       -> 2026.08.16.000

If the version line in the .lua was edited by hand it is taken as-is and
nothing is computed. That way a deliberate version always wins over the clock,
and the automation cannot argue with an author who has already decided.

Run: python3 tools/pack.py [--check]

--check exits non-zero if anything would change, and writes nothing. That is
what CI uses to tell "someone forgot to rebuild" from "nothing to do".
"""

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DIST = os.path.join(ROOT, "dist")

RAW = "https://raw.githubusercontent.com/SeanStoves/dbinfinity-mudforge/HEAD"
HOMEPAGE = "https://github.com/SeanStoves/dbinfinity-mudforge"

REPO_NAME = "Solao's Dragonball Infinity Plugins"
REPO_DESC = ("GMCP-driven panels for Dragonball Infinity: scouter map, character "
             "portrait, tabbed chat. Plus Transcript, which works anywhere.")

# id -> (category, doc page). 'widgets' is the only category proven to appear in
# the browser; it is not that 'tools' is broken, it is that it was never
# confirmed, and a plugin nobody can find is worse than one filed oddly.
CATALOGUE = {
    "dbi-map":      ("widgets", "docs/scouter.md"),
    "dbi-portrait": ("widgets", "docs/portrait.md"),
    "dbi-chat":     ("widgets", "docs/chat.md"),
    "dbi-codex":    ("widgets", "docs/codex.md"),
    "dbi-mapper":   ("widgets", "docs/mapper.md"),
    "mudlog":       ("widgets", "docs/transcript.md"),
}

VERSION_RE = re.compile(r'^(\s*version\s*=\s*")([^"]*)(")', re.M)
DATED_RE = re.compile(r"^(\d{4})\.(\d{2})\.(\d{2})\.(\d{3})$")


def meta_of(script, who):
    """The fields the index needs, read out of the plugin table."""
    out = {}
    for key in ("id", "name", "version", "author", "description"):
        m = re.search(r'\b' + key + r'\s*=\s*"((?:[^"\\]|\\.)*)"', script)
        if not m:
            sys.exit(f"{who}: no {key} in the plugin table")
        out[key] = m.group(1).replace('\\"', '"')
    return out


def next_version(published, today):
    """The next YYYY.MM.DD.NNN after `published`, for a change made today."""
    m = DATED_RE.match(published or "")
    if m and f"{m.group(1)}.{m.group(2)}.{m.group(3)}" == today:
        n = int(m.group(4)) + 1
        if n > 999:
            sys.exit(f"999 releases of one plugin in a day ({today}) -- "
                     "the counter has nowhere left to go, so this needs a human")
        return f"{today}.{n:03d}"
    # a different day, or a version from before this scheme
    return f"{today}.000"


def main():
    check_only = "--check" in sys.argv
    today = datetime.now(timezone.utc).strftime("%Y.%m.%d")

    os.makedirs(DIST, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "github.com"), exist_ok=True)

    # Catalogue order, not directory order. The index is a list and the browser
    # shows it in the order given, so sorting by filename would reshuffle the
    # published index on a run that changed nothing.
    on_disk = {n[:-4] for n in os.listdir(SRC) if n.endswith(".lua")}
    stray = on_disk - set(CATALOGUE)
    if stray:
        sys.exit("in src/ but not in CATALOGUE, so it would ship to nobody: "
                 + ", ".join(sorted(stray)))

    entries, changed = [], []
    for pid, (category, doc) in CATALOGUE.items():
        name = f"{pid}.lua"
        path = os.path.join(SRC, name)
        if not os.path.exists(path):
            sys.exit(f"CATALOGUE names {pid} but src/{name} is not there")
        with open(path, encoding="utf-8") as fh:
            script = fh.read()
        meta = meta_of(script, f"src/{name}")
        if meta["id"] != pid:
            sys.exit(f"src/{name} declares id '{meta['id']}' -- the file name "
                     "and the id have to agree or the bundle lands elsewhere")

        # what is already published, if anything
        old_script, old_version = None, None
        bundle_path = os.path.join(DIST, f"{pid}.json")
        if os.path.exists(bundle_path):
            with open(bundle_path, encoding="utf-8") as fh:
                old = json.load(fh)
            old_script, old_version = old.get("script"), old.get("version")

        # A hand-edited version wins. Only when the author left it alone AND
        # the script moved does the clock get a say.
        if old_version is not None and meta["version"] == old_version \
                and old_script is not None and script != old_script:
            fresh = next_version(old_version, today)
            script = VERSION_RE.sub(lambda m: m.group(1) + fresh + m.group(3),
                                    script, count=1)
            meta["version"] = fresh
            changed.append(f"{pid} {old_version} -> {fresh}")
            if not check_only:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(script)
        elif old_script is None or script != old_script or meta["version"] != old_version:
            changed.append(f"{pid} {old_version or '(new)'} -> {meta['version']}")

        bundle = dict(meta, category=category, script=script)
        # sorted keys and a trailing newline, so an unchanged plugin produces a
        # byte-identical file and the hash does not churn
        blob = json.dumps(bundle, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        if not check_only:
            with open(bundle_path, "w", encoding="utf-8") as fh:
                fh.write(blob)

        raw = blob.encode("utf-8")
        entries.append({
            "id": meta["id"],
            "name": meta["name"],
            "version": meta["version"],
            "author": meta["author"],
            "description": meta["description"],
            "category": category,
            # No cache-buster. A '?v=' was tried and the client normalises the
            # query away, so a URL never requested still served an older bundle
            # out of cache -- which surfaced as an integrity failure rather than
            # a stale install. The sha256 is what actually protects that, and it
            # works: it refused the bad download.
            "downloadUrl": f"{RAW}/dist/{pid}.json",
            "format": "json",
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size": len(raw),
            "license": "MIT",
            "homepage": f"{HOMEPAGE}/blob/HEAD/{doc}",
        })
        print(f"  {meta['id']:<14} {meta['version']:<16} {len(raw)} bytes")

    index = {
        "schemaVersion": 1,
        "name": REPO_NAME,
        "description": REPO_DESC,
        "homepage": HOMEPAGE,
        # Only stamped when something moved. A timestamp that changes on every
        # run makes an empty rebuild look like a release.
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pluginCount": len(entries),
        "plugins": entries,
    }

    old_index = None
    index_path = os.path.join(ROOT, "plugins.json")
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as fh:
            old_index = json.load(fh)
    if old_index is not None and old_index.get("plugins") == entries:
        index["generated"] = old_index.get("generated", index["generated"])

    if not check_only:
        body = json.dumps(index, indent=2, ensure_ascii=False) + "\n"
        for where in (index_path, os.path.join(ROOT, "github.com", "plugins.json")):
            with open(where, "w", encoding="utf-8") as fh:
                fh.write(body)

    if changed:
        print("\nchanged:")
        for line in changed:
            print("  " + line)
    else:
        print("\nnothing changed")

    if check_only and changed:
        sys.exit(1)


if __name__ == "__main__":
    main()

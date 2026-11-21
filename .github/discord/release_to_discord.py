"""Posts a GitHub release to the Discord server's #releases channel, the way
v1.2.0 was posted (the user, 2026-11-21: "set this as default"):

  1. a card: the rotating shiny Teddiursa over "autocrystal <tag>", the zip's
     SHA-256 line, the footer and the release time, with Download / Release
     page buttons under it - the message pings the Release Ping role;
  2. the notes as plain messages (full chat width), "# Patch notes <tag>" on
     top, headings / bold / bullets as on GitHub, no link previews.

  python release_to_discord.py release.json
      release.json: `gh release view <tag> --json tagName,name,url,body,assets,publishedAt`
      DISCORD_RELEASES_WEBHOOK: the #releases webhook (made by the server bot,
      so it may send buttons)
  --no-ping   post without pinging Release Ping (a test re-post)
"""
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sync_readme import call, say, Fail
import readme_to_discord as R2D

ROLE_ID = "1570554558525083758"  # Release Ping
GREEN = 0x8BC34A
SUPPRESS_EMBEDS = 4               # (no link previews under the notes)
WEBHOOK_PATTERN = re.compile(r"^https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+$")
TEDDY = os.path.join(HERE, "art", "release_teddy_400.gif")


def post(hook, body, files=(), components=False):
    url = hook + "?wait=true" + ("&with_components=true" if components else "")
    body.setdefault("allowed_mentions", {"parse": []})
    if files:
        body["attachments"] = [{"id": i, "filename": f[0]} for i, f in enumerate(files)]
    return call("POST", url, body, list(files))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("release_json")
    ap.add_argument("--no-ping", action="store_true")
    a = ap.parse_args()
    hook = os.environ.get("DISCORD_RELEASES_WEBHOOK", "").strip()
    if not WEBHOOK_PATTERN.match(hook):
        sys.exit("DISCORD_RELEASES_WEBHOOK isn't set to a Discord webhook link")
    with open(a.release_json, encoding="utf-8") as f:
        r = json.load(f)
    tag = r["tagName"]
    zipurl = next((x["url"] for x in r.get("assets", []) if x["name"].endswith(".zip")), r["url"])

    # The zip's SHA-256 line goes up into the card; the notes go without it.
    notes, sha = (r.get("body") or "").replace("\r\n", "\n"), None
    m = re.search(r"^[^\n]*SHA-256[^\n]*`[0-9a-fA-F]{64}`[^\n]*$", notes, re.M)
    if m:
        sha = m.group(0).strip()
        notes = (notes[:m.start()] + notes[m.end():]).strip()
    msgs = [x["content"] for x in R2D.convert(notes, 0) if x["content"].strip()]

    head = {"content": "<@&%s>" % ROLE_ID,
            "embeds": [{"color": GREEN, "title": "autocrystal %s" % tag, "url": r["url"],
                        "image": {"url": "attachment://release_teddy.gif"},
                        "footer": {"text": "autocrystal · Windows · Gold, Silver & Crystal"}}]}
    if sha:
        head["embeds"][0]["description"] = sha
    if r.get("publishedAt"):
        head["embeds"][0]["timestamp"] = r["publishedAt"]
    if not a.no_ping:
        head["allowed_mentions"] = {"parse": [], "roles": [ROLE_ID]}
    buttons = [{"type": 1, "components": [
        {"type": 2, "style": 5, "label": "Download " + tag, "url": zipurl},
        {"type": 2, "style": 5, "label": "Release page", "url": r["url"]}]}]
    teddy = [("release_teddy.gif", open(TEDDY, "rb").read())]
    try:
        post(hook, dict(head, components=buttons), teddy, components=True)
    except Fail as e:
        # (a webhook that isn't the bot's can't send buttons: the links go in the card)
        say(" (buttons refused: %s - the links go in the card)" % str(e)[:120])
        head["embeds"][0]["description"] = ((sha + "\n\n") if sha else "") + \
            "**[Download %s](<%s>) · [Release page](<%s>)**" % (tag, zipurl, r["url"])
        post(hook, head, teddy)

    # A big heading over the notes, in the first message if it still fits
    # Discord's 2,000 letters, else on its own.
    heading = "# Patch notes %s" % tag
    if msgs and len(heading) + 1 + len(msgs[0]) <= 2000:
        msgs[0] = heading + "\n" + msgs[0]
    else:
        msgs.insert(0, heading)
    for text in msgs:
        post(hook, {"content": text, "flags": SUPPRESS_EMBEDS})
    say("Posted %s to #releases: the card and %d message(s) of notes." % (tag, len(msgs)))


if __name__ == "__main__":
    main()

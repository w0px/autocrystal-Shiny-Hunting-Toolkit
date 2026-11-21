"""Posts a GitHub release's notes to the Discord server's #releases channel.

Reads release.json (from `gh release view <tag> --json name,tagName,url,body`)
and sends the notes through the #releases webhook, split into messages of at
most 2000 characters at line breaks. The first message pings the Release Ping
role. Needs DISCORD_RELEASES_WEBHOOK (a repository secret).
"""
import json
import os
import re
import sys
import time
import urllib.request

ROLE_ID = "1570554558525083758"  # Release Ping
LIMIT = 2000
WEBHOOK_PATTERN = re.compile(r"^https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+$")


def chunks(text, limit):
    out, cur = [], ""
    for line in text.splitlines(keepends=True):
        while len(line) > limit:  # (a single over-long line: hard split)
            if cur:
                out.append(cur)
                cur = ""
            out.append(line[:limit])
            line = line[limit:]
        if len(cur) + len(line) > limit:
            out.append(cur)
            cur = ""
        cur += line
    if cur.strip():
        out.append(cur)
    return out


def post(url, content, ping):
    payload = {
        "content": content,
        "flags": 4,  # no link previews
        "allowed_mentions": {"parse": [], "roles": [ROLE_ID] if ping else []},
    }
    req = urllib.request.Request(url + "?wait=true", data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": "autocrystal-release-post (github actions)"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                r.read()
                return
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = float(json.loads(e.read() or b"{}").get("retry_after", 2))
                time.sleep(wait + 0.5)
                continue
            raise
    raise RuntimeError("Discord kept rate-limiting the post")


def main():
    url = os.environ.get("DISCORD_RELEASES_WEBHOOK", "").strip()
    if not WEBHOOK_PATTERN.match(url):
        sys.exit("DISCORD_RELEASES_WEBHOOK isn't set to a Discord webhook link")
    with open(sys.argv[1], encoding="utf-8") as f:
        rel = json.load(f)
    name = rel.get("name") or rel["tagName"]
    head = f"<@&{ROLE_ID}> **{name}** is out: <{rel['url']}>\n\n"
    body = (rel.get("body") or "").replace("\r\n", "\n").strip()
    parts = chunks(head + body, LIMIT)
    for i, part in enumerate(parts):
        post(url, part, ping=(i == 0))
        time.sleep(1)
    print(f"Posted {name} to #releases in {len(parts)} message(s).")


if __name__ == "__main__":
    main()

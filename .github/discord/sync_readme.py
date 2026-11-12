# Puts autocrystal's README into the Discord #readme forum - one post per
# section (readme_to_discord.py) - and keeps it the newest: a re-run edits only
# the messages that changed, adds new sections, and never pings anyone.
#
# It needs no saved state: it finds the posts in the forum by their titles.
# The posts are written by the forum's webhook; the bot token is only used to
# read the forum (its posts, tags) and to wake up posts Discord has archived.
#
#   python sync_readme.py docs/README.md            the webhook + bot token from the environment:
#                                                   DISCORD_README_WEBHOOK, DISCORD_BOT_TOKEN
#   python sync_readme.py --git <checkout>          GitHub's newest README (after a git fetch;
#                                                   the checkout's files aren't touched)
#   --webhook-file F / --token-file F               read them from files instead
#   --dry-run                                       shows what would change
import argparse, io, json, mimetypes, os, re, subprocess, sys, time, urllib.error, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import readme_to_discord as R2D

API = "https://discord.com/api/v10"


def say(s): print(s, flush=True)


class Fail(Exception): pass


def call(method, url, body=None, files=None, token=None, ok404=False, dry=False):
    safe = re.sub(r"/webhooks/(\d+)/[^/?]+", r"/webhooks/\1/<token>", url.replace(API, ""))
    if dry and method != "GET":
        say("   would %s %s" % (method, safe)); return {"id": "0", "channel_id": "0"}
    headers = {"User-Agent": "DiscordBot (https://github.com, 1.0) readme-sync"}
    if token: headers["Authorization"] = "Bot " + token
    if files:
        b = uuid.uuid4().hex
        out = io.BytesIO()
        def part(hs, data):
            out.write(("--%s\r\n" % b).encode())
            for h in hs: out.write((h + "\r\n").encode())
            out.write(b"\r\n"); out.write(data); out.write(b"\r\n")
        part(['Content-Disposition: form-data; name="payload_json"', "Content-Type: application/json"], json.dumps(body).encode())
        for i, (name, data) in enumerate(files):
            part(['Content-Disposition: form-data; name="files[%d]"; filename="%s"' % (i, name),
                  "Content-Type: " + (mimetypes.guess_type(name)[0] or "application/octet-stream")], data)
        out.write(("--%s--\r\n" % b).encode())
        data, headers["Content-Type"] = out.getvalue(), "multipart/form-data; boundary=" + b
    else:
        data = json.dumps(body).encode() if body is not None else None
        headers["Content-Type"] = "application/json"
    for _ in range(10):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=headers), timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            if e.code == 429:
                try: wait = float(json.loads(raw).get("retry_after", 1))
                except ValueError: wait = 1
                time.sleep(min(wait, 60) + 0.2); continue
            if e.code == 404 and ok404: return None
            raise Fail("Discord said %d to %s %s: %s" % (e.code, method, safe, raw[:300]))
    raise Fail("Discord kept rate limiting %s %s" % (method, safe))


def main():
    global API
    ap = argparse.ArgumentParser()
    ap.add_argument("readme", nargs="?")
    ap.add_argument("--git")
    ap.add_argument("--webhook-file")
    ap.add_argument("--token-file")
    ap.add_argument("--api", default=API)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    API = a.api.rstrip("/")
    read = lambda f: open(f, encoding="utf-8").read().strip()
    hook_url = read(a.webhook_file) if a.webhook_file else os.environ.get("DISCORD_README_WEBHOOK", "").strip()
    token = read(a.token_file) if a.token_file else os.environ.get("DISCORD_BOT_TOKEN", "").strip()
    if token.lower().startswith("bot "): token = token[4:].strip()
    if not hook_url or not token: raise SystemExit("Needs the #readme webhook and the bot token (see the top of this file).")
    m = re.match(r"^https://(?:\w+\.)?discord(?:app)?\.com/api(?:/v\d+)?/webhooks/(\d+)/([\w-]+)", hook_url)
    if not m: raise SystemExit("That isn't a Discord webhook link.")
    W = "%s/webhooks/%s/%s" % (API, m.group(1), m.group(2))
    hook_id = m.group(1)
    dry = a.dry_run

    if a.git:
        subprocess.run(["git", "-C", a.git, "fetch", "-q", "origin"], check=True)
        md = subprocess.run(["git", "-C", a.git, "show", "origin/main:docs/README.md"], check=True, capture_output=True).stdout.decode("utf-8")
        def image(src): return subprocess.run(["git", "-C", a.git, "show", "origin/main:docs/" + src], capture_output=True).stdout or None
    else:
        md = open(a.readme or "docs/README.md", encoding="utf-8").read()
        base = os.path.dirname(os.path.abspath(a.readme or "docs/README.md"))
        def image(src):
            p = os.path.join(base, src)
            return open(p, "rb").read() if os.path.exists(p) else None

    bot = lambda method, path, body=None, **k: call(method, API + path, body, token=token, dry=dry, **k)
    hook = call("GET", W)
    forum, guild = hook["channel_id"], hook["guild_id"]
    tags = {t["name"]: t["id"] for t in (bot("GET", "/channels/%s" % forum) or {}).get("available_tags", [])}

    # the forum's posts: the open ones and the archived ones
    threads = {}
    for t in (bot("GET", "/guilds/%s/threads/active" % guild) or {}).get("threads", []):
        if t.get("parent_id") == forum: threads.setdefault(t["name"], t)
    before = None
    while True:
        r = bot("GET", "/channels/%s/threads/archived/public?limit=100%s" % (forum, "&before=" + before if before else ""))
        for t in r.get("threads", []): threads.setdefault(t["name"], t)
        if not r.get("has_more") or not r.get("threads"): break
        before = r["threads"][-1]["thread_metadata"]["archive_timestamp"]

    posts = R2D.posts(md)

    def want(msg):
        body = {"content": msg["content"], "allowed_mentions": {"parse": []}}
        files, embeds = [], []
        for im in msg["images"]:
            src = im["src"]
            if re.match(r"^https?://", src): embeds.append(src)
            else:
                data = image(src)
                if data: files.append((os.path.basename(src), data))
                else: body["content"] += "\n-# (picture: %s)" % src
        body["embeds"] = [{"image": {"url": u}} for u in embeds[:10]]
        body["attachments"] = [{"id": i, "filename": f[0]} for i, f in enumerate(files)]
        key = (body["content"], tuple(embeds[:10]), tuple((f[0], len(f[1])) for f in files))
        return body, files, key

    def have_key(x):
        return (x.get("content", ""), tuple(e.get("image", {}).get("url", "") for e in x.get("embeds", []) if e.get("type") in (None, "rich", "image")),
                tuple((f["filename"], f["size"]) for f in x.get("attachments", [])))

    changed = 0
    for post in reversed(posts):       # new posts last section first: the forum lists the newest on top
        t = threads.get(post["title"])
        msgs = post["messages"]
        if t is None:
            say(" + %s (%d messages)" % (post["title"], len(msgs)))
            body, files, _ = want(msgs[0])
            body["thread_name"] = post["title"]
            if post["tag"] in tags: body["applied_tags"] = [tags[post["tag"]]]
            x = call("POST", W + "?wait=true", body, files, dry=dry)
            for m_ in msgs[1:]:
                body, files, _ = want(m_)
                call("POST", W + "?wait=true&thread_id=" + x["channel_id"], body, files, dry=dry)
            changed += 1
            continue
        # (the bot sees which messages are there; their text it reads through
        # the webhook - a bot without Discord's "message content" permission
        # gets other senders' messages blank)
        ids = sorted((x["id"] for x in (bot("GET", "/channels/%s/messages?limit=100" % t["id"]) or []) if x.get("webhook_id") == hook_id), key=int)
        old = [call("GET", "%s/messages/%s?thread_id=%s" % (W, i, t["id"])) for i in ids]
        todo = []
        for i, m_ in enumerate(msgs):
            body, files, key = want(m_)
            if i < len(old):
                if have_key(old[i]) != key: todo.append(("PATCH", "%s/messages/%s?thread_id=%s" % (W, old[i]["id"], t["id"]), body, files))
            else:
                todo.append(("POST", "%s?wait=true&thread_id=%s" % (W, t["id"]), body, files))
        for x in old[len(msgs):]:
            todo.append(("DELETE", "%s/messages/%s?thread_id=%s" % (W, x["id"], t["id"]), None, None))
        if not todo: continue
        say(" ~ %s (%d messages changed)" % (post["title"], len(todo)))
        if t.get("thread_metadata", {}).get("archived"):
            bot("PATCH", "/channels/%s" % t["id"], {"archived": False})
        for method, url, body, files in todo:
            call(method, url, body, files, dry=dry, ok404=(method == "DELETE"))
        changed += 1

    for name in sorted(set(threads) - {p["title"] for p in posts}):
        say(" ? %s: no longer in the README (post left as it is)" % name)
    if posts and posts[0]["title"] in threads and not threads[posts[0]["title"]].get("flags", 0) & 2:
        bot("PATCH", "/channels/%s" % threads[posts[0]["title"]]["id"], {"flags": 2})
    say("README: %d sections, %d posts changed%s." % (len(posts), changed, " (dry run)" if dry else ""))


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        raise SystemExit(str(e))

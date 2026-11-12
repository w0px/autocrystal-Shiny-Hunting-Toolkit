# Turns autocrystal's docs/README.md into Discord forum posts: one post per
# section, each a list of messages (<= 2000 letters, Discord's limit) with the
# section's pictures right after the text they belong to.
#   python readme_to_discord.py README.md out.json [--images DIR]
# Discord shows markdown headings, bold, lists, code and links, but not HTML,
# tables, inline pictures or #anchors - those are converted here:
#   <img>        -> a picture under the message (an upload, or a link Discord shows)
#   <b>/<a>/<br> -> **bold** / [text](link) / new line;  <details> -> a bold line
#   tables       -> one "- **first column** - the rest" line per row
#   #anchors     -> the section on GitHub; relative links -> GitHub
import html, json, os, re, sys

REPO = "https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit"
README_URL = REPO + "/blob/main/docs/README.md"
LIMIT = 1900
TAGS = {"": "Getting Started", "The Launcher": "Launcher", "Modules": "Modules", "FAQ": "FAQ"}
DEEP = "Simulating Randomness"


def slug(h):
    s = re.sub(r"[^\w\- ]", "", h.lower().strip()).replace(" ", "-")
    return s


def html_to_md(t):
    t = re.sub(r"<img\b([^>]*?)/?>", lambda m: "\n\x00IMG %s\x00\n" % json.dumps(attrs(m.group(1))), t, flags=re.S)
    t = re.sub(r"<details>\s*<summary>(.*?)</summary>", r"\n**\1**\n", t, flags=re.S)
    t = re.sub(r"</details>", "", t)
    t = re.sub(r"<h1[^>]*>(.*?)</h1>", r"\n# \1\n", t, flags=re.S)
    t = re.sub(r"<br\s*/?>", "\n", t)
    t = re.sub(r"</?b>", "**", t)
    t = re.sub(r"</?i>", "*", t)
    t = re.sub(r'<a\s+href="([^"]+)"[^>]*>(.*?)</a>', r"[\2](\1)", t, flags=re.S)
    t = re.sub(r"</?p[^>]*>", "\n", t)
    t = re.sub(r"</?(div|span|sub|sup|center)[^>]*>", "", t)
    return html.unescape(t).replace(" ", " ")


def attrs(s):
    return {k: v for k, v in re.findall(r'(\w+)\s*=\s*"([^"]*)"', s)}


def tables(lines):
    out, i = [], 0
    while i < len(lines):
        if lines[i].lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{3,}", lines[i + 1]):
            i += 2
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                out.append("- **%s** - %s" % (cells[0], " - ".join(c for c in cells[1:] if c)))
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out


def links(t):
    def fix(m):
        text, url = m.group(1), m.group(2)
        if url.startswith("#"): url = README_URL + url
        elif not re.match(r"^[a-z]+:", url): url = REPO + "/blob/main/docs/" + url.lstrip("./")
        return "[%s](<%s>)" % (text, url)    # <...>: no link preview under the post
    return re.sub(r"(?<!!)\[([^\]]+)\]\(([^)\s]+)\)", fix, t)


def convert(block, top_heading_level):
    """Markdown/HTML text -> list of {content, images}."""
    # code blocks stay as they are
    parts = re.split(r"(```.*?```)", block, flags=re.S)
    text = []
    for k, p in enumerate(parts):
        if k % 2:
            text.append(p); continue
        p = html_to_md(p)
        ls = tables(p.split("\n"))
        res = []
        for l in ls:
            m = re.match(r"^(#{1,6})\s+(.*)$", l)
            if m:
                lvl = len(m.group(1)) - top_heading_level   # the post's own heading is its title
                l = ("## " if lvl <= 1 else "### " if lvl == 2 else "**") + m.group(2).strip() + ("**" if lvl > 2 else "")
            if re.match(r"^\s*(---+|\*\*\*+)\s*$", l): l = ""
            # (indents from the README's HTML would show as spaces; list
            # items keep theirs - that's how Discord nests them)
            if not re.match(r"^\s*([-*+]|\d+\.)\s", l): l = l.lstrip()
            res.append(l.rstrip())
        text.append(links("\n".join(res)))
    t = "".join(text)
    t = re.sub(r"\n{3,}", "\n\n", t).strip()

    msgs, cur, imgs = [], "", []
    def flush():
        nonlocal cur, imgs
        if cur.strip() or imgs: msgs.append({"content": cur.strip(), "images": imgs})
        cur, imgs = "", []
    for piece in re.split(r"(\x00IMG .*?\x00)", t):
        if piece.startswith("\x00IMG "):
            a = json.loads(piece[5:-1])
            imgs.append({"src": a.get("src", ""), "alt": a.get("alt", "")})
            continue
        if not piece.strip(): continue
        if imgs: flush()          # pictures go under the text before them
        for para in re.split(r"\n\n(?=(?:[^`]|`[^`]|``[^`])*$)", piece.strip()) if "```" not in piece else split_keep_code(piece.strip()):
            if len(cur) + len(para) + 2 > LIMIT: flush()
            while len(para) > LIMIT:          # one huge paragraph / code block
                cut = para.rfind("\n", 0, LIMIT)
                cut = cut if cut > 200 else LIMIT
                head, para = para[:cut], para[cut:].lstrip("\n")
                if head.count("```") % 2: head += "\n```"; para = "```\n" + para
                cur = head; flush()
            cur = (cur + "\n\n" + para) if cur else para
    flush()
    return msgs


def split_keep_code(t):
    out, buf, code = [], [], False
    for line in t.split("\n"):
        if line.strip().startswith("```"): code = not code
        if not code and line.strip() == "" and buf:
            out.append("\n".join(buf)); buf = []
        else:
            buf.append(line)
    if buf: out.append("\n".join(buf))
    return out


def posts(md):
    lines = md.replace("\r\n", "\n").split("\n")
    sections, group, cur = [], "", None
    def start(title, tag, lvl):
        nonlocal cur
        cur = {"title": title, "tag": tag, "lvl": lvl, "lines": []}
        sections.append(cur)
    start("Overview", "Getting Started", 1)
    code = False
    for l in lines:
        if l.strip().startswith("```"): code = not code
        m = None if code else re.match(r"^(#{1,2})\s+(.*)$", l)
        if m and len(m.group(1)) == 1:
            group = m.group(2).strip()
            start(group, "Deep Dive" if group.startswith(DEEP) else TAGS.get(group, group), 1)
            continue
        if m:
            h = m.group(2).strip()
            if h == "Table of Contents": start("_toc", "", 2); continue
            if h == "Functions": cur["lines"].append("## Functions"); continue
            if group.startswith(DEEP) and not h.startswith("How Headbutt Trees"):
                cur["lines"].append("## " + h); continue
            start(h, "Deep Dive" if group.startswith(DEEP) else TAGS.get(group, group), 2)
            continue
        cur["lines"].append(l)
    out = []
    for s in sections:
        if s["title"] == "_toc": continue
        msgs = convert("\n".join(s["lines"]), s["lvl"])
        if not msgs: continue
        out.append({"title": s["title"][:100], "tag": s["tag"], "link": README_URL + "#" + slug(s["title"]), "messages": msgs})
    return out


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    P = posts(open(src, encoding="utf-8").read())
    json.dump(P, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    n = sum(len(p["messages"]) for p in P)
    print("%d posts, %d messages, %d pictures" % (len(P), n, sum(len(m["images"]) for p in P for m in p["messages"])))
    for p in P:
        print(" [%s] %s - %d msg, longest %d" % (p["tag"], p["title"], len(p["messages"]), max(len(m["content"]) for m in p["messages"])))

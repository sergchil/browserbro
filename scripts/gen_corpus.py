#!/usr/bin/env python3
"""Generates Tests/RoutingCoreTests/Fixtures/corpus.json.

This is an independent oracle: it re-implements the fixture rules by hand in Python,
so the Swift engine is checked against a second implementation, not against itself.
"""
import itertools, json, re, pathlib
from urllib.parse import urlsplit

CHROME_WORK = "com.google.Chrome#Profile 3"
FF_SERGEY = "org.mozilla.firefox#Profiles/a1b2c3d4.Profile 2"
CANARY = "com.google.Chrome.canary"
BRAVE_WORK = "com.brave.Browser#Profile 2"
SAFARI = "com.apple.Safari"
FIREFOX = "org.mozilla.firefox"

def dom(host, d):
    return host == d or host.endswith("." + d)

def expect(url, src, mods):
    if "option" in mods:
        return "picker"
    p = urlsplit(url)
    host = (p.hostname or "").rstrip(".").lower()
    path = p.path or "/"
    if any(dom(host, d) for d in ["linear.app", "slack.com", "atlassian.net"]) or src == "com.tinyspeck.slackmacgap":
        return CHROME_WORK
    if dom(host, "docs.google.com") and src != "com.apple.mail":
        return FF_SERGEY
    if host in ("localhost", "127.0.0.1"):
        return CANARY
    if dom(host, "acme.com") and path.startswith("/admin"):
        return BRAVE_WORK
    if dom(host, "acme.com"):
        return CHROME_WORK
    if "shift" in mods:
        return SAFARI
    if re.search(r"^https://(www\.|m\.)?youtube\.com/watch", url):
        return SAFARI
    if re.fullmatch(r"[^./?#]*\.github\.io", host):
        return FIREFOX
    if "utm_source=zoom" in url.lower():
        return SAFARI
    return "picker"

urls = [
    "https://linear.app/acme/issue/ABC-87",
    "https://app.slack.com/client/T1/C2",
    "https://acme.atlassian.net/wiki/spaces/X",
    "https://notlinear.app/",
    "https://docs.google.com/document/d/abc/edit",
    "https://DOCS.Google.com./spreadsheets/d/1",
    "https://drive.google.com/file/d/1",
    "http://localhost:3000/debug",
    "http://127.0.0.1:8080/",
    "https://www.acme.com/uae",
    "https://www.acme.com/admin/orders",
    "https://acme.com/administrator",
    "https://notacme.com/admin",
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "https://m.youtube.com/watch?v=1",
    "https://youtube.com/shorts/abc",
    "https://sergchil.github.io/blog/",
    "https://a.b.github.io/",
    "https://github.io/",
    "https://example.com/?utm_source=Zoom&x=1",
    "https://example.com/plain",
    "https://news.ycombinator.com/item?id=1",
    "https://www.bbc.co.uk/news",
    "https://en.wikipedia.org/wiki/Router",
    "https://example.org:8443/path?q=1#frag",
]
sources = [None, "com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.Terminal"]
modsets = ["", "option", "shift", "shift+command"]

cases = []
for url, src, mods in itertools.product(urls, sources, modsets):
    c = {"url": url, "expect": expect(url, src, mods.split("+") if mods else [])}
    if src: c["from"] = src
    if mods: c["modifiers"] = mods
    cases.append(c)
cases = cases[:400]
out = pathlib.Path(__file__).resolve().parents[1] / "Tests/RoutingCoreTests/Fixtures/corpus.json"
out.write_text(json.dumps(cases, indent=1) + "\n")
print(f"wrote {len(cases)} cases to {out}")

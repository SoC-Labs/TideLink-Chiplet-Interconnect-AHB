#!/usr/bin/env python3
"""Serve docs/BUG_REGISTRY.yaml as a live web page.

Every request re-reads and re-renders the YAML, so there is no build step and
nothing to keep in sync: save the file, and the open tab refreshes itself with
your filters, expanded cards and scroll position intact.

    python3 scripts/serve_bug_registry.py                 # http://127.0.0.1:8765
    python3 scripts/serve_bug_registry.py --port 9000
    python3 scripts/serve_bug_registry.py --host 0.0.0.0  # reachable on the LAN

Routes
    /                     the page
    /api/registry.json    the parsed registry
    /api/version          content hash + parse status (polled for live reload)

A YAML syntax error is shown in the browser with the parser message instead of
a blank page, and the tab recovers on its own once the file parses again.

Depends only on the standard library plus PyYAML (via gen_bug_registry_html).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_bug_registry_html as gen  # noqa: E402  (needs the path above)


# --------------------------------------------------------------------------- #
# Self-hosted extras. The generated page is deliberately plain so it can also be
# published as a static artifact; live reload and the theme switch are injected
# here, by the server only.
# --------------------------------------------------------------------------- #
LIVE_SNIPPET = r"""
<style>
  .tl-live {
    position: fixed;
    right: 14px;
    bottom: 14px;
    z-index: 50;
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 6px 10px;
    border: 1px solid var(--line);
    border-radius: 3px;
    background: var(--surface);
    box-shadow: var(--shadow);
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: .06em;
    text-transform: uppercase;
    color: var(--ink-dim);
  }
  .tl-live .tl-dot {
    width: 7px; height: 7px; border-radius: 50%;
    background: var(--ok); flex: none;
  }
  .tl-live.is-stale .tl-dot { background: var(--sev-high); }
  .tl-live.is-down .tl-dot  { background: var(--sev-crit); }
  .tl-btn {
    font: inherit;
    text-transform: inherit;
    letter-spacing: inherit;
    color: var(--ink-mid);
    background: var(--surface-2);
    border: 1px solid var(--line);
    border-radius: 2px;
    padding: 2px 7px;
    cursor: pointer;
  }
  .tl-btn:hover { border-color: var(--ink-dim); color: var(--ink); }
  @media print { .tl-live { display: none; } }
</style>

<div class="tl-live" id="tl-live" role="status" aria-live="polite">
  <span class="tl-dot" aria-hidden="true"></span>
  <span id="tl-txt">live</span>
  <button type="button" class="tl-btn" id="tl-theme">auto</button>
</div>

<script>
(function () {
  "use strict";

  var VERSION  = "__VERSION__";
  var INTERVAL = __INTERVAL__;
  var bar = document.getElementById("tl-live");
  var txt = document.getElementById("tl-txt");

  /* ---- theme: auto -> light -> dark, remembered per browser ---- */
  var themes = ["auto", "light", "dark"];
  var btn = document.getElementById("tl-theme");
  function paint(t) {
    if (t === "auto") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", t);
    btn.textContent = t;
    btn.title = t === "auto" ? "Theme: following the system" : "Theme: " + t;
  }
  var saved = null;
  try { saved = localStorage.getItem("tl-theme"); } catch (e) {}
  paint(themes.indexOf(saved) >= 0 ? saved : "auto");
  btn.addEventListener("click", function () {
    var next = themes[(themes.indexOf(btn.textContent) + 1) % themes.length];
    try { localStorage.setItem("tl-theme", next); } catch (e) {}
    paint(next);
  });

  /* ---- carry the view across a reload ---- */
  if ("scrollRestoration" in history) history.scrollRestoration = "manual";
  try {
    var raw = sessionStorage.getItem("tl-view");
    if (raw) {
      sessionStorage.removeItem("tl-view");
      if (window.TLRegistry) window.TLRegistry.restore(JSON.parse(raw));
    }
  } catch (e) {}

  function keepView() {
    try {
      if (window.TLRegistry) {
        sessionStorage.setItem("tl-view", JSON.stringify(window.TLRegistry.state()));
      }
    } catch (e) {}
  }

  /* ---- poll for a changed registry ---- */
  function setState(cls, label) {
    bar.className = "tl-live" + (cls ? " " + cls : "");
    txt.textContent = label;
  }

  function poll() {
    fetch("/api/version", { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (v) {
        if (v.sha !== VERSION) {
          setState("", "reloading");
          keepView();
          location.reload();
          return;
        }
        setState(v.ok ? "" : "is-stale", v.ok ? "live" : "yaml error");
      })
      .catch(function () { setState("is-down", "server down"); });
  }

  setInterval(poll, INTERVAL);
  window.addEventListener("focus", poll);
})();
</script>
"""

ERROR_PAGE = r"""
<title>Bug registry — YAML error</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; background: #14181c; color: #e6ecf0;
    font: 14px/1.6 ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
  }
  .wrap { max-width: 900px; margin: 0 auto; padding: 48px 20px; }
  h1 { font-size: 17px; letter-spacing: .04em; text-transform: uppercase; color: #f2708a; margin: 0 0 6px; }
  p  { color: #9aa8b2; margin: 0 0 22px; }
  pre {
    background: #0c1013; border: 1px solid #27333c; border-left: 3px solid #f2708a;
    border-radius: 3px; padding: 14px 16px; overflow-x: auto; margin: 0; font-size: 12.5px;
  }
</style>
<div class="wrap">
  <h1>__SRC__ did not parse</h1>
  <p>Fix the file and this page reloads itself.</p>
  <pre>__DETAIL__</pre>
</div>
"""


def esc(text: str) -> str:
    return (str(text).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def document(fragment: str, extra: str = "") -> str:
    """Wrap a generated fragment in a real document.

    The artifact host supplies its own skeleton, so the generated file omits one.
    Served directly it needs a doctype, or the browser renders in quirks mode.
    """
    title = "TideLink known-bug registry"
    match = re.search(r"<title>(.*?)</title>", fragment, re.S)
    if match:
        title = match.group(1).strip()
        fragment = fragment.replace(match.group(0), "", 1)
    return (
        "<!doctype html>\n<html lang=\"en\">\n<head>\n"
        "<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        f"<title>{esc(title)}</title>\n"
        "<style>html { -webkit-text-size-adjust: 100%; }</style>\n"
        "</head>\n<body>\n"
        f"{fragment}\n{extra}</body>\n</html>\n"
    )


class Registry:
    """The YAML on disk, re-read on demand."""

    def __init__(self, src: Path, interval_ms: int, live: bool):
        self.src = src
        self.interval_ms = interval_ms
        self.live = live

    def sha(self) -> str:
        try:
            return hashlib.sha256(self.src.read_bytes()).hexdigest()[:16]
        except OSError:
            return "missing"

    def page(self) -> str:
        version = self.sha()
        try:
            fragment = gen.render(gen.load(self.src))
        except Exception:                                  # noqa: BLE001 - shown in-browser
            fragment = (ERROR_PAGE
                        .replace("__SRC__", esc(self.src.name))
                        .replace("__DETAIL__", esc(traceback.format_exc())))
        extra = ""
        if self.live:
            extra = (LIVE_SNIPPET
                     .replace("__VERSION__", version)
                     .replace("__INTERVAL__", str(self.interval_ms)))
        return document(fragment, extra)

    def version(self) -> dict:
        info = {"sha": self.sha(), "ok": True, "error": None}
        try:
            gen.load(self.src)
        except Exception as exc:                           # noqa: BLE001
            info["ok"] = False
            info["error"] = str(exc).splitlines()[0][:300]
        return info

    def data(self) -> tuple[int, bytes]:
        try:
            payload = gen.load(self.src)
        except Exception as exc:                           # noqa: BLE001
            return 500, json.dumps({"error": str(exc)}).encode()
        return 200, json.dumps(payload, default=gen._jsonable, indent=2).encode()


class Handler(BaseHTTPRequestHandler):
    server_version = "tidelink-bug-registry"
    protocol_version = "HTTP/1.1"

    @property
    def registry(self) -> Registry:
        return self.server.registry            # type: ignore[attr-defined]

    def log_message(self, fmt, *args):
        # Version polling would otherwise bury every real request.
        if self.path.startswith("/api/version"):
            return
        sys.stderr.write("%s  %s\n" % (self.log_date_time_string(), fmt % args))

    def send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):                                     # noqa: N802
        self.do_GET()

    def do_GET(self):                                      # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path == "/":
            self.send(200, self.registry.page().encode(), "text/html; charset=utf-8")
        elif path == "/api/version":
            self.send(200, json.dumps(self.registry.version()).encode(),
                      "application/json; charset=utf-8")
        elif path == "/api/registry.json":
            code, body = self.registry.data()
            self.send(code, body, "application/json; charset=utf-8")
        elif path == "/favicon.ico":
            self.send(200, "🐛".encode(), "text/plain; charset=utf-8")
        else:
            self.send(404, b"not found\n", "text/plain; charset=utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=gen.SRC, help="registry YAML to serve")
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address (default localhost; 0.0.0.0 exposes it on the network)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--interval", type=int, default=1500,
                    help="live-reload poll interval in ms")
    ap.add_argument("--no-live", action="store_true",
                    help="serve without the live-reload/theme control")
    args = ap.parse_args()

    if not args.src.exists():
        print(f"error: {args.src} not found", file=sys.stderr)
        return 2

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.registry = Registry(args.src, args.interval, not args.no_live)  # type: ignore[attr-defined]

    shown = "localhost" if args.host in ("127.0.0.1", "localhost") else args.host
    print(f"serving {args.src} on http://{shown}:{args.port}")
    if args.host == "0.0.0.0":  # noqa: S104 - deliberate, and called out
        print("note: bound to all interfaces — the registry is readable by anyone "
              "who can reach this host")
    print("re-renders on every request; ctrl-c to stop")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

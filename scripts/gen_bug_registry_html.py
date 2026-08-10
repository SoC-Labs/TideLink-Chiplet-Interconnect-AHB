#!/usr/bin/env python3
"""Render the TideLink registries as self-contained browsable pages.

Two living documents, two pages, one stylesheet:

    docs/BUG_REGISTRY.yaml   -> docs/bug_registry.html     (defects)
    docs/BUILD_REGISTRY.yaml -> docs/build_registry.html   (the bytes they ran in)

Both are living (agents advance per-entry status/verification blocks; the
approver owns the sign-off flag), so the pages are generated rather than
hand-maintained.

    python3 scripts/gen_bug_registry_html.py            # -> both pages
    python3 scripts/gen_bug_registry_html.py --watch    # rewrite on every YAML save
    python3 scripts/gen_bug_registry_html.py --check    # non-zero if stale
    python3 scripts/gen_bug_registry_html.py --no-builds # bug page only

The build registry is optional: when docs/BUILD_REGISTRY.yaml is absent the bug
page is written exactly as before and nothing fails.

The output is a single file with no external requests: the YAML is embedded as
JSON and the page builds itself client-side.

For a browsable view that re-renders on request, run scripts/serve_bug_registry.py
instead — no regeneration step at all.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import time
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "docs" / "BUG_REGISTRY.yaml"
OUT = REPO / "docs" / "bug_registry.html"
PLACEHOLDER = "__REGISTRY_JSON__"


TEMPLATE = r"""<title>TideLink Known-Bug Registry</title>
<style>
  /* ---- tokens ------------------------------------------------------------ */
  :root {
    color-scheme: light;
    --bg:        #e9edf0;
    --surface:   #f9fbfc;
    --surface-2: #f1f4f6;
    --ink:       #101a20;
    --ink-mid:   #46555f;
    --ink-dim:   #6d7d88;
    --line:      #ccd6dc;
    --line-soft: #dde4e9;
    --accent:    #0b6e7a;
    --accent-ink:#07515a;
    --accent-bg: #dceef0;

    --sev-crit:  #ad1f3c;
    --sev-high:  #a9650c;
    --sev-med:   #6f6a16;
    --sev-low:   #566571;
    --sev-fyi:   #78838d;

    --st-open:       #a9b6bf;
    --st-root:       #90a7b3;
    --st-fix:        #648e9e;
    --st-sim:        #367d90;
    --st-hw:         #0f6675;
    --st-signed:     #084d59;
    --st-deferred:   #6c5f87;
    --st-wontfix:    #8e99a1;

    /* in-band label ink: group A rides the pale stages, group B the saturated
       ones. The two groups swap ink between themes, so both stay legible. */
    --seg-a: #0b0f13;
    --seg-b: #f7fbfc;

    --ok:      #1c6b4f;
    --ok-bg:   #ddeee6;
    --warn-bg: #f4e8d6;

    --shadow: 0 1px 2px rgba(16, 26, 32, .06), 0 6px 18px -12px rgba(16, 26, 32, .28);

    --mono: ui-monospace, "SFMono-Regular", "JetBrains Mono", "IBM Plex Mono", Menlo, Consolas, "Liberation Mono", monospace;
    --sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      color-scheme: dark;
      --bg:        #0b0f13;
      --surface:   #141b21;
      --surface-2: #1a232a;
      --ink:       #dde5ea;
      --ink-mid:   #a6b4be;
      --ink-dim:   #7d8c97;
      --line:      #27333c;
      --line-soft: #1f2931;
      --accent:    #54c6d2;
      --accent-ink:#8adde6;
      --accent-bg: #10333a;

      --sev-crit:  #f2708a;
      --sev-high:  #e2a251;
      --sev-med:   #c2ba5e;
      --sev-low:   #93a3b0;
      --sev-fyi:   #78868f;

      --st-open:       #3a4750;
      --st-root:       #4f6874;
      --st-fix:        #2f7d90;
      --st-sim:        #3ba0b0;
      --st-hw:         #58c5d1;
      --st-signed:     #8fe3ea;
      --st-deferred:   #9d8fc0;
      --st-wontfix:    #5c686f;

      --seg-a: #dde5ea;
      --seg-b: #08181c;

      --ok:      #63c79b;
      --ok-bg:   #10322a;
      --warn-bg: #33291a;

      --shadow: 0 1px 0 rgba(255, 255, 255, .02), 0 10px 24px -18px rgba(0, 0, 0, .9);
    }
  }

  :root[data-theme="dark"] {
    color-scheme: dark;
    --bg: #0b0f13; --surface: #141b21; --surface-2: #1a232a;
    --ink: #dde5ea; --ink-mid: #a6b4be; --ink-dim: #7d8c97;
    --line: #27333c; --line-soft: #1f2931;
    --accent: #54c6d2; --accent-ink: #8adde6; --accent-bg: #10333a;
    --sev-crit: #f2708a; --sev-high: #e2a251; --sev-med: #c2ba5e; --sev-low: #93a3b0; --sev-fyi: #78868f;
    --st-open: #3a4750; --st-root: #4f6874; --st-fix: #2f7d90; --st-sim: #3ba0b0;
    --st-hw: #58c5d1; --st-signed: #8fe3ea; --st-deferred: #9d8fc0; --st-wontfix: #5c686f;
    --seg-a: #dde5ea; --seg-b: #08181c;
    --ok: #63c79b; --ok-bg: #10322a; --warn-bg: #33291a;
    --shadow: 0 1px 0 rgba(255,255,255,.02), 0 10px 24px -18px rgba(0,0,0,.9);
  }

  :root[data-theme="light"] {
    color-scheme: light;
    --bg: #e9edf0; --surface: #f9fbfc; --surface-2: #f1f4f6;
    --ink: #101a20; --ink-mid: #46555f; --ink-dim: #6d7d88;
    --line: #ccd6dc; --line-soft: #dde4e9;
    --accent: #0b6e7a; --accent-ink: #07515a; --accent-bg: #dceef0;
    --sev-crit: #ad1f3c; --sev-high: #a9650c; --sev-med: #6f6a16; --sev-low: #566571; --sev-fyi: #78838d;
    --st-open: #a9b6bf; --st-root: #90a7b3; --st-fix: #648e9e; --st-sim: #367d90;
    --st-hw: #0f6675; --st-signed: #084d59; --st-deferred: #6c5f87; --st-wontfix: #8e99a1;
    --seg-a: #0b0f13; --seg-b: #f7fbfc;
    --ok: #1c6b4f; --ok-bg: #ddeee6; --warn-bg: #f4e8d6;
    --shadow: 0 1px 2px rgba(16,26,32,.06), 0 6px 18px -12px rgba(16,26,32,.28);
  }

  /* ---- base -------------------------------------------------------------- */
  * { box-sizing: border-box; }

  body {
    margin: 0;
    background: var(--bg);
    color: var(--ink);
    font-family: var(--sans);
    font-size: 15px;
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
  }

  .page {
    max-width: 1160px;
    margin-inline: auto;
    padding: 28px 20px 72px;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }

  a { color: var(--accent-ink); text-decoration-thickness: 1px; text-underline-offset: 2px; }

  :focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
    border-radius: 2px;
  }

  code, .mono { font-family: var(--mono); font-variant-ligatures: none; }

  .eyebrow {
    font-family: var(--mono);
    font-size: 10.5px;
    letter-spacing: .13em;
    text-transform: uppercase;
    color: var(--ink-dim);
  }

  /* ---- masthead ---------------------------------------------------------- */
  .masthead {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    padding-bottom: 15px;
    border-bottom: 1px solid var(--line);
  }
  .masthead h1 {
    font-family: var(--mono);
    font-size: clamp(21px, 3vw, 28px);
    font-weight: 600;
    letter-spacing: -.02em;
    line-height: 1.15;
    margin: 4px 0 3px;
    text-wrap: balance;
  }
  .masthead .lede { margin: 0; color: var(--ink-mid); max-width: 68ch; font-size: 14px; }
  .meta-strip {
    margin-top: 10px;
    display: flex;
    flex-wrap: wrap;
    gap: 4px 22px;
    font-family: var(--mono);
    font-size: 11.5px;
    color: var(--ink-dim);
  }
  .meta-strip b { color: var(--ink-mid); font-weight: 500; }

  /* ---- board ------------------------------------------------------------- */
  .tiles {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(148px, 1fr));
    gap: 1px;
    background: var(--line);
    border: 1px solid var(--line);
    border-radius: 4px;
    overflow: hidden;
  }
  .tile {
    background: var(--surface);
    padding: 13px 14px 12px;
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }
  .tile .num {
    font-family: var(--mono);
    font-size: 27px;
    font-weight: 600;
    line-height: 1;
    font-variant-numeric: tabular-nums;
    letter-spacing: -.02em;
  }
  .tile .cap { font-size: 11.5px; color: var(--ink-mid); line-height: 1.35; }
  .tile.is-alarm .num { color: var(--sev-crit); }
  .tile.is-act .num   { color: var(--sev-high); }
  .tile.is-good .num  { color: var(--ok); }

  .lifecycle { display: flex; flex-direction: column; gap: 8px; }
  .lc-bar {
    display: flex;
    height: 30px;
    border-radius: 3px;
    overflow: hidden;
    border: 1px solid var(--line);
    background: var(--surface);
  }
  .lc-seg {
    border: 0;
    padding: 0;
    cursor: pointer;
    min-width: 26px;
    font-family: var(--mono);
    font-size: 11px;
    font-weight: 600;
    color: var(--seg-fg, #fff);
    font-variant-numeric: tabular-nums;
    transition: filter .12s ease;
  }
  .lc-seg:hover { filter: brightness(1.12); }
  .lc-seg[aria-pressed="true"] { box-shadow: inset 0 0 0 2px var(--ink); }
  .lc-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 6px 16px;
    font-family: var(--mono);
    font-size: 10.5px;
    letter-spacing: .06em;
    text-transform: uppercase;
    color: var(--ink-dim);
  }
  .lc-legend span { display: inline-flex; align-items: center; gap: 6px; }
  .lc-key { width: 9px; height: 9px; border-radius: 1px; flex: none; }

  /* ---- panels ------------------------------------------------------------ */
  .panels { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 14px; }
  .panel {
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: 4px;
    padding: 14px 16px 15px;
    box-shadow: var(--shadow);
  }
  .panel > h2 {
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: .12em;
    text-transform: uppercase;
    color: var(--ink-dim);
    margin: 0 0 10px;
    display: flex;
    align-items: baseline;
    gap: 8px;
  }
  .panel > h2 .n { color: var(--ink); font-size: 13px; font-variant-numeric: tabular-nums; }
  .panel ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 7px; }
  .panel li { font-size: 13.5px; line-height: 1.45; display: flex; gap: 9px; }
  .panel li .idref { flex: none; }

  .idref {
    font-family: var(--mono);
    font-size: 11.5px;
    font-weight: 600;
    color: var(--accent-ink);
    background: var(--accent-bg);
    border: 1px solid transparent;
    border-radius: 2px;
    padding: 1px 5px;
    cursor: pointer;
    text-decoration: none;
  }
  .idref:hover { border-color: var(--accent); }

  details.context {
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: 4px;
    padding: 0 16px;
  }
  details.context > summary {
    cursor: pointer;
    list-style: none;
    padding: 12px 0;
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: .12em;
    text-transform: uppercase;
    color: var(--ink-dim);
    display: flex;
    align-items: center;
    gap: 9px;
  }
  details.context > summary::-webkit-details-marker { display: none; }
  details.context .ctx-body { padding: 0 0 16px; display: flex; flex-direction: column; gap: 12px; }
  details.context p { margin: 0; font-size: 13.5px; color: var(--ink-mid); max-width: 92ch; }

  /* ---- filters ----------------------------------------------------------- */
  .filters {
    position: sticky;
    top: 0;
    z-index: 5;
    background: color-mix(in srgb, var(--bg) 88%, transparent);
    backdrop-filter: blur(8px);
    border: 1px solid var(--line);
    border-radius: 4px;
    padding: 10px 12px;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px 14px;
  }
  .filters input[type="search"] {
    font-family: var(--mono);
    font-size: 12.5px;
    padding: 6px 9px;
    min-width: 210px;
    flex: 1 1 210px;
    color: var(--ink);
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: 3px;
  }
  .filters input[type="search"]::placeholder { color: var(--ink-dim); }
  .fgroup { display: flex; flex-wrap: wrap; gap: 5px; align-items: center; }
  .fgroup > .eyebrow { margin-right: 2px; }

  .toggle {
    font-family: var(--mono);
    font-size: 11px;
    letter-spacing: .04em;
    padding: 4px 8px;
    border-radius: 2px;
    border: 1px solid var(--line);
    background: var(--surface);
    color: var(--ink-mid);
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    transition: background .12s ease, color .12s ease, border-color .12s ease;
  }
  .toggle:hover { border-color: var(--ink-dim); }
  .toggle[aria-pressed="true"] {
    background: var(--ink);
    border-color: var(--ink);
    color: var(--bg);
  }
  .toggle .dot { width: 8px; height: 8px; border-radius: 1px; flex: none; }
  .toggle .n { font-variant-numeric: tabular-nums; opacity: .72; }
  .filters .spacer { flex: 1 1 auto; }
  .filters .count { font-family: var(--mono); font-size: 11.5px; color: var(--ink-dim); font-variant-numeric: tabular-nums; }
  .linkbtn {
    background: none; border: 0; padding: 0; cursor: pointer;
    font-family: var(--mono); font-size: 11px; color: var(--accent-ink);
    text-decoration: underline; text-underline-offset: 2px;
  }

  /* ---- bug cards --------------------------------------------------------- */
  .list { display: flex; flex-direction: column; gap: 8px; }

  .bug {
    background: var(--surface);
    border: 1px solid var(--line);
    border-left: 3px solid var(--sev);
    border-radius: 4px;
    box-shadow: var(--shadow);
  }
  .bug[hidden] { display: none; }
  .bug[open] { background: var(--surface); border-color: var(--ink-dim); }
  .bug > summary {
    cursor: pointer;
    list-style: none;
    padding: 11px 14px;
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    align-items: center;
    gap: 4px 12px;
  }
  .bug > summary::-webkit-details-marker { display: none; }
  .bug > summary:hover .btitle { color: var(--accent-ink); }

  .chev {
    width: 9px; height: 9px; flex: none;
    border-right: 1.5px solid var(--ink-dim);
    border-bottom: 1.5px solid var(--ink-dim);
    transform: rotate(-45deg);
    transition: transform .16s ease;
    margin-left: 2px;
  }
  .bug[open] .chev { transform: rotate(45deg); }

  .bhead { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; min-width: 0; }
  .bid { font-family: var(--mono); font-size: 12px; font-weight: 600; color: var(--sev); letter-spacing: .02em; flex: none; }
  .btitle { font-size: 14.5px; font-weight: 500; line-height: 1.35; }
  .bmeta { grid-column: 2; display: flex; flex-wrap: wrap; gap: 5px; padding-top: 5px; }
  .bstatus { display: flex; align-items: center; gap: 9px; flex: none; }
  .bstatus .slabel {
    font-family: var(--mono); font-size: 10.5px; letter-spacing: .07em;
    text-transform: uppercase; color: var(--st); white-space: nowrap;
  }

  .rail { display: flex; gap: 2px; flex: none; }
  .rail i { width: 13px; height: 5px; border-radius: 1px; background: var(--line); display: block; }
  .rail i.on { background: var(--st); }
  .rail.off i { background: transparent; box-shadow: inset 0 0 0 1px var(--st); }

  .chip {
    font-family: var(--mono);
    font-size: 10.5px;
    letter-spacing: .04em;
    padding: 2px 6px;
    border-radius: 2px;
    border: 1px solid var(--line);
    color: var(--ink-mid);
    background: var(--surface-2);
    white-space: nowrap;
  }
  .chip.k { color: var(--ink-dim); }
  .chip.k b { color: var(--ink-mid); font-weight: 500; }
  .chip.gate { color: var(--ok); border-color: color-mix(in srgb, var(--ok) 40%, var(--line)); background: var(--ok-bg); }
  .chip.hw   { color: var(--ok); border-color: color-mix(in srgb, var(--ok) 40%, var(--line)); background: var(--ok-bg); }
  .chip.net  { color: var(--sev-high); border-color: color-mix(in srgb, var(--sev-high) 40%, var(--line)); background: var(--warn-bg); }
  .chip.sign { color: var(--st-signed); border-color: color-mix(in srgb, var(--st-signed) 45%, var(--line)); background: var(--accent-bg); }

  /* ---- card body --------------------------------------------------------- */
  .body { padding: 4px 14px 18px 14px; display: flex; flex-direction: column; gap: 16px; border-top: 1px solid var(--line-soft); margin-top: 2px; }
  .body > section { display: flex; flex-direction: column; gap: 7px; }
  .body h3 {
    margin: 0;
    font-family: var(--mono);
    font-size: 10.5px;
    letter-spacing: .13em;
    text-transform: uppercase;
    color: var(--ink-dim);
    padding-top: 12px;
    border-top: 1px dashed var(--line-soft);
  }
  .body > section:first-child h3 { padding-top: 4px; border-top: 0; }
  .body p { margin: 0; max-width: 82ch; color: var(--ink-mid); font-size: 13.5px; }
  .body p + p { margin-top: 7px; }
  .body p strong, .body li strong { color: var(--ink); font-weight: 600; }
  .body code {
    font-size: 12px;
    background: var(--surface-2);
    border: 1px solid var(--line-soft);
    border-radius: 2px;
    padding: 0 4px;
    color: var(--ink);
  }
  .body ul { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 7px; }
  .body ul.bul li { position: relative; padding-left: 15px; font-size: 13.5px; color: var(--ink-mid); max-width: 82ch; }
  .body ul.bul li::before {
    content: "";
    position: absolute; left: 2px; top: .62em;
    width: 5px; height: 5px; border-radius: 1px;
    background: var(--ink-dim);
  }
  .body ul.bul.warm li::before { background: var(--sev-high); }
  .body ul.bul.cold li::before { background: var(--st-deferred); }

  .sub { display: flex; flex-direction: column; gap: 5px; }
  .subhead {
    font-family: var(--mono); font-size: 10.5px; letter-spacing: .08em;
    text-transform: uppercase; color: var(--ink-dim);
  }

  .kv { display: grid; grid-template-columns: minmax(96px, max-content) minmax(0, 1fr); gap: 6px 14px; align-items: baseline; }
  .kv dt {
    font-family: var(--mono); font-size: 10.5px; letter-spacing: .08em;
    text-transform: uppercase; color: var(--ink-dim);
  }
  .kv dd { margin: 0; font-size: 13px; color: var(--ink-mid); min-width: 0; }
  .kv dd .mono { font-size: 12px; color: var(--ink); word-break: break-word; }

  .state { display: inline-flex; align-items: center; gap: 6px; font-family: var(--mono); font-size: 12px; }
  .state .dot { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--ink-dim); }
  .state.yes { color: var(--ok); } .state.yes .dot { background: var(--ok); }
  .state.no  { color: var(--ink-dim); } .state.no .dot { background: var(--line); box-shadow: inset 0 0 0 1px var(--ink-dim); }
  .state.part { color: var(--sev-high); } .state.part .dot { background: var(--sev-high); }

  .tags { display: flex; flex-wrap: wrap; gap: 5px; }

  .verdict {
    background: var(--surface-2);
    border: 1px solid var(--line-soft);
    border-left: 2px solid var(--st);
    border-radius: 3px;
    padding: 11px 13px;
  }
  .verdict p { color: var(--ink); }
  .signrow { display: flex; flex-wrap: wrap; align-items: center; gap: 9px; padding-top: 9px; }

  pre.snip {
    margin: 0;
    font-family: var(--mono);
    font-size: 11.5px;
    line-height: 1.5;
    background: var(--surface-2);
    border: 1px solid var(--line);
    border-radius: 3px;
    padding: 10px 12px;
    overflow-x: auto;
    color: var(--ink);
  }
  .scroll-x { overflow-x: auto; max-width: 100%; }

  footer.foot {
    border-top: 1px solid var(--line);
    padding-top: 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    font-size: 12.5px;
    color: var(--ink-dim);
  }
  footer.foot p { margin: 0; max-width: 88ch; }

  .empty { padding: 40px 8px; text-align: center; color: var(--ink-dim); font-family: var(--mono); font-size: 13px; }

  @media (max-width: 720px) {
    .bug > summary { grid-template-columns: auto minmax(0, 1fr); }
    .bstatus { grid-column: 2; padding-top: 6px; }
    .kv { grid-template-columns: minmax(0, 1fr); gap: 2px; }
    .kv dd { margin-bottom: 6px; }
  }

  @media (prefers-reduced-motion: reduce) {
    * { transition: none !important; animation: none !important; }
  }
</style>

<div class="page">
  <header class="masthead">
    <div>
      <div class="eyebrow" id="m-eyebrow"></div>
      <h1>TideLink known-bug registry</h1>
      <p class="lede">Outstanding and recently-resolved bugs on the GPIO&nbsp;PHY&nbsp;V2 chiplet interconnect.
        Agents advance <span class="mono">status</span>, <span class="mono">fix</span> and
        <span class="mono">verification</span>; the approver owns <span class="mono">signoff.approved</span>.</p>
    </div>
    <div class="meta-strip" id="m-meta"></div>
  </header>

  <section class="tiles" id="tiles" aria-label="Registry summary"></section>

  <section class="lifecycle" aria-label="Sign-off lifecycle distribution">
    <div class="eyebrow">Sign-off lifecycle &mdash; where all bugs sit (click a band to filter)</div>
    <div class="lc-bar" id="lc-bar"></div>
    <div class="lc-legend" id="lc-legend"></div>
  </section>

  <section class="panels" id="panels" aria-label="Action queues"></section>

  <details class="context" id="context">
    <summary><span class="chev" aria-hidden="true"></span>Key context &mdash; read before acting on any item</summary>
    <div class="ctx-body" id="ctx-body"></div>
  </details>

  <div class="filters" role="toolbar" aria-label="Filter bugs">
    <input type="search" id="q" placeholder="search id, title, commit, file, verdict…" aria-label="Search registry" />
    <div class="fgroup" id="f-sev" aria-label="Filter by severity"></div>
    <div class="fgroup" id="f-flag" aria-label="Filter by state"></div>
    <span class="spacer"></span>
    <span class="count" id="count"></span>
    <button type="button" class="linkbtn" id="expand-all">expand all</button>
    <button type="button" class="linkbtn" id="reset">reset</button>
  </div>

  <main class="list" id="list"></main>

  <footer class="foot" id="foot"></footer>
</div>

<script id="registry-data" type="application/json">__REGISTRY_JSON__</script>
<script>
(function () {
  "use strict";

  var DATA = JSON.parse(document.getElementById("registry-data").textContent);
  var BUGS = DATA.bugs || [];

  var SEV = {
    rank1_critical: { label: "rank-1 critical", short: "RANK-1", v: "--sev-crit", order: 0 },
    high:           { label: "high",            short: "HIGH",   v: "--sev-high", order: 1 },
    medium:         { label: "medium",          short: "MED",    v: "--sev-med",  order: 2 },
    low:            { label: "low",             short: "LOW",    v: "--sev-low",  order: 3 },
    fyi:            { label: "fyi",             short: "FYI",    v: "--sev-fyi",  order: 4 }
  };

  // The lifecycle is a real progression, so it is drawn as one. deferred/wontfix
  // are not stages on it and are drawn off-ladder.
  var LADDER = ["open", "root_caused", "fix_built", "sim_proven", "hw_proven", "signed_off"];
  var STATUS = {
    open:        { label: "open",        v: "--st-open",     fg: "--seg-a", step: 0, note: "not yet root-caused" },
    root_caused: { label: "root caused", v: "--st-root",     fg: "--seg-a", step: 1, note: "mechanism understood, no working fix yet" },
    fix_built:   { label: "fix built",   v: "--st-fix",      fg: "--seg-a", step: 2, note: "implemented, not yet verified" },
    sim_proven:  { label: "sim proven",  v: "--st-sim",      fg: "--seg-b", step: 3, note: "reproduce-first sim test passes with the fix" },
    hw_proven:   { label: "hw proven",   v: "--st-hw",       fg: "--seg-b", step: 4, note: "verified on the KR260 pair" },
    signed_off:  { label: "signed off",  v: "--st-signed",   fg: "--seg-b", step: 5, note: "approver has signed" },
    deferred:    { label: "deferred",    v: "--st-deferred", fg: "--seg-b", step: -1, note: "needs a decision or a separate workstream" },
    wontfix:     { label: "wontfix",     v: "--st-wontfix",  fg: "--seg-a", step: -1, note: "accepted as-is / out of scope" }
  };

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  // Folded YAML scalars arrive as one long line; blank lines survive as \n\n.
  function prose(text) {
    return String(text || "").trim().split(/\n\s*\n/).map(function (p) {
      var html = esc(p.replace(/\s*\n\s*/g, " ").trim())
        .replace(/`([^`]+)`/g, function (_, c) { return "<code>" + c + "</code>"; })
        .replace(/\b(FIXED|OPEN|DEFERRED|NOT RESOLVED|CONFIRMED|REFUTED|CRITICAL|DONE|LANDED|SUPERSEDED|BLOCKED)\b/g,
                 "<strong>$1</strong>");
      return "<p>" + html + "</p>";
    }).join("");
  }

  var CODEISH = /^(?:[0-9a-f]{7,40}|0x[0-9A-Fa-f_]+|[\w./-]*\.(?:sv|v|py|sh|flist|yaml|yml|tcl|log|md)(?:[:#][\w:.-]+)?|[\w./-]+\/[\w./-]+)$/;
  function isCodeish(s) { return typeof s === "string" && CODEISH.test(s.trim()); }

  function inline(s) {
    if (s === true)  return '<span class="state yes"><i class="dot"></i>yes</span>';
    if (s === false) return '<span class="state no"><i class="dot"></i>no</span>';
    if (s == null)   return '<span class="state no"><i class="dot"></i>none</span>';
    var t = String(s).trim();
    if (/^(n\/a|none|unknown)/i.test(t)) return '<span class="state no"><i class="dot"></i>' + esc(t) + "</span>";
    if (isCodeish(t)) return '<span class="mono">' + esc(t) + "</span>";
    return esc(t).replace(/`([^`]+)`/g, "<code>$1</code>");
  }

  // Evidence entries are typed: commit:<sha>, memory:<file>, or a free claim.
  function evidence(list) {
    if (!list || !list.length) return '<span class="state no"><i class="dot"></i>none recorded</span>';
    return '<div class="tags">' + list.map(function (e) {
      var s = String(e), m = s.match(/^(commit|memory|file|test):(.+)$/);
      if (m) return '<span class="chip k"><b>' + esc(m[1]) + "</b> " + esc(m[2]) + "</span>";
      return '<span class="chip">' + esc(s) + "</span>";
    }).join("") + "</div>";
  }

  function bullets(list, tone) {
    return '<ul class="bul ' + (tone || "") + '">' + list.map(function (i) {
      var html = esc(String(i).replace(/\s*\n\s*/g, " ").trim())
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/^((?:FIX\s*\d|A\d|Cause [AB]|Option [AB]|# Option [AB])[^:(]*)/, "<strong>$1</strong>");
      return "<li>" + html + "</li>";
    }).join("") + "</ul>";
  }

  // Command lists (review_only_commands) belong in a terminal block, not bullets —
  // they are meant to be read and copied verbatim.
  function isCommandList(list) {
    return list.length > 0 && list.every(function (i) {
      return /^\s*(#|git |make |python|source |bash |ssh |sudo )/.test(String(i));
    });
  }

  function section(title, inner) {
    return inner ? "<section><h3>" + esc(title) + "</h3>" + inner + "</section>" : "";
  }

  function statusOf(bug) { return STATUS[bug.status] || STATUS.open; }
  function sevOf(bug) { return SEV[bug.severity] || SEV.fyi; }

  function awaitingSignoff(b) {
    var s = b.status;
    return (s === "sim_proven" || s === "hw_proven") && !(b.signoff && b.signoff.approved);
  }
  function needsDecision(b) {
    return b.status === "deferred" || !!b.decision_needed;
  }

  /* ---- card ------------------------------------------------------------- */
  function rail(bug) {
    var st = statusOf(bug), off = st.step < 0;
    var out = '<span class="rail' + (off ? " off" : "") + '" aria-hidden="true">';
    for (var i = 1; i <= 5; i++) out += "<i" + (!off && st.step >= i ? ' class="on"' : "") + "></i>";
    return out + "</span>";
  }

  function headChips(bug) {
    var v = bug.verification || {}, f = bug.fix || {}, out = [];
    out.push('<span class="chip k"><b>area</b> ' + esc(bug.area || "—") + "</span>");
    if (f.branch) out.push('<span class="chip k"><b>branch</b> ' + esc(f.branch) + "</span>");
    if (f.commit) out.push('<span class="chip k"><b>commit</b> ' + esc(f.commit) + "</span>");
    if (v.in_sim_gate === true) out.push('<span class="chip gate">gated</span>');
    if (v.hw_tested === true) out.push('<span class="chip hw">hw-proven</span>');
    if (f.netlist_affecting === true) out.push('<span class="chip net">netlist</span>');
    if (bug.signoff && bug.signoff.approved) out.push('<span class="chip sign">signed</span>');
    else if (awaitingSignoff(bug)) out.push('<span class="chip sign">awaiting sign-off</span>');
    if (bug.decision_needed) out.push('<span class="chip net">decision needed</span>');
    return out.join("");
  }

  var KNOWN = {
    id: 1, title: 1, severity: 1, area: 1, status: 1, summary: 1, root_cause: 1, fix: 1,
    verification: 1, signoff: 1, related: 1, caveats: 1, action_items: 1, refuted: 1,
    hw_discriminators: 1, decision_needed: 1, closes_when: 1
  };
  var FIX_KNOWN = { approach: 1, candidates: 1, files: 1, commit: 1, branch: 1, netlist_affecting: 1 };

  function fixBlock(f) {
    if (!f) return "";
    var out = "";
    if (f.approach) out += prose(f.approach);
    if (f.candidates && f.candidates.length) out += bullets(f.candidates, "warm");

    // Free-form extras (build_note, naming_note, review_only_commands, …). Prose
    // and lists get a stacked label so they keep the same measure as the body;
    // short scalars fall through to the facts table below.
    var rows = "";
    Object.keys(f).forEach(function (k) {
      if (FIX_KNOWN[k]) return;
      var val = f[k];
      if (val == null) return;
      var label = esc(k.replace(/_/g, " "));
      if (Array.isArray(val) && isCommandList(val)) {
        out += '<div class="sub"><span class="subhead">' + label + '</span><pre class="snip">' +
          esc(val.join("\n")) + "</pre></div>";
      } else if (Array.isArray(val)) {
        out += '<div class="sub"><span class="subhead">' + label + "</span>" + bullets(val) + "</div>";
      } else if (typeof val === "string" && val.length > 90) {
        out += '<div class="sub"><span class="subhead">' + label + "</span>" + prose(val) + "</div>";
      } else {
        rows += "<dt>" + label + "</dt><dd>" + inline(val) + "</dd>";
      }
    });

    if (f.files && f.files.length) {
      rows += "<dt>files</dt><dd>" + f.files.map(function (x) {
        return '<div class="mono">' + esc(x) + "</div>";
      }).join("") + "</dd>";
    }
    if (f.commit) rows += "<dt>commit</dt><dd>" + inline(f.commit) + "</dd>";
    if (f.branch) rows += "<dt>branch</dt><dd>" + inline(f.branch) + "</dd>";
    if ("netlist_affecting" in f) {
      rows += "<dt>netlist</dt><dd>" + (f.netlist_affecting
        ? '<span class="state part"><i class="dot"></i>changes the netlist</span>'
        : '<span class="state no"><i class="dot"></i>no netlist change</span>') + "</dd>";
    }
    if (rows) out += '<dl class="kv">' + rows + "</dl>";
    return out;
  }

  function verifyBlock(v) {
    if (!v) return "";
    var order = ["sim_test", "in_sim_gate", "hw_tested", "hw_evidence"], rows = "";
    var keys = order.filter(function (k) { return k in v; })
      .concat(Object.keys(v).filter(function (k) { return order.indexOf(k) < 0; }));
    keys.forEach(function (k) {
      var val = v[k], body;
      if (k === "in_sim_gate") {
        body = val === true ? '<span class="state yes"><i class="dot"></i>in <span class="mono">make sim_gate</span></span>'
             : val === false ? '<span class="state no"><i class="dot"></i>not gated</span>'
             : '<span class="state part"><i class="dot"></i>' + esc(String(val)) + "</span>";
      } else if (k === "hw_tested") {
        body = val === true ? '<span class="state yes"><i class="dot"></i>proven on the pair</span>'
             : val === false ? '<span class="state no"><i class="dot"></i>not hardware-tested</span>'
             : '<span class="state part"><i class="dot"></i>' + esc(String(val)) + "</span>";
      } else if (typeof val === "string" && val.length > 90) {
        body = prose(val);
      } else {
        body = '<span class="scroll-x">' + inline(val) + "</span>";
      }
      rows += "<dt>" + esc(k.replace(/_/g, " ")) + "</dt><dd>" + body + "</dd>";
    });
    return '<dl class="kv">' + rows + "</dl>";
  }

  function signBlock(bug) {
    var s = bug.signoff || {}, st = statusOf(bug);
    var out = '<div class="verdict" style="--st: var(' + st.v + ')">' +
      (s.claude_verdict ? prose(s.claude_verdict) : "<p>No verdict recorded.</p>") +
      '<div class="signrow">' +
      (s.approved
        ? '<span class="chip sign">approved' + (s.approved_by ? " · " + esc(s.approved_by) : "") +
          (s.approved_date ? " · " + esc(s.approved_date) : "") + "</span>"
        : '<span class="chip">not approved &mdash; approver action required</span>') +
      (!s.approved ? ' <button type="button" class="linkbtn snipbtn" data-id="' + esc(bug.id) + '">sign-off snippet</button>' : "") +
      "</div>" +
      '<pre class="snip" hidden data-snip="' + esc(bug.id) + '"></pre>' +
      "</div>";
    return out + section("Evidence", evidence(s.evidence));
  }

  function card(bug) {
    var st = statusOf(bug), sev = sevOf(bug);
    var el = document.createElement("details");
    el.className = "bug";
    el.id = bug.id;
    el.style.setProperty("--sev", "var(" + sev.v + ")");
    el.style.setProperty("--st", "var(" + st.v + ")");
    el.dataset.sev = bug.severity;
    el.dataset.status = bug.status;
    el.dataset.text = [bug.id, bug.title, bug.area, bug.summary, bug.root_cause,
      JSON.stringify(bug.fix || {}), JSON.stringify(bug.verification || {}),
      JSON.stringify(bug.signoff || {})].join(" ").toLowerCase();
    el.dataset.awaiting = awaitingSignoff(bug) ? "1" : "0";
    el.dataset.gated = (bug.verification && bug.verification.in_sim_gate === true) ? "1" : "0";
    el.dataset.decision = needsDecision(bug) ? "1" : "0";

    var body = "";
    body += section("Summary", bug.summary ? prose(bug.summary) : "");
    body += section("Root cause", bug.root_cause ? prose(bug.root_cause) : "");
    body += section("Fix", fixBlock(bug.fix));
    body += section("Hardware discriminators", bug.hw_discriminators ? bullets(bug.hw_discriminators) : "");
    body += section("Verification", verifyBlock(bug.verification));
    body += section("Caveats", bug.caveats ? bullets(bug.caveats, "warm") : "");
    body += section("Action items", bug.action_items ? bullets(bug.action_items, "warm") : "");
    body += section("Refuted", bug.refuted ? bullets(bug.refuted, "cold") : "");
    body += section("Decision needed", bug.decision_needed ? prose(bug.decision_needed) : "");
    body += section("Closes when", bug.closes_when ? prose(bug.closes_when) : "");
    body += section("Sign-off", signBlock(bug));
    if (bug.related && bug.related.length) {
      body += section("Related", '<div class="tags">' + bug.related.map(function (r) {
        return '<a class="idref" href="#' + esc(r) + '">' + esc(r) + "</a>";
      }).join("") + "</div>");
    }
    Object.keys(bug).forEach(function (k) {
      if (KNOWN[k] || bug[k] == null) return;
      body += section(k.replace(/_/g, " "), Array.isArray(bug[k]) ? bullets(bug[k]) : prose(bug[k]));
    });

    el.innerHTML =
      "<summary>" +
        '<span class="chev" aria-hidden="true"></span>' +
        '<span class="bhead"><span class="bid">' + esc(bug.id) + '</span>' +
        '<span class="btitle">' + esc(bug.title) + "</span></span>" +
        '<span class="bstatus">' + rail(bug) + '<span class="slabel">' + esc(st.label) + "</span></span>" +
        '<span class="bmeta">' + headChips(bug) + "</span>" +
      "</summary>" +
      '<div class="body">' + body + "</div>";
    return el;
  }

  /* ---- board ------------------------------------------------------------ */
  function tile(num, cap, cls) {
    return '<div class="tile ' + (cls || "") + '"><span class="num">' + num + '</span><span class="cap">' + cap + "</span></div>";
  }

  function buildBoard() {
    var openCrit = BUGS.filter(function (b) {
      return b.severity === "rank1_critical" && ["signed_off", "wontfix"].indexOf(b.status) < 0;
    }).length;
    var awaiting = BUGS.filter(awaitingSignoff).length;
    var decisions = BUGS.filter(needsDecision).length;
    var gated = BUGS.filter(function (b) { return b.verification && b.verification.in_sim_gate === true; }).length;
    var hw = BUGS.filter(function (b) { return b.verification && b.verification.hw_tested === true; }).length;

    document.getElementById("tiles").innerHTML =
      tile(BUGS.length, "bugs tracked") +
      tile(openCrit, "rank-1 critical still open", openCrit ? "is-alarm" : "is-good") +
      tile(awaiting, "awaiting sign-off", awaiting ? "is-act" : "") +
      tile(decisions, "awaiting a decision", decisions ? "is-act" : "") +
      tile(gated, "regression-locked in <span class=\"mono\">sim_gate</span>", "is-good") +
      tile(hw, "proven on the KR260 pair", "is-good");

    var counts = {}, order = LADDER.concat(["deferred", "wontfix"]);
    BUGS.forEach(function (b) { counts[b.status] = (counts[b.status] || 0) + 1; });

    var bar = document.getElementById("lc-bar"), legend = document.getElementById("lc-legend");
    bar.innerHTML = ""; legend.innerHTML = "";
    order.forEach(function (k) {
      var n = counts[k] || 0, meta = STATUS[k];
      if (n) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "lc-seg";
        b.style.flexGrow = String(n);
        b.style.background = "var(" + meta.v + ")";
        b.style.setProperty("--seg-fg", "var(" + meta.fg + ")");
        b.textContent = n;
        b.title = meta.label + " — " + meta.note;
        b.setAttribute("aria-pressed", "false");
        b.dataset.status = k;
        b.addEventListener("click", function () { toggleStatus(k); });
        bar.appendChild(b);
      }
      var l = document.createElement("span");
      l.innerHTML = '<i class="lc-key" style="background: var(' + meta.v + ')"></i>' +
        esc(meta.label) + " · " + n;
      if (!n) l.style.opacity = ".45";
      legend.appendChild(l);
    });
  }

  function buildPanels() {
    var c = DATA.campaign || {}, html = "";
    function panel(title, n, items, render) {
      return '<div class="panel"><h2>' + esc(title) + '<span class="n">' + n + "</span></h2><ul>" +
        items.map(render).join("") + "</ul></div>";
    }
    // Entries are "TL-004 …" or "TL-013/014 …" (a coupled pair) — link every id.
    function withId(text) {
      var m = String(text).match(/^(TL-\d+(?:\/\d+)*)\s*[: ]\s*(.*)$/);
      if (!m) return "<li><span>" + esc(text) + "</span></li>";
      var ids = m[1].split("/").map(function (part, i) {
        return i === 0 ? part : "TL-" + part;
      });
      return "<li>" + ids.map(function (id) {
        return '<a class="idref" href="#' + esc(id) + '">' + esc(id) + "</a>";
      }).join("") + "<span>" + esc(m[2].replace(/^[—-]\s*/, "")) + "</span></li>";
    }
    if (c.awaiting_david_signoff) {
      html += panel("Awaiting sign-off", c.awaiting_david_signoff.length, c.awaiting_david_signoff, withId);
    }
    if (c.david_decisions) {
      html += panel("Decisions for the approver", c.david_decisions.length, c.david_decisions, withId);
    }
    document.getElementById("panels").innerHTML = html;

    var ctx = (c.key_context || []).map(function (t) { return prose(t); }).join("");
    if (c.notes) ctx = prose(c.notes) + ctx;
    document.getElementById("ctx-body").innerHTML = ctx || "<p>No campaign context recorded.</p>";
    if (!ctx) document.getElementById("context").hidden = true;

    document.getElementById("m-eyebrow").textContent =
      (c.name || "bug registry") + " · schema v" + (DATA.schema_version || "?");
    document.getElementById("m-meta").innerHTML =
      "<span><b>generated</b> " + esc(DATA.generated || "—") + "</span>" +
      "<span><b>approver</b> " + esc(DATA.approver || "—") + "</span>" +
      "<span><b>maintainer</b> " + esc(DATA.maintainer || "—") + "</span>";

    var p = DATA.signoff_policy || {};
    document.getElementById("foot").innerHTML =
      "<p><b>Sign-off policy.</b> Claude may advance status to <span class=\"mono\">" +
        esc(p.claude_max_status || "hw_proven") + "</span> on evidence; <span class=\"mono\">signed_off</span> " +
        "requires the approver. Anything that changes the netlist on the tapeout trunk, pushes to a public " +
        "default branch, or is a rig/architecture decision is never auto-signed.</p>" +
      "<p>Generated from <span class=\"mono\">docs/BUG_REGISTRY.yaml</span> — the YAML stays the source of truth. " +
        "Regenerate with <span class=\"mono\">python3 scripts/gen_bug_registry_html.py</span> after any edit." +
        "__BUILD_LINK__</p>";
  }

  /* ---- filtering -------------------------------------------------------- */
  var state = { q: "", sev: {}, status: {}, awaiting: false, gated: false, decision: false };

  function buildFilters() {
    var sevCounts = {}, wrap = document.getElementById("f-sev");
    BUGS.forEach(function (b) { sevCounts[b.severity] = (sevCounts[b.severity] || 0) + 1; });
    wrap.innerHTML = '<span class="eyebrow">severity</span>';
    Object.keys(SEV).sort(function (a, b) { return SEV[a].order - SEV[b].order; }).forEach(function (k) {
      if (!sevCounts[k]) return;
      var b = document.createElement("button");
      b.type = "button"; b.className = "toggle"; b.setAttribute("aria-pressed", "false");
      b.dataset.key = k;
      b.innerHTML = '<i class="dot" style="background: var(' + SEV[k].v + ')"></i>' +
        SEV[k].label + ' <span class="n">' + sevCounts[k] + "</span>";
      b.addEventListener("click", function () {
        state.sev[k] = !state.sev[k];
        syncToggles();
        apply();
      });
      wrap.appendChild(b);
    });

    var flags = [
      ["awaiting", "awaiting sign-off"],
      ["decision", "needs a decision"],
      ["gated", "regression-locked"]
    ];
    var fw = document.getElementById("f-flag");
    fw.innerHTML = '<span class="eyebrow">state</span>';
    flags.forEach(function (pair) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "toggle"; b.setAttribute("aria-pressed", "false");
      b.dataset.flag = pair[0];
      b.textContent = pair[1];
      b.addEventListener("click", function () {
        state[pair[0]] = !state[pair[0]];
        syncToggles();
        apply();
      });
      fw.appendChild(b);
    });
  }

  // Single source of truth for control appearance: every control re-reads `state`,
  // so restoring state after a live reload needs no per-control bookkeeping.
  function syncToggles() {
    document.querySelectorAll("[data-key]").forEach(function (b) {
      b.setAttribute("aria-pressed", state.sev[b.dataset.key] ? "true" : "false");
    });
    document.querySelectorAll("[data-flag]").forEach(function (b) {
      b.setAttribute("aria-pressed", state[b.dataset.flag] ? "true" : "false");
    });
    document.querySelectorAll(".lc-seg").forEach(function (b) {
      b.setAttribute("aria-pressed", state.status[b.dataset.status] ? "true" : "false");
    });
    document.getElementById("q").value = state.q;
  }

  function toggleStatus(k) {
    state.status[k] = !state.status[k];
    syncToggles();
    apply();
  }

  function apply() {
    var anySev = Object.keys(state.sev).some(function (k) { return state.sev[k]; });
    var anyStatus = Object.keys(state.status).some(function (k) { return state.status[k]; });
    var shown = 0;
    document.querySelectorAll(".bug").forEach(function (el) {
      var ok = true;
      if (anySev && !state.sev[el.dataset.sev]) ok = false;
      if (anyStatus && !state.status[el.dataset.status]) ok = false;
      if (state.awaiting && el.dataset.awaiting !== "1") ok = false;
      if (state.gated && el.dataset.gated !== "1") ok = false;
      if (state.decision && el.dataset.decision !== "1") ok = false;
      if (ok && state.q && el.dataset.text.indexOf(state.q) < 0) ok = false;
      el.hidden = !ok;
      if (ok) shown++;
    });
    document.getElementById("count").textContent = shown + " / " + BUGS.length + " shown";
    document.getElementById("empty").hidden = shown > 0;
  }

  /* ---- wire up ---------------------------------------------------------- */
  var list = document.getElementById("list");
  BUGS.slice().sort(function (a, b) {
    var d = sevOf(a).order - sevOf(b).order;
    return d || String(a.id).localeCompare(String(b.id));
  }).forEach(function (b) { list.appendChild(card(b)); });

  var empty = document.createElement("div");
  empty.className = "empty"; empty.id = "empty"; empty.hidden = true;
  empty.textContent = "no bugs match these filters";
  list.appendChild(empty);

  buildBoard();
  buildPanels();
  buildFilters();
  apply();

  document.getElementById("q").addEventListener("input", function (e) {
    state.q = e.target.value.trim().toLowerCase();
    apply();
  });

  document.getElementById("expand-all").addEventListener("click", function (e) {
    var opening = e.target.textContent === "expand all";
    document.querySelectorAll(".bug").forEach(function (d) { if (!d.hidden) d.open = opening; });
    e.target.textContent = opening ? "collapse all" : "expand all";
  });

  document.getElementById("reset").addEventListener("click", function () {
    state = { q: "", sev: {}, status: {}, awaiting: false, gated: false, decision: false };
    syncToggles();
    apply();
  });

  // Sign-off snippet: the exact YAML block to paste back into the registry.
  list.addEventListener("click", function (e) {
    var btn = e.target.closest(".snipbtn");
    if (!btn) return;
    e.preventDefault();
    var pre = list.querySelector('pre[data-snip="' + btn.dataset.id + '"]');
    if (!pre.textContent) {
      var d = new Date(), pad = function (n) { return String(n).padStart(2, "0"); };
      pre.textContent =
        "# docs/BUG_REGISTRY.yaml — " + btn.dataset.id + "\n" +
        "    signoff:\n" +
        "      approved: true\n" +
        "      approved_by: " + (DATA.approver || "").replace(/\s*<.*>$/, "") + "\n" +
        "      approved_date: " + d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "\n";
    }
    pre.hidden = !pre.hidden;
    btn.textContent = pre.hidden ? "sign-off snippet" : "hide snippet";
  });

  function openHash() {
    var id = decodeURIComponent(location.hash.slice(1));
    if (!id) return;
    var el = document.getElementById(id);
    if (el && el.classList.contains("bug")) {
      el.hidden = false;
      el.open = true;
      el.scrollIntoView({ block: "start", behavior: "smooth" });
    }
  }
  window.addEventListener("hashchange", openHash);
  openHash();

  // Read/replay the whole view. The dev server uses this to carry filters, open
  // cards and scroll position across a live reload when the YAML changes.
  window.TLRegistry = {
    generated: DATA.generated || null,
    state: function () {
      return {
        q: state.q, sev: state.sev, status: state.status,
        awaiting: state.awaiting, gated: state.gated, decision: state.decision,
        open: Array.prototype.map.call(document.querySelectorAll(".bug[open]"),
                                       function (d) { return d.id; }),
        scroll: window.scrollY
      };
    },
    restore: function (s) {
      if (!s) return;
      state.q = s.q || "";
      state.sev = s.sev || {};
      state.status = s.status || {};
      state.awaiting = !!s.awaiting;
      state.gated = !!s.gated;
      state.decision = !!s.decision;
      syncToggles();
      apply();
      (s.open || []).forEach(function (id) {
        var el = document.getElementById(id);
        if (el && el.classList.contains("bug")) el.open = true;
      });
      if (typeof s.scroll === "number") {
        requestAnimationFrame(function () { window.scrollTo(0, s.scroll); });
      }
    }
  };
})();
</script>
"""


# --------------------------------------------------------------------------- #
# Build registry — a second page from the same tokens.
#
# docs/BUG_REGISTRY.yaml tracks defects; docs/BUILD_REGISTRY.yaml tracks the
# BYTES they were seen in (which bitstream ran on which board, from which commit,
# with which parameters, and what was actually proven). The two are read
# together, so the build page reuses this page's stylesheet verbatim — it is
# lifted out of TEMPLATE rather than copied, so the two can never drift.
#
# The build registry is optional: if the YAML is absent, only the bug page is
# written and nothing fails.
# --------------------------------------------------------------------------- #
BUILD_SRC = REPO / "docs" / "BUILD_REGISTRY.yaml"
BUILD_OUT = REPO / "docs" / "build_registry.html"
BUILD_PLACEHOLDER = "__BUILD_JSON__"
STYLE_SLOT = "__SHARED_STYLE__"

_STYLE_RE = re.compile(r"<style>.*?</style>", re.S)


def shared_style() -> str:
    """The bug page's <style> block, so the build page cannot drift from it."""
    match = _STYLE_RE.search(TEMPLATE)
    if not match:
        raise RuntimeError("bug-registry template has no <style> block to share")
    return match.group(0)


BUILD_TEMPLATE = r"""<title>TideLink Build Registry</title>
__SHARED_STYLE__
<style>
  /* Build-page additions only. Everything else is the bug page's stylesheet. */
  .hero {
    background: var(--surface);
    border: 1px solid var(--line);
    border-left: 3px solid var(--ok);
    border-radius: 4px;
    box-shadow: var(--shadow);
    padding: 15px 16px;
    display: flex;
    flex-direction: column;
    gap: 9px;
  }
  .hero h2 { margin: 0; font-size: 15px; font-weight: 600; }
  .hero p  { margin: 0; max-width: 88ch; color: var(--ink-mid); font-size: 13.5px; }
  .hero .tags { margin-top: 2px; }
  .unknown { color: var(--ink-dim); font-family: var(--mono); font-size: 12px; font-style: italic; }
  .kv dd .tags { margin-top: 1px; }
  .warnrow {
    background: var(--warn-bg);
    border: 1px solid color-mix(in srgb, var(--sev-high) 40%, var(--line));
    border-radius: 3px;
    padding: 8px 11px;
    font-size: 13px;
    color: var(--ink-mid);
    max-width: 88ch;
  }
</style>

<div class="page">
  <header class="masthead">
    <div>
      <div class="eyebrow" id="m-eyebrow"></div>
      <h1>TideLink build registry</h1>
      <p class="lede">Which bitstream ran on which board, built from which commit, with which
        parameters, and what was actually proven. A new entry is appended on every deploy and
        promoted to <span class="mono">hw_validated</span> only when a named, retained artefact
        proves it.</p>
    </div>
    <div class="meta-strip" id="m-meta"></div>
  </header>

  <section class="tiles" id="tiles" aria-label="Registry summary"></section>

  <section id="hero" aria-label="Last known-good build"></section>

  <details class="context" id="mech">
    <summary><span class="chev" aria-hidden="true"></span>What the build manifest records &mdash; and what it does not</summary>
    <div class="ctx-body" id="mech-body"></div>
  </details>

  <div class="filters" role="toolbar" aria-label="Filter builds">
    <input type="search" id="q" placeholder="search id, target, sha, board, hash…" aria-label="Search builds" />
    <div class="fgroup" id="f-status" aria-label="Filter by status"></div>
    <div class="fgroup" id="f-prov" aria-label="Filter by provenance"></div>
    <span class="spacer"></span>
    <span class="count" id="count"></span>
    <button type="button" class="linkbtn" id="expand-all">expand all</button>
    <button type="button" class="linkbtn" id="reset">reset</button>
  </div>

  <main class="list" id="list"></main>

  <footer class="foot" id="foot"></footer>
</div>

<script id="build-data" type="application/json">__BUILD_JSON__</script>
<script>
(function () {
  "use strict";

  var DATA   = JSON.parse(document.getElementById("build-data").textContent);
  var BUILDS = DATA.builds || [];

  var STATUS = {
    hw_validated: { label: "hw validated", v: "--st-hw",      order: 0, note: "a named retained artefact proves a hardware result" },
    deployed:     { label: "deployed",     v: "--st-sim",     order: 1, note: "flashed to a board; results claimed, not evidenced" },
    built:        { label: "built",        v: "--st-fix",     order: 2, note: "bitstream exists; never recorded as flashed" },
    superseded:   { label: "superseded",   v: "--st-wontfix", order: 3, note: "replaced by a later build of the same target" },
    known_bad:    { label: "known bad",    v: "--sev-crit",   order: 4, note: "hardware showed this build broken" }
  };

  var PROV = {
    full:              { label: "full",              v: "--ok",        note: "clean tree, hash recomputable, commit fetchable" },
    partial:           { label: "partial",           v: "--sev-high",  note: "dirty tree, unreachable commit, or bytes gone" },
    sha_unrecoverable: { label: "sha unrecoverable", v: "--sev-crit",  note: "source commit never recorded — A/B control only, never a version datapoint" }
  };

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function prose(text) {
    return String(text || "").trim().split(/\n\s*\n/).map(function (p) {
      var html = esc(p.replace(/\s*\n\s*/g, " ").trim())
        .replace(/`([^`]+)`/g, function (_, c) { return "<code>" + c + "</code>"; })
        .replace(/\b(NOT|NEVER|ONLY|UNKNOWN|DIFFERENT|BYTE-IDENTICAL|WARNING)\b/g, "<strong>$1</strong>");
      return "<p>" + html + "</p>";
    }).join("");
  }

  var CODEISH = /^(?:[0-9a-f]{7,64}|0x[0-9A-Fa-f_]+|[\w./{},~+-]*\.(?:sv|v|py|sh|flist|yaml|yml|tcl|log|json|bit|bin|md)(?:[:#][\w:.-]+)?|[\w./~-]+\/[\w./{},~-]*)$/;

  // "unknown" is the whole point of this registry: it means the field was never
  // recorded at build time, not that nobody looked. It gets its own treatment.
  function inline(s) {
    if (s === true)  return '<span class="state yes"><i class="dot"></i>yes</span>';
    if (s === false) return '<span class="state no"><i class="dot"></i>no</span>';
    if (s == null)   return '<span class="unknown">not recorded</span>';
    var t = String(s).trim();
    if (/^(unknown|none|n\/a|-)$/i.test(t)) return '<span class="unknown">' + esc(t) + " &mdash; not recorded at build time</span>";
    if (CODEISH.test(t)) return '<span class="mono">' + esc(t) + "</span>";
    return esc(t).replace(/`([^`]+)`/g, "<code>$1</code>");
  }

  function chips(list) {
    return '<div class="tags">' + list.map(function (c) {
      return '<span class="chip">' + esc(c) + "</span>";
    }).join("") + "</div>";
  }

  function bullets(list, tone) {
    return '<ul class="bul ' + (tone || "") + '">' + list.map(function (i) {
      return "<li>" + esc(String(i).replace(/\s*\n\s*/g, " ").trim())
        .replace(/`([^`]+)`/g, "<code>$1</code>")
        .replace(/\b(NOT|NEVER|ONLY|DIFFERENT|BYTE-IDENTICAL)\b/g, "<strong>$1</strong>") + "</li>";
    }).join("") + "</ul>";
  }

  function isLong(v) { return typeof v === "string" && (v.length > 130 || /\s\s/.test(v)); }

  // One value, rendered by shape: long prose as paragraphs, lists as bullets or
  // chips, nested maps as a nested kv block.
  function value(v) {
    if (Array.isArray(v)) {
      if (!v.length) return '<span class="unknown">none</span>';
      return v.some(isLong) ? bullets(v) : chips(v.map(String));
    }
    if (v && typeof v === "object") return kv(v);
    if (isLong(v)) return prose(v);
    return inline(v);
  }

  function kv(obj) {
    var rows = Object.keys(obj).map(function (k) {
      return "<dt>" + esc(k.replace(/_/g, " ")) + "</dt><dd>" + value(obj[k]) + "</dd>";
    });
    return rows.length ? '<dl class="kv">' + rows.join("") + "</dl>"
                       : '<span class="unknown">empty</span>';
  }

  function section(title, html) {
    return html ? "<section><h3>" + esc(title) + "</h3>" + html + "</section>" : "";
  }

  function statusOf(b) { return STATUS[b.status] || STATUS.built; }
  function provOf(b)   { return PROV[b.provenance] || PROV.partial; }

  // ---- search index: everything a reader might paste in, including hashes ----
  function haystack(b) {
    return JSON.stringify(b).toLowerCase();
  }

  function card(b) {
    var st = statusOf(b), pv = provOf(b);
    var src = b.source || {}, bd = b.build || {}, bs = b.bitstream || {}, val = b.validation || {};

    var head =
      '<summary><div class="bhead">' +
        '<span class="bid">' + esc(b.id) + "</span>" +
        '<span class="btitle">' + esc(bd.fpga_target || bd.asic_flow || "unknown target") +
          ' <span class="mono" style="color:var(--ink-dim)">' + esc(String(b.date || "")) + "</span></span>" +
      "</div>" +
      '<div class="bstatus">' +
        '<span class="chip">' + esc(pv.label) + "</span>" +
        '<span class="slabel">' + esc(st.label) + "</span>" +
      "</div>" +
      '<div class="bmeta">' +
        (src.git_sha ? '<span class="chip k"><b>sha</b> ' + esc(String(src.git_sha).slice(0, 12)) + "</span>" : "") +
        (src.git_dirty === true ? '<span class="chip net">dirty</span>' : "") +
        (bd.phy ? '<span class="chip k"><b>phy</b> ' + esc(bd.phy) + "</span>" : "") +
        (bs.retained === true ? '<span class="chip">bytes on disk</span>' : '<span class="chip net">bytes gone</span>') +
        ((val.evidence_class && val.evidence_class !== "none")
          ? '<span class="chip k"><b>evidence</b> ' + esc(val.evidence_class) + "</span>"
          : '<span class="chip net">no evidence</span>') +
      "</div></summary>";

    var body = '<div class="body">' +
      section("Source", kv(src)) +
      section("Dependencies", b.submodule_pins ? value(b.submodule_pins) : "") +
      section("Build", kv(bd)) +
      section("Parameters", b.key_parameters ? value(b.key_parameters) : "") +
      section("Build environment", b.build_env ? value(b.build_env) : "") +
      section("Bitstream", kv(bs)) +
      section("Hardware", kv({
        boards: b.boards, rig: b.rig, deployments: b.deployments
      })) +
      section("Validation", kv(val)) +
      section("Known bad", (b.known_bad && b.known_bad.length) ? bullets(b.known_bad, "warm") : "") +
      section("Actions", (b.actions && b.actions.length) ? bullets(b.actions) : "") +
      section("Notes", b.notes ? prose(b.notes) : "") +
      section("Sign-off", b.signoff ? kv(b.signoff) : "") +
    "</div>";

    return '<details class="bug" id="' + esc(b.id) + '" style="--sev: var(' + st.v + '); --st: var(' + st.v + ')">' +
           head + body + "</details>";
  }

  // ---- summary ---------------------------------------------------------- //
  var counts = {
    total: BUILDS.length,
    hw: BUILDS.filter(function (b) { return b.status === "hw_validated"; }).length,
    unrec: BUILDS.filter(function (b) { return b.provenance === "sha_unrecoverable"; }).length,
    dirty: BUILDS.filter(function (b) { return (b.source || {}).git_dirty === true; }).length,
    bytes: BUILDS.filter(function (b) { return (b.bitstream || {}).retained === true; }).length,
    artefact: BUILDS.filter(function (b) { return (b.validation || {}).evidence_class === "retained_artifact"; }).length
  };

  document.getElementById("tiles").innerHTML = [
    ['<div class="tile"><div class="num">' + counts.total + '</div><div class="cap">builds registered</div></div>'],
    ['<div class="tile is-good"><div class="num">' + counts.hw + '</div><div class="cap">hw&nbsp;validated &mdash; a retained artefact proves it</div></div>'],
    ['<div class="tile is-alarm"><div class="num">' + counts.unrec + '</div><div class="cap">source commit unrecoverable</div></div>'],
    ['<div class="tile is-act"><div class="num">' + counts.dirty + '</div><div class="cap">built from a dirty tree (diff never captured)</div></div>'],
    ['<div class="tile"><div class="num">' + counts.bytes + '</div><div class="cap">bitstreams still on disk</div></div>'],
    ['<div class="tile is-act"><div class="num">' + counts.artefact + '</div><div class="cap">with a retained test artefact</div></div>']
  ].join("");

  var meta = [];
  if (DATA.generated) meta.push(["generated", DATA.generated]);
  if (DATA.schema_version != null) meta.push(["schema", "v" + DATA.schema_version]);
  if (DATA.companion) meta.push(["companion", DATA.companion]);
  document.getElementById("m-meta").innerHTML = meta.map(function (m) {
    return '<span class="chip k"><b>' + esc(m[0]) + "</b> " + esc(m[1]) + "</span>";
  }).join("");
  document.getElementById("m-eyebrow").textContent = "docs/BUILD_REGISTRY.yaml";

  var roll = DATA.rollup || {};
  var lkg = BUILDS.filter(function (b) { return b.id === roll.last_known_good; })[0];
  document.getElementById("hero").innerHTML =
    '<div class="hero">' +
      '<div class="eyebrow">Last known-good build</div>' +
      "<h2>" + esc(roll.last_known_good || "none recorded") + "</h2>" +
      (roll.headline ? prose(roll.headline) : "") +
      (lkg ? '<div class="tags">' +
        '<span class="chip k"><b>commit</b> ' + esc((lkg.source || {}).git_sha || "unknown") + "</span>" +
        '<span class="chip k"><b>bit sha256</b> ' + esc((lkg.bitstream || {}).bit_sha256 || "unknown") + "</span>" +
        '<span class="chip k"><b>usr_access</b> ' + esc((lkg.bitstream || {}).usr_access || "unknown") + "</span>" +
      "</div>" : "") +
      ((roll.caveats && roll.caveats.length) ? bullets(roll.caveats, "warm") : "") +
    "</div>";

  var mech = DATA.manifest_mechanism || {};
  document.getElementById("mech-body").innerHTML =
    kv({ schema: mech.schema, writer: mech.writer, call_site: mech.call_site }) +
    (mech.records ? '<div class="sub"><div class="subhead">records</div>' + value(mech.records) + "</div>" : "") +
    (mech.does_not_record ? '<div class="sub"><div class="subhead">does not record</div>' + bullets(mech.does_not_record, "warm") + "</div>" : "") +
    (mech.traps ? '<div class="sub"><div class="subhead">traps</div>' + value(mech.traps) + "</div>" : "");

  // ---- filters ----------------------------------------------------------- //
  var state = { q: "", status: {}, prov: {} };
  var list = document.getElementById("list");

  list.innerHTML = BUILDS.map(card).join("") || '<div class="empty">no builds registered</div>';

  function group(el, map, key, tally) {
    el.innerHTML = '<span class="eyebrow">' + (key === "status" ? "status" : "provenance") + "</span>" +
      Object.keys(map).map(function (k) {
        var n = tally[k] || 0;
        return '<button type="button" class="toggle" data-k="' + key + '" data-v="' + k + '"' +
               ' aria-pressed="false" title="' + esc(map[k].note) + '">' +
               '<i class="dot" style="background: var(' + map[k].v + ')"></i>' +
               esc(map[k].label) + ' <span class="n">' + n + "</span></button>";
      }).join("");
  }

  function tally(field) {
    var out = {};
    BUILDS.forEach(function (b) { out[b[field]] = (out[b[field]] || 0) + 1; });
    return out;
  }

  group(document.getElementById("f-status"), STATUS, "status", tally("status"));
  group(document.getElementById("f-prov"), PROV, "prov", tally("provenance"));

  function apply() {
    var shown = 0;
    BUILDS.forEach(function (b) {
      var el = document.getElementById(b.id);
      if (!el) return;
      var okS = !Object.keys(state.status).length || state.status[b.status];
      var okP = !Object.keys(state.prov).length || state.prov[b.provenance];
      var okQ = !state.q || haystack(b).indexOf(state.q) !== -1;
      var vis = okS && okP && okQ;
      el.hidden = !vis;
      if (vis) shown++;
    });
    document.getElementById("count").textContent = shown + " / " + BUILDS.length + " builds";
  }

  function syncToggles() {
    Array.prototype.forEach.call(document.querySelectorAll(".toggle"), function (t) {
      var bag = t.dataset.k === "status" ? state.status : state.prov;
      t.setAttribute("aria-pressed", bag[t.dataset.v] ? "true" : "false");
    });
  }

  document.addEventListener("click", function (e) {
    var t = e.target.closest(".toggle");
    if (!t) return;
    var bag = t.dataset.k === "status" ? state.status : state.prov;
    if (bag[t.dataset.v]) delete bag[t.dataset.v]; else bag[t.dataset.v] = true;
    syncToggles();
    apply();
  });

  document.getElementById("q").addEventListener("input", function (e) {
    state.q = e.target.value.trim().toLowerCase();
    apply();
  });

  document.getElementById("expand-all").addEventListener("click", function () {
    var any = !!list.querySelector(".bug:not([hidden]):not([open])");
    Array.prototype.forEach.call(list.querySelectorAll(".bug:not([hidden])"), function (d) { d.open = any; });
    this.textContent = any ? "collapse all" : "expand all";
  });

  document.getElementById("reset").addEventListener("click", function () {
    state = { q: "", status: {}, prov: {} };
    document.getElementById("q").value = "";
    syncToggles();
    apply();
  });

  document.getElementById("foot").innerHTML =
    "Generated from <span class=\"mono\">docs/BUILD_REGISTRY.yaml</span>. " +
    "A field shown as <span class=\"unknown\">unknown</span> was not recorded at build time &mdash; " +
    "the YAML carries the reason as a comment on each such line. " +
    "Defects live in the companion <a href=\"bug_registry.html\">known-bug registry</a>.";

  apply();

  function openHash() {
    var id = decodeURIComponent(location.hash.slice(1));
    if (!id) return;
    var el = document.getElementById(id);
    if (el && el.classList.contains("bug")) {
      el.hidden = false;
      el.open = true;
      el.scrollIntoView({ block: "start", behavior: "smooth" });
    }
  }
  window.addEventListener("hashchange", openHash);
  openHash();
})();
</script>
"""


def _jsonable(obj):
    """YAML gives back date/datetime for unquoted dates; emit them as ISO strings."""
    if isinstance(obj, (datetime.date, datetime.datetime)):
        return obj.isoformat()
    raise TypeError(f"cannot serialise {type(obj).__name__} to JSON")


def render(data: dict, build_link: bool = True) -> str:
    payload = json.dumps(data, ensure_ascii=False, sort_keys=False, default=_jsonable)
    # Keep the JSON island from ever terminating its own <script> element.
    payload = payload.replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    # The cross-link is only emitted when there is a build page to link to, so a
    # repo without docs/BUILD_REGISTRY.yaml never grows a dangling link. The
    # fragment lands inside a double-quoted JS string.
    link = (" The bitstreams these defects were seen in are in the companion "
            "<a href=\\\"build_registry.html\\\">build registry</a>."
            if build_link and BUILD_SRC.exists() else "")
    return TEMPLATE.replace(PLACEHOLDER, payload).replace("__BUILD_LINK__", link)


def load(src: Path) -> dict:
    """Parse the registry, rejecting anything that is not a bug list."""
    with src.open() as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict) or "bugs" not in data:
        raise ValueError(f"{src} has no top-level `bugs` list")
    return data


def render_builds(data: dict) -> str:
    payload = json.dumps(data, ensure_ascii=False, sort_keys=False, default=_jsonable)
    payload = payload.replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    return (BUILD_TEMPLATE
            .replace(STYLE_SLOT, shared_style())
            .replace(BUILD_PLACEHOLDER, payload))


def load_builds(src: Path) -> dict:
    """Parse the build registry, rejecting anything that is not a build list."""
    with src.open() as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict) or "builds" not in data:
        raise ValueError(f"{src} has no top-level `builds` list")
    return data


def build(src: Path, out: Path) -> str:
    data = load(src)
    html = render(data)
    out.write_text(html)
    print(f"wrote {out} — {len(data['bugs'])} bugs, {len(html):,} bytes")
    return html


def build_builds(src: Path, out: Path) -> str | None:
    """Write the build-registry page. A missing registry is not an error."""
    if not src.exists():
        print(f"skipped {out.name} — {src} not present")
        return None
    data = load_builds(src)
    html = render_builds(data)
    out.write_text(html)
    validated = sum(1 for b in data["builds"] if b.get("status") == "hw_validated")
    print(f"wrote {out} — {len(data['builds'])} builds "
          f"({validated} hw_validated), {len(html):,} bytes")
    return html


def watch(pairs: list[tuple[Path, Path, "object"]], interval: float = 1.0) -> int:
    """Rebuild whenever a watched YAML changes. A bad edit is reported, not fatal.

    `pairs` is (src, out, builder); each builder has the (src, out) signature of
    build() / build_builds().
    """
    print("watching " + ", ".join(str(p[0]) for p in pairs) + " (ctrl-c to stop)")
    last: dict[Path, object] = {}
    while True:
        for src, out, builder in pairs:
            try:
                stamp = src.stat().st_mtime_ns
            except FileNotFoundError:
                stamp = None
            if last.get(src, "init") != stamp:
                last[src] = stamp
                try:
                    builder(src, out)
                except Exception as exc:                  # noqa: BLE001 - keep watching
                    print(f"error: {exc}", file=sys.stderr)
        time.sleep(interval)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", type=Path, default=SRC)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--builds-src", type=Path, default=BUILD_SRC,
                    help="build registry YAML (skipped silently if absent)")
    ap.add_argument("--builds-out", type=Path, default=BUILD_OUT)
    ap.add_argument("--no-builds", action="store_true",
                    help="render the bug registry only")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if an output is missing or stale (for CI)")
    ap.add_argument("--watch", action="store_true",
                    help="rebuild on every change to a registry YAML")
    args = ap.parse_args()

    pairs = [(args.src, args.out, build)]
    if not args.no_builds:
        pairs.append((args.builds_src, args.builds_out, build_builds))

    if args.watch:
        try:
            return watch(pairs)
        except KeyboardInterrupt:
            print("\nstopped")
            return 0

    try:
        data = load(args.src)
        builds = load_builds(args.builds_src) if (
            not args.no_builds and args.builds_src.exists()) else None
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.check:
        stale = []
        wanted = [(args.out, render(data))]
        if builds is not None:
            wanted.append((args.builds_out, render_builds(builds)))
        for out, html in wanted:
            current = out.read_text() if out.exists() else None
            if current != html:
                stale.append(out)
        if stale:
            for out in stale:
                print(f"stale: {out} does not match its registry — "
                      f"run python3 {Path(__file__).relative_to(REPO)}", file=sys.stderr)
            return 1
        print("up to date: " + ", ".join(str(o) for o, _ in wanted))
        return 0

    build(args.src, args.out)
    if not args.no_builds:
        build_builds(args.builds_src, args.builds_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

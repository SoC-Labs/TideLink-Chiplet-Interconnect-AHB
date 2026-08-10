# TideLink documentation site

Sphinx + MyST-Markdown source for the TideLink ReadTheDocs site. Pages are
written in Markdown (`.md`), parsed by `myst-parser`.

This directory is **not** the engineering record — that stays in `../docs/`.
The site cites those documents and the RTL by path and line.

## Building locally

From the repository root:

```bash
python3 -m pip install -r docs_site/requirements.txt
python3 -m sphinx -b html docs_site docs_site/_build/html
```

Then open `docs_site/_build/html/index.html`.

Notes:

- Python **3.11** is what ReadTheDocs uses; anything ≥ 3.9 will build locally.
- A virtualenv is recommended so the doc dependencies do not collide with the
  verification environment that `set_env.sh` sets up:

  ```bash
  python3 -m venv .venv-docs
  . .venv-docs/bin/activate
  python3 -m pip install -r docs_site/requirements.txt
  python3 -m sphinx -b html docs_site docs_site/_build/html
  ```

- `sourcing ./set_env.sh` is **not** required to build the docs. It is required
  for everything else in this repository, but the doc build touches no EDA tool.
- To treat warnings as errors while editing (useful before opening an MR):

  ```bash
  python3 -m sphinx -b html -W --keep-going docs_site docs_site/_build/html
  ```

- Build output lands in `docs_site/_build/`, which is git-ignored
  (`docs_site/.gitignore`). Do not commit it.

## How ReadTheDocs builds it

ReadTheDocs reads `/.readthedocs.yaml` at the repository root:

| Setting | Value |
|---|---|
| Builder image | `ubuntu-22.04` |
| Python | `3.11` |
| Sphinx configuration | `docs_site/conf.py` |
| Dependencies | `docs_site/requirements.txt` |
| Formats | `htmlzip` (HTML is always produced; PDF is deliberately not requested) |
| `fail_on_warning` | `false` |

PDF output is off on purpose: it pulls the full LaTeX toolchain, and the wide
register and parameter tables in this site make `latexmk` failures likely enough
that they would break otherwise-good builds. Turn it on only after checking a
PDF build locally.

## Conventions for authors

- **Cite everything.** A claim about behaviour gets a file path and line, a
  commit SHA, or a log line. If you cannot ground it, write `UNVERIFIED`
  explicitly. Never invent a measurement.
- **RTL wins over docs.** Several documents in `../docs/` are older than the
  RTL they describe. Where they disagree, document the RTL and add a short
  note naming the divergence.
- **Hazards get an admonition**, not a sentence in a paragraph. Use
  `:::{danger}` for anything that can wedge a board or hang a CPU, and
  `:::{warning}` for anything that produces silently wrong results.
- **Diagrams** use `sphinxcontrib-mermaid` via a ```` ```{mermaid} ```` fence.
  It is configured for client-side rendering, so no node toolchain is needed.
- **Cross-reference with `{doc}`**, e.g. ``{doc}`register_map` ``, so the
  toctree and the links stay consistent.

## Pages

All 14 toctree pages are written; there are no stubs left. `index.md` is the
root document and `README.md` (this file) is deliberately outside the toctree
via `exclude_patterns` in `conf.py`.

| Section | Pages |
|---|---|
| Introduction | `overview.md`, `architecture.md`, `functionality.md` |
| Integration | `register_map.md`, `integration.md`, `parameters.md` |
| Verification | `verification.md`, `simulation_tests.md`, `hardware_tests.md` |
| Hardware | `boards.md`, `bringup.md` |
| Reference | `known_issues.md`, `build_registry.md`, `contributing.md` |

When editing, keep these cross-page invariants true — each has already been
wrong once:

- `tidelink_top` declares **30** parameters (`src/rtl/tidelink_top.sv:39-229`);
  `tidelink_vivado_wrapper` declares **22**. Neither is 43.
- `mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i`
  (`axi_chiplet_controller.sv:711`) — `apb_debug_unlock_i` was removed from that
  OR on 2026-07-24.
- The gate is **43** blocking suites + **2** sentinels; `sim_gate_quick` is
  **14**. Regenerate with `make sim_gate_inventory`, never by hand.
- `AUTO_ANCHOR_EN` is the *sibling* eth-chiplet's name; the knob here is
  `EPOCH_ANCHOR_EN`.

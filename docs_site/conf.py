"""Sphinx configuration for the TideLink documentation site.

Build locally:
    python3 -m pip install -r docs_site/requirements.txt
    python3 -m sphinx -b html docs_site docs_site/_build/html

ReadTheDocs builds this file via /.readthedocs.yaml.
"""

# -- Project information -----------------------------------------------------

project = "TideLink"
author = "SoC Labs, University of Southampton"
copyright = "2026, SoC Labs, University of Southampton"

# TideLink has no semantic version tag on the working trunks; the release
# string names the documented tree instead so a rendered page is traceable.
version = "v1"
release = "v1 (branch fix/z2-drop-park-hook)"

# -- General configuration ---------------------------------------------------

extensions = [
    "myst_parser",
    "sphinx_copybutton",
    "sphinx_design",
    "sphinxcontrib.mermaid",
]

root_doc = "index"

source_suffix = {
    ".md": "markdown",
    ".rst": "restructuredtext",
}

exclude_patterns = [
    "_build",
    "Thumbs.db",
    ".DS_Store",
    # Build instructions for this site; intentionally outside the toctree.
    "README.md",
]

language = "en"

# -- MyST-Markdown configuration ---------------------------------------------

myst_enable_extensions = [
    "colon_fence",   # ::: fenced directives
    "deflist",       # definition lists (used by the parameter/register pages)
    "attrs_inline",  # inline attributes, e.g. {.hazard}
    "substitution",  # |name| substitutions
    "tasklist",      # - [ ] checklists in the runbook pages
    # NOTE: "linkify" is deliberately NOT enabled. It requires the optional
    # linkify-it-py package and would auto-link bare text such as register
    # addresses and hierarchical signal paths.
]

# Generate anchors for h1..h3 so cross-page deep links stay stable.
myst_heading_anchors = 3

# -- Mermaid configuration ---------------------------------------------------

# "raw" emits the diagram source into the page and lets the bundled mermaid
# JavaScript render it in the browser. This keeps the build free of node,
# mmdc and puppeteer, none of which are available on a default RTD builder.
mermaid_output_format = "raw"
mermaid_init_js = "mermaid.initialize({startOnLoad:true});"

# -- HTML output -------------------------------------------------------------

html_theme = "sphinx_rtd_theme"
html_title = "TideLink"
html_short_title = "TideLink"

html_theme_options = {
    "navigation_depth": 3,
    "collapse_navigation": False,
    "sticky_navigation": True,
    "titles_only": False,
}

# No _static/ directory is shipped; declaring one that does not exist emits a
# warning on every build.
html_static_path = []

# -- Warning suppression -----------------------------------------------------

# The pages cite repository paths, register names and RTL identifiers in
# backticks. Those are not Sphinx targets and must not be resolved as
# cross-references, so the missing-xref class is suppressed rather than
# worked around with per-page markup.
suppress_warnings = [
    "myst.xref_missing",
    "myst.header",
]

nitpicky = False

#!/bin/sh
#-----------------------------------------------------------------------------
# site_require.sh — fail a recipe with a NAMED message when a site variable is
#                   unset, instead of letting a tool fail on an empty path.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Usage, as the first line of a make recipe (via $(SITE_REQUIRE) in mk/site.mk):
#
#     $(SITE_REQUIRE) VERDI_HOME "the Verdi install root (waveform GUI)"
#
# For a variable EVERY target in a Makefile needs, use SITE_VARS_REQUIRED in
# mk/site.mk instead — that reports all of them at once, at parse time, before
# anything is built.
#
# Exit 1 on a missing variable. Never exits 0 silently on a usage mistake
# either: called with no variable name it fails, because a check that cannot
# fail is not a check.
#-----------------------------------------------------------------------------
set -u

var="${1:-}"
what="${2:-a per-machine path}"

if [ -z "$var" ]; then
    echo "site_require.sh: internal error — called with no variable name." >&2
    exit 1
fi

# POSIX indirect expansion. eval is safe here: $var comes from a Makefile
# literal, never from user input, and the pattern check below rejects anything
# that is not a plain variable name.
case "$var" in
    *[!A-Za-z0-9_]* | "" )
        echo "site_require.sh: internal error — '$var' is not a variable name." >&2
        exit 1 ;;
esac
eval "value=\${$var:-}"

if [ -n "$value" ]; then
    exit 0
fi

echo "ERROR: [site] $var is not set — it locates $what." >&2
echo "       This target needs it; there is no default. A default pointing at" >&2
echo "       one lab's mount resolves on exactly one machine and fails" >&2
echo "       everywhere else as a missing file rather than a missing setting." >&2
echo "" >&2
echo "       Fix: copy site.env.example to site.env and set $var there, or" >&2
echo "            export it in your environment (\`source set_env.sh\`)." >&2
echo "            site.env.example says what $var locates." >&2
exit 1

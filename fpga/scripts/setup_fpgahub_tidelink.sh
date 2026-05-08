#!/usr/bin/env bash
# setup_fpgahub_tidelink.sh — configure /etc/fpgahub/config.toml on the
# fpgahub-daemon host for the tidelink pair (pynq_z2_02_pl + pynq_z2_03_pl).
#
# What it does (idempotently):
#   1. Backs up /etc/fpgahub/config.toml to a timestamped file.
#   2. Appends a marker-bracketed block adding:
#        - manifest_path → tidelink/fpga/fpgahub.toml
#        - [boards.<n>.host] (PS-side ssh + empty proxy)
#        - [boards.<n>.secrets] (pynq.ssh_password = file:...)
#        - [boards.<n>.program.linux] (method = pynq_overlay)
#      ...for both pynq_z2_02_pl and pynq_z2_03_pl.
#   3. Creates /etc/fpgahub/secrets/pynq.passwd from $PYNQ_SUDO_PASSWORD
#      (default: xilinx) if missing.
#   4. Validates the new config by running fpgahub's Config.load() — if
#      validation fails, restores the backup and exits non-zero.
#   5. Reloads fpgahubd and runs `fpgahub manifest reload <board>` for
#      each pair member.
#
# Run from mapstone-dev (where the daemon lives):
#
#    sudo /home/dam1n19/SoCLabs/tidelink/fpga/scripts/setup_fpgahub_tidelink.sh
#
# Or dry-run:
#
#    sudo /home/dam1n19/SoCLabs/tidelink/fpga/scripts/setup_fpgahub_tidelink.sh --dry-run
#
# Optional env:
#   MANIFEST_PATH      — path to fpgahub.toml on this host. Default: try the
#                        in-repo path (parent of this script), then fall back
#                        to /etc/fpgahub/tidelink-fpgahub.toml. Override with
#                        an absolute path if you've staged the manifest
#                        somewhere else.
#   TIDELINK_DIR       — alternative to MANIFEST_PATH: a tidelink checkout
#                        root. The script picks $TIDELINK_DIR/fpga/fpgahub.toml.
#                        Ignored when MANIFEST_PATH is set.
#   PYNQ_SUDO_PASSWORD — value to put in /etc/fpgahub/secrets/pynq.passwd (default: xilinx)
#
# To revert: copy the timestamped backup back over /etc/fpgahub/config.toml
# and `sudo systemctl restart fpgahubd`.

set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

if [ "$(id -u)" -ne 0 ] && [ $DRY_RUN -eq 0 ]; then
    echo "ERROR: run as root (or with sudo). Pass --dry-run to preview." >&2
    exit 1
fi

# Resolve the manifest path. Three candidates, in priority order:
#   1. $MANIFEST_PATH   — explicit override.
#   2. $TIDELINK_DIR/fpga/fpgahub.toml — when the user has a checkout.
#   3. <script_dir>/../fpgahub.toml or <script_dir>/../../fpga/fpgahub.toml
#      — auto-detect when the script lives inside a tidelink checkout.
#   4. /etc/fpgahub/tidelink-fpgahub.toml — admin-staged fallback.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${MANIFEST_PATH:-}" ]; then
    :  # use as-is
elif [ -n "${TIDELINK_DIR:-}" ]; then
    MANIFEST_PATH="$TIDELINK_DIR/fpga/fpgahub.toml"
elif [ -f "$SCRIPT_DIR/../../fpga/fpgahub.toml" ]; then
    MANIFEST_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)/fpga/fpgahub.toml"
elif [ -f "/etc/fpgahub/tidelink-fpgahub.toml" ]; then
    MANIFEST_PATH="/etc/fpgahub/tidelink-fpgahub.toml"
else
    echo "ERROR: cannot find fpgahub.toml — set MANIFEST_PATH or TIDELINK_DIR" >&2
    echo "       (or stage the manifest at /etc/fpgahub/tidelink-fpgahub.toml)" >&2
    exit 2
fi

if [ ! -f "$MANIFEST_PATH" ]; then
    echo "ERROR: manifest not found at $MANIFEST_PATH" >&2
    exit 2
fi
echo "Using manifest at: $MANIFEST_PATH"

CONFIG=/etc/fpgahub/config.toml
SECRET_DIR=/etc/fpgahub/secrets
SECRET_FILE="$SECRET_DIR/pynq.passwd"
SUDO_PASSWORD="${PYNQ_SUDO_PASSWORD:-xilinx}"
MARKER_BEGIN="# >>> tidelink-fpgahub-setup >>>"
MARKER_END="# <<< tidelink-fpgahub-setup <<<"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found — is fpgahub installed on this host?" >&2
    exit 2
fi

run() {
    if [ $DRY_RUN -eq 1 ]; then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

# Idempotency check: if our marker is already in the config, we've already
# applied. Nothing to do.
if grep -qF "$MARKER_BEGIN" "$CONFIG"; then
    echo "Tidelink config block already present in $CONFIG (marker found)."
    echo "If you need to update, remove the block between"
    echo "  $MARKER_BEGIN"
    echo "  $MARKER_END"
    echo "from $CONFIG and re-run this script."
    exit 0
fi

# Sanity-check that the boards we're about to configure actually exist in
# the daemon's view. Avoids appending [boards.foo.*] for a board the
# operator hasn't declared.
for B in pynq_z2_02_pl pynq_z2_03_pl; do
    if ! /opt/fpgahub/bin/fpgahub board show "$B" >/dev/null 2>&1; then
        echo "ERROR: board '$B' is unknown to fpgahubd." >&2
        echo "       Check 'fpgahub board list' — board names must match exactly." >&2
        exit 3
    fi
done

# 1. Backup
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$CONFIG.bak-$TS"
echo "Backing up $CONFIG → $BACKUP"
run "cp -p $CONFIG $BACKUP"

# 2a. Inject manifest_path into the EXISTING [boards.<n>] header lines.
#
# The boards already exist in the config (they're how the daemon knows
# about them), so we can't write a fresh [boards.<n>] block — TOML rejects
# re-declaration of the same table. Instead, surgically insert a
# manifest_path line immediately after each existing header. The awk
# below is idempotent: it skips boards that already have manifest_path
# inside their block (which the marker check above already guarantees,
# but belt-and-braces).
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# Pre-check: detect existing manifest_path bindings on either pair member.
# A different manifest is a real conflict (fpgahub binds one manifest per
# board) — bail unless the operator opts in via REPLACE_MANIFEST=1.
REPLACE_MANIFEST="${REPLACE_MANIFEST:-0}"
need_replace=0

declare -A EXISTING_MP
for B in pynq_z2_02_pl pynq_z2_03_pl; do
    existing=$(awk -v target="$B" '
        BEGIN { inside = 0 }
        /^\[boards\.[A-Za-z0-9_]+\][[:space:]]*$/ {
            name = $0; sub(/^\[boards\./, "", name); sub(/\][[:space:]]*$/, "", name)
            inside = (name == target) ? 1 : 0; next
        }
        /^\[/ { inside = 0 }
        inside && /^[[:space:]]*manifest_path[[:space:]]*=/ {
            mp = $0
            sub(/^[[:space:]]*manifest_path[[:space:]]*=[[:space:]]*"/, "", mp)
            sub(/"[[:space:]]*$/, "", mp)
            print mp; exit
        }
    ' "$CONFIG")
    if [ -n "$existing" ]; then
        EXISTING_MP[$B]="$existing"
        if [ "$existing" = "$MANIFEST_PATH" ]; then
            echo "Note: [boards.$B] already has manifest_path = $MANIFEST_PATH (matches — no change needed)."
        else
            need_replace=1
            echo "WARN: [boards.$B] is bound to a DIFFERENT manifest:"
            echo "        existing : $existing"
            echo "        wanted   : $MANIFEST_PATH"
        fi
    fi
done

if [ $need_replace -eq 1 ] && [ "$REPLACE_MANIFEST" != "1" ]; then
    cat <<EOF >&2

ERROR: at least one pair member is already bound to a different manifest.
       fpgahub binds ONE manifest per board, so the existing binding
       would shadow the tidelink actions.

       To proceed, decide which project owns this board right now:

         a. Re-run with REPLACE_MANIFEST=1 to overwrite the existing
            manifest_path with tidelink's. The other project's actions
            on this board will become unavailable until you switch back.

              sudo MANIFEST_PATH="$MANIFEST_PATH" REPLACE_MANIFEST=1 $0

         b. Pick a different board for the tidelink slave (would also
            require recreating the pair declaration in fpgahubd config).

         c. Manually edit /etc/fpgahub/config.toml to remove the existing
            manifest_path before re-running.

       No changes have been made.
EOF
    exit 6
fi

awk -v mp="$MANIFEST_PATH" '
BEGIN {
    targets["pynq_z2_02_pl"] = 1
    targets["pynq_z2_03_pl"] = 1
}

# Match a [boards.<name>] header. Track whether were inside one of our
# targets so we can skip / replace its existing manifest_path line below.
/^\[boards\.[A-Za-z0-9_]+\][[:space:]]*$/ {
    name = $0; sub(/^\[boards\./, "", name); sub(/\][[:space:]]*$/, "", name)
    print
    in_target = (name in targets) ? 1 : 0
    injected_for[name] = 0
    next
}

# Any other [...] header closes the section. If we never saw a
# manifest_path inside a target section, inject ours now (right before
# the new section header).
/^\[/ {
    if (in_target && name && !injected_for[name]) {
        print "manifest_path = \"" mp "\""
        injected_for[name] = 1
    }
    in_target = 0
    print
    next
}

# Replace any existing manifest_path inside a target section with ours.
in_target && /^[[:space:]]*manifest_path[[:space:]]*=/ {
    print "manifest_path = \"" mp "\""
    injected_for[name] = 1
    next
}

{ print }

END {
    # Catch the case where the file ends inside a target section that
    # never got an injection (no other [...] header followed).
    if (in_target && name && !injected_for[name]) {
        print "manifest_path = \"" mp "\""
    }
}
' "$CONFIG" > "$TMP_OUT"

# 2b. Append the marker-bracketed block of NEW sub-tables. These are
# brand-new TOML tables (host, secrets, program, program.linux,
# program.linux.params), so they don't collide with the existing
# [boards.<n>] declaration. The marker brackets keep them grouped for
# the idempotency check + revert.
cat >> "$TMP_OUT" <<EOF

$MARKER_BEGIN
# Added by tidelink/fpga/scripts/setup_fpgahub_tidelink.sh on $TS.
# Sub-tables for pynq_z2_02_pl (die_a, master) and pynq_z2_03_pl
# (die_b, slave). The matching manifest_path entries were injected
# in-place above each board's existing [boards.<n>] header.

[boards.pynq_z2_02_pl.host]
ssh = "xilinx@192.168.4.101"
proxy = ""

[boards.pynq_z2_02_pl.secrets]
"pynq.ssh_password" = "file:$SECRET_FILE"

[boards.pynq_z2_02_pl.program.linux]
method = "pynq_overlay"
description = "Load PL bitstream via PYNQ fpga_manager over SSH"

[boards.pynq_z2_02_pl.program.linux.params]
remote_dir = "/home/xilinx/.fpgahub"
sudo_secret = "pynq.ssh_password"

[boards.pynq_z2_03_pl.host]
ssh = "xilinx@192.168.6.101"
proxy = ""

[boards.pynq_z2_03_pl.secrets]
"pynq.ssh_password" = "file:$SECRET_FILE"

[boards.pynq_z2_03_pl.program.linux]
method = "pynq_overlay"
description = "Load PL bitstream via PYNQ fpga_manager over SSH"

[boards.pynq_z2_03_pl.program.linux.params]
remote_dir = "/home/xilinx/.fpgahub"
sudo_secret = "pynq.ssh_password"
$MARKER_END
EOF

if [ $DRY_RUN -eq 1 ]; then
    echo "[dry-run] would write a modified $CONFIG with:"
    echo "  - manifest_path injected into existing [boards.pynq_z2_02_pl] / [boards.pynq_z2_03_pl] headers"
    echo "  - the following new sub-tables appended at the bottom:"
    sed -n "/$MARKER_BEGIN/,/$MARKER_END/p" "$TMP_OUT"
else
    cp -p "$TMP_OUT" "$CONFIG"
fi

# 3. Secret file
if [ ! -f "$SECRET_FILE" ]; then
    echo "Creating secret store at $SECRET_FILE (group-fpga readable)"
    run "install -d -m 0750 -o root -g fpga $SECRET_DIR"
    if [ $DRY_RUN -eq 0 ]; then
        printf '%s' "$SUDO_PASSWORD" > "$SECRET_FILE"
        chmod 0640 "$SECRET_FILE"
        chgrp fpga "$SECRET_FILE"
    else
        echo "[dry-run] would write \$PYNQ_SUDO_PASSWORD into $SECRET_FILE (mode 0640, group fpga)"
    fi
else
    echo "$SECRET_FILE already exists — leaving in place."
fi

# 4. Validate the new config by loading it through fpgahub's own schema.
# This catches typos before we restart the daemon (fpgahubd's auto-restart
# loop is opaque; failing closed here is far more debuggable).
echo "Validating $CONFIG against fpgahub's Config schema..."
if [ $DRY_RUN -eq 0 ]; then
    if ! /opt/fpgahub/bin/python -c "
from pathlib import Path
from fpgahub.config import Config
Config.load(Path('$CONFIG'))
print('  OK')
" ; then
        echo "ERROR: config validation failed — restoring backup." >&2
        cp -p "$BACKUP" "$CONFIG"
        echo "       restored from $BACKUP" >&2
        exit 4
    fi
else
    echo "[dry-run] would validate via fpgahub.config.Config.load(...)"
fi

# 5. Reload daemon + manifests
echo "Reloading fpgahubd..."
run "systemctl reload-or-restart fpgahubd"
sleep 1

if [ $DRY_RUN -eq 0 ]; then
    if ! systemctl is-active fpgahubd >/dev/null 2>&1; then
        echo "ERROR: fpgahubd is not active after reload — see 'journalctl -u fpgahubd -n 30'." >&2
        exit 5
    fi
fi

for B in pynq_z2_02_pl pynq_z2_03_pl; do
    echo "Reloading manifest for $B..."
    run "/opt/fpgahub/bin/fpgahub manifest reload $B"
done

cat <<EOF

Done. The tidelink pair is now wired up via fpgahub.

Next steps (one-time):
  1. Install an SSH pubkey for whoever fpgahubd runs as into
     xilinx@192.168.{4,6}.101:~/.ssh/authorized_keys so the
     pynq_overlay plugin's BatchMode=yes ssh works.

  2. Verify the binding:
       fpgahub manifest show pynq_z2_02_pl  | grep deploy_pair
       fpgahub board show     pynq_z2_02_pl | grep -A2 program

  3. Try a deploy from any client (after acquiring the lease):
       fpgahub --addr mapstone-dev.ecs.soton.ac.uk pair lease acquire bridge1 \\
           --user \$(whoami) --ttl 3600
       fpgahub actions run pynq_z2_02_pl deploy_pair
       fpgahub actions run pynq_z2_03_pl deploy_pair

To revert: cp -p $BACKUP $CONFIG && systemctl restart fpgahubd
EOF

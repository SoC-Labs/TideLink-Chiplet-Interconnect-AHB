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
#   TIDELINK_DIR       — path to the tidelink checkout (default: parent of this script)
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

# Resolve repo root from the script location so manifest_path is correct
# regardless of where the user ran us from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_DIR="${TIDELINK_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MANIFEST_PATH="$TIDELINK_DIR/fpga/fpgahub.toml"

if [ ! -f "$MANIFEST_PATH" ]; then
    echo "ERROR: manifest not found at $MANIFEST_PATH" >&2
    echo "       set TIDELINK_DIR to your tidelink checkout root." >&2
    exit 2
fi

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

# 2. Append the tidelink block
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# Generate the block. Per-board sections at the bottom of the file work
# regardless of where the original [boards.<n>] block lives because TOML
# treats per-key paths as additive (only the same exact key triggers the
# duplicate-key error). manifest_path / host / program / secrets are all
# new keys for these boards, so this is safe.
cat > "$TMPFILE" <<EOF

$MARKER_BEGIN
# Added by tidelink/fpga/scripts/setup_fpgahub_tidelink.sh on $TS.
# Configures pynq_z2_02_pl (die_a, master) and pynq_z2_03_pl (die_b, slave)
# for the tidelink pair: PS-side ethernet for fpgahub deploy, manifest
# binding for the tidelink fpgahub.toml actions, pynq_overlay program plugin.

[boards.pynq_z2_02_pl]
manifest_path = "$MANIFEST_PATH"

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

[boards.pynq_z2_03_pl]
manifest_path = "$MANIFEST_PATH"

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
    echo "[dry-run] would append the following block to $CONFIG:"
    cat "$TMPFILE"
else
    cat "$TMPFILE" >> "$CONFIG"
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

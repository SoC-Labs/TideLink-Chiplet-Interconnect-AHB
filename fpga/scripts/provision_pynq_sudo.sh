#!/usr/bin/env bash
# provision_pynq_sudo.sh — one-time setup on a fresh PYNQ-Z2 image so
# fpgahub actions (deploy_pair, stress_pair, ...) can use `sudo -n`
# without a password prompt.
#
# Drops a /etc/sudoers.d/pynq-fpgahub file giving the `xilinx` user
# NOPASSWD: ALL. Validated with `visudo -cf` before install. Idempotent
# — re-running on a board that's already provisioned is a no-op.
#
# Designed to be invoked by a fpgahub manifest action (see
# fpga/fpgahub.toml ::provision_pynq_sudo). Works equally well as a
# standalone tool when run from the host that has SSH access to the
# board.
#
# Required env (one or both):
#   PYNQ_HOST=user@host       — SSH target. Default: arg $1.
#   PYNQ_PROXY=user@jumphost  — Optional ProxyJump.
#   PYNQ_PASSWORD=...         — The xilinx user's existing sudo password.
#                               fpgahub injects this via secret_env when
#                               this script runs as a manifest action.
#
# Usage:
#   PYNQ_HOST=xilinx@192.168.4.101 PYNQ_PASSWORD=xilinx \
#       fpga/scripts/provision_pynq_sudo.sh
#
# This is a LAB convenience — NOPASSWD: ALL is overkill for production.
# These boards are isolated /24s on a development server, accessed only
# by trusted fpgahub clients via SSH. If you're running this somewhere
# that matters, scope the rule down to the specific commands the
# pynq_overlay plugin and stress runner actually need.

set -euo pipefail

PYNQ_HOST="${PYNQ_HOST:-${1:-}}"
PYNQ_PROXY="${PYNQ_PROXY:-}"
PASSWORD="${PYNQ_PASSWORD:-}"

if [ -z "$PYNQ_HOST" ]; then
    echo "ERROR: set PYNQ_HOST=user@host (or pass it as arg \$1)" >&2
    exit 2
fi
if [ -z "$PASSWORD" ]; then
    echo "ERROR: set PYNQ_PASSWORD (the xilinx user's existing sudo password)" >&2
    echo "       in a fpgahub action this comes from secret_env =" >&2
    echo "       { PYNQ_PASSWORD = \"pynq.ssh_password\" }." >&2
    exit 2
fi

SSH_OPTS=(-oBatchMode=yes -oStrictHostKeyChecking=accept-new -oUserKnownHostsFile=/dev/null)
if [ -n "$PYNQ_PROXY" ]; then
    SSH_OPTS+=(-oProxyJump="$PYNQ_PROXY")
fi

echo "Provisioning NOPASSWD sudo on $PYNQ_HOST..."

# The remote script does the work. Password is fed via stdin, never on
# the command line — `sudo -S` reads it from stdin once and the new
# sudoers rule means no further password is needed. visudo -cf catches
# any malformed input before it lands.
ssh "${SSH_OPTS[@]}" "$PYNQ_HOST" \
    "PASSWORD='$PASSWORD' bash -s" <<'REMOTE_SCRIPT'
set -eu

TARGET=/etc/sudoers.d/pynq-fpgahub
RULE="xilinx ALL=(ALL) NOPASSWD: ALL"
COMMENT="# Installed by tidelink/fpga/scripts/provision_pynq_sudo.sh"
COMMENT2="# Lab use: NOPASSWD allows fpgahub actions (deploy_pair, stress_pair) to run sudo non-interactively."

# Idempotency: if the target file already has our rule (verbatim), skip.
if sudo -n test -f "$TARGET" 2>/dev/null && \
   sudo -n grep -qF "$RULE" "$TARGET" 2>/dev/null; then
    echo "Already provisioned: $TARGET contains the expected rule (sudo -n verified)."
    exit 0
fi

# Stage the file in /tmp and validate before installing.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
{
    echo "$COMMENT"
    echo "$COMMENT2"
    echo "$RULE"
} > "$TMP"
chmod 0440 "$TMP"

# visudo -cf takes a single file path; -q for quiet. Returns non-zero
# on any syntax issue.
if ! visudo -cf "$TMP" >/dev/null; then
    echo "ERROR: generated sudoers fragment failed visudo -cf" >&2
    exit 3
fi

# Install via sudo -S (password-fed). After this lands, sudo -n will
# work for all future invocations of any command.
echo "Installing $TARGET..."
echo "$PASSWORD" | sudo -S install -m 0440 -o root -g root "$TMP" "$TARGET"

# Verify the new rule is live.
if sudo -n true 2>/dev/null; then
    echo "OK: NOPASSWD sudo is live (sudo -n confirmed)."
else
    echo "ERROR: $TARGET installed but sudo -n still requires a password." >&2
    echo "       Check 'sudo cat $TARGET' for content / permissions." >&2
    exit 4
fi
REMOTE_SCRIPT

echo "Done. Future fpgahub actions on $PYNQ_HOST can use sudo -n."

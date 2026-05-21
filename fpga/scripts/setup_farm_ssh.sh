#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### TideLink FPGA build-farm — passwordless SSH bootstrap
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Establishes passwordless SSH from THIS host to FARM_HOST for the current
### user, so Vivado's `launch_runs -host` (BatchMode=yes) can log in unattended.
### Idempotent. Run from an authenticated shell — it will prompt ONCE for the
### remote password to install the key, then verify BatchMode works.
###
### NOTE: /home is local per host, so ~/.ssh on FARM_HOST is a DIFFERENT
### directory than here; the key must be authorised there explicitly. If the
### site uses Kerberos and you prefer GSSAPI over a long build, set instead:
###   FPGA_REMOTE_CMD='ssh -q -o BatchMode=yes -o GSSAPIAuthentication=yes \
###                    -o GSSAPIDelegateCredentials=yes'
### and ensure a long-lived/renewable TGT (k5start) — pubkey is more robust
### for multi-hour unattended runs, which is what this script sets up.
###
###   FARM_HOST=srv04936 ./setup_farm_ssh.sh
###-----------------------------------------------------------------------------
set -eu

FARM_HOST="${FARM_HOST:?set FARM_HOST=<remote host>}"
KEY="${HOME}/.ssh/id_ed25519_fpgafarm"
SSH_BATCH=(ssh -q -o ConnectTimeout=30 -o ConnectionAttempts=3 -o BatchMode=yes)

echo "Farm SSH bootstrap:  $(hostname -s) -> $FARM_HOST  (user $USER)"

if "${SSH_BATCH[@]}" "$FARM_HOST" true 2>/dev/null; then
    echo "OK: passwordless SSH to $FARM_HOST already works — nothing to do."
    exit 0
fi

if [ ! -f "$KEY" ]; then
    echo "Generating dedicated farm key: $KEY"
    ssh-keygen -t ed25519 -N '' -C "fpgafarm-${USER}@$(hostname -s)" -f "$KEY"
fi

# Use the farm key by default for this host without editing global config.
touch "${HOME}/.ssh/config"
chmod 600 "${HOME}/.ssh/config"
if ! grep -qE "^Host[[:space:]]+${FARM_HOST}\$" "${HOME}/.ssh/config" 2>/dev/null; then
    {
        echo ""
        echo "# Added by tidelink fpga/scripts/setup_farm_ssh.sh"
        echo "Host ${FARM_HOST}"
        echo "    IdentityFile ${KEY}"
        echo "    IdentitiesOnly yes"
    } >> "${HOME}/.ssh/config"
    echo "Added Host ${FARM_HOST} block to ~/.ssh/config"
fi

echo "Installing public key on $FARM_HOST (expect ONE password prompt)..."
ssh-copy-id -i "${KEY}.pub" "$FARM_HOST"

echo "Verifying BatchMode login..."
if "${SSH_BATCH[@]}" "$FARM_HOST" 'echo BATCH_OK on $(hostname -s)'; then
    echo "SUCCESS: passwordless SSH to $FARM_HOST is ready for Vivado -host."
else
    echo "STILL FAILING: pubkey auth may be disabled on $FARM_HOST." >&2
    echo "  - check 'sshd' allows PubkeyAuthentication and ~/.ssh perms (700/600)" >&2
    echo "  - or fall back to the GSSAPI/Kerberos FPGA_REMOTE_CMD in the header" >&2
    exit 1
fi

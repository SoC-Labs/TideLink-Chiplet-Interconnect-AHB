#!/usr/bin/env bash
# provision_pynq_peer_keys.sh — generate/propagate SSH trust so a PYNQ-Z2
# board's xilinx user can SSH to mapstone-dev (as david) and to the peer
# board (as xilinx). Required for the stress runner's `peer_agent` spawn
# under the ProxyJump topology (Option B).
#
# Trust chain set up by this script:
#   xilinx@<this-board>:~/.ssh/id_ed25519 (generated if missing)
#     ├── pubkey appended to david@mapstone-dev:~/.ssh/authorized_keys
#     └── pubkey appended to xilinx@<peer-board>:~/.ssh/authorized_keys
#
# Idempotent: re-running checks for the pubkey already present in each
# authorized_keys file before appending. Designed to be invoked from a
# fpgahub manifest action OR run standalone from any host that has SSH
# access (currently password-or-key) to:
#   - this board (PYNQ_HOST)
#   - the peer board (PEER_HOST)
#   - mapstone-dev as david (the `proxy` target of the ProxyJump topology;
#     either via SSH key or via this same script run on mapstone-dev itself)
#
# Required env (matches the rest of the provision_pynq_* family):
#   PYNQ_HOST=user@host       — this board. Default: arg $1.
#   PEER_HOST=user@host       — peer board. Default: arg $2.
#   MAPSTONE_HOST=user@host   — david@mapstone-dev (or accessible alias).
#                                Default: david@mapstone-dev.ecs.soton.ac.uk.
#   PYNQ_PROXY=user@jumphost  — Optional ProxyJump for SSH into the boards.
#                                Used only for THIS script's connection;
#                                the keypair it provisions has its own
#                                ProxyJump expectations (see below).
#   PYNQ_PASSWORD=...         — sudo password for the boards (consumed by
#                                ssh helpers if needed; in fpgahub action
#                                this comes from secret_env).

set -euo pipefail

PYNQ_HOST="${PYNQ_HOST:-${1:-}}"
PEER_HOST="${PEER_HOST:-${2:-}}"
MAPSTONE_HOST="${MAPSTONE_HOST:-david@mapstone-dev.ecs.soton.ac.uk}"
PYNQ_PROXY="${PYNQ_PROXY:-}"

if [ -z "$PYNQ_HOST" ] || [ -z "$PEER_HOST" ]; then
    echo "ERROR: required: PYNQ_HOST=<user@board>, PEER_HOST=<user@peer>." >&2
    echo "  e.g. PYNQ_HOST=xilinx@192.168.4.101 PEER_HOST=xilinx@192.168.6.101 $0" >&2
    exit 2
fi

SSH_OPTS=(
    -oBatchMode=yes
    -oStrictHostKeyChecking=accept-new
    -oUserKnownHostsFile=/dev/null
    -oLogLevel=ERROR
)
if [ -n "$PYNQ_PROXY" ]; then
    SSH_OPTS+=(-oProxyJump="$PYNQ_PROXY")
fi

echo "Provisioning peer-SSH keys on $PYNQ_HOST..."
echo "  peer    : $PEER_HOST"
echo "  proxy   : $MAPSTONE_HOST (intermediate hop)"

# 1. Ensure xilinx@board has a keypair; emit pubkey to stdout.
PUBKEY=$(ssh "${SSH_OPTS[@]}" "$PYNQ_HOST" 'bash -s' <<'REMOTE'
set -eu
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -C "$(whoami)@$(hostname)-tidelink-peer" -f ~/.ssh/id_ed25519 >/dev/null
fi
cat ~/.ssh/id_ed25519.pub
REMOTE
)

if [ -z "$PUBKEY" ]; then
    echo "ERROR: failed to obtain pubkey from $PYNQ_HOST" >&2
    exit 3
fi

KEY_TAG=$(echo "$PUBKEY" | awk '{print $NF}')
echo "  pubkey tag: $KEY_TAG"

# 2. Append pubkey at david@mapstone-dev (intermediate hop), idempotent.
echo "Trusting pubkey at $MAPSTONE_HOST..."
echo "$PUBKEY" | ssh "${SSH_OPTS[@]}" "$MAPSTONE_HOST" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
     if grep -qF '$KEY_TAG' ~/.ssh/authorized_keys 2>/dev/null; then \
         echo '  (already trusted at $MAPSTONE_HOST)'; \
     else \
         cat >> ~/.ssh/authorized_keys && echo '  added to $MAPSTONE_HOST'; \
     fi"

# 3. Append pubkey at xilinx@peer-board (final hop), idempotent.
echo "Trusting pubkey at $PEER_HOST..."
echo "$PUBKEY" | ssh "${SSH_OPTS[@]}" "$PEER_HOST" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
     if grep -qF '$KEY_TAG' ~/.ssh/authorized_keys 2>/dev/null; then \
         echo '  (already trusted at $PEER_HOST)'; \
     else \
         cat >> ~/.ssh/authorized_keys && echo '  added to $PEER_HOST'; \
     fi"

# 4. Pre-seed known_hosts on the board so the runner's BatchMode SSH
#    doesn't trip on first-connection prompts. We pass
#    StrictHostKeyChecking=accept-new in the runner anyway, but UserKnownHostsFile=/dev/null
#    means the runner won't persist; we pre-seed the system-wide file to
#    cover that and any future tools.
echo "Pre-seeding known_hosts on $PYNQ_HOST for proxy + peer..."
PROXY_HOST=$(echo "$MAPSTONE_HOST" | awk -F@ '{print $2}')
PEER_HOST_ONLY=$(echo "$PEER_HOST" | awk -F@ '{print $2}')

ssh "${SSH_OPTS[@]}" "$PYNQ_HOST" \
    "ssh-keyscan -H $PROXY_HOST $PEER_HOST_ONLY 2>/dev/null >> ~/.ssh/known_hosts && \
     sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts && \
     echo '  known_hosts updated'"

echo "Done. xilinx@$PYNQ_HOST → $MAPSTONE_HOST → $PEER_HOST chain ready."

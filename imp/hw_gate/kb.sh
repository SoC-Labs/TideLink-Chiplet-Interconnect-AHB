#!/usr/bin/env bash
# kb.sh — run a privileged command on a KR260 board.
# Mirrors the auth of tidelink/pynq_host/scripts/kr260_eth_run.sh:
#   sshpass -e for the login, `sudo -S` fed over stdin.
# Secret comes from the environment, never from the command line.
#   usage: KR260_PASSWORD=... kb.sh <board-ip> '<remote command>'
set -eu
IP="$1"; shift
CMD="$*"
: "${KR260_PASSWORD:?KR260_PASSWORD not set}"
export SSHPASS="$KR260_PASSWORD"
printf '%s\n' "$KR260_PASSWORD" | sshpass -e ssh \
     -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=15 \
     "ubuntu@$IP" "sudo -S -p '' $CMD"

#!/bin/bash
# tl36.sh - mapstone-dev wrapper: run tl36.py on a board (a|b), or on both in parallel.
# Usage: tl36.sh a|b <tl36.py args...>      single board
#        tl36.sh both <tl36.py args...>     both boards in parallel (~1 RTT skew)
PASS=xilinx
SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
ip_of() { case "$1" in a) echo 192.168.4.101 ;; b) echo 192.168.6.101 ;; esac; }
run_one() { # die args...
    local die="$1"; shift
    sshpass -p $PASS ssh -n $SSHC xilinx@$(ip_of $die) \
        "echo $PASS | sudo -S python3 /home/xilinx/tl36.py $*" 2>/dev/null | sed "s/^/[$die] /"
}
tgt="$1"; shift
if [ "$tgt" = both ]; then
    run_one a "$@" & run_one b "$@" & wait
else
    run_one "$tgt" "$@"
fi

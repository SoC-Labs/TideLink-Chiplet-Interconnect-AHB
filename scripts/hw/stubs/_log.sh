# sourced by every stub: append one line to $STUBLOG (argv only; stdin is never logged)
STUBLOG=${STUBLOG:-/dev/null}
slog() { printf '%s\t%s\n' "$(date +%H:%M:%S.%N | cut -c1-12)" "$*" >> "$STUBLOG"; }

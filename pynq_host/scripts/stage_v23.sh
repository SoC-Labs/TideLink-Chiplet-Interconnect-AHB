#!/usr/bin/env bash
# stage_v23.sh — Convert .bit→.bin, generate manifests, and cat-pipe to mapstone-dev
# Run from any host after build_pair_farmed completes.
# Usage: bash pynq_host/scripts/stage_v23.sh
set -eu

TIDELINK_HOME="$(cd "$(dirname "$0")/../.." && pwd)"
BIT2BIN="$TIDELINK_HOME/fpga/scripts/bit2bin.py"

BIT_A="$TIDELINK_HOME/imp/fpga/output/pynq-z2-pair-all/tidelink.bit"
BIT_B="$TIDELINK_HOME/imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit"
HWH_A="$TIDELINK_HOME/imp/fpga/output/pynq-z2-pair-all/tidelink.hwh"
HWH_B="$TIDELINK_HOME/imp/fpga/output/pynq-z2-pair-flip-all/tidelink.hwh"
BIN_A="$TIDELINK_HOME/imp/fpga/output/pynq-z2-pair-all/tidelink.bin"
BIN_B="$TIDELINK_HOME/imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin"

COMMIT=$(cd "$TIDELINK_HOME" && git rev-parse HEAD)
DATE_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST_NOW=$(hostname)

echo "=== Stage v23 (M1+M2+M7+M4b+M4e+M6+M8) ==="
echo "  commit: $COMMIT"
echo "  date:   $DATE_NOW"

# 1. Convert .bit → .bin
echo "--- bit2bin ---"
python3 "$BIT2BIN" "$BIT_A" "$BIN_A"
python3 "$BIT2BIN" "$BIT_B" "$BIN_B"
echo "  non-flip: $(wc -c < "$BIN_A") bytes"
echo "  flip:     $(wc -c < "$BIN_B") bytes"

# 2. Checksums
SHA_A=$(sha256sum "$BIN_A" | cut -d' ' -f1)
SHA_B=$(sha256sum "$BIN_B" | cut -d' ' -f1)
echo "  sha256 non-flip: $SHA_A"
echo "  sha256 flip:     $SHA_B"

# 3. Create staging dir on mapstone-dev
echo "--- mkdir /tmp/td_v23_priv on mapstone-dev ---"
ssh mapstone-dev "mkdir -p /tmp/td_v23_priv && chmod 777 /tmp/td_v23_priv"

# 4. Transfer binaries (cat-pipe: avoids rsync/bashrc corruption)
echo "--- transferring binaries ---"
cat "$BIN_A" | ssh mapstone-dev "cat > /tmp/td_v23_priv/tidelink.bin"
cat "$HWH_A" | ssh mapstone-dev "cat > /tmp/td_v23_priv/tidelink.hwh"
cat "$BIN_B" | ssh mapstone-dev "cat > /tmp/td_v23_priv/tidelink-flip.bin"
cat "$HWH_B" | ssh mapstone-dev "cat > /tmp/td_v23_priv/tidelink-flip.hwh"

# 5. Transfer scripts
echo "--- transferring scripts ---"
cat "$TIDELINK_HOME/pynq_host/scripts/deploy_pair.sh" | ssh mapstone-dev \
    "cat > /tmp/td_v23_priv/deploy_pair.sh && chmod +x /tmp/td_v23_priv/deploy_pair.sh"
cat "$TIDELINK_HOME/pynq_host/scripts/probe_autoneg_obs.sh" | ssh mapstone-dev \
    "cat > /tmp/td_v23_priv/probe_autoneg_obs.sh && chmod +x /tmp/td_v23_priv/probe_autoneg_obs.sh"
cat "$TIDELINK_HOME/pynq_host/scripts/v23_variance_loop.sh" | ssh mapstone-dev \
    "cat > /tmp/td_v23_priv/v23_variance_loop.sh && chmod +x /tmp/td_v23_priv/v23_variance_loop.sh"

# 6. Manifests
echo "--- writing manifests ---"
ssh mapstone-dev "cat > /tmp/td_v23_priv/tidelink.bin.manifest.json" <<EOF
{
  "sha256": "$SHA_A",
  "source_commit": "$COMMIT",
  "build_host": "$HOST_NOW",
  "build_date": "$DATE_NOW",
  "target": "pynq-z2-pair-all",
  "expected_lock_min": 8,
  "label": "v23-m8"
}
EOF

ssh mapstone-dev "cat > /tmp/td_v23_priv/tidelink-flip.bin.manifest.json" <<EOF
{
  "sha256": "$SHA_B",
  "source_commit": "$COMMIT",
  "build_host": "$HOST_NOW",
  "build_date": "$DATE_NOW",
  "target": "pynq-z2-pair-flip-all",
  "expected_lock_min": 8,
  "label": "v23-m8-flip"
}
EOF

# 7. Verify
echo "--- staged files on mapstone-dev ---"
ssh mapstone-dev "ls -la /tmp/td_v23_priv/"

echo ""
echo "=== Staging complete. To run variance test: ==="
echo "  ssh mapstone-dev 'nohup /tmp/td_v23_priv/v23_variance_loop.sh > /tmp/v23_variance.log 2>&1 &'"
echo "  ssh mapstone-dev 'tail -f /tmp/v23_variance.log'"

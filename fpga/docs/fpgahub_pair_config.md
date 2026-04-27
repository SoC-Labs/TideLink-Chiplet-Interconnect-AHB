# TideLink FPGA Hub — Paired-Board Operator Recipe

This document is the operator's reference for registering the TideLink
`pynq-z2-pair` entry in `/etc/fpgahub/config.toml` and running the full
paired-board CI flow.

**Upstream requirement:** fpgahub `feat/pair-tokens-and-env` (or later) must be
installed.  The `{pair.*}` manifest tokens and `FPGAHUB_PEER_*` env injection
used by `fpga/fpgahub.toml` are not available in older fpgahub releases.

---

## 1  `/etc/fpgahub/config.toml` — board + pair entries

Add the following to the hub-wide config on `mapstone-dev`.  Replace
placeholder IPs / MACs with actual hardware values; the values below match
the bench-01 cable harness.

```toml
# ---- Die A ----------------------------------------------------------------
[boards.tidelink_z2_a]
server        = "mapstone-dev"
hub_path      = "1-8.1"
description   = "TideLink Pynq-Z2 (die A in tidelink_bridge_01)"
manifest_path = "/home/dam1n19/SoCLabs/tidelink/fpga/fpgahub.toml"

[boards.tidelink_z2_a.naming]
tty_symlink_dir = "tidelink_a"
net_name        = "tidelink_a_eth"

[boards.tidelink_z2_a.network]
host_ip   = "192.168.100.1/24"
board_ip  = "192.168.100.10"
board_mac = "02:00:5e:00:99:01"
hostname  = "tidelink-a"

[boards.tidelink_z2_a.host]
ssh   = "xilinx@tidelink-a.local"
proxy = "mapstone-dev.example.org"

[boards.tidelink_z2_a.secrets]
"pynq.ssh_password" = "file:/var/lib/fpgahub/secrets/tidelink_z2_a/pynq_ssh_password"

# ---- Die B ----------------------------------------------------------------
[boards.tidelink_z2_b]
server        = "mapstone-dev"
hub_path      = "1-8.2"
description   = "TideLink Pynq-Z2 (die B in tidelink_bridge_01)"
manifest_path = "/home/dam1n19/SoCLabs/tidelink/fpga/fpgahub.toml"

[boards.tidelink_z2_b.naming]
tty_symlink_dir = "tidelink_b"
net_name        = "tidelink_b_eth"

[boards.tidelink_z2_b.network]
host_ip   = "192.168.101.1/24"
board_ip  = "192.168.101.10"
board_mac = "02:00:5e:00:99:02"
hostname  = "tidelink-b"

[boards.tidelink_z2_b.host]
ssh   = "xilinx@tidelink-b.local"
proxy = "mapstone-dev.example.org"

[boards.tidelink_z2_b.secrets]
"pynq.ssh_password" = "file:/var/lib/fpgahub/secrets/tidelink_z2_b/pynq_ssh_password"

# ---- Pair -----------------------------------------------------------------
[pairs.tidelink_bridge_01]
members       = ["tidelink_z2_a", "tidelink_z2_b"]
link_kind     = "tidelink_gpio_bridge"
roles         = { tidelink_z2_a = "die_a", tidelink_z2_b = "die_b" }
bringup_order = ["tidelink_z2_a", "tidelink_z2_b"]
description   = "Pynq-Z2 RPi-header GPIO bridge, bench 01"
```

Secret file contents are the raw PYNQ `xilinx` account password (no newline).
Create them with:

```sh
sudo install -d -m 700 -o fpgahub /var/lib/fpgahub/secrets/tidelink_z2_a
printf '%s' '<password>' | \
  sudo tee /var/lib/fpgahub/secrets/tidelink_z2_a/pynq_ssh_password > /dev/null
# repeat for tidelink_z2_b
```

---

## 2  Bring-up walkthrough

```sh
# 1. Acquire the pair lease and power/configure both boards in bringup_order.
fpgahub pair up tidelink_bridge_01 --ttl 7200

# 2. Confirm both members are leased and attached.
fpgahub pair status tidelink_bridge_01

# 3. Run the full CI flow against each member (programs + stress on each).
#    ci_pair_full = build_z2_pair -> deploy_z2_pair -> stress_pair
fpgahub actions run tidelink_z2_a ci_pair_full
fpgahub actions run tidelink_z2_b ci_pair_full

# 4. Tear down — releases the pair lease atomically.
fpgahub pair down tidelink_bridge_01
```

`pair up` walks `bringup_order` (die A first, then die B) and rolls back both
on any failure.  `pair down` is the reverse.

To lease the pair for interactive work without running CI:

```sh
fpgahub pair lease acquire tidelink_bridge_01 --ttl 3600
# ... work ...
fpgahub pair lease release tidelink_bridge_01
```

---

## 3  Token reference

The table below shows the values `stress_pair` sees when dispatched against
`tidelink_z2_a` (i.e. fpgahub is rendering tokens for die A's perspective):

| Token                      | Rendered value                        |
|----------------------------|---------------------------------------|
| `{pair.id}`                | `"tidelink_bridge_01"`                |
| `{pair.link_kind}`         | `"tidelink_gpio_bridge"`              |
| `{pair.local.role}`        | `"die_a"`                             |
| `{pair.peer.name}`         | `"tidelink_z2_b"`                     |
| `{pair.peer.role}`         | `"die_b"`                             |
| `{pair.peer.ip}`           | `"192.168.101.10"`                    |
| `{pair.peer.host.ssh}`     | `"xilinx@tidelink-b.local"`           |
| `{pair.peer.host.proxy}`   | `"mapstone-dev.example.org"`          |

When the same action runs against `tidelink_z2_b`, local/peer swap: the
peer tokens reflect die A and `{pair.local.role}` = `"die_b"`.

The matching `FPGAHUB_PEER_*` environment variables are injected into the
local action subprocess automatically.  Optional fields (e.g.
`FPGAHUB_PEER_HOST_PROXY`) are omitted when `None`, so guards like
`[ -n "$FPGAHUB_PEER_HOST_PROXY" ]` work correctly.

---

## 4  `set_env.sh` integration

`fpga/set_env.sh` will gain a thin `fpga_use_pair` helper (tracked in a
follow-on commit):

```sh
fpga_use_pair() {
    fpgahub pair up "$1" --ttl "${2:-7200}"
    trap "fpgahub pair down '$1'" EXIT
}
```

**No env shimming is required** inside `set_env.sh`.  fpgahub already injects
`FPGAHUB_PAIR_ID`, `FPGAHUB_LOCAL_ROLE`, `FPGAHUB_PEER_NAME`,
`FPGAHUB_PEER_IP`, etc. into every action subprocess automatically when the
board is part of an active pair.  The helper is purely a convenience wrapper
around `fpgahub pair up` / `pair down` plus an EXIT trap.

---

## 5  Troubleshooting

| Symptom / error                 | Likely cause                               | Fix                                                        |
|---------------------------------|--------------------------------------------|------------------------------------------------------------|
| `409 pair_required`             | Action uses `{pair.*}` tokens but board is not in a pair lease | Run `fpgahub pair lease acquire <pair_id>` first, or use `fpgahub pair up`. |
| `paired_partner_unleased`       | One member has a lease; the other does not | Release both with `fpgahub pair down`, then `pair up` again. |
| Ribbon link never trains (stuck at credit-init) | Role strap not set | Check that `FPGAHUB_LOCAL_ROLE` is correct and that the PYNQ overlay startup script wrote it to the AXI GPIO strap register at `0x4404_0000`. |
| Role strap mismatch (both report same role) | `die_a`/`die_b` role assignment in `[pairs.*]` is swapped relative to physical cable | Swap `roles` values in config.toml for this pair entry, or swap the board assignments in `members`. |
| `stress_pair` exits immediately with SSH timeout | `{pair.peer.host.ssh}` resolves to wrong hostname | Run `fpgahub pair show tidelink_bridge_01` and confirm `board_ip` / `hostname` fields match actual hardware. |

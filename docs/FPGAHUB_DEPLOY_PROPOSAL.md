# Long-term fpgahub deploy/stress flow for the tidelink pair

**Goal**: replace the ad-hoc `deploy_pair_proxy.sh` / `sshpass` pipeline with
plugin-based bitstream load and manifest-driven stress runs, so that
`make program_via_plugin BOARD=pynq_z2_02_pl` (or `fpgahub actions run
pynq_z2_02_pl deploy_pair`) works from any client machine that has a
reachable fpgahub daemon — no SSH passwords in argv, no per-machine SSH
keys to the boards, no hand-staged ProxyJump.

## Current state (2026-05-08)

- Daemon is up on mapstone-dev (`fpgahubd.service`).
- Pair `bridge1` is declared: `pynq_z2_02_pl` (die_a, master) ↔
  `pynq_z2_03_pl` (die_b, slave), `link_kind = rpi_header_ribbon`.
- **No manifest is bound** to either board (`fpgahub manifest show
  pynq_z2_02_pl` → 404).
- **No `program` plugin is configured** on either board (`fpgahub board
  program ...` → "no method").
- `fpga/fpgahub.toml` exists in-repo and declares `deploy_z2_pair`,
  `stress_pair`, `ci_pair_full` — but those actions key off
  `{host.ssh}`, `{host.proxy}` and `pynq.ssh_password`, none of which
  exist in the per-board config yet.
- For pair operation the bitstreams are NOT symmetric: master uses
  `pynq-z2-pair-all`, slave uses `pynq-z2-pair-flip-all` (the latter
  has a mirrored RPi pinout for the cross-cable). The current
  manifest's `deploy_z2_pair` only knows about a single `TARGET=
  pynq-z2-pair` — needs to become role-aware.

## Steps

### 1. Per-board host + program method (`/etc/fpgahub/config.toml`)

For each of `pynq_z2_02_pl` and `pynq_z2_03_pl`, add:

```toml
[boards.pynq_z2_02_pl.host]
ssh = "xilinx@192.168.4.101"   # PS-side ethernet — reachable when no PL bitstream loaded
proxy = ""                      # empty = daemon co-located with the board

[boards.pynq_z2_02_pl.secrets]
"pynq.ssh_password" = "file:/etc/fpgahub/secrets/pynq.passwd"

[boards.pynq_z2_02_pl.program.linux]
method = "pynq_overlay"
description = "Load PL bitstream via PYNQ fpga_manager over SSH"

[boards.pynq_z2_02_pl.program.linux.params]
remote_dir = "/home/xilinx/.fpgahub"
sudo_secret = "pynq.ssh_password"
# ssh_opts inherits BatchMode=yes / StrictHostKeyChecking=accept-new
```

…and the equivalent `pynq_z2_03_pl` block with `ssh = "xilinx@192.168.6.101"`.

**Why PS-side IPs (`.4.101` / `.6.101`)** even though the pair is on PL
boards: PYNQ Linux is reachable via the Zynq PS GEM unconditionally.
The PL ethernet (LAN8720) only comes up after the bitstream loads,
which is exactly the operation we're trying to perform — chicken-and-
egg if we routed deploy traffic over the PL link.

### 2. Manifest binding

Add `manifest_path` to each pair member:

```toml
[boards.pynq_z2_02_pl]
manifest_path = "/home/dam1n19/SoCLabs/tidelink/fpga/fpgahub.toml"

[boards.pynq_z2_03_pl]
manifest_path = "/home/dam1n19/SoCLabs/tidelink/fpga/fpgahub.toml"
```

Reload after editing:

```sh
sudo systemctl reload fpgahubd        # or `restart` if reload doesn't pick it up
fpgahub manifest reload pynq_z2_02_pl
fpgahub manifest reload pynq_z2_03_pl
fpgahub manifest show pynq_z2_02_pl   # confirm the action list comes back
```

### 3. Secret store

Drop the PYNQ sudo password into a root-owned, group-fpga readable file:

```sh
sudo install -d -m 0750 -o root -g fpga /etc/fpgahub/secrets
echo -n "xilinx" | sudo tee /etc/fpgahub/secrets/pynq.passwd > /dev/null
sudo chmod 0640 /etc/fpgahub/secrets/pynq.passwd
sudo chgrp fpga /etc/fpgahub/secrets/pynq.passwd
```

Test with `fpgahub board program pynq_z2_02_pl <bit>` later — the
`pynq_overlay` plugin reads this via the `pynq.ssh_password` secret
reference set above.

### 4. SSH key from mapstone-dev → boards

`pynq_overlay` runs with `BatchMode=yes`, so password auth in argv is
out of the picture. Either:

a. **Key-based**: install `~root/.ssh/id_ed25519.pub` (or whatever the
   daemon runs as) into `xilinx@<board>:~/.ssh/authorized_keys` on
   each board. One-time setup. fpgahubd then SSHes silently.

b. **Password via `sshpass` wrapped by the plugin**: `pynq_overlay`'s
   `sudo_secret` mechanism handles the *remote* sudo password but
   not the *SSH* password — for that, key-based is the only option
   without forking the plugin.

Option (a) is the standard path. The boards already have the
`xilinx` user; just append the daemon's pubkey.

### 5. Manifest update — role-aware bitstream

Two options. **Option A** (simpler, use built-in `vivado_xsa.bin`-style
artefact selector by role) requires a fpgahub feature I haven't
verified exists. **Option B** (add explicit pair-all / pair-flip-all
TARGETs and let the role decide which to call) is local to our repo.

### Option B — recommended

Edit `fpga/Makefile` to expose `pair-all` / `pair-flip-all` as
selectable TARGETs (already valid per `VALID_TARGETS`). Then in
`fpga/fpgahub.toml` add:

```toml
[artefacts.bitstream_pynq_z2_pair_all]
kind = "bitstream"
path = "../imp/fpga/output/pynq-z2-pair-all/tidelink.bit"

[artefacts.bitstream_bin_pynq_z2_pair_all]
kind = "bitstream"
path = "../imp/fpga/output/pynq-z2-pair-all/tidelink.bin"

[artefacts.hwh_pynq_z2_pair_all]
kind = "other"
path = "../imp/fpga/output/pynq-z2-pair-all/tidelink.hwh"

# (and the matching trio for pair-flip-all)
```

Replace the existing `deploy_z2_pair` action with a role-aware one:

```toml
[[actions]]
id          = "deploy_pair_role_aware"
title       = "Deploy bitstream matching this side's pair role"
description = "Uses PYNQ fpga_manager over SSH/SCP. die_a → pair-all, die_b → pair-flip-all."
command     = ["make", "-C", "fpga", "deploy",
               "TARGET=pynq-z2-{pair.local.target_suffix}",
               "PYNQ_HOST={host.ssh}",
               "PYNQ_PROXY={host.proxy}"]
secret_env  = { PYNQ_PASSWORD = "pynq.ssh_password" }
requires    = ["pair_member"]
timeout_s   = 600
```

…where `target_suffix` is a new pair-role token rendered by fpgahub.
If that token doesn't exist, the simpler approach is two separate
actions, `deploy_pair_master` (TARGET=pynq-z2-pair-all) and
`deploy_pair_slave` (TARGET=pynq-z2-pair-flip-all), and binding them
to the right board via `requires`/`role` filters.

### 6. CI assembly

Update `ci_pair_full` to chain the role-aware deploy + the existing
`stress_pair`:

```toml
[[actions]]
id        = "ci_pair_full"
title     = "Full CI: build → deploy → stress (pair)"
steps     = ["build_z2_pair_all", "build_z2_pair_flip_all",
             "deploy_pair_role_aware", "stress_pair"]
timeout_s = 0
```

Now `fpgahub actions run bridge1 ci_pair_full` (chassis-level) builds
both bitstreams, deploys the matching one to each member, and runs
the paired stress test in one shot.

## After this lands

From any client (this dev box, your laptop, CI):

```sh
# acquire pair lease — 1 hour
fpgahub --addr mapstone-dev.ecs.soton.ac.uk pair lease acquire bridge1 \
    --user $(whoami) --ttl 3600

# deploy the right bitstream to each side
fpgahub actions run pynq_z2_02_pl deploy_pair_role_aware
fpgahub actions run pynq_z2_03_pl deploy_pair_role_aware

# run paired stress test (orchestrates SSH-on-master internally)
fpgahub actions run pynq_z2_02_pl stress_pair

# release
fpgahub --addr ... pair lease release bridge1
```

Or in one shot via the `make` wrapper:

```sh
make TARGET=pynq-z2-pair-all program_via_plugin BOARD=pynq_z2_02_pl
make TARGET=pynq-z2-pair-flip-all program_via_plugin BOARD=pynq_z2_03_pl
make stress_via_fpgahub FPGAHUB_TARGET=pynq_z2_02_pl
```

## What this buys us

1. **No SSH passwords in argv** — pubkey + secret store, both off-process.
2. **No per-machine SSH plumbing** — the daemon owns the SSH path; clients only need `--addr mapstone-dev.ecs.soton.ac.uk`.
3. **Lease-aware** — fpgahub serialises pair access; concurrent CI jobs queue properly.
4. **Composable** — `ci_pair_full` chains build → deploy → stress, fail-fast.
5. **Audit trail** — every action is logged with run ID, lease holder, and SSE event stream.
6. **Symmetric for solo + pair** — the same `program.linux` plugin handles single-instance deploys too; `deploy_z2_single` already exists.

## Files to edit

- `/etc/fpgahub/config.toml` — board host + program + secrets + manifest_path additions (sudo).
- `/etc/fpgahub/secrets/pynq.passwd` — new file (sudo).
- `~xilinx/.ssh/authorized_keys` on each board — new pubkey entries (one-time).
- `fpga/fpgahub.toml` — new artefact entries for `pair-all` / `pair-flip-all`, role-aware `deploy_pair_role_aware` action, updated `ci_pair_full`.
- `fpga/Makefile` — confirm `TARGET=pynq-z2-pair-all` / `pynq-z2-pair-flip-all` work end-to-end (they're already in `VALID_TARGETS`; just verify `BITSTREAM` path resolves).

## Token vocabulary verified (2026-05-08)

`fpgahub/manifest.py` declares these pair tokens (other tokens, e.g.
`target_suffix`, do **not** exist):

```
pair.id, pair.link_kind, pair.local.role, pair.peer.{name,role,ip,
   mac,pl_mac,hostname,host.ssh,host.proxy,host.dev_host}
```

There is no `requires_role` filter on actions — only `requires`
(flag-based) and `requires_capabilities` (capability tags). So the
single-action / role-conditional pattern below is what works.

### Final shape of the role-aware deploy action

In `fpga/Makefile`, add a small dispatcher that maps
`{pair.local.role}` → bitstream target:

```make
# Map fpgahub pair role (die_a / die_b) → bitstream TARGET, then run deploy.
.PHONY: deploy_pair_role
deploy_pair_role:
	@case "$(ROLE)" in \
	    die_a) $(MAKE) -f $(firstword $(MAKEFILE_LIST)) deploy TARGET=pynq-z2-pair-all PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)" ;; \
	    die_b) $(MAKE) -f $(firstword $(MAKEFILE_LIST)) deploy TARGET=pynq-z2-pair-flip-all PYNQ_HOST="$(PYNQ_HOST)" PYNQ_PROXY="$(PYNQ_PROXY)" ;; \
	    *)     echo "ERROR: ROLE must be die_a or die_b (got '$(ROLE)')" >&2; exit 2 ;; \
	esac
```

And in `fpga/fpgahub.toml`, replace `deploy_z2_pair` with:

```toml
[[actions]]
id          = "deploy_pair"
title       = "Deploy bitstream matching this side's pair role"
description = "PYNQ fpga_manager over SSH/SCP. die_a → pair-all, die_b → pair-flip-all."
command     = ["make", "-C", "fpga", "deploy_pair_role",
               "ROLE={pair.local.role}",
               "PYNQ_HOST={host.ssh}",
               "PYNQ_PROXY={host.proxy}"]
secret_env  = { PYNQ_PASSWORD = "pynq.ssh_password" }
timeout_s   = 600
```

`ci_pair_full` becomes:

```toml
[[actions]]
id        = "ci_pair_full"
title     = "Full CI: build → deploy → stress (pair)"
steps     = ["build_z2_pair_all", "build_z2_pair_flip_all",
             "deploy_pair", "stress_pair"]
timeout_s = 0
```

Add the two missing build actions:

```toml
[[actions]]
id        = "build_z2_pair_all"
title     = "Build pynq-z2-pair-all (master)"
command   = ["make", "-C", "fpga", "TARGET=pynq-z2-pair-all", "build_design"]
produces  = ["bitstream_built_z2_pair_all"]
timeout_s = 3600

[[actions]]
id        = "build_z2_pair_flip_all"
title     = "Build pynq-z2-pair-flip-all (slave)"
command   = ["make", "-C", "fpga", "TARGET=pynq-z2-pair-flip-all", "build_design"]
produces  = ["bitstream_built_z2_pair_flip_all"]
timeout_s = 3600
```

## Routing + secret-store verified (2026-05-08)

- mapstone-dev has direct kernel routes to both PS-side /24s:
  - `192.168.4.0/24 dev pynq_z2_02_ps`
  - `192.168.6.0/24 dev pynq_z2_03_ps`
  So `xilinx@192.168.4.101` from the daemon resolves with no extra
  ProxyJump plumbing — `host.proxy` stays empty.
- There's no top-level `fpgahub secrets list` command. The
  `secret_env = { … = "pynq.ssh_password" }` mechanism in the
  manifest indirects via `[boards.<n>.secrets]` → `file:<path>`. So
  the file path is per-board and entirely operator-chosen; the
  proposal's `/etc/fpgahub/secrets/pynq.passwd` is a sensible
  convention but not enforced.

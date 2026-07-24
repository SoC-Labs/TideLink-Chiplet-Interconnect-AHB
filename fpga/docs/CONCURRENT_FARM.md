# TideLink FPGA — concurrent independent-job farm

This is the **second**, complementary farming model to
`FARM_NFS_EXPORT_REQUEST.md`. Pick by what you actually want:

| | Vivado `-host` (`FPGA_REMOTE_HOSTS`) | Concurrent farm (this doc) |
|---|---|---|
| What it distributes | *runs inside one* `vivado` invocation | *whole `build_design` invocations* |
| Parallelism for this flow | ~none — one `synth_1`→`impl_1` per TARGET | **N TARGETs build at once**, one per host |
| Needs identical-path **NFS export** | **yes** (still an open sysadmin request) | **no** |
| Needs identical Vivado path + passwordless ssh | yes | yes (remote host only) |
| Works **today** | no (NFS export not in place) | **yes** |

The win here is concrete: a pair build is **two fully independent Vivado
builds** — master `pynq-z2-pair-all` and slave `pynq-z2-pair-flip-all`.
Sequentially that is ~2×22 min back-to-back. Run them concurrently, one
local and one on `farm-host-a`, and the pair finishes in roughly the time of a
single build while taking the slave's load off the contended local host.

## Use it

```bash
# Pair: master here + slave on farm-host-a, at the same time (the headline):
make -C fpga build_pair_farmed FARM_HOST=farm-host-a

# Pair: both halves in parallel on THIS host (no remote dependency):
make -C fpga build_pair_concurrent

# Generic: any set of TARGETs, each pinned to local or a farm host:
make -C fpga farm_build \
     FARM_JOBS="pynq-z2-pair-all@local pynq-z2-pair-flip-all@farm-host-a"
make -C fpga farm_build \
     FARM_JOBS="pynq-z2-single@local mps3@farm-host-a"

# ILA build (passes through to build_design.tcl):
make -C fpga build_pair_farmed FPGA_INSERT_DEBUG_CORE=1
```

Artefacts land at `imp/fpga/output/<TARGET>/tidelink.bit|.hwh|.xsa` for
**both** local and farmed jobs — the exact path `make deploy`,
`deploy_pair_role` and the fpgahub deploy actions already read, so nothing
downstream changes. Per-job logs: `imp/fpga/run/farm/<TARGET>@<HOST>.<ts>.log`;
the orchestrator prints a PASS/FAIL table and tails any failed job's log.

## One-time remote setup (per farm host)

```bash
fpga/scripts/setup_farm_ssh.sh FARM_HOST=farm-host-a   # passwordless ssh (1 prompt)
```

The remote host additionally needs (verified on farm-host-a, 2026-05-18):

* `vivado` 2024.1 at `/apps/Xilinx/Vivado/2024.1/bin/vivado` (same as here),
* the shared `/research` IP mount (`/research/AAA/ip_library/...` — CMSDK/XHB500),
* `rsync` + `make` on `PATH`.

`farm_build.sh` preflights all of these and fails fast with the exact fix
rather than hanging a parallel run. No NFS export, no shared `$HOME`.

## How a farmed job works

1. `build_farm.sh` runs `make package_ip` **once locally** (the IP repo
   `imp/fpga/tidelink_ip` is TARGET-independent) so the parallel
   `build_design` fan-out can't corrupt it with concurrent writers. Local
   jobs then run with `SKIP_PACKAGE_IP=1` to reuse that one repo.
2. For a remote job, `farm_build.sh`:
   * `rsync`s the working tree to `~/.cache/tidelink-farm/<TARGET>/` on the
     host — including the submodule working tree and the gitignored-but-real
     `deps/xhb500/generated/` (so the remote skips XHB500 regeneration);
     excluding `imp/`, `.git/`, sim/coverage debris. `--delete` mirrors
     source deletions but **protects** the remote `imp/` so re-syncs keep
     Vivado's incremental state.
   * runs `make package_ip && make build_design TARGET=<t>` **on the host**
     (its own tree → its own IP repo, no cross-host races),
   * `rsync`s only `imp/fpga/output/<TARGET>/` back to the identical local
     path (plus the run log for diagnosis).
3. All jobs run under `&`; the orchestrator `wait`s each, aggregates exit
   codes, and exits non-zero if any failed.

## Concurrency-safety changes in the Makefile

Two shared-state hazards had to be closed for parallel local builds:

* `package_ip` is `.PHONY`, so every `make build_design` used to re-trigger
  it → N concurrent writers to the one IP repo. `build_design` now takes its
  `package_ip` prerequisite **conditionally**: `SKIP_PACKAGE_IP=1` drops it,
  and the farm runs `package_ip` exactly once up front. Standalone
  `make build_design` is unchanged (still does `package_ip` first).
* `build_design` used a shared `RUN_DIR` as cwd and a shared
  `build_design.log/.jou`. It now uses a **per-TARGET** `BUILD_RUN_DIR =
  $(RUN_DIR)/$(TARGET)` for cwd, log and journal, so two TARGETs building at
  once can't clobber each other's `.Xil/`, journal or log.

Neither change affects a normal single-target `make build_design` /
`make deploy` flow.

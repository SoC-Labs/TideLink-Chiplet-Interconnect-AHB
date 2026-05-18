# TideLink FPGA build farm — Vivado `-host` + NFS export request

> **If you just want concurrent farmed builds today**, you do **not** need
> this NFS export — see **`CONCURRENT_FARM.md`** for independent-job farming
> (`make build_pair_farmed` / `farm_build`), which runs whole-TARGET builds
> in parallel across hosts over plain ssh+rsync. This document is only for
> Vivado-native `launch_runs -host` run-distribution, which remains blocked
> on the NFS export below.


This sets up **Vivado-native remote-host farming** (`launch_runs -host`) so the
CPU-contended `srv03335` can offload synthesis/implementation onto `srv04936`
(and run multiple OOC-IP / strategy runs in parallel where they exist).

## What Vivado actually does (so the requirements make sense)

`launch_runs synth_1 -host {srv03335 4} -host {srv04936 8}` makes Vivado **SSH
into each host and execute the generated `runme.sh` in the *same absolute run
directory***. It distributes whole *runs* across hosts — a single run executes
entirely on one host; it does **not** split one synth/impl across machines.
With this flow's one `synth_1`→`impl_1` per target the concrete win is
*offload* onto the less-loaded host, plus parallelism when several runs exist.

Hard requirements (Vivado 2024.1, UG892; Project Mode, Linux only):

| # | Requirement | Status here |
|---|-------------|-------------|
| 1 | Project + run tree at the **identical absolute path** on every host | **NEEDS THE NFS EXPORT BELOW** — `/home` is local per host |
| 2 | Vivado at the **identical path**, same version, on every host | `/apps/Xilinx/Vivado/2024.1` is **local disk** on srv03335 — srv04936 must have the same install at the same path |
| 3 | **Passwordless** SSH launcher→host (Vivado uses `BatchMode=yes`) | run `fpga/scripts/setup_farm_ssh.sh` |
| 4 | Consistent uid/gid + clock across hosts | central auth → uid 74755 `dam1n19`, gid 245 `fp` consistent; checked by `farm_check` |

Anything Vivado reads by absolute path (RTL, IP repo, target dir, the
`.runs`/`.gen` dirs) must satisfy #1 — so the **whole repo tree
`/home/dam1n19/SoCLabs` must be shared**, not just the build output. That is
exactly the directory in scope. Dependencies already under `/research`
(`ARM_IP_LIBRARY_PATH`, `CMSDK_DIR`, …) are already identical on both hosts.

## The request to send to the sysadmin / ECS-IT

> **Subject:** NFS export of a build tree, srv03335 → srv04936, identical path
>
> For Vivado distributed runs I need the directory **`/home/dam1n19/SoCLabs`**
> on **srv03335** to be visible **read-write at the exact same absolute path
> `/home/dam1n19/SoCLabs` on srv04936** (Vivado SSHes to the remote host and
> runs in the same absolute path; the path must match byte-for-byte).
>
> - Access: RW, for uid `74755` (`dam1n19`), gid `245` (`fp`) / `5171` (`arm`).
> - `root_squash` is fine — all build I/O is as `dam1n19`, never root.
> - File locking must work (Vivado/`.runs` rely on it): NFSv4.x preferred
>   (same as the existing `/eda`, `/srv` exports), or NFSv3 **with**
>   `nlockmgr`. Mount `rw,hard,sync` (or `actimeo` tuned), not `soft`.
> - It overlays a subtree of srv04936's *local* `/home/dam1n19` — a single
>   NFS submount on `/home/dam1n19/SoCLabs` is intended and expected.
>
> If srv03335 cannot itself be an NFS server (workstation/firewall), an
> equivalent that satisfies Vivado is **either** host serving the tree, **or**
> relocating it onto a NAS-backed share that is mounted at one identical
> absolute path on **both** hosts — see the fallback below.

## Fallback if an exact mount over local `/home` is refused

Vivado only cares that the path is **identical on both hosts** — not that it is
under `/home`. If IT will not submount over local `/home/dam1n19`, ask for the
tree on any neutral path mounted identically on both (e.g.
`/fpgafarm/tidelink`), then point the build at it — `BUILD_DIR` (and the repo
checkout) live there, and Vivado's baked-in absolute paths then match:

```
make TARGET=pynq-z2-pair build_design \
     BUILD_DIR=/fpgafarm/tidelink/imp/fpga \
     FPGA_REMOTE_HOSTS="srv03335 4 srv04936 8"
```

(Do **not** try a symlink to fake the path — Vivado resolves real paths into
`runme.sh`; only a real identical mountpoint works.)

## Bring-up runbook

```bash
# 0. (sysadmin) NFS export in place per the request above.

# 1. Passwordless SSH for unattended Vivado login (one password prompt):
fpga/scripts/setup_farm_ssh.sh            # FARM_HOST=srv04936 default

# 2. Confirm srv04936 has Vivado 2024.1 at /apps/Xilinx/Vivado/2024.1
#    (req #2 — local-disk install; ask IT to mirror it if absent).

# 3. Verify ALL four prerequisites before trusting a real build:
make -C fpga farm_check FARM_HOST=srv04936     # must print RESULT: PASS

# 4. Farm a build (offload heavier share onto the less-loaded srv04936):
make -C fpga TARGET=pynq-z2-pair build_design \
     FPGA_REMOTE_HOSTS="srv03335 4 srv04936 8"
```

Leave `FPGA_REMOTE_HOSTS` empty for an unchanged local build. Kerberos sites
that prefer GSSAPI over a long pubkey session: see the alternative
`FPGA_REMOTE_CMD` documented in `fpga/scripts/setup_farm_ssh.sh`.

## Files

| File | Role |
|------|------|
| `fpga/build_design.tcl` | reads `FPGA_REMOTE_HOSTS`/`FPGA_REMOTE_CMD` → `launch_runs -host` |
| `fpga/Makefile` | `FPGA_REMOTE_HOSTS`, `FPGA_REMOTE_CMD`, `farm_check` |
| `fpga/scripts/farm_preflight.sh` | validates the 4 requirements vs `FARM_HOST` |
| `fpga/scripts/setup_farm_ssh.sh` | passwordless SSH bootstrap |

# TideLink live-eye browser (web)

A FastAPI + Plotly toolkit that turns the 4-step manual ritual
(lease bridge1 -> stage bitstream -> SSH deploy+converge -> SSH eye
sweep) into "open a URL, click Run, watch the eye render live."

Reuses the v1 16-phase global sweep in `../eye_sweep.py` (now a
generator); the future `--mode deep` (per-lane 128-point score grid
via Region-10 APB) will drop in behind the same UI shell.

## Quick start (dev)

```bash
# 1. Install deps
python3 -m venv ~/.venvs/tideeye
~/.venvs/tideeye/bin/pip install -r pynq_host/scripts/eye_toolkit/web/requirements.txt

# 2. Run from the repo root
cd ~/SoCLabs/tidelink
~/.venvs/tideeye/bin/uvicorn pynq_host.scripts.eye_toolkit.web.app:app \
    --host 127.0.0.1 --port 8088

# 3. From your laptop, open an SSH tunnel and visit it
laptop$ ssh -L 8088:localhost:8088 mapstone-dev
laptop$ open http://localhost:8088/
```

## Quick start (production via systemd)

```bash
cd ~/SoCLabs/tidelink/pynq_host
make install-web                # copies the user unit to ~/.config/systemd/user/
systemctl --user enable --now tideeye-web
systemctl --user status tideeye-web
```

The unit binds `127.0.0.1:8088` and uses `WorkingDirectory=%h/SoCLabs/tidelink`.

## Auth model

- **No auth on the HTTP surface.** The server is loopback-only; SSH
  local-port-forwarding is the authentication.
- **fpgahubd auth:** prefers the unix socket at
  `/run/fpgahub/fpgahub.sock` (filesystem perms gate access — make
  sure the daemon user is in group `fpga`). Falls back to a Bearer
  token if you set `FPGAHUB_TOKEN=<...>` in the systemd unit's
  Environment= line.

## **DO NOT expose publicly**

> The live-eye server has **no** authentication on its HTTP surface.
> The systemd unit binds `127.0.0.1`; any change to `0.0.0.0` would
> let any host on the lab network drive deploys and consume the
> `bridge1` lease. The entry-point CLI hard-refuses `--host 0.0.0.0`
> for the same reason.

## API surface

| Endpoint                          | Method | Purpose |
|-----------------------------------|--------|---------|
| `/`                               | GET    | Serves the SPA |
| `/healthz`                        | GET    | Liveness probe |
| `/api/lease?board=bridge1`        | GET    | Current holder + queue length |
| `/api/lease/release`              | POST   | Releases the server-side lease |
| `/api/runs`                       | POST   | Starts a run; 409 if one is already in flight |
| `/api/runs/{id}/state`            | GET    | Current state of a run |
| `/api/runs/{id}/abort`            | POST   | Aborts a run |
| `/api/runs/{id}/events`           | GET    | SSE stream of run events |

POST `/api/runs` body (all fields optional):

```json
{
  "stage_dir":     "/tmp/tidelink_deploy",
  "master_ip":     "192.168.4.101",
  "slave_ip":      "192.168.6.101",
  "board":         "bridge1",
  "skip_deploy":   false,
  "skip_converge": false,
  "ttl_seconds":   1800
}
```

## SSE event kinds

| Event           | Payload fields                                  |
|-----------------|--------------------------------------------------|
| `state`         | `state` (the new RunState string), `reason?`    |
| `lease_acquired`| `holder`, `token`, `expires_at`                  |
| `lease_lost`    | `reason`                                         |
| `deploy`        | `deploy_kind` (`deploying` / `deployed` / `bringup_started` / `lane_count` / `bringup_ok` / `bringup_failed` / `deploy_failed` / `unreachable`), `board?`, plus event-specific fields |
| `sweep_row`     | `board`, `phase`, `lock_mask`, `lock_count`, `fault_mask`, `cal_done`, `fcsm_state`, `cr_pkt_seen` |
| `closed`        | (sentinel — end of stream)                       |
| `ping`          | keepalive every 15s                              |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `503` on `/api/lease` with "no fpgahubd auth available" | Not in group `fpga` AND `FPGAHUB_TOKEN` not set | `sudo gpasswd -a $USER fpga` then re-login, OR set `FPGAHUB_TOKEN` in the unit's Environment= |
| `404` on `/api/lease` saying "not a known fpgahub link or board" | `bridge1` doesn't exist on this fpgahubd | Check `/api/v1/links` on the daemon; correct the `board` field in your POST body |
| Run hangs at `lease_queued` | Someone else holds `bridge1` | Wait for them; or hit `/api/lease/release` if you know it's stale |
| SSE never delivers `sweep_row` | Board unreachable / sshpass missing on host | Check `bringup_pair_converge.sh` runs manually; install `sshpass` on `mapstone-dev` |
| Heatmap stays grey | Browser EventSource was closed by an intermediate proxy that strips `text/event-stream` | The SSH tunnel works directly; if you've put nginx in front, configure `proxy_buffering off` |
| `409` when starting a new run | Previous run is still active | Click Abort first; or wait for it to terminate |

## Deferred (v1.1 / v2 — see `docs/LIVE_EYE_BROWSER_PROPOSAL.md`)

- "Recent builds" dropdown (scan `~/SoCLabs/tidelink/staging/`).
- `mode=averaging` for marginal-phase detection.
- `/snapshot.png` endpoint.
- `mode=deep` 8x128 per-lane score grid (gated on Region-10 RTL).
- Continuous re-sweep loop (current default is single-sweep on demand).

## Files

```
app.py        FastAPI app: routes + SSE.
lease.py      fpgahubd REST client (links/boards auto-detect, heartbeat task).
deploy.py     subprocess wrapper for deploy_pair.sh + bringup_pair_converge.sh.
sweep_live.py async wrapper around eye_sweep.iter_sweep_global_phase().
runner.py     per-session Run state machine + asyncio.Queue event stream.
static/       index.html + app.js + style.css (Plotly via CDN).
systemd/      tideeye-web.service user unit.
tests/        pytest suite — runs in <10s without HW.
requirements.txt
```

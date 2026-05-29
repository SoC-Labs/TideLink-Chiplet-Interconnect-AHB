# TideLink stress_toolkit web

FastAPI + Plotly browser GUI for end-to-end functional stress testing.
Sibling to `eye_toolkit/web/` (live-lane-phase).

## API surface

| Endpoint                          | Method | Purpose |
|-----------------------------------|--------|---------|
| `/`                               | GET    | Serves the SPA |
| `/healthz`                        | GET    | Liveness probe |
| `/api/lease?board=bridge1`        | GET    | Current holder + queue |
| `/api/lease/release`              | POST   | Releases the server-side lease |
| `/api/runs`                       | POST   | Starts a run; 409 if one already in flight |
| `/api/runs/{id}/state`            | GET    | Current state of a run |
| `/api/runs/{id}/abort`            | POST   | Aborts a run |
| `/api/runs/{id}/events`           | GET    | SSE stream of run events |

POST body — `mode` selects one of six test families, plus per-mode
configs:

```json
{
  "mode": "packet",
  "stage_dir": "/tmp/tidelink_deploy",
  "master_ip": "192.168.4.101",
  "slave_ip":  "192.168.6.101",
  "board":     "bridge1",
  "skip_deploy":   true,
  "skip_converge": true,
  "enable_phy_sentinel": true,
  "packet": {
    "packet_size_words": 16,
    "packet_count":      100,
    "direction":         "both",
    "inter_packet_us":   0
  }
}
```

## Modes

* `packet`   — AHB packet roundtrip (TX -> peer FIFO -> verify)
* `doorbell` — APB doorbell flood with `DOORBELL_RESP_ACC` verification
* `ptp`      — port of `bringup_ptp_sync.sh` (PHC convergence)
* `phy`      — passive `tidelink_gpio_phy_apb_regs` poller
* `fcsm`     — `SWI_LANE_STATUS` poller (kill-switch sentinel)
* `auto`     — randomised mix of the first three with PHY health alarm

## DO NOT expose publicly

* No HTTP auth — loopback-only.
* Hard-refuses `--host 0.0.0.0`.
* Authenticate via SSH local-port-forward.

## Quick start

```bash
python3 -m venv ~/.venvs/tidestress
~/.venvs/tidestress/bin/pip install \
    -r pynq_host/scripts/stress_toolkit/web/requirements.txt
cd ~/SoCLabs/tidelink
~/.venvs/tidestress/bin/uvicorn \
    pynq_host.scripts.stress_toolkit.web.app:app \
    --host 127.0.0.1 --port 8089
```

## systemd

```bash
cp pynq_host/scripts/stress_toolkit/web/systemd/tidelink-stress-web.service \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now tidelink-stress-web
```

Coexists with `tideeye-web.service` (port 8088).

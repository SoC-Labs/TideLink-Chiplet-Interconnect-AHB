# TideLink stress_toolkit

Comprehensive HW functional stress testing for the TideLink chiplet
bridge. Sibling to `eye_toolkit` (live-lane-phase channel
characterisation) — this one focuses on whether **the data path
works** under load, while `eye_toolkit` answers **how good is the
channel**.

## Test modes

1. **AHB packet stress** — packet write/read roundtrip across many
   sizes and directions, with credit/RELEASED_ACC tracking.
2. **Doorbell volume stress** — flood APB `REG_DOORBELL` and verify
   `DOORBELL_RESP_ACC` deltas equal `N * MAX_CREDITS`.
3. **PTP HW sync convergence** — port of `bringup_ptp_sync.sh`; servos
   slave to master via the FC-adapter HW_SYNC initiator and confirms
   `SERVO_STATUS.locked` within 5 s, sustained |offset| < 100 ns for
   10 consecutive samples.
4. **PHY health monitoring** — passive 1 Hz poll of
   `tidelink_gpio_phy_apb_regs` at `0x4403_2160`. Surfaces
   canary/wiring/noise anomalies. Runs alongside any other test.
5. **FCSM credit-path live state** — 10 Hz poll of `SWI_LANE_STATUS`
   @ `0x4403_2108`; abort sentinel if FCSM ever leaves LINK_IDLE
   during another test.
6. **AUTO mode** — randomised mix of the above 5 for a user-picked
   duration, with PHY health always running as the alarm.

## Run

```bash
# From the repo root:
python3 -m venv ~/.venvs/tidestress
~/.venvs/tidestress/bin/pip install -r pynq_host/scripts/stress_toolkit/web/requirements.txt
cd ~/SoCLabs/tidelink
~/.venvs/tidestress/bin/uvicorn pynq_host.scripts.stress_toolkit.web.app:app \
    --host 127.0.0.1 --port 8089
```

Then from your laptop:

```bash
ssh -L 8089:localhost:8089 mapstone-dev
open http://localhost:8089/
```

The `tidelink-stress-web.service` systemd unit binds `127.0.0.1:8089`
and can run concurrently with `tideeye-web.service` on `:8088`.

## Safety

* The runner NEVER writes to `AHB_TX` (`0x4400_0000`) speculatively.
  The AHB packet test does, but only after a link-up pre-flight (16/16
  lanes + cal_done + FCSM == LINK_IDLE) and only via the safe
  `assert_link_safe_for_tx` gate inherited from `overlay.py`.
* Doorbell volume / PHY health / FCSM monitor / PTP convergence test
  modes only touch APB / PHC / PMOD — they are wedge-safe even on a
  bad link.

## Architecture

```
pynq_host/scripts/stress_toolkit/
├── README.md                     — this file
├── stress_lib.py                 — shared register maps + parsers
├── tests/                        — pytest for stress_lib
└── web/
    ├── README.md
    ├── app.py                    — FastAPI entry, SSE stream
    ├── runner.py                 — async per-mode orchestrator
    ├── lease.py                  — re-export of eye_toolkit/web/lease.py
    ├── deploy.py                 — re-export of eye_toolkit/web/deploy.py
    ├── mmio_remote.py            — SSH /dev/mem read/write wrapper
    ├── stress_modes.py           — six test modes (PacketStress,
    │                               DoorbellVolume, PtpConvergence,
    │                               PhyHealth, FcsmMonitor, Auto)
    ├── tests/                    — pytest for runner / parsers
    ├── requirements.txt
    ├── systemd/
    │   └── tidelink-stress-web.service
    └── static/
        ├── index.html
        ├── app.js
        └── style.css
```

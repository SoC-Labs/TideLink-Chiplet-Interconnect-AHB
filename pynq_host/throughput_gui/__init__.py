"""TideLink throughput-characterization web GUI (port 8090).

Third member of the web-toolkit family (eye_toolkit/web :8088,
stress_toolkit/web :8089) per docs/THROUGHPUT_GUI_PLAN_2026_06_12.md.

P0 walking skeleton: one canned ``throughput_m2s`` run end-to-end with a
live SSE Plotly chart, SQLite+NDJSON run store, fail-closed bitstream
provenance, and the safety interlocks (criterion-B + delivery-proof gate,
single-experiment mutex, jam-signature auto-abort).
"""

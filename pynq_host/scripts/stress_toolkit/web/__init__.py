"""TideLink stress_toolkit web app — FastAPI + Plotly + SSE.

Listens on 127.0.0.1:8089 (eye_toolkit uses :8088). Both can run
concurrently and share the bridge1 lease via fpgahubd.
"""

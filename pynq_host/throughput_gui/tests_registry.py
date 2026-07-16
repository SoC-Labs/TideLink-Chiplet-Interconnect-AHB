"""Test-definition registry (§4.1 contract).

A test definition is an opaque contract
``{name, params, target boards} -> {status stream, results}`` so the
companion test-plan doc can land new tests here with NO frontend
changes — the GUI renders parameter forms from ``param_schema``.

P0 ships only the canned ``throughput_m2s`` test. P1 adds
throughput_s2m / throughput_bidir / doorbell_rtt / credit_recovery /
soak and sweep axes.
"""
from __future__ import annotations

REGISTRY = {
    "throughput_m2s": {
        "name": "throughput_m2s",
        "title": "M→S sustained throughput",
        "category": "throughput",
        "param_schema": {
            "burst_words": {"type": "int", "default": 16,
                            "min": 1, "max": 256,
                            "doc": "payload words per packet"},
            "rate_pps": {"type": "float", "default": 0.0, "min": 0.0,
                         "doc": "offered packet rate; 0 = unthrottled"},
            "duration_s": {"type": "float", "default": 10.0,
                           "min": 0.5, "max": 600.0},
            "win_s": {"type": "float", "default": 0.5,
                      "min": 0.1, "max": 10.0,
                      "doc": "measurement window"},
        },
        "sweep_axes": ["burst_words", "rate_pps"],   # P1
        "targets": "both",
        "hazard": "ahb_tx",
    },
}


class ParamError(ValueError):
    pass


def get_test(name: str) -> dict:
    try:
        return REGISTRY[name]
    except KeyError:
        raise ParamError("unknown test %r (have: %s)"
                         % (name, ", ".join(sorted(REGISTRY))))


def validate_params(test_name: str, params: dict) -> dict:
    """Coerce + bound-check params against the schema; fill defaults.
    Raises ParamError on unknown keys or out-of-range values."""
    schema = get_test(test_name)["param_schema"]
    unknown = set(params) - set(schema)
    if unknown:
        raise ParamError("unknown params: %s" % ", ".join(sorted(unknown)))
    out = {}
    for key, spec in schema.items():
        raw = params.get(key, spec["default"])
        try:
            val = int(raw) if spec["type"] == "int" else float(raw)
        except (TypeError, ValueError):
            raise ParamError("param %s: not a %s: %r"
                             % (key, spec["type"], raw))
        if "min" in spec and val < spec["min"]:
            raise ParamError("param %s=%s below min %s"
                             % (key, val, spec["min"]))
        if "max" in spec and val > spec["max"]:
            raise ParamError("param %s=%s above max %s"
                             % (key, val, spec["max"]))
        out[key] = val
    return out

"""fpgahub_sdk.testkit — the test-porting kit (Phase 7B, SDK.md §2.2).

The :class:`RegBus` protocol (the *entire* hardware abstraction) +
:class:`HALBridge` (moved verbatim from the canonical
``cocotb/common/hal_bridge.py``, algorithm unchanged — only the
constructor seam generalised to a ``RegBus``) + the :class:`CocotbAhbBus`
sim adapter.

Importing this package must succeed with cocotb **absent** (it is the
dev-host-only ``fpgahub-sdk[cocotb]`` extra; the PYNQ PS and the
pure-unit tests run without it). ``CocotbAhbBus`` is therefore defined
unconditionally and only *imports* cocotb lazily when instantiated
(SDK.md §2.4 "cocotb is an optional extra").

:class:`PynqMmioBus` is added in 7C (SDK.md §2.2 / §4): the PS-side half
of the seam, ``pynq`` lazily imported so this re-export stays safe with
``pynq`` absent. :class:`JtagAxiBus` is added in 7E (SDK.md §2.2 / §5.2):
the no-PS analogue of :class:`PynqMmioBus` over Xilinx
``hw_server``/``xsdb``; its backend is lazily resolved on instantiation
so this re-export stays safe with the toolchain absent — exactly the
``cocotbext`` / ``pynq`` discipline.

Vendored copy — canonical source: ~/SoCLabs/fpgahub/src/fpgahub_sdk/testkit/
"""

from __future__ import annotations

from ._bridge import HALBridge
from .buses import CocotbAhbBus, JtagAxiBus, PynqMmioBus, RegBus, RegBusBase

__all__ = [
    "RegBus",
    "RegBusBase",
    "HALBridge",
    "CocotbAhbBus",
    "PynqMmioBus",
    "JtagAxiBus",
]

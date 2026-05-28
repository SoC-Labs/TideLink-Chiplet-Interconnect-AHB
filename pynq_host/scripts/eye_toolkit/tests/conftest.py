"""Make `eye_sweep` and `eye_dump_bilateral` importable when pytest is
run from anywhere — the toolkit is a script directory, not an
installed package."""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_TOOLKIT = os.path.dirname(_HERE)
if _TOOLKIT not in sys.path:
    sys.path.insert(0, _TOOLKIT)

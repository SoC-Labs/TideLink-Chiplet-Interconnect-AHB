"""Python model of a paired TideLink's APB register bank.

Used in simulation (cocotb py_pair tests) and potentially on PYNQ
to model the remote side when only one hardware instance is available.
"""

from tidelink.regs import (
    REG_DOORBELL,
    REG_RELEASED_ACC,
    REG_DOORBELL_RESP_ACC,
)


class PairRegisterBank:
    """Models the paired TideLink's APB register bank in Python.

    Processes writes that arrive from the DUT's AHB master:
    - Write to doorbell (0x014): triggers a response write back to the DUT
    - Write to released tokens accumulator (0x020): accumulates the value
    - Write to doorbell response accumulator (0x024): accumulates the value

    The pair has its own token count (simulating its own FIFO state) and
    can be independently reset.
    """

    def __init__(self, base_addr, dut_apb_base, max_tokens):
        self.base_addr = base_addr
        self.dut_apb_base = dut_apb_base
        self.max_tokens = max_tokens
        self.reset()

    def reset(self):
        self.token_count = self.max_tokens
        self.released_tokens_acc = 0
        self.doorbell_pending = False
        self.log_lines = []

    def log(self, msg):
        self.log_lines.append(msg)

    def handle_ahb_write(self, addr, data):
        """Process an AHB write from the DUT's returner master.

        Returns a list of (addr, data) response tuples that the caller
        should write back to the DUT's APB interface.
        """
        offset = addr - self.base_addr
        responses = []

        if offset == REG_DOORBELL:
            self.doorbell_pending = True
            self.log(f"PAIR: Doorbell rung! Responding with token_count={self.token_count}")
            responses.append((
                self.dut_apb_base + REG_DOORBELL_RESP_ACC,
                self.token_count
            ))
        elif offset == REG_RELEASED_ACC:
            self.released_tokens_acc += data
            self.log(f"PAIR: Received {data} released tokens "
                     f"(total accumulated: {self.released_tokens_acc})")
        elif offset == REG_DOORBELL_RESP_ACC:
            self.released_tokens_acc += data
            self.log(f"PAIR: Received {data} doorbell response tokens "
                     f"(total accumulated: {self.released_tokens_acc})")
        else:
            self.log(f"PAIR: Unknown write to offset 0x{offset:03X} = 0x{data:08X}")

        return responses

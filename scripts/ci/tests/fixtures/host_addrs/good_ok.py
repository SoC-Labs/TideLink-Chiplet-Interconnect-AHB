"""FIXTURE (must PASS check_host_addrs): real registers, a justified relative 0x3C, a foreign block."""
ERRINJ = 0x023C                            # link_error_injection
OFF_LANE_MASK = 0x214                      # link_lane_mask
OFF_STATUS = 0x2010                        # status
FC_NODE_PTP_REL = 0x3C   # regmap-lint: relative offset inside a PTP-node block, not an APB address
TC_CTRL = 0x8                              # TideChart block, foreign register space


def f(rd, wr):
    wr(0x8C03023C, 0)                      # die_b APB aperture + 0x23C
    return rd(0x84032108)                  # die_a APB aperture + swi_lane_status

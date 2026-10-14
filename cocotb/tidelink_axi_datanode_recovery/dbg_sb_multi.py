import cocotb
from cocotb.triggers import ClockCycles
from test_sideband_crc_breadth import setup, mkmsg, TX, RX
from test_sideband_crc_replay import _bringup
@cocotb.test()
async def t(dut):
    tb = await _bringup(dut); await setup(tb)
    from test_sideband_crc_replay import Mon
    mon = Mon(tb); mon.start()
    for i in range(3):
        await tb.ahb_tx_write_packet(TX, mkmsg(0xA0000000+i, 2), gap=4)
    await ClockCycles(dut.hclk, 20000)
    mon.stop()
    dut._log.info(f'DBG app_valid rises={mon.count(RX,"l2a_fc_replay_app_valid")} isExp={mon.count(RX,"isExpPacket")} notexp={mon.count(RX,"isNotExpPacket")} l9b={mon.count(RX,"socl_l9b_reanchor_now")} l9c={mon.count(RX,"socl_l9c_backward")}')
    dut._log.info('DBG expnum '+str([(e[0],e[3]) for e in mon.ev if e[1]==RX and e[2]=="exp_pkt_num"]))
    apb = tb.apb(RX)
    for r in (0x2004,0x200C,0x2010,0x201C):
        dut._log.info(f"DBG reg {r:#x} = {await apb.read(r):#x}")
    ws = [await tb.ahb_fifo_read_word(RX, i*4) for i in range(14)]
    dut._log.info("DBG words " + " ".join(f"{w:08x}" for w in ws))
    for r in (0x2010,):
        dut._log.info(f"DBG after reg {r:#x} = {await apb.read(r):#x}")

# tidelink_peer_aperture cocotb suite — flist pointer.
#
# The peer aperture test reuses the full tidelink_fpga.flist for the
# pair tb plus tidelink_eye_visibility.flist for the new Region 10 shim.
# This file is informational; the actual flists used at simulation time
# are passed via COMPILE_ARGS in the Makefile.
-f ${TIDELINK_HOME}/flists/tidelink_fpga.flist
-f ${TIDELINK_HOME}/flists/tidelink_eye_visibility.flist

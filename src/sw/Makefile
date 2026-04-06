# ──────────────────────────────────────────────────────────────────────────
# SoCLabs TideLink — C Driver Build & Generation
#
# Targets:
#   generate    Generate CMSIS-style C headers from SystemRDL sources
#   compile     Compile all driver .c files (syntax check, no link)
#   clean       Remove generated headers and object files
#
# Requirements:
#   - python3 with systemrdl-compiler installed
#   - arm-none-eabi-gcc (for compile target)
# ──────────────────────────────────────────────────────────────────────────

RDL2C       := python3 ../../scripts/rdl2c.py
RDL_DIR     := ../rdl
OUT_DIR     := .

CC          := arm-none-eabi-gcc
CFLAGS      := -mcpu=cortex-m0 -mthumb -Wall -Wextra -Werror -I.

# ── RDL sources → generated headers ─────────────────────────────────────

GENERATED_HEADERS := \
    $(OUT_DIR)/tidelink_regs.generated.h \
    $(OUT_DIR)/tidelink_ptp_regs.generated.h \
    $(OUT_DIR)/tidelink_addr_translator_regs.generated.h \
    $(OUT_DIR)/phc_regs.generated.h \
    $(OUT_DIR)/wlink_regs.generated.h

# ── Driver sources ──────────────────────────────────────────────────────

SRCS := tidelink.c tidelink_ptp.c tidelink_addr_trans.c tidelink_perf.c phc.c
OBJS := $(SRCS:.c=.o)

# ── Targets ─────────────────────────────────────────────────────────────

.PHONY: all generate compile clean

all: generate compile

generate: $(GENERATED_HEADERS)

compile: generate $(OBJS)

clean:
	rm -f $(GENERATED_HEADERS) $(OBJS)

# ── Generation rules ────────────────────────────────────────────────────

$(OUT_DIR)/tidelink_regs.generated.h: $(RDL_DIR)/tidelink_regs.rdl
	$(RDL2C) $< -o $@

$(OUT_DIR)/tidelink_ptp_regs.generated.h: $(RDL_DIR)/tidelink_ptp_regs.rdl
	$(RDL2C) $< -o $@

$(OUT_DIR)/tidelink_addr_translator_regs.generated.h: $(RDL_DIR)/tidelink_addr_translator_regs.rdl
	$(RDL2C) $< -o $@

$(OUT_DIR)/phc_regs.generated.h: $(RDL_DIR)/phc_regs.rdl
	$(RDL2C) $< -o $@

$(OUT_DIR)/wlink_regs.generated.h: $(RDL_DIR)/wlink_regs.rdl
	$(RDL2C) $< -o $@

# ── Compilation rules ───────────────────────────────────────────────────

%.o: %.c $(GENERATED_HEADERS)
	$(CC) $(CFLAGS) -c $< -o $@

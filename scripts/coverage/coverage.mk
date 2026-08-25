# coverage.mk - the coverage repository's make interface.
#
#   include scripts/coverage/coverage.mk      (from the top-level Makefile)
#
#   make cov_pack        build one coverage artifact from whatever .vdb files
#                        the last gate run left behind
#   make cov_publish     DRY RUN of the upload. Prints every PUT and property.
#   make cov_publish_real  actually upload      [NEEDS CREDENTIALS]
#   make cov_baseline    promote this artifact to verif-baseline  [NEEDS CREDS]
#   make cov_diff        diff the newest artifact against BASE=<dir>
#   make cov_track       write the small, git-tracked half into docs/coverage/
#   make cov_selftest    prove the whole chain offline: no store, no simulator
#
# COVERAGE IS COLLECTED BY THE SUITES, NOT BY THIS FILE. `make sim_gate` and
# `make -C cocotb coverage` produce the .vdb files; cov_pack.sh only ever reads
# them. That separation is deliberate: a packer that can also RUN the tests is a
# packer that can be asked to re-run one suite to fix a number.

COV_DIR      := $(SOCLABS_TIDELINK_DIR)/scripts/coverage
COV_OUT      ?= $(SOCLABS_TIDELINK_DIR)/imp/coverage
COV_SCOPE    ?= $(COV_DIR)/SCOPE.txt
COV_TRACKED  ?= $(SOCLABS_TIDELINK_DIR)/docs/coverage

# The newest artifact, resolved once. `ls -1dt ... | head -1` is avoided on
# purpose: `head` exiting first kills the pipeline under pipefail, which has
# already bitten this project three times in three different scripts.
COV_LATEST = $$(find $(COV_OUT) -maxdepth 1 -type d -name 'covrun-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | sed -n '1s/^[^ ]* //p')

.PHONY: cov_pack cov_publish cov_publish_real cov_baseline cov_diff cov_track cov_selftest cov_latest

cov_pack:
	@bash $(COV_DIR)/cov_pack.sh --out $(COV_OUT) --scope $(COV_SCOPE) \
	    --suites "$(SIM_GATE_ALL_SUITES)" $(COV_PACK_ARGS)

cov_latest:
	@echo "$(COV_LATEST)"

cov_publish:
	@a="$(COV_LATEST)"; [ -n "$$a" ] || { echo "cov_publish: no artifact under $(COV_OUT) -- run 'make cov_pack'"; exit 2; }; \
	python3 $(COV_DIR)/cov_publish.py --artifact "$$a"

# Split from cov_publish so that no one reaches the network by typing the
# obvious target. The rehearsal is the default everywhere in this tree.
cov_publish_real:
	@a="$(COV_LATEST)"; [ -n "$$a" ] || { echo "no artifact"; exit 2; }; \
	python3 $(COV_DIR)/cov_publish.py --artifact "$$a" --publish

cov_baseline:
	@a="$(COV_LATEST)"; [ -n "$$a" ] || { echo "no artifact"; exit 2; }; \
	python3 $(COV_DIR)/cov_publish.py --artifact "$$a" --publish --promote-baseline

# BASE may be a local artifact dir or an extracted baseline. Exit code IS the
# verdict: 0 pass, 1 regressed, 2 review, 3 refused.
cov_diff:
	@a="$(COV_LATEST)"; [ -n "$$a" ] || { echo "no artifact"; exit 2; }; \
	[ -n "$(BASE)" ] || { echo "cov_diff: pass BASE=<artifact dir>"; exit 2; }; \
	python3 $(COV_DIR)/cov_diff.py --base "$(BASE)" --head "$$a"

# The durability half. The heavy database lives in the store; the small,
# decision-carrying files live in git, where every clone has a copy and
# `git log -p docs/coverage/` IS the coverage changelog. Two independent
# systems, neither of them one host with a reapable directory.
cov_track:
	@a="$(COV_LATEST)"; [ -n "$$a" ] || { echo "no artifact"; exit 2; }; \
	t=$$(basename "$$a"); mkdir -p $(COV_TRACKED); \
	cp "$$a/report/cov_summary.json"            "$(COV_TRACKED)/$$t.summary.json"; \
	cp "$$a/unexercised/unexercised_scoped.json" "$(COV_TRACKED)/$$t.unexercised.json"; \
	cp "$$a/manifest/cov_manifest.json"          "$(COV_TRACKED)/$$t.manifest.json"; \
	echo "cov_track: wrote 3 file(s) into $(COV_TRACKED) for $$t"; \
	echo "cov_track: these are git-tracked ON PURPOSE -- ~10 KB per run, and"; \
	echo "cov_track: they answer 'what changed' with no store and no network."

cov_selftest:
	@python3 $(COV_DIR)/cov_diff.py --selftest
	@python3 $(COV_DIR)/cov_publish.py --selftest
	@python3 $(COV_DIR)/cov_identity_selftest.py

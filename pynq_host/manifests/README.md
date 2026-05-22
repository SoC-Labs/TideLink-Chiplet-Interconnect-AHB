# TideLink bitstream provenance manifests (Bug #32 guard)

These manifests pin the sha256 of a known-good bitstream so `deploy_pair.sh`
and `verify_deployed.sh` REFUSE to flash anything else from the shared
volatile staging dir (`/tmp/tidelink_deploy`). This is the guard against the
May-6 phase-v2 mixup (MD5 `188ebdd8`, a known-0/16 build) that got deployed
blindly into the v1 release and every post-cycle test.

## morning-v1 (`tidelink.bin.manifest.json`)

The known-good morning bitstream (MD5 `86aa3a95`, ~14.40/16 lane lock) lives on
`mapstone-dev` at `/home/david/tidelink_hwval/tidelink.bin` — NOT in this repo.
The committed manifest carries the metadata (label `morning-v1`,
`expected_lock_min` 14) but its `sha256` field is a PLACEHOLDER that must be
filled on the host where the real `.bin` exists:

```sh
# on mapstone-dev:
pynq_host/scripts/make_bitstream_manifest.sh \
    /home/david/tidelink_hwval/tidelink.bin \
    --label morning-v1 --lock-min 14 --target pynq-z2-pair \
    --out /home/david/tidelink_hwval/tidelink.bin.manifest.json
```

That writes the manifest WITH the real sha256 next to the bin. Then stage the
bin + its `.manifest.json` together into `/tmp/tidelink_deploy/` and deploy
with `--manifest` (or let deploy_pair.sh auto-discover the sibling manifest).

## IMPORTANT — known contamination

The on-disk v1-release bundle at
`td-bisect/v1-release/bitstreams/tidelink.bin` is the WRONG bitstream:
MD5 `188ebdd8`, sha256 `606e1648…` — the May-6 phase-v2 0/16 build. The
corrected v1 bundle must reference the `morning-v1` manifest (MD5 `86aa3a95`),
NOT this contaminated copy. See BUG_TRACKER.md Bug #32.

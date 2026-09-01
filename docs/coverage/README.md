# docs/coverage/ — the git-tracked half of a coverage artifact

Three small JSON files per run, written by `make cov_track`:

    <run_tag>.summary.json       canonical metrics       ~2 KB
    <run_tag>.unexercised.json   scoped unexercised list ~1 KB
    <run_tag>.manifest.json      fail-closed identity    ~4 KB

The merged coverage database lives in Artifactory (`verif-coverage`), which is
backed up nightly to `/research`. These files live here, in git, where every
clone has a copy.

Two independent systems on purpose. Neither of them is one host with a reapable
directory — which is the failure this whole design is against.

`git log -p docs/coverage/` IS the coverage changelog, and `git diff` between two
of these files IS the delta explanation. Neither needs the store to be up, a
credential, or a network.

**Empty right now.** No baseline has been tracked yet: the only runs produced so
far came from a dirty worktree and are correctly marked `promotable: false`, and
a baseline that cannot identify its own inputs is not a baseline. See
`docs/plans/COVERAGE_REPOSITORY_2026-08-26.md` §8 item 7.

`cov_fetch_baseline.sh` fails loudly while this directory is empty. That is the
intended behaviour: "no baseline" is a missing measurement, not a passing result.

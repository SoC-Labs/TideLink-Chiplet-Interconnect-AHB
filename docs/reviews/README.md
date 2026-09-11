# Reviews

Landed reviews of the TideLink chiplet interconnect. Each review names its review point, its
method and its evidence, so a claim in it can be re-checked against the tree it was written from.

## 2026-09-09 / 2026-09-10 — Rev-2 review and programme

| File | What it is |
|---|---|
| [`2026-09-09_REV2_REVIEW.md`](2026-09-09_REV2_REVIEW.md) | The synthesis report. Sections 0–9 plus an appendix: verdict, repository and rev2 state, method, architecture and its ten structural liabilities, the consolidated open-defect register with severities and what closes each item, verification and validation (what the gate covers, whether the tests can fail, the first coverage baseline), throughput (the model reconciled with every measurement and the ranked candidate list), build flows and repository hygiene, what the next iteration should have, and a five-wave multi-agent action plan. |
| [`2026-09-09_REV2_REVIEW_APPENDIX.md`](2026-09-09_REV2_REVIEW_APPENDIX.md) | The eight full reviewer reports behind that synthesis (~2,900 lines), every claim line-cited. Redacted before landing; see its header. |
| [`2026-09-10_REV2_PROGRAMME.md`](2026-09-10_REV2_PROGRAMME.md) | The forward-looking companion: the target layered architecture and its ownership table, the contract TideLink means to guarantee, the feature-complete checklist, nine phases (0–8) with numbered steps and file-on-disk exit criteria, the 24-week timeline, and the material for presenting and defending the work. |

**Review point:** `origin/main` **5e8bdb5a**.
**Candidate under review:** `rev2/integration` **cba9774d** (+59 commits), with `rev2/hygiene` **df0f1f24** noted as the branch to land first.
**Dates:** review 2026-09-09; programme 2026-09-10.

### Method

Eight reviewers worked in parallel against a read-only checkout of `origin/main` at 5e8bdb5a, each
with a distinct scope — architecture, transaction-layer RTL, link/PHY/FCSM/PTP RTL, verification,
the open-defect register, throughput, flow/tooling/hygiene, and the rev2 delta — with a coordinator
folding the results together and independently spot-checking the peer session's claims. Every
finding carries a severity, a confidence grade (verified in code with a line cite, plausible, or
hypothesis), an effort estimate and, where possible, a one-line proof recipe. Nothing in the tree
was edited, no simulation, synthesis, lint or CDC run was launched by the reviewers, no board was
touched, and no vendor IP library was written to. Gate and hardware statements come from scripts
and archived run records, which are named in the review's evidence section.

### Headline verdict

TideLink works on the vehicle it has been validated on — one KR260 with both dies in fabric
delivers credit-gated packets byte-exact at 5000/5000 with autonomous bring-up — but it is not
tapeout-ready, its verification apparatus cannot currently say whether it is, and the file set that
would tape out is not the file set that was validated: the ASIC flist compiles the AXI flow-control
state machines with zero recovery hooks, and that arm was measured wedging where the FPGA twin
escapes. Nothing is gated by CI on either forge, the aggregate gate rewrites tracked files and so
refuses its own PASS, and 43 of 63 benches are wired into nothing. Throughput sits at about 8% of
the raw pad rate against a single explaining invariant — 3.06 link cycles per 32-bit word, set by a
16-packet replay window against a ~49-cycle acknowledgement round trip — which leaves roughly ten
times available on the same PHY. The in-flight `rev2/integration` branch is a month of real
progress on exactly the right problems and is itself not yet land-ready; an eleven-item checklist
closes it. The recommendation is that the next iteration be a consolidation-and-hardening release
rather than a feature release, with a throughput programme that starts from a measurement and one
named lever. One item is a decision rather than a task: a board credential is in public git
history, and rotation is the only remediation.

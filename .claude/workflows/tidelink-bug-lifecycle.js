export const meta = {
  name: 'tidelink-bug-lifecycle',
  description: 'Dynamic per-run TideLink bug lifecycle: discover current sim_gate failures + registry coverage gaps, triage each (stale-test vs real break), spec a non-vacuous regression test, and synthesize an auto-apply-safe / propose-risky plan',
  whenToUse: 'After the gate goes red, or periodically to hunt regressions. Pass args.tree to point at a worktree (defaults to the consolidated one).',
  phases: [
    { title: 'Discover', detail: 'run registry coverage + read the live gate failures and ungated fixed bugs' },
    { title: 'Triage', detail: 'one independent agent per failing suite / coverage gap' },
    { title: 'Synthesize', detail: 'consolidated plan: auto-apply-safe vs propose vs David-decision' },
  ],
}

const TREE = (typeof args === 'object' && args && args.tree) || '/home/dam1n19/SoCLabs/tidelink-consolidated'

const COMMON = `
WORKING TREE (read-only unless told otherwise): ${TREE}. Registry (single source of truth): docs/BUG_REGISTRY.yaml. Live gate results: imp/sim_gate/<suite>.status (line = "suite VERDICT walltime <sha>-<dirty>") and imp/sim_gate/<suite>.log.
CONTEXT: the sim gate is tip-stamped + fail-loud (make sim_gate_regressions). A "stale test" = the test hard-encodes behavior a DELIBERATE, correct RTL fix changed (update the test). A "real break" = the RTL genuinely regressed (fix / gate / decision). Be skeptical: "lanes never lock" / "link never comes up (TRAIN_FAIL, FCSM stuck)" is more likely REAL; a hard-coded constant/threshold is likely STALE. A stale-test fix is only SAFE to auto-apply if the updated test still FAILS on reverted RTL (non-vacuous) — otherwise it masks a bug.
CONSTRAINTS: never touch /research/AAA/ip_library/**, branch fix/v2-sync-clock-gate, or pynq_host/throughput_gui/agent/tl_perf_agent.py. Do NOT build/run sims (analysis only) to avoid VCS contention.
`

const DISC_SCHEMA = {
  type: 'object',
  properties: {
    gate_stamp: { type: 'string' },
    failing_suites: { type: 'array', items: { type: 'object', properties: { suite: { type: 'string' }, logline: { type: 'string' } }, required: ['suite'] } },
    coverage_gaps: { type: 'array', items: { type: 'string' } },
    ungated_fixed_bugs: { type: 'array', items: { type: 'string' } },
  },
  required: ['failing_suites'],
}

const TRIAGE_SCHEMA = {
  type: 'object',
  properties: {
    suite: { type: 'string' },
    classification: { type: 'string', enum: ['stale_test', 'real_break', 'needs_confirmation'] },
    root_cause: { type: 'string' },
    test_spec: { type: 'object', properties: { file: { type: 'string' }, assertion: { type: 'string' }, why_catches: { type: 'string' } }, required: ['file', 'assertion'] },
    proposed_fix: { type: 'string' },
    auto_safe: { type: 'boolean', description: 'true only if a bounded, sim-verifiable, non-vacuous fix that is NOT netlist-affecting nor a tradeoff' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
  required: ['suite', 'classification', 'root_cause', 'proposed_fix', 'auto_safe', 'confidence'],
}

const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    auto_apply: { type: 'array', items: { type: 'string' }, description: 'sim-verified low-risk fixes to apply + commit (with their confirming re-run)' },
    propose_for_review: { type: 'array', items: { type: 'string' } },
    decisions_for_david: { type: 'array', items: { type: 'string' } },
    ordered_actions: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['auto_apply', 'ordered_actions', 'summary'],
}

phase('Discover')
const disc = await agent(
  `${COMMON}\nDISCOVER the current work-list. In ${TREE}: (1) run \`make sim_gate_registry_coverage\` and capture its FAIL/WARN/GAP lines; (2) read imp/sim_gate/*.status and list every suite whose 2nd field is FAIL (with a one-line reason from its .log); (3) list bugs in docs/BUG_REGISTRY.yaml whose status is sim_proven/hw_proven but verification.in_sim_gate is not true (ungated fixed bugs). Return the structured lists. (You MAY run the static coverage make target; do NOT run sim builds.)`,
  { schema: DISC_SCHEMA, phase: 'Discover', label: 'discover' }
)

const failing = (disc && disc.failing_suites) ? disc.failing_suites : []
log(`discovered ${failing.length} failing suites, ${(disc && disc.coverage_gaps || []).length} coverage gaps, ${(disc && disc.ungated_fixed_bugs || []).length} ungated fixed bugs`)

phase('Triage')
const triaged = failing.length
  ? (await parallel(failing.map((it) => () =>
      agent(
        `${COMMON}\nTriage ONE failing sim_gate suite and specify a robust, NON-VACUOUS regression test for it.\nSUITE: ${it.suite}\nREASON: ${it.logline || '(read imp/sim_gate/' + it.suite + '.log)'}\nRead the suite log + its test file + the relevant RTL and the git delta since it last passed. Classify stale_test vs real_break vs needs_confirmation; give the exact fix; set auto_safe truthfully (only if bounded, sim-verifiable, non-vacuous, not netlist-affecting, not a tradeoff).`,
        { schema: TRIAGE_SCHEMA, phase: 'Triage', label: `triage:${it.suite}` }
      )
    ))).filter(Boolean)
  : []

phase('Synthesize')
const plan = await agent(
  `${COMMON}\nSynthesis lead. Given the discovery and per-suite triage below, produce the plan.\nDISCOVERY:\n${JSON.stringify(disc, null, 1)}\nTRIAGE:\n${JSON.stringify(triaged, null, 1)}\nSplit into: auto_apply (sim-verified low-risk, non-vacuous, not netlist/tradeoff), propose_for_review, and decisions_for_david (netlist-affecting or HW tradeoffs). Every landed fix must add/point a gating test so make sim_gate_registry_coverage covers it. ordered_actions = what to do next, autonomous-safe first.`,
  { schema: PLAN_SCHEMA, phase: 'Synthesize', label: 'synthesize', effort: 'high' }
)

return { discover: disc, triaged, plan }

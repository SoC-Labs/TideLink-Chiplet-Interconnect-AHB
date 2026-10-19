#!/usr/bin/env bash
# Formal gate: the contract must be PROVEN on the real RTL and FALSIFIED on the pre-TL-059 mutant.
# Exit 0 only if both hold (a proof that cannot fail is not a proof).  Needs vcf + licence.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
command -v vcf >/dev/null 2>&1 || { module load vc_formal 2>/dev/null; }
command -v vcf >/dev/null 2>&1 || { echo "ci_formal: vcf not available"; exit 2; }
rc=0
verif/formal/run_formal.sh main   1 >/dev/null 2>&1
if grep -q 'falsified\|inconclusive' imp/formal/main/report_list.txt || ! grep -q 'proven' imp/formal/main/report_list.txt; then
  echo "ci_formal: MAIN not fully proven"; sed -n '/> Assertion/,/> Cover/p' imp/formal/main/report_list.txt; rc=1
else echo "ci_formal: main PROVEN"; fi
verif/formal/run_formal.sh mutant 1 >/dev/null 2>&1
if ! grep -q 'falsified' imp/formal/mutant/report_list.txt; then echo "ci_formal: MUTANT NOT CAUGHT (proof is hollow)"; rc=1
else echo "ci_formal: mutant falsified (required)"; fi
exit $rc

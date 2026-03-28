# Phase 4b Manifest (Compaction-Resilient)

Generated: 2026-03-28
Iteration: 1

## Expected Outputs

| Agent | Output File | Status |
|-------|------------|--------|
| depth-token-flow | depth_token_flow_findings.md | PENDING |
| depth-state-trace | depth_state_trace_findings.md | PENDING |
| depth-edge-case | depth_edge_case_findings.md | PENDING |
| depth-external | depth_external_findings.md | PENDING |
| scanner-A | blind_spot_A_findings.md | PENDING |
| scanner-B | blind_spot_B_findings.md | PENDING |
| scanner-C | blind_spot_C_findings.md | PENDING |
| validation-sweep | validation_sweep_findings.md | PENDING |
| niche-SIGNATURE_VERIFICATION_AUDIT | niche_SIGNATURE_VERIFICATION_AUDIT_findings.md | PENDING |
| niche-SEMANTIC_CONSISTENCY_AUDIT | niche_SEMANTIC_CONSISTENCY_AUDIT_findings.md | PENDING |
| niche-SEMANTIC_GAP_INVESTIGATOR | niche_SEMANTIC_GAP_INVESTIGATOR_findings.md | PENDING |
| injectable-vault_accounting | depth_vault_accounting_injectable_findings.md | PENDING |
| injectable-dex_integration | depth_dex_integration_injectable_findings.md | PENDING |
| design-stress-testing | design_stress_findings.md | PENDING |

## Post-Step Requirements
- confidence_scores.md (written by scoring agent after all above complete)

## Budget
- depth_floor: 12 (4 breadth agents)
- total_findings: 55
- max_depth_spawns: min(max(12, ceil(55/5)+7), 20) = 18
- dst_reserved: 1
- depth_available: 17
- agents_spawned: 14 (within budget)

## Key Facts
- SCRATCHPAD: /Users/dhruv/catalystlabs/coverage/.plamen/thorough-20260328-152658/
- PROJECT_ROOT: /Users/dhruv/catalystlabs/coverage
- LANGUAGE: evm
- PROVEN_ONLY: true
- RAG_TOOLS_AVAILABLE: false (0.3 floor for all RAG scores)
- MEDUSA_AVAILABLE: false (skipped)

# Spawn Manifest - Phase 3 Breadth Analysis

| Template | Required? | Agent ID | Focus Area | Status |
|----------|-----------|----------|------------|--------|
| TEMPORAL_PARAMETER_STALENESS | YES | Agent-1 | core-state-economics | QUEUED |
| SHARE_ALLOCATION_FAIRNESS | YES | Agent-1 | core-state-economics | QUEUED |
| ECONOMIC_DESIGN_AUDIT | YES | Agent-1 | core-state-economics | QUEUED |
| SEMI_TRUSTED_ROLES | YES | Agent-2 | access-control | QUEUED |
| TOKEN_FLOW_TRACING | YES | Agent-3 | token-flow-external | QUEUED |
| EXTERNAL_PRECONDITION_AUDIT | YES | Agent-3 | token-flow-external | QUEUED |
| ORACLE_ANALYSIS | YES | Agent-4 | oracle-zero-state | QUEUED |
| ZERO_STATE_RETURN | YES | Agent-4 | oracle-zero-state | QUEUED |

**Injectable Skills (brief headers injected into breadth agents)**:
- VAULT_ACCOUNTING → Agent-1 (core state), Agent-4 (zero state)
- DEX_INTEGRATION_SECURITY → Agent-3 (token flow + external)

**Gate Check**: All REQUIRED templates have agents? YES

## Niche Agents (Phase 4b - deferred to depth loop)
| Niche Agent | Required? | Budget Slot | Status |
|-------------|-----------|------------|--------|
| SIGNATURE_VERIFICATION_AUDIT | YES | Phase 4b iter 1 | DEFERRED |
| SEMANTIC_CONSISTENCY_AUDIT | YES | Phase 4b iter 1 | DEFERRED |

## Merge Decisions
- M1: TEMPORAL_PARAMETER_STALENESS + Agent-1 core state (cached premium params are state mutations)
- M3: SHARE_ALLOCATION_FAIRNESS + Agent-1 core state (allocation fairness is state correctness)
- M4: ECONOMIC_DESIGN_AUDIT + Agent-1 core state (monetary params are state correctness)
- M5: EXTERNAL_PRECONDITION_AUDIT + Agent-3 external (external preconditions are external dep analysis)
- SEMI_TRUSTED_ROLES standalone (M2 - access control agent solo due to 7+ roles complexity)
- ORACLE_ANALYSIS + ZERO_STATE_RETURN merged in Agent-4 (oracle drives share pricing; zero-state is ERC4626 edge case)

**Breadth-to-depth redirect**: 4 agents (below Medium baseline of 4) → depth_floor = 12 + (4-4) = 12

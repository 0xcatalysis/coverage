# Consensus Map (Axis 2 Pre-Computation)
# Orchestrator-computed before scoring agent runs.
# Formula: (agents that flagged same root cause) / (agents whose domain covers this location)
# Specialized agent bonus: +0.2 for Required skill template agent (capped at 1.0)
# Single-domain rule: If only 1 agent's domain covers the location → Consensus = 1.0 if found

## HIGH SEVERITY

| Finding ID | Agents That Found It | Domain-Covering Agents | Consensus Score | Notes |
|-----------|---------------------|----------------------|----------------|-------|
| RS1-1 | breadth(CS#1), rescan#1, depth-state-trace, SGI(niche), DST, validation-sweep | all 4 depth + scanners | 0.90 | Confirmed by 5 agents across phases; SEMI_TRUSTED_ROLES skill bonus |
| PC3-1 | percontract#3, depth-token-flow, validation-sweep | token-flow, scanner-C scope | 1.0 | 3 agents; single-domain (ClaimManager swap output) |
| PC3-2 | percontract#3, depth-token-flow, depth-external, DEX-inject, validation-sweep | token-flow+external+DEX | 1.0 | 4 agents; DEX_INTEGRATION_SECURITY required skill bonus |

## MEDIUM SEVERITY

| Finding ID | Agents That Found It | Domain-Covering Agents | Consensus Score | Notes |
|-----------|---------------------|----------------------|----------------|-------|
| CS-1 | breadth#1, percontract#1(PC1-4 variant), SGI | state-trace, edge-case | 0.85 | 3 agents; TEMPORAL skill bonus |
| CS-2 | breadth#1, depth-state-trace, SGI, validation-sweep, VA-inject | state-trace+token-flow | 0.95 | 5 agents; VAULT_ACCOUNTING skill bonus |
| CS-5 | breadth#1, depth-state-trace | state-trace | 0.85 | 2 agents; SEMI_TRUSTED_ROLES skill |
| AC-1 | breadth#2 | access-control | 1.0 | Single domain |
| AC-2 | breadth#2, DST(DST-3) | access-control | 0.90 | 2 agents; DST confirms |
| AC-3 | breadth#2, DST(DST-2) | access-control | 0.90 | 2 agents; DST confirms mass-withdrawal scenario |
| OZ-3 | breadth#4, depth-external | external | 0.85 | 2 agents |
| TF-4 | breadth#3, depth-token-flow, DEX(DEX-1 compounds) | token-flow+external | 0.90 | 3 agents; DEX injection deepens |
| TF-7 | breadth#3, depth-external | external | 0.80 | 2 agents; PARTIAL (confirmation varies) |
| RS1-2 | rescan#1, depth-token-flow | token-flow | 0.85 | 2 agents |
| RS2-1 | rescan#2, depth-state-trace | state-trace | 0.85 | 2 agents |
| PC2-1 | percontract#2, depth-state-trace | state-trace | 0.85 | 2 agents |
| PC4-1 | percontract#4, depth-token-flow, validation-sweep | token-flow | 1.0 | 3 agents; VAULT_ACCOUNTING bonus |
| PC4-2 | percontract#4, depth-state-trace | state-trace | 0.85 | 2 agents |
| VA-1 | VA-inject (new) | vault-accounting (injectable) | 1.0 | Single required-skill agent; +0.2 bonus → capped 1.0 |
| VA-3 | VA-inject (new) | vault-accounting (injectable) | 1.0 | Single required-skill agent; +0.2 bonus → capped 1.0 |
| SGI-3 | SGI-niche (new) | semantic-gap (niche) | 1.0 | Single required niche agent; +0.2 bonus |
| DEX-1 | DEX-inject (new) | dex-integration (injectable) | 1.0 | Single required-skill agent; +0.2 bonus |
| BLIND-C-1 | scanner-C | scanner-C | 1.0 | Single domain |
| SC-8 | SC-niche | semantic-consistency (niche) | 1.0 | Single required niche agent; +0.2 bonus |

## LOW SEVERITY (Sample — scoring agent computes full set)

| Finding ID | Agents That Found It | Consensus Score | Notes |
|-----------|---------------------|----------------|-------|
| CS-3 | breadth#1, pass2-confirmed | 0.80 | |
| CS-4 | breadth#1, depth-state-trace | 0.80 | |
| CS-6 | breadth#1, depth-edge-case | 0.80 | |
| CS-9 | breadth#1, depth-edge-case | 0.80 | |
| OZ-1 | breadth#4, depth-external | 0.80 | |
| OZ-2 | breadth#4, depth-edge-case | 0.80 | |
| OZ-5 | breadth#4, depth-edge-case | 0.80 | |
| TF-1 | breadth#3 | 1.0 | Single domain |
| TF-5 | breadth#3, depth-external | 0.80 | |
| PC1-1 | percontract#1, VA-inject(VA-6) | 0.85 | |
| PC1-2 | percontract#1, BLIND-A-3(duplicate?) | 0.85 | |
| RS1-3 | rescan#1 | 1.0 | Single domain |
| RS2-2 | rescan#2, depth-external | 0.80 | |
| RS3-2 | rescan#3 | 1.0 | Single domain |
| PC2-3 | percontract#2 | 1.0 | Single domain |
| PC3-4 | percontract#3 | 1.0 | Single domain |
| PC3-5 | percontract#3, depth-state-trace | 0.85 | |
| PC4-3 | percontract#4, depth-external | 0.85 | |
| PC4-4 | percontract#4, depth-external | 0.80 | |
| AC-4 | breadth#2, depth-external | 0.80 | |
| AC-8 | breadth#2, depth-state-trace | 0.80 | |
| BLIND-C-2 | scanner-C | 1.0 | Single domain |
| BLIND-B-1 | scanner-B | 1.0 | Single domain |
| SGI-8 | SGI-niche | 1.0 | Single required niche agent |
| DEX-4 | DEX-inject | 1.0 | Single required-skill agent |
| SC-5 | SC-niche | 1.0 | Single required niche agent |

# Finding → Hypothesis Mapping

## Master Mapping Table

| Finding ID | Source Agent | Hypothesis | Status | Notes |
|-----------|-------------|------------|--------|-------|
| CS-1 | Core State Economics #1 | H-2 | CONFIRMED | Unbounded gateGracePeriod accumulation |
| CS-2 | Core State Economics #1 | H-3 | CONFIRMED | totalPremiumLiability phantom residual |
| CS-3 | Core State Economics #1 | H-20 | PARTIAL | Stale lastKnownMorphoValue — grouped with OZ-3 |
| CS-4 | Core State Economics #1 | H-26 | CONFIRMED | Premium rate retroactive |
| CS-5 | Core State Economics #1 | H-8 | CONFIRMED | Retroactive deductible/maxLoss params |
| CS-6 | Core State Economics #1 | H-34 | PARTIAL | cumulativePremiumPerUnit precision loss |
| CS-7 | Core State Economics #1 | H-59 | CONFIRMED | uint32 truncation (Informational) |
| CS-8 | Core State Economics #1 | H-58 | CONFIRMED | Fee split rounding (Informational) |
| CS-9 | Core State Economics #1 | H-27 | CONFIRMED | depositCap reopens after withdrawal |
| CS-10 | Core State Economics #1 | H-57 | CONFIRMED | Timestamp advance at rate=0 (Informational) |
| AC-1 | Access Control #2 | H-16 | CONFIRMED | CREATOR_ROLE no timelock |
| AC-2 | Access Control #2 | H-9 | CONFIRMED | Curator blocks claims |
| AC-3 | Access Control #2 | H-10 | CONFIRMED | Claim approval gate race |
| AC-4 | Access Control #2 | H-56 | PARTIAL | morphoGateActive no timelock |
| AC-5 | Access Control #2 | REFUTED | REFUTED | Whitelist mitigates |
| AC-6 | Access Control #2 | H-61 | PARTIAL | 24h admin transfer (Informational) |
| AC-7 | Access Control #2 | EXCLUDED | CONFIRMED | Positive finding — defensive design |
| AC-8 | Access Control #2 | H-37 | CONFIRMED | executeUpgrade ordering |
| AC-9 | Access Control #2 | H-51 | CONFIRMED | approveSpender (Informational, TRUSTED-ACTOR) |
| OZ-1 | Oracle/Zero-State #4 | H-24 | PARTIAL | Oracle revert in bindPolicy |
| OZ-2 | Oracle/Zero-State #4 | H-28 | CONFIRMED | Post-maturity deposits |
| OZ-3 | Oracle/Zero-State #4 | H-20 | PARTIAL | Stale morpho value fallback |
| OZ-4 | Oracle/Zero-State #4 | REFUTED | REFUTED | No truncation |
| OZ-5 | Oracle/Zero-State #4 | H-38 | CONFIRMED | rescueTokens proxy check |
| OZ-6 | Oracle/Zero-State #4 | H-60 | CONFIRMED | Gas optimization (Informational) |
| TF-1 | Token Flow/External #3 | H-44 | CONFIRMED | block.timestamp deadline |
| TF-2 | Token Flow/External #3 | REFUTED | REFUTED | Dust cleanup intended |
| TF-3 | Token Flow/External #3 | H-45 | CONFIRMED | Unsolicited donation |
| TF-4 | Token Flow/External #3 | H-7 | CONFIRMED | amountOutMin=1 sandwich |
| TF-5 | Token Flow/External #3 | H-29 | PARTIAL | Fee-on-transfer collateral |
| TF-6 | Token Flow/External #3 | EXCLUDED | CONFIRMED | Positive finding |
| TF-7 | Token Flow/External #3 | H-11 | PARTIAL | PolicyManager DoS |
| TF-8 | Token Flow/External #3 | H-50 | CONFIRMED | Stale route calldata (Informational) |
| RS1-1 | Re-Scan Agent #1 | H-1 | CONFIRMED | Grace window uninsured premium |
| RS1-2 | Re-Scan Agent #1 | H-22 | CONFIRMED | Operator waives insurance |
| RS1-3 | Re-Scan Agent #1 | H-25 | CONFIRMED | Infrastructure orphaning |
| RS2-1 | Re-Scan Agent #2 | H-12 | CONFIRMED | Revoked spec still callable |
| RS2-2 | Re-Scan Agent #2 | H-23 | CONFIRMED | distributeBatch no isolation |
| RS2-3 | Re-Scan Agent #2 | H-4 | CONFIRMED | Excess swap stranded |
| RS3-2 | Re-Scan Agent #3 | H-40 | PARTIAL | Stale evidence hash |
| PC1-1 | Per-Contract #1 | H-14 | CONFIRMED | maxWithdraw double-deduction |
| PC1-2 | Per-Contract #1 | H-21 | CONFIRMED | Pre-policy phantom premium |
| PC1-3 | Per-Contract #1 | H-48 | PARTIAL | totalPrincipal transient break (Informational) |
| PC1-4 | Per-Contract #1 | H-2 | CONFIRMED | gateGracePeriod accumulation |
| PC2-1 | Per-Contract #2 | H-19 | CONFIRMED | Quote startTime staleness |
| PC2-3 | Per-Contract #2 | H-41 | CONFIRMED | Single-use binding guard |
| PC2-5 | Per-Contract #2 | H-42 | CONFIRMED | Defence-in-depth gap (Informational) |
| PC3-1 | Per-Contract #3 | H-4 | CONFIRMED | Excess swap stranded |
| PC3-2 | Per-Contract #3 | H-5 | CONFIRMED | Fee-tier desync |
| PC3-4 | Per-Contract #3 | H-33 | CONFIRMED | Misleading event |
| PC3-5 | Per-Contract #3 | H-31 | CONFIRMED | evidenceHash consumed on rejection |
| PC4-1 | Per-Contract #4 | H-6 | CONFIRMED | Stale approval old RewardsManager |
| PC4-2 | Per-Contract #4 | H-13 | CONFIRMED | poolFeeBps retroactive |
| PC4-3 | Per-Contract #4 | H-35 | CONFIRMED | updateVault no nonReentrant |
| PC4-4 | Per-Contract #4 | H-36 | PARTIAL | Cached vault underlying |
| SGI-1 | Semantic Gap Investigator | H-3 | CONFIRMED | totalPremiumLiability phantom (same as CS-2) |
| SGI-2 | Semantic Gap Investigator | H-1 | CONFIRMED | Grace period uninsured (same as RS1-1) |
| SGI-3 | Semantic Gap Investigator | H-39 | CONFIRMED | Post-expiry catch-up premium |
| SGI-4 | Semantic Gap Investigator | H-34 | PARTIAL | _safeSub rounding (same as CS-6) |
| SGI-5 | Semantic Gap Investigator | H-3 | PARTIAL | Phantom when redeemShares=0 (variant of CS-2) |
| SGI-6 | Semantic Gap Investigator | H-10 | CONFIRMED | Claim approval serialization (same as AC-3) |
| SGI-7 | Semantic Gap Investigator | EXCLUDED | PARTIAL | First-second discount (Informational, by design) |
| SGI-8 | Semantic Gap Investigator | REFUTED | REFUTED per ITER2-LC-1 | Checkpoint manipulation not possible |
| VA-1 | Vault Accounting Injectable | H-30 | CONFIRMED | Premium debt zeroed by rounding |
| VA-2 | Vault Accounting Injectable | H-3 | PARTIAL | totalAssets returns 0 (variant of CS-2) |
| VA-3 | Vault Accounting Injectable | H-15 | CONFIRMED | previewRedeem overstates |
| VA-4 | Vault Accounting Injectable | REFUTED | REFUTED | Donation attack infeasible |
| VA-5 | Vault Accounting Injectable | EXCLUDED | CONFIRMED | Round-trip dust (Informational, no chain) |
| VA-6 | Vault Accounting Injectable | H-3 | CONFIRMED | Cross-user totalAssets distortion |
| VA-7 | Vault Accounting Injectable | EXCLUDED | CONFIRMED | userShortfall off-by-one (Informational) |
| DEX-1 | DEX Integration Injectable | H-7 | CONFIRMED | amountOutMin=0 (same as TF-4) |
| DEX-2 | DEX Integration Injectable | H-7 | PARTIAL | SWAP_EXECUTOR override (enabler) |
| DEX-3 | DEX Integration Injectable | REFUTED | REFUTED | Approval race not exploitable |
| DEX-4 | DEX Integration Injectable | H-4 | CONFIRMED | Large swap stranded (compounds PC3-1) |
| BLIND-A-1 | Blind Spot A | H-27 | CONFIRMED | depositCap=0 after maxCoverableLossBps increase |
| BLIND-A-2 | Blind Spot A | STANDALONE | CONFIRMED | Blocked premiumRecipient → Low |
| BLIND-A-3 | Blind Spot A | H-21 | PARTIAL | Pre-start phantom premium (same as PC1-2) |
| BLIND-A-4 | Blind Spot A | H-49 | PARTIAL | Stale pending values (Informational) |
| BLIND-A-5 | Blind Spot A | H-11 | CONFIRMED | View DoS amplification (Informational, compounds TF-7) |
| BLIND-B-1 | Blind Spot B | H-47 | CONFIRMED | Factory instant admin vs pool 24h |
| BLIND-B-2 | Blind Spot B | H-25 | CONFIRMED | setCoverPoolFactory one-time write |
| BLIND-B-3 | Blind Spot B | H-46 | CONFIRMED | Cross-contract pause dependency |
| BLIND-C-1 | Blind Spot C | H-17 | CONFIRMED | renounceOwnership not overridden |
| BLIND-C-2 | Blind Spot C | H-18 | CONFIRMED | PREMIUM_COLLECTOR_ROLE not granted |
| BLIND-C-3 | Blind Spot C | H-32 | CONFIRMED | setNativeWrapper stale routes |
| BLIND-C-4 | Blind Spot C | H-43 | CONFIRMED | Missing recoverTokens (Informational) |
| SC-5 | Semantic Consistency | H-53 | CONFIRMED | _MAX_FEE_BPS misleading |
| SC-8 | Semantic Consistency | H-52 | CONFIRMED | coverageLimit cached vs live |
| SC-9 | Semantic Consistency | H-54 | CONFIRMED | Naming inconsistency (Informational) |
| ITER2-FA-2 | Depth Iter2 Factory | H-55 | CONFIRMED | Dead code combined fee cap (Informational) |
| DST-1 | Design Stress | DST (non-vuln) | CONFIRMED | Premium drain spiral — design limit |
| DST-2 | Design Stress | DST (non-vuln) | CONFIRMED | Serialized claims — design limit |
| DST-3 | Design Stress | DST (non-vuln) | CONFIRMED | Curator claim denial — structural risk |
| DST-4 | Design Stress | DST (non-vuln) | CONFIRMED | Lifecycle uninsured windows |
| DST-5 | Design Stress | DST (non-vuln) | CONFIRMED | Narrow coverage band — design tradeoff |
| SIG-1 | Signature Audit | EXCLUDED | CONFIRMED | Informational, no finding |
| SIG-3 | Signature Audit | EXCLUDED | CONFIRMED | Positive |
| SIG-6 | Signature Audit | EXCLUDED | CONFIRMED | Design adequate |
| SIG-7 | Signature Audit | EXCLUDED | CONFIRMED | Design adequate |

## Depth/Validation Sweep Findings → Hypothesis Mapping

These findings from depth/scanner/iter2 agents confirmed or extended breadth findings. They are mapped to the hypothesis they support, not listed as standalone.

| Finding ID | Source | Maps To | Relationship |
|-----------|--------|---------|--------------|
| DEPTH-TF-1 | depth_token_flow | H-4 | Confirms excess payout stranding |
| DEPTH-TF-2 | depth_token_flow | H-5 | Confirms fee-tier desync |
| DEPTH-TF-3 | depth_token_flow | H-7 | Confirms amountOutMin=1 path |
| DEPTH-TF-4 | depth_token_flow | H-6 | Confirms stale approval |
| DEPTH-TF-5 | depth_token_flow | H-22 | Confirms operator insurance waiver |
| DEPTH-TF-6 | depth_token_flow | H-29 | Confirms fee-on-transfer revert |
| DEPTH-TF-7 | depth_token_flow | H-44 | Confirms block.timestamp deadline |
| DEPTH-TF-8 | depth_token_flow | H-4 | Confirms multi-vault surplus stranding |
| DEPTH-ST-1 | depth_state_trace | H-1 | Confirms grace window premium loss |
| DEPTH-ST-2 | depth_state_trace | H-3 | Confirms phantom liability |
| DEPTH-ST-3 | depth_state_trace | H-2 | Confirms unbounded grace period |
| DEPTH-ST-4 | depth_state_trace | H-8 | Confirms parameter change combo |
| DEPTH-ST-5 | depth_state_trace | H-10 | Confirms dual claim-blocking |
| DEPTH-ST-6 | depth_state_trace | H-19 | Confirms startTime staleness |
| DEPTH-ST-7 | depth_state_trace | H-12 | Confirms revoked spec callable |
| DEPTH-ST-8 | depth_state_trace | H-13 | Confirms poolFeeBps live read |
| DEPTH-ST-9 | depth_state_trace | H-14 | Confirms maxWithdraw double-deduction |
| DEPTH-ST-10 | depth_state_trace | H-21 | Confirms pre-policy phantom |
| DEPTH-ST-11 | depth_state_trace | H-26 | Confirms premium rate notice |
| DEPTH-EC-2 | depth_edge_case | H-3 | Confirms phantom after all exit |
| DEPTH-EC-3 | depth_edge_case | H-20 | Confirms stale Morpho value |
| DEPTH-EC-6 | depth_edge_case | H-21 | Confirms pre-policy phantom |
| DEPTH-EC-8 | depth_edge_case | H-27 | Confirms depositCap=0 |
| DEPTH-EC-9 | depth_edge_case | H-28 | Confirms expired+gate combo |
| DEPTH-EX-1 | depth_external | H-11 | Confirms emergency exit DoS |
| DEPTH-EX-2 | depth_external | H-11 | Confirms double external call |
| DEPTH-EX-3 | depth_external | H-20 | Confirms stale cap during downtime |
| DEPTH-EX-4 | depth_external | H-5 | Confirms fee desync |
| DEPTH-EX-5 | depth_external | REFUTED | No partial state |
| DEPTH-EX-6 | depth_external | H-35 | Confirms reentrancy in updateVault |
| DEPTH-EX-7 | depth_external | H-23 | Confirms distributeBatch DoS |
| DEPTH-EX-8 | depth_external | H-24 | Confirms Chainlink DoS |
| VS-1 | validation_sweep | H-1 | Confirms maturity boundary timing |
| VS-UPDATE-RS1-1 | validation_sweep | H-1 | Confirms grace window finding |
| VS-UPDATE-CS-2 | validation_sweep | H-3 | Confirms phantom residual |
| VS-UPDATE-PC4-1 | validation_sweep | H-6 | Confirms stale approval |
| VS-UPDATE-PC3-1 | validation_sweep | H-4 | Confirms excess swap stranding |
| VS-UPDATE-PC3-2 | validation_sweep | H-5 | Confirms fee-tier desync |
| ITER2-ST-1 | depth_iter2_state | H-19 | Corrects PC2-1 — buyer cannot grieve |
| ITER2-ST-2 | depth_iter2_state | H-8 | Extends CS-5 with compound path |
| ITER2-ST-3 | depth_iter2_state | H-12 | Corrects RS2-1 attack direction |
| ITER2-FA-1 | depth_iter2_factory | H-25 | Extends RS1-3 with blast radius |
| ITER2-FA-2 | depth_iter2_factory | H-55 | New — dead code finding |
| ITER2-FA-3 | depth_iter2_factory | H-13 | Confirms single-tx retroactive fee |
| ITER2-LC-1 | depth_iter2_lowconf | SGI-8 REFUTED | Refutes checkpoint manipulation |
| ITER2-LC-2 | depth_iter2_lowconf | H-14 | Confirms maxRedeem also affected |
| ITER2-LC-3 | depth_iter2_lowconf | AC-4 REFUTED path | Refutes owner profit from toggle |
| ITER2-LC-4 | depth_iter2_lowconf | PC4-4 stays PARTIAL | ERC-7201 survives upgrade |

## Standalone Findings (Orphan → Single-Finding Hypotheses)

These findings did not group with any other finding:

| Finding ID | Hypothesis | Reason for Standalone |
|-----------|-----------|----------------------|
| BLIND-A-2 | STANDALONE (H-62) | Unique: blocked premiumRecipient → premium lockup; different fix from any other |
| VA-5 | EXCLUDED | Informational dust loss, no chain potential |
| VA-7 | EXCLUDED | Informational off-by-one, no chain potential |
| SGI-7 | EXCLUDED | Informational, by design |
| SIG-1 | EXCLUDED | Informational, no funds at risk |

## Duplicate Resolution Log

| Discarded | Duplicate Of | How Resolved |
|-----------|-------------|-------------|
| RS3-1 | RS1-1 | Same root cause, merged into H-1 |
| PC2-2 | RS1-3 | Same root cause, merged into H-25 |
| PC2-4 | RS2-1 | Same root cause, merged into H-12 |
| PC3-3 | RS2-3 | Same root cause, merged into H-4 |
| PC1-5 | N/A | REFUTED — atomic rollback |
| SC-2 | RS1-1 | Duplicate — same maturity mismatch |
| SGI-5 | CS-2/SGI-1 | Variant of same phantom mechanism, merged into H-3 |
| VA-2 | CS-2/SGI-1 | Variant of same phantom mechanism, merged into H-3 |

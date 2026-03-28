# Recon Summary (Agent 3)

## Build Status
- **Status**: success (per build_status.md — Foundry project compiled)

## Contracts In-Scope (13)
1. CoverPool (344 lines) — Curator-controlled pool with EIP-712 quote validation
2. CoverPoolFactory (230 lines) — UUPS upgradeable factory for CoverPool clones
3. PolicyManager (374 lines) — Central policy orchestration (request, bind, cancel)
4. ClaimManager (726 lines) — Claim processing, slashing coordination, collateral swapping
5. PremiumCollector (297 lines) — ERC-4626 share accrual and redemption for premium distribution
6. PremiumManager (212 lines) — Fee splitting (platform/pool/restaker) and reward distribution
7. SpecRegistry (139 lines) — Immutable spec registration per (coverPool, specId)
8. Swapper (376 lines) — Generic DEX swap routing with whitelisted targets
9. CoveredVaultWrapper (644 lines) — ERC-4626 wrapper over Morpho V2 with per-user insurance
10. CoveredVaultAccrual (165 lines) — Premium accrual engine (reward-per-token pattern)
11. CoveredVaultStorage (190 lines) — Storage layout for CoveredVaultWrapper
12. CoveredVaultAdmin (230 lines) — Timelocked admin functions
13. BasePolicyInteractions (167 lines) — Abstract base for policy/claim interactions

**Total**: ~4,094 in-scope lines

## External Dependencies
1. **Morpho V2 vault** (IVaultV2) — ERC-4626 yield source, gate/cap risk
2. **ChainlinkPriceFeed** (IChainlinkPriceFeed) — USD price oracle for stake validation
3. **StakeManager** (IStakeManager) — Committee and vault management (out of scope)
4. **SlashingManager** (ISlashingManager) — Stake slashing for claim payouts (out of scope)
5. **RewardsManager** (IRewardsManager) — Restaker reward distribution (out of scope)
6. **Uniswap V3** (via UniswapV3Adapter) — DEX swap execution and quoting

## Detected Patterns (Flags)
- TEMPORAL: YES (premium accrual, timelocks, policy windows, distributeInterval)
- ORACLE: YES (ChainlinkPriceFeed in PolicyManager)
- ERC4626_VAULT: YES (CoveredVaultWrapper, PremiumCollector)
- BALANCE_DEPENDENT: YES (insurance claims, swap verification)
- SEMI_TRUSTED_ROLE: YES (7+ privileged roles)
- SHARE_ALLOCATION: YES (per-user principal/share tracking)
- MONETARY_PARAMETER: YES (premium rates, fees, deductibles)
- SIGNATURES: YES (EIP-712 quotes)
- DEX_INTEGRATION: YES (Swapper + UniswapV3Adapter)
- UPGRADEABLE: YES (8 UUPS contracts)
- CALLBACKS: YES (IBindPolicyHook, ISpec.evaluate)
- ASSEMBLY: YES (tstore/tload transient storage)
- FLASH_LOAN: NO
- CROSS_CHAIN: NO

## Recommended Templates (Required)
1. SEMI_TRUSTED_ROLES
2. TOKEN_FLOW_TRACING
3. ZERO_STATE_RETURN
4. TEMPORAL_PARAMETER_STALENESS
5. ECONOMIC_DESIGN_AUDIT
6. EXTERNAL_PRECONDITION_AUDIT
7. ORACLE_ANALYSIS
8. SHARE_ALLOCATION_FAIRNESS

## Required Niche Agents
1. SIGNATURE_VERIFICATION_AUDIT
2. SEMANTIC_CONSISTENCY_AUDIT

## Required Injectable Skills
1. VAULT_ACCOUNTING
2. DEX_INTEGRATION_SECURITY

## Artifacts Written
- contract_inventory.md
- attack_surface.md
- detected_patterns.md
- setter_list.md
- emit_list.md
- constraint_variables.md
- template_recommendations.md
- recon_summary.md

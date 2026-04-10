# Coverage to Core Integration

## Overview

Coverage uses Core as the execution and accounting substrate for restaked security.
The boundary is strict:

- Coverage defines underwriting, policy semantics, premium routing, and claim intent.
- Core executes committee-level stake, reward distribution, and slashing on SSP adapters.

This separation keeps restaking platform complexity out of Coverage contracts.

## Integration Matrix

| Coverage Contract | Core Contract | Function | Purpose |
|---|---|---|---|
| `PolicyManager` | `StakeManager` | `createCommittee(policyId, pool, duration)` | Create policy-scoped committee scaffold |
| `PolicyManager` | `StakeManager` | `addOperatorToCommittee(curator, policyId)` | Explicitly register pool curator as committee operator (called immediately after `createCommittee`) |
| `CoverPool` | `StakeManager` | `setCommitteeVaults(policyId, vaults[], coverageLimit)` | Bind selected vaults/strategies; configures TVL limits on EigenLayer vaults |
| `PolicyManager` | `StakeManager` | `getCommitteeVaults(policyId)` | Verify vault backing exists before bind finalization |
| `PolicyManager` | `StakeManager` | `getCommitteeTokenStakes(policyId)` | Retrieve per-vault token-native stake amounts for USD sufficiency check |
| `PolicyManager` | `ChainlinkPriceFeed` | `getUSDValue(token, amount)` | Convert `coverageLimit` and committee token stakes to USD for bind-time sufficiency check |
| `PremiumManager` | `RewardsManager` | `distributeRewards(policyId, operator, amount, token, taskId)` | Trigger Core reward fan-out; RewardsManager pulls restaker share from PremiumManager, then routes via SSPRouter |
| `ClaimManager` | `SlashingManager` | `previewSlashing(committeeId, operator)` | Read per-vault token-native stake amounts before executing |
| `ClaimManager` | `SlashingManager` | `executeSlashing(committeeId, operator, VaultSlash[], taskId)` | Execute token-native per-vault slashing and return seized collateral |

> **Note:** EigenLayer operator setup (depositing stake, allocating magnitude, and registering to the
> committee's operator set) is performed off-chain by the restaker before bind. See
> [Restaker Setup](./04-restaker-setup.md) for the full sequence.

## Committee and Policy Identity

Coverage enforces `policyId == committeeId` across all cross-layer calls.

Implications:

- Capacity is set once at policy request (`coverageAmount`).
- Vault assignment is attached to the same id at bind time.
- Rewards and slashing are naturally scoped to the policy's committee.

Typical covered-vault actor mapping (CoveredVaultWrapper model):

- `buyer`: `CoveredVaultWrapper`.
- `claimer`: `CoveredVaultWrapper` (withdrawal-triggered claim path).
- `beneficiary`: `CoveredVaultWrapper` — receives the payout and tops up the withdrawing user atomically.

## Flow-by-Flow Integration

### 1) Pool Creation

Sequence:

1. Curator invokes `CoverPoolFactory.createCoverPool(params)`.
2. Factory deploys and initializes a pool clone with curator as owner.

Outcome:

- Curator is pool owner and holds `DEFAULT_ADMIN_ROLE` on the pool.
- Pool is tracked in factory for `coverPoolExists()` validation.

### 2) Coverage Request and Committee Creation

Sequence:

1. Covered vault (or its adapter acting as buyer) calls `PolicyManager.requestCoverage(...)`.
2. Manager creates draft and increments `policyId`.
3. Manager calls `StakeManager.createCommittee(policyId, pool, duration)`.
4. Manager calls `StakeManager.addOperatorToCommittee(curator, policyId)` to explicitly register the pool's curator as committee operator.

Outcome:

- Draft exists in Coverage.
- Committee scaffold exists in Core with policy-aligned id and curator as operator.

### 3) Vault Binding and Policy Activation

Sequence:

1. Curator calls `CoverPool.bindPolicyForRequest(...)` with quote and vaults.
2. Pool calls `StakeManager.setCommitteeVaults(policyId, vaults, coverageLimit)`.
   - `SSPRouter._configureEigenStrategies` runs internally: adds strategies to operator set, sets TVL limits (converting `coverageLimit` USD to token-native amounts), and locks duration vaults.
3. `PolicyManager.bindPolicy(...)` checks:
   - committee has at least one vault (`getCommitteeVaults`),
   - `getCommitteeTokenStakes(policyId)` returns per-vault stakes; their USD values (via `ChainlinkPriceFeed.getUSDValue`) sum to >= `coverageLimit` USD-equivalent.

Outcome:

- Policy transitions to bound/active state only when Core backing is present and stake is sufficient.

### 4) Premium Rewards Routing

Sequence:

1. `CoveredVaultWrapper.collectPremium()` flushes accrued premium and calls `PremiumManager.distributePremium(...)`.
2. `PremiumManager` pulls tokens via `safeTransferFrom`, computes fee splits.
3. Platform fee → `platformTreasury`; pool fee → pool `feeRecipient`.
4. `PremiumManager` calls `RewardsManager.distributeRewards(policyId, curator, restakerSplit, token, taskId)`.
5. `RewardsManager` pulls the restaker share from `PremiumManager` to itself via `safeTransferFrom(premiumManager, address(this), ...)` (requires PremiumManager to have approved RewardsManager), then calls `SSPRouter.distributeRewards(..., tokenSource=address(this))`.
6. `SSPRouter` pulls from `RewardsManager` and fans out to adapters.

Outcome:

- Coverage specifies policy/operator reward intent.
- Core executes final per-SSP reward distribution.

### 5) Claim-Driven Slashing

Sequence:

1. `CoveredVaultWrapper._settleWithdrawalTransfer` detects a shortfall and calls `ClaimManager.fileClaim(...)`.
2. `ClaimManager` calls `SlashingManager.previewSlashing(policyId, operator)` to get per-vault token-native stake amounts.
3. `ClaimManager._computeVaultSlashes` quotes each cross-token stake via `Swapper.quoteSwap`, then computes proportional token-native `VaultSlash[]` amounts, inflating cross-token amounts by `1 / (1 - maxSwapSlippageBps)` for slippage coverage.
4. `ClaimManager` calls `SlashingManager.executeSlashing(policyId, operator, VaultSlash[], taskId)`.
5. Core returns seized collateral token arrays.
6. Coverage swaps or directly transfers to beneficiary; surplus collateral is routed to `RewardsManager` via `PremiumManager.forwardRewards`.

No USD conversion or price feed is involved in the claim execution path. The only price-feed use in Coverage is at **bind time** inside `PolicyManager._validateStakeSufficiency`, which converts the committee's token-native stake to USD and compares it against `coverageLimit`.

Outcome:

- Core performs SSP slashing mechanics.
- Coverage performs beneficiary-facing settlement; `CoveredVaultWrapper` receives the payout and tops up the user's withdrawal.

No-shortfall withdrawal path:

- If the Morpho vault returns sufficient assets, no claim is filed and no Core slashing call is made.

## Data and Unit Conventions

- Slash amounts passed to `executeSlashing` are **token-native** (not USD); `ClaimManager` computes them via `previewSlashing` + `quoteSwap`.
- Coverage payouts are token-denominated by `payoutToken`.
- `coverageAmount` in `PolicyDraft` is treated as the committee stake requirement (USD, 8 decimals) for bind-time sufficiency checks only; `ChainlinkPriceFeed` is used exclusively there.

## Trust and Failure Boundaries

Coverage assumptions about Core:

- committee state and stake reads are correct and timely,
- reward/slash execution either succeeds or reverts atomically,
- token arrays returned from slashing are valid and aligned.

Failure patterns:

- If Core stake is insufficient at bind check, policy bind reverts.
- If slashing returns empty arrays, claim payout reverts.
- If price feed conversion fails or is stale, policy bind path fails (bind-time stake sufficiency check).

## Operational Best Practices

- Keep `policyId` and committee references consistent in all off-chain orchestration.
- Ensure restakers have deposited into the committee's duration vault before bind. Duration vaults act as EigenLayer operators — no separate magnitude allocation or operator-set registration is needed. See [Restaker Setup](./04-restaker-setup.md).
- Register and verify vault module mappings in Core (`SSPRouter.registerVaultModule`) before bind.
- Configure swap routes for expected collateral → payout token pairs before claims; `Swapper.quoteSwap` is used at claim time for slippage computation.
- `WETH` price feed must be registered in `ChainlinkPriceFeed` before binding policies whose payout token is WETH (stake USD sufficiency check at bind).

## Next Steps

- [Restaker Setup and Delegation Lifecycle](./04-restaker-setup.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)

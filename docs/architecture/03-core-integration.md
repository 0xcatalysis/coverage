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
| `PolicyManager` | `StakeManager` | `createCommittee(policyId, pool, duration)` | Create policy-scoped committee; auto-assigns pool curator as operator |
| `CoverPool` | `StakeManager` | `addCommitteeVaults(policyId, vaults[])` | Bind selected vaults/strategies backing policy |
| `PolicyManager` | `StakeManager` | `getCommitteeVaults(policyId)` | Verify vault backing exists before bind finalization |
| `PolicyManager` | `StakeManager` | `getCommitteeTokenStakes(policyId)` | Retrieve per-vault token-native stakes for USD sufficiency check at bind |
| `PolicyManager` | `ChainlinkPriceFeed` | `getUSDValue(token, amount)` | Convert stake and coverageLimit to USD for bind-time sufficiency check |
| `PremiumManager` | `RewardsManager` | `distributeRewards(policyId, operator, amount, token, taskId)` | Trigger Core reward fan-out; SSPRouter pulls restaker share from PremiumManager |
| `ClaimManager` | `SlashingManager` | `previewSlashing(policyId, operator)` | Query per-vault token-native stake data before computing slash amounts |
| `ClaimManager` | `SlashingManager` | `executeSlashing(policyId, operator, vaultSlashes[], taskId)` | Execute policy-scoped token-native slashing and retrieve collateral |

> **Note:** EigenLayer operator setup (depositing stake, allocating magnitude, and registering to the
> committee's operator set) is performed off-chain by the restaker before bind. See
> [Restaker Setup](./04-restaker-setup.md) for the full sequence.

## Committee and Policy Identity

Coverage enforces `policyId == committeeId` across all cross-layer calls.

Implications:

- Committee is created with duration at policy request (no USD capacity parameter).
- Vault assignment is attached to the same id at bind time.
- Stake sufficiency is verified at bind time against the quote's `coverageLimit` via USD conversion.
- Rewards and slashing are naturally scoped to the policy's committee.

Typical covered-vault actor mapping:

- `buyer`: covered vault or cover adapter.
- `claimer`: cover adapter (withdrawal-triggered claim path).
- `beneficiary`: cover adapter for atomic shortfall make-whole, then forwarded to covered vault/user path.

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
   `createCommittee` auto-assigns the pool's curator as the committee operator internally.

Outcome:

- Draft exists in Coverage.
- Committee scaffold exists in Core with policy-aligned id and curator as operator.

### 3) Vault Binding and Policy Activation

Sequence:

1. Curator calls `CoverPool.bindPolicyForRequest(...)` with quote and vaults.
2. Pool calls `StakeManager.addCommitteeVaults(policyId, vaults)`.
3. `PolicyManager.bindPolicy(...)` checks:
   - committee has at least one vault (`getCommitteeVaults`),
   - total stake (USD) ≥ coverage limit (USD) by calling `getCommitteeTokenStakes` and `ChainlinkPriceFeed.getUSDValue` for each token.

Outcome:

- Policy transitions to bound/active state only when Core backing is present and stake in USD covers the quote's `coverageLimit`.

### 4) Premium Rewards Routing

Sequence:

1. `PremiumCollector` redeems covered-vault shares to underlying.
2. `PremiumManager.distributePremium(...)` computes fee splits.
3. Coverage calls `RewardsManager.distributeRewards(policyId, operator, amount, token)`.
4. `SSPRouter` pulls the restaker share directly from `PremiumManager` (approved via `approveSpender`).

Outcome:

- Coverage specifies policy/operator reward intent.
- Core executes final per-SSP reward distribution.

### 5) Claim-Driven Slashing

Sequence:

1. During covered-vault withdrawal, adapter detects shortfall and files claim.
2. `ClaimManager` calls `SlashingManager.previewSlashing(policyId, operator)` to retrieve per-vault token-native stakes.
3. `ClaimManager` computes a `VaultSlash[]` array: proportional token-native slash amounts per vault, with per-vault upward slippage inflation derived from `Swapper.quoteSwap(...)`.
4. `ClaimManager` calls `SlashingManager.executeSlashing(policyId, operator, vaultSlashes[], taskId)`.
5. Core returns collateral token arrays.
6. Coverage swaps or directly transfers to beneficiary (adapter in this integration model).

Outcome:

- Core performs SSP slashing mechanics using token-native amounts per vault.
- Coverage performs beneficiary-facing settlement, then adapter completes make-whole transfer flow.

No-shortfall withdrawal path:

- If adapter deallocation returns sufficient assets, no claim is filed and no Core slashing call is made.

## Data and Unit Conventions

- Slash inputs to Core are token-native per vault (no USD conversion at claim time).
- Bind-time stake sufficiency check uses USD conversion via `ChainlinkPriceFeed` in `PolicyManager`.
- Coverage payouts are token-denominated by `payoutToken`.

## Trust and Failure Boundaries

Coverage assumptions about Core:

- committee state and stake reads are correct and timely,
- reward/slash execution either succeeds or reverts atomically,
- token arrays returned from slashing are valid and aligned.

Failure patterns:

- If Core stake is insufficient at bind check, policy bind reverts.
- If slashing returns empty arrays or all zero amounts, claim payout reverts.
- If `ChainlinkPriceFeed` is unset or stale, bind-time stake sufficiency check fails.

## Operational Best Practices

- Keep `policyId` and committee references consistent in all off-chain orchestration.
- Ensure restakers have deposited into the committee's duration vault before bind. Duration vaults act as EigenLayer operators — no separate magnitude allocation or operator-set registration is needed. See [Restaker Setup](./04-restaker-setup.md).
- Register and verify vault module mappings in Core (`SSPRouter.registerVaultModule`) before bind.
- Configure swap routes for expected collateral → payout token pairs before claims.
- `ChainlinkPriceFeed` must be configured on `PolicyManager` with price feeds for all supported payout and collateral tokens before bind.

## Next Steps

- [Restaker Setup and Delegation Lifecycle](./04-restaker-setup.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)
- [Covered Vault Integration](./07-covered-vault-integration.md)

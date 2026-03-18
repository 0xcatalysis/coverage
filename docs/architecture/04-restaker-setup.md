# Restaker Setup and Delegation Lifecycle

## Overview

Before a policy can be bound, the restaker must complete a deposit setup that makes their stake
slashable by the policy's committee. This process involves depositing directly into an EigenLayer
duration vault (and optionally a Symbiotic vault).

The restaker deposit is performed directly against EigenLayer contracts (no Coverage script needed).
Stake sufficiency is enforced at bind time by `PolicyManager.bindPolicy`, which converts per-vault
token-native stakes to USD via `ChainlinkPriceFeed.getUSDValue` and checks against the quote's
`coverageLimit`.

## Duration Vault Model (EigenLayer)

On EigenLayer, **duration vaults (`DurationVaultStrategy`) act as the operator** — the curator
does NOT register as an EigenLayer operator, set an allocation delay, allocate magnitude, or
register to an operator set. The vault handles all of this internally:

- When `PolicyManager.requestCoverage` is called, it triggers `StakeManager.createCommittee`,
  which calls `SSPRouter.createCommittee`.
- `SSPRouter.createCommittee` automatically deploys a `DurationVaultStrategy` contract (via
  `EigenAdapter.deployDurationVaultStrategy`) for each acceptable collateral token.
- Each `DurationVaultStrategy` registers itself as an EigenLayer operator and operator set upon
  deployment.
- Restakers deposit collateral directly into the duration vault through EigenLayer's
  `StrategyManager.depositIntoStrategy(durationVault, token, amount)`.
- No separate magnitude allocation or operator set registration is needed from the restaker.

## EigenLayer Delegation Lifecycle for a Committee

```mermaid
flowchart TD
    DEPOSIT["1. Deposit into duration vault\nStrategyManager.depositIntoStrategy(durationVault, token, amount)"]
    VAULTS["2. Add vaults to committee\n(via CoverPool.bindPolicyForRequest)"]
    BIND["3. Bind policy\n(PolicyManager.bindPolicy)"]
    SLASH["Slashable on claim\n(SlashingManager.executeSlashing)"]

    DEPOSIT --> VAULTS
    VAULTS --> BIND
    BIND --> SLASH
```

### Step 1: Deposit into Duration Vault

The restaker deposits collateral into the `DurationVaultStrategy` auto-deployed by
`EigenAdapter.deployDurationVaultStrategy` when the committee was created. Deposits go through
EigenLayer's standard `StrategyManager`:

```solidity
IERC20(token).approve(eigenStrategyManager, amount);
IStrategyManager(eigenStrategyManager).depositIntoStrategy(durationVault, token, amount);
```

The `durationVault` address is the `DurationVaultStrategy` contract deployed for this committee.
It acts as both an EigenLayer strategy (accepts deposits) and an EigenLayer operator (is
slashable). Its address is stored in `StakeManager.getCommitteeVaults(policyId)` after committee
creation.

The deposited amount must satisfy the coverage USD requirement. At bind time `PolicyManager.bindPolicy`
calls `StakeManager.getCommitteeTokenStakes(policyId)` to retrieve per-vault token-native stakes,
then converts each to USD via `ChainlinkPriceFeed.getUSDValue(token, amount)` and checks that the
sum meets or exceeds the quote's `coverageLimit` (also converted to USD).

Example: to cover a `coverageLimit` of 1000 USD, at least `$1000 / ETH_USD_PRICE` ETH worth of
WETH must be deposited into the committee's duration vault.

### Steps 2 & 3: Add Vaults and Bind Policy

These steps are performed by the curator via `CoverPool.bindPolicyForRequest(...)`, which:

1. calls `StakeManager.setCommitteeVaults(policyId, [durationVaultStrategy], coverageLimit)` —
   registers the vault as a committee vault and calls `EigenAdapter.addStrategiesToOperatorSet`
   to configure it,
2. calls `PolicyManager.bindPolicy(...)` — verifies committee has at least one vault, checks that
   total stake (USD) ≥ `coverageLimit` (USD) via `getCommitteeTokenStakes` +
   `ChainlinkPriceFeed.getUSDValue`, and activates the policy.

## Why a Separate Setup Phase Exists

Policy binding (`BindPolicy.s.sol`) and restaker deposit are deliberately separated because:

- **Different actors and keys**: deposit uses the restaker key; binding uses the curator key and
  quote signer key.
- **Asynchronous stake propagation**: after deposit, the USD value reported by `EigenAdapter` may
  take one or more blocks to reflect on-chain price feed data.
- **One-time vs per-policy**: stake deposit is per-restaker/committee setup; binding is per-policy.
- **Protocol boundary**: the deposit phase crosses EigenLayer/Symbiotic APIs directly; the bind
  phase only touches Coverage and Core contracts.

## Premium Reward Flow

After policy binding and premium collection, premiums are distributed as follows:

1. `PremiumCollector` redeems vault shares and transfers underlying to `PremiumManager`.
2. `PremiumManager.distributePremium` splits the amount into platform fee, pool fee, and restaker
   share. Platform and pool fees are transferred immediately. The **restaker share stays in
   `PremiumManager`** — it is NOT transferred to `RewardsManager`.
3. `PremiumManager` calls `RewardsManager.distributeRewards(policyId, curator, amount, token, taskId)`.
4. `RewardsManager` calls `SSPRouter.distributeRewards(..., tokenSource=premiumManager)`.
5. `SSPRouter` pulls the tokens directly from `PremiumManager` via
   `token.safeTransferFrom(premiumManager, adapter, amount)`.

**Prerequisite**: admin must call `PremiumManager.approveSpender(token, sspRouter, type(uint256).max)`
once during initial setup so that SSPRouter has an unlimited allowance to pull tokens.

## Vault Module Registration Prerequisite

Before any vault can be bound to a committee, the core admin must register it in `SSPRouter`:

```bash
cast send $SSPROUTER "registerVaultModule(address,uint8)" $VAULT_ADDRESS 2 \
  --private-key $CORE_ADMIN_PRIVATE_KEY --rpc-url $RPC_URL
# 2 = EIGENLAYER; 1 = SYMBIOTIC
```

For duration vaults auto-deployed by `createCommittee`, this is handled automatically.

Verify:
```bash
cast call $SSPROUTER "getVaultModule(address)(uint8)" $VAULT_ADDRESS --rpc-url $RPC_URL
# Expected: 2 (EIGENLAYER) or 1 (SYMBIOTIC)
```

## Stake Sufficiency Check at Bind Time

The stake sufficiency check runs inside `PolicyManager.bindPolicy` after `setCommitteeVaults`
has registered the vaults:

```
sum_i( ChainlinkPriceFeed.getUSDValue(tokens[i], tokenStakes[i]) )
  >= ChainlinkPriceFeed.getUSDValue(payoutToken, coverageLimit)
```

Where `tokens[i]` and `tokenStakes[i]` come from `StakeManager.getCommitteeTokenStakes(policyId)`,
and `coverageLimit` is the value from the curator-signed quote. Both sides are expressed in USD
with 8 decimal places. For example, a `coverageLimit` of `1000e18` payout-token units for a
$1 peg token corresponds to $1,000 USD (8 decimals: `100_000_000_000`).

## Restaker Deposit Reference

The restaker deposit is a single direct EigenLayer call — no Coverage script is needed.
Get the `durationVault` address from `StakeManager.getCommitteeVaults(policyId)[0]` after committee creation.

```bash
# 1. Approve collateral token to EigenLayer StrategyManager
cast send $COLLATERAL_TOKEN "approve(address,uint256)" $EIGEN_STRATEGY_MANAGER $DEPOSIT_AMOUNT \
  --private-key $RESTAKER_PRIVATE_KEY --rpc-url $RPC_URL

# 2. Deposit into the duration vault
cast send $EIGEN_STRATEGY_MANAGER \
  "depositIntoStrategy(address,address,uint256)" \
  $EIGEN_DURATION_VAULT $COLLATERAL_TOKEN $DEPOSIT_AMOUNT \
  --private-key $RESTAKER_PRIVATE_KEY --rpc-url $RPC_URL
```

| Variable | Description |
|----------|-------------|
| `RESTAKER_PRIVATE_KEY` | Restaker private key |
| `EIGEN_STRATEGY_MANAGER` | EigenLayer StrategyManager address |
| `EIGEN_DURATION_VAULT` | DurationVaultStrategy for this committee (`StakeManager.getCommitteeVaults(policyId)[0]`) |
| `COLLATERAL_TOKEN` | Collateral token accepted by the duration vault |
| `DEPOSIT_AMOUNT` | Amount to deposit (wei) |

## Key Addresses on Sepolia

| Component | Address |
|-----------|---------|
| EigenLayer DelegationManager | `0xD4A7E1Bd8015057293f0D0A557088c286942e84b` |
| EigenLayer StrategyManager | `0x2E3D6c0744b10eb0A4e6F679F71554a39Ec47a5D` |
| EigenAdapter (AVS) | `0xA28871e253C972A96003D3f432CA4170f4ae2A78` |
| SSPRouter | `0xc2F3906Bb57c8Db7DF2DddF0f2CEc521fE6834f8` |

Duration vault addresses are looked up at runtime via `StakeManager.getCommitteeVaults(policyId)`.

## Common Failure Modes

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| `InsufficientStake` at bind | Total stake USD < `coverageLimit` USD | Deposit more collateral or reduce `coverageLimit` in the quote |
| `VaultModuleNotSet` at `setCommitteeVaults` | Duration vault not registered in `SSPRouter` | Core admin: `SSPRouter.registerVaultModule(vault, 2)` |
| `PriceFeedNotFound` at bind | Payout or collateral token not registered in `ChainlinkPriceFeed` | Core admin: `registerPriceFeed(token, aggregator)` before bind |
| `InvalidCommitteeId` | `policyId = 0` (not set from output of RequestCoverage) | Set `POLICY_ID` env var from `RequestCoverage.s.sol` output |
| Stake reads 0 before bind | Vaults not yet added to committee (expected) | Stake = 0 until `bindPolicyForRequest` runs `setCommitteeVaults` |
| `SSPRouter safeTransferFrom` reverts on distribution | PremiumManager has not approved SSPRouter | Admin: `PremiumManager.approveSpender(token, sspRouter, type(uint256).max)` |

## Related Pages

- [Core Integration](./03-core-integration.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)

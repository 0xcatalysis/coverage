# Restaker Setup and Delegation Lifecycle

## Overview

Before a policy can be bound, the restaker must complete a deposit setup that makes their stake
slashable by the policy's committee. This process involves depositing directly into an EigenLayer
duration vault (and optionally a Symbiotic vault).

The restaker deposit is performed directly against EigenLayer contracts (no Coverage script needed).
Stake sufficiency is enforced at bind time by `PolicyManager.bindPolicy`, which reads
`StakeManager.getCommitteeTokenStakes(policyId)` and converts each vault's token-native stake to USD
via `ChainlinkPriceFeed.getUSDValue`, then requires the total >= `coverageLimit` in USD.

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

The deposited amount must satisfy the coverage USD requirement. The USD value is computed by
`EigenAdapter.getStrategiesStakeUSD(vaults)` at bind time:

```
stake_USD = totalShares * sharesToUnderlyingView() * ChainlinkPriceFeed.getUSDValue(token, 1e18) / 1e18
```

Example: to cover `coverageAmount = 100_000_000_000` (1000 USD at 8 decimals), at least
`$1000 / ETH_USD_PRICE` ETH worth of WETH must be deposited.

### Steps 2 & 3: Add Vaults and Bind Policy

These steps are performed by the curator via `CoverPool.bindPolicyForRequest(...)`, which:

1. calls `StakeManager.setCommitteeVaults(policyId, [durationVaultStrategy], coverageLimit)` — registers the
   vault as a committee vault, calls `EigenAdapter.addStrategiesToOperatorSet` to configure it,
   sets TVL limits on the duration vault (converting `coverageLimit` USD to token-native amounts),
   and locks the duration vault.
2. calls `PolicyManager.bindPolicy(...)` — verifies committee has at least one vault, reads
   `getCommitteeTokenStakes(policyId)`, converts total stake to USD via `ChainlinkPriceFeed.getUSDValue`,
   and requires `totalStakeUSD >= coverageLimitUSD` before activating the policy.

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

1. `CoveredVaultWrapper.collectPremium()` (permissionless) checkpoints the premium accumulator and calls `PremiumManager.distributePremium(...)`, approving PremiumManager to pull the pending amount first.
2. `PremiumManager.distributePremium` pulls tokens via `safeTransferFrom` and splits the amount into platform fee, pool fee, and restaker share. Platform and pool fees are transferred immediately.
3. `PremiumManager` calls `RewardsManager.distributeRewards(policyId, curator, restakerSplit, token, taskId)`.
4. `RewardsManager` pulls the restaker share **from `PremiumManager` to itself** via
   `token.safeTransferFrom(premiumManager, address(this), restakerSplit)`.
5. `RewardsManager` calls `SSPRouter.distributeRewards(..., tokenSource=address(this))`.
6. `SSPRouter` pulls tokens from `RewardsManager` and fans out to adapters.

**Prerequisite**: admin must call `PremiumManager.approveSpender(token, rewardsManager, type(uint256).max)`
once during initial setup so that `RewardsManager` has an unlimited allowance to pull the restaker share from `PremiumManager`.

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

The stake check runs inside `PolicyManager.bindPolicy`, not during vault registration. After
`StakeManager.setCommitteeVaults` configures the vaults, `bindPolicy` calls:

```
StakeManager.getCommitteeTokenStakes(policyId)
  → returns (vaults[], tokens[], tokenStakes[])
```

Then for each vault with non-zero stake:
```
totalStakeUSD += ChainlinkPriceFeed.getUSDValue(tokens[i], tokenStakes[i])
```

And the coverage limit in USD:
```
coverageLimitUSD = ChainlinkPriceFeed.getUSDValue(payoutToken, coverageLimit)
```

Bind reverts with `InsufficientStake` if `totalStakeUSD < coverageLimitUSD`.

For example, to back a policy with `coverageLimit = 1 WETH` (where 1 WETH = $1,000 USD at bind time),
the committee must hold >= $1,000 USD worth of staked collateral.

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
| `InsufficientStake` at bind | `totalStakeUSD` < `coverageLimitUSD` in `PolicyManager.bindPolicy` | Deposit more collateral or reduce `COVERAGE_AMOUNT` |
| `VaultModuleNotSet` at `setCommitteeVaults` | Duration vault not registered in `SSPRouter` | Core admin: `SSPRouter.registerVaultModule(vault, 2)` |
| `PriceFeedNotFound` at bind or `fileClaim` | Token not registered in `ChainlinkPriceFeed` | Core admin: `registerPriceFeed(token, aggregator, stalenessThreshold)` |
| `InvalidCommitteeId` | `policyId = 0` (not set from output of RequestCoverage) | Set `POLICY_ID` env var from `RequestCoverage.s.sol` output |
| Stake reads 0 before bind | Vaults not yet added to committee (expected) | Stake = 0 until `bindPolicyForRequest` runs `setCommitteeVaults` |
| `RewardsManager safeTransferFrom` reverts on distribution | PremiumManager has not approved RewardsManager | Admin: `PremiumManager.approveSpender(token, rewardsManager, type(uint256).max)` |

## Related Pages

- [Core Integration](./03-core-integration.md)
- [Policy Lifecycle](./05-policy-lifecycle.md)
- [Premiums and Claims](./06-premiums-claims.md)

# Catalysis Morpho Adapter

> NAV-based insurance coverage adapter for Morpho Vault V2.

## Overview

`CatalysisCoverAdapter` sits between a **Covered Vault** (Morpho V2) and an **Underlying Vault** (any ERC-4626 vault) to provide automatic insurance against NAV losses.

```
User ──► Covered Vault (V2) ──► CatalysisCoverAdapter ──► Underlying Vault (V1/V2)
              │                        │
              │ management fee         │ insurance claim
              ▼                        ▼
        Catalysis Treasury       Catalysis CoverPool
```

When a user deposits into the Covered Vault, the adapter forwards assets to the Underlying Vault and tracks both **global** and **per-user** principal. On withdrawal, if the Underlying Vault's NAV has dropped, the adapter automatically files an insurance claim and transfers the payout **directly to the user** — up to `maxCoverableLossBps` of their personal principal.


## Architecture

### Insurance Mechanics

The adapter uses a **per-user principal tracking** model — each user's deposits and underlying shares are tracked individually, while a single Catalysis policy purchased by the curator covers all users.

| Concept                  | Description                                                                            |
| ------------------------ | -------------------------------------------------------------------------------------- |
| **totalPrincipal**       | Global sum of all assets deposited via `allocate()`                                    |
| **userPrincipal**        | Per-user principal tracked on user deposit/mint (not on allocator `ALLOCATE_SELECTOR`) |
| **userUnderlyingShares** | Per-user share count in the underlying vault                                           |
| **maxCoverableLossBps**  | Cap on covered loss as % of user principal (e.g., `1000` = 10%)                        |
| **Deductible**           | 1% (`DEDUCTIBLE_BPS = 100`) — users absorb this portion of any loss                    |
| **Coverage limit**       | Per-policy limit from the CoverPool, decreases as claims are paid                      |
| **Absolute cap**         | Max assets the vault can allocate to this adapter, set by `onPolicyBound`              |

### `realAssets()` — Share Price Reporting

The adapter reports **pure current value** to the Covered Vault:

```
realAssets() = currentValue() = underlyingVault.convertToAssets(underlyingShares)
```

Insurance is **NOT** baked into the share price. Instead, insurance payouts are transferred directly to users during withdrawal. This means the Covered Vault's share price reflects the actual underlying NAV at all times.

### Allocate Flow (`allocate`)

When the parent vault calls `allocate()`, the adapter deposits assets into the underlying vault:

- **Always**: increases `underlyingShares` and `totalPrincipal`
- **User operations** (deposit/mint — `selector != ALLOCATE_SELECTOR`): additionally tracks `userPrincipal[sender]` and `userUnderlyingShares[sender]`
- **Allocator operations** (`selector == ALLOCATE_SELECTOR`): only updates global state, no per-user tracking

### Deallocate Flow — Three Branches (`deallocate`)

The `deallocate()` function has three distinct branches based on the selector and sender:

| Branch                  | Condition                                                                                               | Behavior                                                                                                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **1 — Emergency / Fee** | `selector == DEALLOCATE_SELECTOR \|\| FORCE_DEALLOCATE_SELECTOR`, or `sender == managementFeeRecipient` | Withdraw assets, decrease `totalPrincipal` proportionally. No per-user tracking. No insurance. `DEALLOCATE`/`FORCE_DEALLOCATE` require `totalPrincipal == 0` after (full withdrawal only). |
| **2 — User Withdrawal** | `userPrincipal[sender] > 0` and `convertToShares(assets) <= userUnderlyingShares[sender]`               | Calls `_withdraw(assets, sender)` — burns pro-rata shares, calculates per-user shortfall, claims insurance and transfers payout directly to user.                                          |
| **3 — Unsupported**     | None of the above                                                                                       | Reverts with `UnsupportedDeallocation(assets, selector, sender)`.                                                                                                                          |

### Per-User Withdrawal (`_withdraw`)

The `_withdraw` function handles user withdrawals with direct insurance:

1. **Withdraw assets** from underlying vault via `withdraw(assets)` → receives exact `assets` tokens
2. **Update per-user state**: decrease `userPrincipal[sender]` and `userUnderlyingShares[sender]` proportionally
3. **Decrease `totalPrincipal`** by the user's proportional principal
4. **Calculate shortfall**: if `userPrincipalForWithdrawal > assets`, shortfall exists
5. **Claim insurance** (if policy active and shortfall > 0):
   - `maxInsurance = userPrincipalForWithdrawal × maxCoverableLossBps / 10000`
   - `effectiveInsurance = maxInsurance × (1 − DEDUCTIBLE_BPS / 10000)`
   - `claimAmount = min(shortfall, effectiveInsurance)`
   - Insurance payout transferred directly to user via `safeTransfer`

### Claim Flow

```
_withdraw(assets, sender)
  ├─► withdraw(assets) from underlying vault
  ├─► update per-user principal & shares
  ├─► decrease totalPrincipal
  └─► if shortfall > 0 && policy active:
        └─► _claimInsurance(claimAmount)
              ├─► _setPendingClaim()        ← transient storage
              ├─► _fileAndResolveClaim()    ← BasePolicyInteractions
              │     └─► ClaimManager.fileAndResolveClaim()
              │           └─► adapter.evaluate()  ← callback validates pending claim
              ├─► _clearPendingClaim()
              ├─► payout = balanceAfter − balanceBefore
              └─► safeTransfer(payout → sender)
```

### Policy Bound Hook (`onPolicyBound`)

When PolicyManager binds a policy, it calls `onPolicyBound(uint96 policyId, uint256 coverageLimit)` on the adapter via the `IBindPolicyHook` interface. This hook:

1. **Auth check** — Only callable by PolicyManager (`msg.sender == policyManager`)
2. **Single execution** — Can only be called once (`policyBoundExecuted` flag)
3. **Policy validation** — Validates: `pol.buyer == parentVault.owner()`, `pol.pool == coverPool`, `pol.claimer == address(this)`
4. **Stores policyId** — The `policyId` is set here (not in the constructor)
5. **Sets absolute cap** on the parent vault:

```
absoluteCap = (BPS_DENOMINATOR / maxCoverableLossBps) × coverageLimit
```

For example, with `maxCoverableLossBps = 1000` (10%) and `coverageLimit = 100`:

- `absoluteCap = (10000 / 1000) × 100 = 1000`
- The vault can hold up to 1000 in assets (10× the coverage limit)

6. **Calls `submit` + `increaseAbsoluteCap`** on the parent vault (requires Curator role)

```
PolicyManager.bindPolicy()
  └─► adapter.onPolicyBound(policyId, coverageLimit)
        ├─► validate: msg.sender == policyManager
        ├─► validate: !policyBoundExecuted
        ├─► validate: pol.buyer == parentVault.owner()
        ├─► validate: pol.pool == coverPool
        ├─► validate: pol.claimer == address(this)
        ├─► policyId = _policyId
        ├─► policyBoundExecuted = true
        ├─► absoluteCap = (10000 / maxCoverableLossBps) × coverageLimit
        ├─► parentVault.submit(increaseAbsoluteCap data)
        └─► parentVault.increaseAbsoluteCap(idData, absoluteCap)
```

> **Note:** The adapter must have the **Curator** role on the parent vault to call `submit` + `increaseAbsoluteCap`. The deploy script sets the adapter as curator. After `onPolicyBound` executes, the owner should transfer the curator role to the final recipient.

## Constructor Parameters

| Parameter              | Type      | Description                                                 |
| ---------------------- | --------- | ----------------------------------------------------------- |
| `_parentVault`         | `address` | Covered Vault (Morpho V2)                                   |
| `_underlyingVault`     | `address` | Underlying Vault (ERC-4626 compliant)                       |
| `_claimManager`        | `address` | Catalysis ClaimManager (PolicyManager derived from it)      |
| `_coverPool`           | `address` | Catalysis CoverPool contract                                |
| `_maxCoverableLossBps` | `uint16`  | Max loss covered in basis points (1–10000, e.g. 1000 = 10%) |

> **Note:** The constructor derives `policyManager` from `claimManager` via `IClaimManager(_claimManager).policyManager()`. Policy validation is deferred to the `onPolicyBound` hook (called after deployment when the policy is bound).

## Deployment

The deploy script (`script/DeployCoveredVault.s.sol`) performs 5 steps atomically:

| Step  | Action                                                                                                        |
| ----- | ------------------------------------------------------------------------------------------------------------- |
| **1** | Deploy Covered Vault via V2 Factory, set deployer as temporary curator & allocator, set name/symbol           |
| **2** | Deploy `CatalysisCoverAdapter(parentVault, underlyingVault, claimManager, coverPool, maxCoverableLossBps)`    |
| **3** | Register adapter, set relative cap, management fee, fee recipient, liquidity adapter (absolute cap set later) |
| **4** | Abdicate `setPerformanceFeeRecipient`, `addAdapter`, `removeAdapter` selectors                                |
| **5** | Revoke deployer allocator, set adapter as curator (for `onPolicyBound` hook), transfer owner                  |

> **Post-deployment:** After PolicyManager calls `onPolicyBound` (which stores the policyId and sets the absolute cap), the owner should transfer the curator role to the final recipient.

### Usage

```bash
# 1. Configure
cp .env.example .env
# Edit .env with your parameters

# 2. Deploy
source .env
forge script script/DeployCoveredVault.s.sol:DeployCoveredVault \
  --rpc-url $ETHEREUM_URL \
  --broadcast \
  --verify \
  -vvvv
```

See [`.env.example`](.env.example) for all required configuration parameters.

## Fund Flow Diagrams

### Deposit — User (allocate with per-user tracking)

```
User deposits 1000 USDC into Covered Vault
  │
  ▼
Covered Vault calls adapter.allocate(1000, DEPOSIT_SELECTOR, user)
  │
  ├─► adapter deposits 1000 USDC into Underlying Vault → receives shares
  ├─► underlyingShares += shares
  ├─► totalPrincipal += 1000
  ├─► userPrincipal[user] += 1000         ← per-user tracking
  └─► userUnderlyingShares[user] += shares ← per-user tracking
```

### Deposit — Allocator (allocate without per-user tracking)

```
Allocator rebalances 500 USDC into adapter
  │
  ▼
Covered Vault calls adapter.allocate(500, ALLOCATE_SELECTOR, allocator)
  │
  ├─► adapter deposits 500 USDC into Underlying Vault → receives shares
  ├─► underlyingShares += shares
  └─► totalPrincipal += 500
      (no per-user tracking for allocator operations)
```

### User Withdrawal — No Loss (profit)

```
userPrincipal = 1000, user's underlying value = 1050 (5% profit)
User withdraws 100 USDC (Branch 2 — user withdrawal)
  │
  ▼
_withdraw(100, user):
  ├─► withdraw(100) from underlying vault → burns sharesToBurn, receives 100 USDC
  ├─► userPrincipalForWithdrawal = 1000 × sharesToBurn / userShares ≈ 95.24
  ├─► userPrincipal[user] -= 95.24
  ├─► userUnderlyingShares[user] -= sharesToBurn
  ├─► totalPrincipal -= 95.24
  ├─► shortfall = 0 (95.24 < 100 → no loss)
  └─► insurancePayout = 0
```

### User Withdrawal — Loss (with insurance)

```
userPrincipal = 1000, user's underlying value = 950 (5% loss)
User withdraws 100 USDC (Branch 2 — user withdrawal)
  │
  ▼
_withdraw(100, user):
  ├─► withdraw(100) from underlying → burns sharesToBurn, receives 100 USDC
  ├─► userPrincipalForWithdrawal = 1000 × sharesToBurn / userShares ≈ 105.26
  ├─► shortfall = 105.26 − 100 = 5.26
  ├─► maxInsurance = 105.26 × 10% = 10.53
  ├─► effectiveInsurance = 10.53 × 99% = 10.42
  ├─► claimAmount = min(5.26, 10.42) = 5.26
  ├─► _claimInsurance(5.26) → 5.26 USDC from CoverPool
  ├─► safeTransfer(5.26 USDC → user)     ← direct to user, not via vault
  ├─► userPrincipal[user] -= 105.26
  ├─► userUnderlyingShares[user] -= sharesToBurn
  └─► totalPrincipal -= 105.26
```

### Emergency Deallocate (Branch 1)

```
Allocator calls deallocate with DEALLOCATE_SELECTOR
  │
  ▼
Branch 1 — emergency path:
  ├─► withdraw(assets) from underlying vault → burns shares
  ├─► underlyingShares -= sharesToBurn
  ├─► principalDecrease = totalPrincipal × assets / currentValue
  ├─► totalPrincipal -= principalDecrease
  ├─► require(totalPrincipal == 0)  ← must be a full withdrawal
  └─► NO insurance, NO per-user tracking
```

### User Withdrawal — Expired Policy

```
userPrincipal = 1000, user's underlying value = 900 (10% loss)
Policy expired → no insurance

User withdraws 100 USDC (Branch 2 — user withdrawal)
  │
  ▼
_withdraw(100, user):
  ├─► withdraw(100) from underlying → receives 100 USDC
  ├─► userPrincipalForWithdrawal ≈ 111.11
  ├─► shortfall = 111.11 − 100 = 11.11
  ├─► policy expired → insurancePayout = 0
  ├─► userPrincipal[user] -= 111.11
  └─► totalPrincipal -= 111.11

  ⚠ User receives 100 USDC from underlying but bears full loss risk
    (no insurance payout since policy is expired)
```

## Profit / Loss Examples

### Example 1: 5% Profit — No Insurance Needed

|                       | Value                        |
| --------------------- | ---------------------------- |
| User Principal        | 1,000 USDC                   |
| User Underlying Value | 1,050 USDC                   |
| User withdraws 100%   | **1,050 USDC** (full upside) |
| From underlying       | 1,050 USDC                   |
| From insurance        | 0 USDC                       |

### Example 2: 5% Loss — Fully Covered by Insurance

|                         | Value                     |
| ----------------------- | ------------------------- |
| User Principal          | 1,000 USDC                |
| User Underlying Value   | 950 USDC                  |
| Shortfall               | 50 USDC                   |
| Max Insurance           | 1,000 × 10% = 100 USDC    |
| Effective Insurance     | 100 × 99% = 99 USDC       |
| Claim Amount            | min(50, 99) = 50 USDC     |
| User receives           | 950 + 50 = **1,000 USDC** |
| From underlying         | 950 USDC                  |
| From insurance (direct) | 50 USDC                   |

### Example 3: 15% Loss — Partially Covered

|                         | Value                   |
| ----------------------- | ----------------------- |
| User Principal          | 1,000 USDC              |
| User Underlying Value   | 850 USDC                |
| Shortfall               | 150 USDC                |
| Max Insurance           | 1,000 × 10% = 100 USDC  |
| Effective Insurance     | 100 × 99% = 99 USDC     |
| Claim Amount            | min(150, 99) = 99 USDC  |
| User receives           | 850 + 99 = **949 USDC** |
| From underlying         | 850 USDC                |
| From insurance (direct) | 99 USDC                 |
| User absorbs            | 51 USDC loss (5.1%)     |

### Example 4: Coverage Partially Exhausted

|                         | Value                   |
| ----------------------- | ----------------------- |
| User Principal          | 1,000 USDC              |
| User Underlying Value   | 950 USDC                |
| Shortfall               | 50 USDC                 |
| Max Insurance           | 1,000 × 10% = 100 USDC  |
| Effective Insurance     | 100 × 99% = 99 USDC     |
| Already paid out        | 70 USDC                 |
| Remaining coverage      | 30 USDC                 |
| Claim (capped)          | min(50, 30) = 30 USDC   |
| User receives           | 950 + 30 = **980 USDC** |
| From underlying         | 950 USDC                |
| From insurance (direct) | 30 USDC                 |
| User absorbs            | 20 USDC loss (2%)       |

## Testing

```bash
# All non-fork tests (92 tests)
forge test --no-match-path "test/Diag.t.sol" --no-match-test "testFork|test_fork" -vv

# Fork tests (requires mainnet RPC)
FOUNDRY_PROFILE=fork forge test --match-test "test_fork" -vv

# Fuzz tests with custom runs
forge test --match-contract Fuzz -vv

# Gas report
forge test --gas-report
```

> **Important:** Fork tests use the `[profile.fork]` foundry profile which sets `isolate = true`, because Morpho V2 uses transient storage (`tstore`/`tload`) which must be cleared between test calls.

## Project Structure

```
src/
├── adapters/vault/
│   └── CatalysisCoverAdapter.sol   # Main adapter contract (535 lines)
├── base/
│   └── BasePolicyInteractions.sol   # Catalysis policy/claim base
├── interfaces/
│   ├── ICatalysisCoverAdapter.sol   # Adapter interface
│   ├── IAlerts.sol                  # Custom errors
│   ├── IEvents.sol                  # Custom events
│   ├── CoverPool/                   # Catalysis protocol interfaces
│   └── Morpho/                      # Morpho V2 interfaces
script/
│   └── DeployCoveredVault.s.sol     # Foundry deploy script
test/
├── CatalysisCoverAdapter.t.sol      # Unit tests (43)
├── CatalysisCoverAdapter.fuzz.t.sol # Fuzz tests (28)
├── CatalysisCoverAdapter.scenarios.t.sol  # Scenario tests (21)
├── CatalysisCoverAdapter.fork.t.sol # Fork tests (mainnet)
├── helpers/
│   └── RealCoverageSetup.sol        # Real PolicyManager + CoverPool setup
└── mocks/                           # Mock contracts
```

## License

MIT

# Analysis: Oracle, Zero-State & Edge Cases — Agent #4

## Oracle Analysis Step Execution Checklist

| Section | Required | Completed | Notes |
|---------|----------|-----------|-------|
| 1. Oracle Inventory | YES | ✓ | 1 oracle: ChainlinkPriceFeed (abstracted) |
| 2. Staleness Analysis | YES | ✓ | Delegated to ChainlinkPriceFeed external contract |
| 3. Decimal Normalization Audit | YES | ✓ | |
| 3d. Decimal Grep Sweep | YES | ✓ | No hardcoded decimal constants in oracle consumers |
| 4. TWAP-Specific Analysis | IF TWAP used | ✗(N/A) | No TWAP oracle |
| 5. Oracle Weight / Threshold Boundaries | IF multi-oracle or thresholds | ✓ | Single threshold: totalStakeUSD >= coverageLimitUSD |
| 6. Oracle Failure Modes | YES | ✓ | |

---

## Sweep 1: Oracle Analysis (Chainlink in PolicyManager)

### 1. Oracle Inventory

| Oracle | Type | Source Contract | Functions Called | Consumers | Update Frequency | Heartbeat |
|--------|------|-----------------|-----------------|-----------|-----------------|-----------|
| ChainlinkPriceFeed | Chainlink (abstracted) | External (not in repo) | `getUSDValue(token, amount)` | `PolicyManager.bindPolicy()` L266-274 | UNKNOWN | UNKNOWN |

The protocol does NOT call Chainlink's `latestRoundData()` directly. It delegates to an external `ChainlinkPriceFeed` contract via the `IChainlinkPriceFeed` interface. The interface returns `uint256` (no roundId, updatedAt, answeredInRound are exposed to PolicyManager).

**Decision made**: USD price conversion at policy bind time. Determines whether `totalStakeUSD >= coverageLimitUSD` (whether staked collateral sufficiently backs the policy).

### 2. Staleness Analysis

The `IChainlinkPriceFeed.getUSDValue()` interface provides NO mechanism for the consumer (`PolicyManager`) to verify staleness, zero price, round completeness, or negative values. All validation is delegated to the external `ChainlinkPriceFeed` implementation. This is an opaque dependency.

**Impact trace**: If `ChainlinkPriceFeed.getUSDValue()` returns stale or manipulated data:

| Consumer Function | Data Used | If Stale/Wrong: Impact | Severity |
|-------------------|-----------|------------------------|----------|
| `bindPolicy()` L266-274 | totalStakeUSD, coverageLimitUSD | Undercollateralized policy could be bound (stale high price inflates totalStakeUSD) OR valid policy could be rejected (stale low price deflates totalStakeUSD) | Medium (bind-time only, not at claim time) |

### 3. Decimal Normalization Audit

| Oracle | Oracle Decimals | Consumer Expects | Normalization | Correct? |
|--------|----------------|-----------------|---------------|----------|
| ChainlinkPriceFeed | 8 (per interface doc) | Compared as-is (both calls return 8-decimal USD) | N/A (both values from same oracle, same decimals) | YES |

The `PolicyManager` calls `getUSDValue()` twice — once for `totalStakeUSD` and once for `coverageLimitUSD` — then compares them directly (`>=`). Since both values come from the same price feed contract with the same decimal convention, no normalization mismatch is possible within PolicyManager itself.

### 3d. Decimal Grep Sweep

| File:Line | Pattern | Hardcoded Value | Oracle's Actual Decimals | Match? |
|-----------|---------|-----------------|-------------------------|--------|
| (none found in PolicyManager.sol) | N/A | N/A | 8 (per interface) | N/A |

No hardcoded decimal constants are used in PolicyManager's oracle consumption. Both USD values are compared directly.

### 5b. Oracle-Based Thresholds

| Threshold | Oracle Data Used | Threshold Value | At Exact Boundary | Off-by-One? |
|-----------|-----------------|----------------|-------------------|-------------|
| `totalStakeUSD >= coverageLimitUSD` (L274) | Both from ChainlinkPriceFeed | Dynamic (coverageLimit) | `>=` allows exact match | NO |

### 6. Oracle Failure Modes

| Failure Mode | Oracle Behavior | Protocol Response | Impact | Mitigation? |
|-------------|-----------------|-------------------|--------|-------------|
| Revert | `getUSDValue()` reverts | `bindPolicy()` reverts entirely | Bind blocked (DoS) | NO — no try/catch |
| Zero return | Returns 0 for price | `totalStakeUSD = 0`, require fails → bind reverts | Bind blocked (DoS) | YES — reverts safely |
| Stale data | Returns outdated price | Passes/fails threshold incorrectly | Under/over-collateralized bind | UNKNOWN — depends on ChainlinkPriceFeed impl |

---

## Finding [OZ-1]: Oracle Revert in `bindPolicy` Causes Unrecoverable DoS on Policy Binding

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,3d,5b,6 | ✗4(N/A no TWAP) | ✗5a(N/A single oracle)
**Rules Applied**: [R4:✓, R5:✗(single oracle), R6:✗(no role in oracle call), R8:✗(single-step), R10:✓, R16:✓]
**Severity**: Low
**Location**: PolicyManager.sol:L266-274
**Description**: The `bindPolicy()` function calls `IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue()` in a loop (for each token) and once more for the coverage limit. These calls have no try/catch wrapper. If the ChainlinkPriceFeed contract reverts (feed not configured for a token, Chainlink feed down, gas limit exceeded in the loop for many tokens), the entire `bindPolicy()` transaction reverts with an opaque error. Unlike the CoveredVaultWrapper which wraps Morpho calls in try/catch for graceful degradation, the PolicyManager provides no fallback.

```solidity
// PolicyManager.sol L266-274
for (uint256 i = 0; i < tokens.length; ++i) {
    if (tokenStakes[i] > 0) {
        totalStakeUSD += IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(tokens[i], tokenStakes[i]);
    }
}
uint256 coverageLimitUSD =
    IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(request.payoutToken, boundPolicy.coverageLimit);
require(totalStakeUSD >= coverageLimitUSD, InsufficientStake(policyId, coverageLimitUSD, totalStakeUSD));
```

**Impact**: If the ChainlinkPriceFeed is temporarily unavailable (Chainlink feed down, contract paused, or a token lacks a configured feed), no policies can be bound until the oracle recovers. This blocks the CoveredVaultWrapper's `onPolicyBound()` callback, keeping `depositCap = 0` and preventing all deposits. The DoS is temporary (until oracle recovers or admin replaces `chainlinkPriceFeed` address), but there is no fallback path.

**Evidence**: [CODE] — PolicyManager.sol L266-274: no try/catch around external oracle calls.

### Precondition Analysis
**Missing Precondition**: ChainlinkPriceFeed must revert (Chainlink downtime, unconfigured token, contract paused)
**Precondition Type**: EXTERNAL
**Why This Blocks**: The oracle revert is an external condition. Under normal operation, the oracle works. This is a temporary DoS, not a permanent one, and admin can replace the price feed address.

### Postcondition Analysis
**Postconditions Created**: Policy binding blocked; CoveredVaultWrapper stuck in pre-deposit state
**Postcondition Types**: STATE
**Who Benefits**: No direct financial benefit — griefing/DoS only

---

## Sweep 2: EIP-712 Signed Quotes in CoverPool

### Quote Verification Flow

1. `_verifyQuote()` (L307-322) applies `validateQuote` modifier + EIP-712 recovery
2. `validateQuote` modifier (L51-65) checks: pool address, coverageLimit != 0, specId != 0, termsHash != 0, beneficiary != 0, startTime < maturityTime, startTime >= now, expirationTime >= now
3. EIP-712 digest computed via `_hashTypedDataV4(policyCommit)` using OZ's EIP712Upgradeable
4. ECDSA.recover extracts signer, checks `hasRole(QUOTE_SIGNER_ROLE, signer)`

### Replay Protection Analysis

| Check | Status | Notes |
|-------|--------|-------|
| Quote uniqueness via policyCommit | YES | `boundPolicyCommits[policyCommit] = true` (L283-285) prevents reuse |
| PolicyManager also checks | YES | `_registeredPolicyCommits[policyCommit]` (L278) — double protection |
| Chain ID in domain separator | YES | OZ `EIP712Upgradeable.__EIP712_init()` embeds chain ID |
| Contract address in domain separator | YES | OZ `_domainSeparatorV4()` includes `address(this)` |
| Cross-pool replay | PROTECTED | `quote.pool == address(this)` check in validateQuote modifier |
| Testnet→mainnet replay | PROTECTED | Chain ID in domain separator prevents cross-chain replay |

### QUOTE_SIGNER_ROLE Compromise

If `QUOTE_SIGNER_ROLE` is compromised:
- Attacker can sign arbitrary quotes BUT cannot call `bindPolicyForRequest()` (requires `DEFAULT_ADMIN_ROLE` = curator)
- Curator must independently call `bindPolicyForRequest()` with the quote
- Curator can revoke QUOTE_SIGNER_ROLE immediately
- Existing bound quotes cannot be "unbound" — boundPolicyCommits mapping is write-only

**Conclusion**: EIP-712 implementation is sound. No replay vulnerability found.

---

## Sweep 3: Zero-State & First-Depositor (CoveredVaultWrapper)

### First Depositor Protection

1. **Deposits blocked before policy binding**: `maxDeposit()` returns 0 when `!policyBoundExecuted` (L467-469). This prevents any deposits before the vault is configured.

2. **`_decimalsOffset() = 6`**: Provides 10^6 virtual shares (L462-464). This is the standard OpenZeppelin inflation attack mitigation. An attacker would need to donate >10^6x the victim's deposit to profit from rounding.

3. **Frontrunning `onPolicyBound()`**:
   - `onPolicyBound()` is called by PolicyManager at the end of `bindPolicy()` (L305)
   - `bindPolicy()` is called by `CoverPool.bindPolicyForRequest()` which requires `DEFAULT_ADMIN_ROLE` (curator)
   - A deposit in the same tx as `onPolicyBound` is not possible because `onPolicyBound` is an internal callback, not a user-callable function
   - Even if an attacker sees the `bindPolicyForRequest` tx in the mempool and frontruns with a deposit, `maxDeposit()` still returns 0 because `policyBoundExecuted` is false until `onPolicyBound` executes
   - After `onPolicyBound` executes in the same block, an attacker could deposit in a subsequent tx, but `_decimalsOffset() = 6` protects against inflation attacks

[TRACE: deposit before onPolicyBound → maxDeposit()=0 → revert "ERC4626: deposit more than max"]

### Return-to-Zero State Analysis

**Can protocol return to totalSupply = 0?** YES — all users can withdraw/redeem all shares.

**What persists when totalSupply = 0?**

| State Variable | Value at Zero Supply | Risk |
|----------------|---------------------|------|
| `totalPrincipal` | 0 (decremented in _withdraw L189) | Safe |
| `cumulativePremiumPerUnit` | Retains elevated value from premium history | Analyzed below |
| `totalPremiumLiability` | May be > 0 if premium was accrued but not collected | Analyzed below |
| `pendingPremium` | May be > 0 if collectPremium() not called | No user impact (only premiumRecipient) |
| `lastKnownMorphoValue` | Retains stale value | Safe (morphoValue recalculated on next op) |
| `policyBoundExecuted` | true | Deposits still allowed up to depositCap |
| `depositCap` | Unchanged | Safe |

### cumulativePremiumPerUnit After Return-to-Zero

When a new user deposits after all users have withdrawn:

```solidity
// _deposit L130
userPremiumDebt[receiver] += assets.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
```

The new depositor's `userPremiumDebt` is set proportionally to the current `cumulativePremiumPerUnit`. This is correct — the reward-per-token pattern. When they later withdraw:

```solidity
// _calcOwedDebt L622
uint256 raw = principal.mulDiv(cumulative, WAD, Math.Rounding.Floor);
return raw > userDebt ? raw - userDebt : 0;
```

Since `cumulative` and `userDebt` were set at the same point, `raw ≈ userDebt`, so owed premium ≈ 0 for the period before the new deposit. New depositors do NOT inherit past premium.

[TRACE: return-to-zero → new deposit → userPremiumDebt = assets * cumulativePremiumPerUnit / WAD → _calcOwedDebt returns ~0]

### totalPremiumLiability After Return-to-Zero

If premium was accrued but all users withdrew, `totalPremiumLiability` may still be > 0 even though `totalPrincipal = 0`.

In `totalAssets()`:
```solidity
uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
return mv > totalLiability ? mv - totalLiability : 0;
```

If `totalPrincipal = 0`, `_accruedPremiumFor()` returns 0 (short-circuits at L97). But `totalPremiumLiability` could still be > 0, reducing `totalAssets()` for the next depositor.

However, this liability represents collected-but-not-yet-transferred premium (`pendingPremium`). The next depositor's share price is lower than 1:1, but this is correct — the vault's Morpho value has been reduced by the premium already owed. The premium recipient can call `collectPremium()` to transfer the pending amount and reduce the mismatch.

[TRACE: all withdraw → totalPremiumLiability may be > 0 → totalAssets() = morphoValue - liability → next depositor gets shares at reduced rate → BUT premium belongs to premiumRecipient, not depositors → collectPremium() resolves this]

### Re-Entry Vulnerability (Return-to-Zero)

| Scenario | Initial State | Return-to-Zero State | Same Vulnerability? |
|----------|---------------|---------------------|---------------------|
| First depositor / inflation | totalSupply=0, totalAssets=0 | totalSupply=0, totalAssets=morphoResidual-liability | Worse if residual > liability |
| Exchange rate manipulation | No shares | No shares but morpho balance exists | Mitigated by _decimalsOffset()=6 |

The `_decimalsOffset() = 6` virtual shares protection applies to BOTH initial zero and return-to-zero states because it is built into the OZ ERC4626 `_convertToShares` and `_convertToAssets` math. There is no special handling needed.

---

## Sweep 4: Vault Accounting Edge Cases

### `totalAssets()` Going Negative

```solidity
// CoveredVaultWrapper.sol L107-109
uint256 mv = _morphoValue();
uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
return mv > totalLiability ? mv - totalLiability : 0;
```

**Can `mv < totalLiability`?** YES — if Morpho's underlying suffers a catastrophic loss, `_morphoValue()` could drop below `totalPremiumLiability`. The function floors at 0, preventing underflow. Share price becomes 0, but deposits/withdrawals still function (shares are worthless but no revert).

[BOUNDARY: morphoValue=0 → totalAssets()=0 → share price = 0]

### `maxDeposit()` Underflow

```solidity
// CoveredVaultWrapper.sol L467-469
if (!policyBoundExecuted) return 0;
return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;
```

**Can `totalPrincipal > depositCap`?** YES — if `maxCoverableLossBps` is increased via `executeMaxCoverableLossBps()`, `depositCap` is recalculated as `(coverageLimit * BPS_DENOMINATOR) / newBps`. If `newBps > oldBps`, `depositCap` decreases. Existing `totalPrincipal` could exceed the new cap. The ternary `> ? : 0` handles this correctly — no underflow, returns 0 (no more deposits allowed).

[TRACE: setMaxCoverableLossBps(1000→5000) → depositCap halves → totalPrincipal may exceed new cap → maxDeposit()=0 → existing deposits can still withdraw]

### `convertToAssets()/convertToShares()` Precision

Deposits and immediate withdrawals: The `_decimalsOffset() = 6` provides 10^6 virtual shares, making rounding loss at most 1 / 10^6 of the deposit. For normal deposit sizes this is negligible. No precision issue found.

---

## Sweep 5: State at Policy Expiry

### Premium Accrual After Maturity

```solidity
// CoveredVaultAccrual.sol L116-136 (_activeElapsedFrom)
if (_isPolicyActive()) {
    return block.timestamp - checkpoint;
}
if (policyId != 0) {
    IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);
    uint256 effectiveMaturity = uint256(meta.maturityTime) + gateGracePeriod;
    if (meta.buyer != address(0) && effectiveMaturity > checkpoint && block.timestamp >= uint256(meta.startTime)) {
        uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
        if (effectiveMaturity > activeStart) {
            return effectiveMaturity - activeStart;
        }
    }
}
return 0;
```

After maturity (+ grace period), `_isPolicyActive()` returns false, and the second branch catches up accrual to `effectiveMaturity`. On subsequent calls (where `checkpoint >= effectiveMaturity`), the condition `effectiveMaturity > checkpoint` is false, so it returns 0. Premium correctly stops accruing after maturity.

[TRACE: block.timestamp > effectiveMaturity → _isPolicyActive()=false → effectiveMaturity <= checkpoint → return 0 → no phantom premium]

### Deposits After Maturity

`maxDeposit()` checks `policyBoundExecuted` but NOT maturity time. Deposits are still possible after policy expires. However:
- Premium will not accrue (activeElapsed = 0 after maturity settled)
- Insurance is inactive (`_isPolicyActive()` returns false)
- Deposits are allowed but uninsured

This is a design question, not a bug — the vault continues to function as a Morpho wrapper without insurance after maturity. However, depositors may not realize they are uninsured.

### Insurance Claims After Maturity

`_computeInsurance()` checks `_isPolicyActive()` (L328). After maturity (+ grace period), this returns false, and insurance payout is 0. This is correct — no claims after policy expires.

### totalPremiumLiability After Maturity

When premium stops accruing, `totalPremiumLiability` remains at its last value. It is decremented during withdrawals (`_executeWithdrawal` L583). If no users withdraw, the liability remains, reducing `totalAssets()`. This is correct — the liability represents premium owed but not yet collected from user positions.

---

## Finding [OZ-2]: Deposits Accepted After Policy Maturity Without Insurance Coverage

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A no oracle at maturity) | ✗7(N/A)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R13:✓, R16:✗(no oracle)]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:L467-469
**Description**: The `maxDeposit()` function only checks `policyBoundExecuted` and `depositCap - totalPrincipal`, but does not check whether the policy has expired (`block.timestamp >= effectiveMaturity`). After policy maturity, deposits are still accepted up to the deposit cap, but these deposits have no insurance coverage — `_isPolicyActive()` returns false, so `_computeInsurance()` always returns 0.

```solidity
// maxDeposit() — no maturity check
function maxDeposit(address) public view override returns (uint256) {
    if (!policyBoundExecuted) return 0;
    return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;
}
```

**Impact**: Users depositing after policy expiry believe they have insurance coverage (the vault name/UI may suggest coverage) but receive none. Any loss during this period is fully absorbed by the depositor. The financial impact depends on whether users are aware of the maturity date.

R13 analysis:
1. Who is harmed: Depositors after maturity who expect coverage
2. Can they avoid it: YES, if they check policy maturity off-chain
3. Is it documented: The NatSpec says "Deposits are blocked until the policy is bound" but does not mention post-maturity behavior
4. Could protocol achieve same goal without harm: YES — add `_isPolicyActive()` check to `maxDeposit()`

### Postcondition Analysis
**Postconditions Created**: Uninsured deposits exist in the vault after maturity
**Postcondition Types**: STATE, TIMING
**Who Benefits**: No one directly benefits — this is a user-facing informational gap

---

## Finding [OZ-3]: `_morphoValue()` Fallback to Stale `lastKnownMorphoValue` Can Misrepresent Assets During Morpho Downtime

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5 | ✗6(traced fallback path)
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R16:✗(not oracle per se)]
**Depth Evidence**: [TRACE: morphoVault.convertToAssets reverts → lastKnownMorphoValue used → premium accrues on stale value], [VARIATION: morphoValue drops 50% but lastKnownMorphoValue reflects pre-drop → totalAssets() overstated]
**Severity**: Medium
**Location**: CoveredVaultAccrual.sol:L139-147
**Description**: When `IVaultV2(morphoVault).convertToAssets()` reverts, `_morphoValue()` falls back to `lastKnownMorphoValue` — the value cached from the last successful deposit or withdrawal. During prolonged Morpho unavailability (gate activated but `setMorphoGateActive` not called, or Morpho contract bug), this cached value becomes stale.

```solidity
// CoveredVaultAccrual.sol L139-147
function _morphoValue() internal view returns (uint256) {
    try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (uint256 val) {
        return val;
    } catch {
        return lastKnownMorphoValue;
    }
}
```

The stale value affects:
1. **`totalAssets()`** — overstated or understated, affecting share price for any view callers
2. **`_accruePremium()`** — the `_liabilityHeadroom(morphoValue)` cap uses stale value. If real Morpho value has dropped, headroom is overstated, allowing over-accrual of premium
3. **`_accruedPremiumFor(mv)`** — view function returns incorrect premium estimate

Note: The Morpho gate mechanism (`setMorphoGateActive(true)`) is designed to handle this by pausing premium accrual. But the gate must be manually activated by the owner. If the owner does not activate the gate promptly, stale values propagate.

**Impact**:
- If Morpho value dropped and `lastKnownMorphoValue` is higher: premium over-accrues (users pay more than they should); `totalAssets()` is overstated
- If Morpho value increased and `lastKnownMorphoValue` is lower: premium under-accrues; `totalAssets()` is understated

Severity assessed at: prolonged Morpho unavailability (hours to days), value drift of 5-20%

### Precondition Analysis
**Missing Precondition**: Morpho `convertToAssets()` must revert AND owner must not activate Morpho gate promptly
**Precondition Type**: EXTERNAL + ACCESS (owner action required)
**Why This Blocks**: If owner activates gate, premium accrual pauses and stale value issue is mitigated. The window of vulnerability is between Morpho failure and gate activation.

### Postcondition Analysis
**Postconditions Created**: Stale morpho value used for premium accrual and totalAssets calculation
**Postcondition Types**: STATE, TIMING
**Who Benefits**: If morpho value dropped: premiumRecipient benefits (over-accrued premium). If morpho value increased: depositors benefit (under-accrued premium).

---

## Finding [OZ-4]: EfficientHashLib Quote Hash Truncates `basePremium` Field to `uint256` Without Validation

**Verdict**: REFUTED
**Step Execution**: ✓1,2 | ✗3(not applicable),4(N/A)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single fixed state)]
**Severity**: N/A
**Location**: CoverPool.sol:L329-343
**Description**: Investigated whether the `_hashQuote` function using `EfficientHashLib.hash()` with 11 uint256 parameters could produce collisions or truncation. The function passes all 10 quote fields plus the typehash as uint256 values. `EfficientHashLib` has a proper 11-parameter overload that hashes all 11 words (352 bytes) with keccak256.

The `uint256(uint160(quote.pool))` and `uint256(uint160(quote.beneficiary))` casts correctly zero-extend addresses to 32 bytes, matching `abi.encode` behavior. No truncation or collision risk found.

**Evidence**: [CODE] — EfficientHashLib.sol has `hash(uint256 v0, ..., uint256 v10)` overload that hashes 0x160 bytes.

---

## Finding [OZ-5]: `rescueTokens` for Morpho Shares Uses `totalPrincipal > 0` as Proxy for Tracked Shares

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R14:✓]
**Depth Evidence**: [TRACE: totalPrincipal=0 but userMorphoShares has dust → rescueTokens sweeps all morpho shares], [BOUNDARY: totalPrincipal=0, sum(userMorphoShares)>0 due to rounding]
**Severity**: Low
**Location**: CoveredVaultAdmin.sol:L196-213
**Description**: The `rescueTokens` function uses `totalPrincipal > 0` as a proxy to determine if any users have morpho shares, rather than tracking actual morpho shares:

```solidity
// CoveredVaultAdmin.sol L205-209
} else if (token == morphoVault) {
    uint256 balance = IVaultV2(morphoVault).balanceOf(address(this));
    uint256 trackedShares = totalPrincipal > 0 ? balance : 0; // conservative: if users exist, don't sweep
    require(amount <= balance - trackedShares, IA.InvalidParameters());
}
```

If `totalPrincipal == 0` but users still have non-zero `userMorphoShares` (e.g., due to rounding dust where the last withdrawer's `totalPrincipal` decremented to 0 but a tiny amount of morpho shares remains from another user's position), the owner could sweep those shares.

In practice, this scenario is extremely unlikely because:
1. Shares are soulbound — no transfer-induced desync
2. `totalPrincipal` tracks 1:1 with deposits/withdrawals
3. `userMorphoShares` is decremented proportionally during withdrawal

However, a more robust check would sum tracked morpho shares or use a dedicated counter.

**Impact**: Owner (semi-trusted) could sweep dust morpho shares belonging to users when `totalPrincipal = 0`. Financial impact is negligible (dust amounts). Requires owner to act maliciously.

R6: Owner is semi-trusted — this is a direction-1 analysis (how ROLE harms USERS). The timelocks on other parameters do not apply to `rescueTokens`.

### Postcondition Analysis
**Postconditions Created**: Morpho shares belonging to users could be swept by owner
**Postcondition Types**: ACCESS, BALANCE
**Who Benefits**: Owner

---

## Finding [OZ-6]: `_isPolicyActive()` Makes External Call to PolicyManager on Every Deposit/Withdraw

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single fixed state)]
**Severity**: Informational
**Location**: CoveredVaultAccrual.sol:L153-159
**Description**: `_isPolicyActive()` calls `_policyManager.policyMetadata(policyId)` — an external view call — every time it is invoked. This is called from `_activeElapsedFrom()` which is called from `_accruePremium()` and `_accruedPremium()`, which are called on every deposit, withdraw, and view function.

```solidity
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
}
```

Similarly, `_activeElapsedFrom()` makes the same external call again when the policy is expired (the second branch, L121). In `_accruePremium()`, `_isPolicyActive()` is called first, and if it returns false, `_activeElapsedFrom()` may call `policyMetadata()` again — up to 2 external calls per accrual.

**Impact**: Gas inefficiency. The `startTime` and `maturityTime` are immutable once set (they come from the bound policy metadata which cannot be changed). These values could be cached in storage at `onPolicyBound()` time to avoid repeated external calls. This is purely a gas optimization — no security impact.

---

## Zero-State Return Checklist for CoveredVaultWrapper

### Can protocol return to zero state?
- [x] All users can withdraw (no locked funds — except if Morpho gate blocks redemptions)
- [x] All shares can be burned
- [x] Supply can reach exactly zero

### What persists when supply = 0?
- [x] Accrued rewards: None (this is a premium-paying vault, not reward-earning)
- [x] Protocol fees (pendingPremium): May be > 0 — belongs to premiumRecipient, not depositors
- [x] Dust balances: Possible morpho share dust, mitigated by `_decimalsOffset()=6`
- [x] Pending operations: None

### Re-entry vulnerability?
- [x] Initial zero state protected: YES — `maxDeposit()=0` before `onPolicyBound()`
- [x] Return-to-zero state protected: YES — `_decimalsOffset()=6` + userPremiumDebt initialization
- [x] Same protection mechanism: YES (virtual shares + debt offset)

### Exchange rate at return-to-zero:
- Formula: `totalAssets() / (totalSupply + 10^6)` where totalSupply=0
- With residual pendingPremium: totalAssets reduced by totalPremiumLiability → lower share price
- Can attacker inflate rate before re-entry: No — `_decimalsOffset()=6` prevents practical inflation

---

## Chain Summary

| Finding ID | Verdict | Postconditions Created | Postcondition Type | Who Benefits |
|------------|---------|------------------------|--------------------|--------------|
| [OZ-1] | PARTIAL | Policy binding blocked (DoS) | STATE | No one (griefing) |
| [OZ-2] | CONFIRMED | Uninsured deposits after maturity | STATE, TIMING | No one (user harm) |
| [OZ-3] | PARTIAL | Stale morpho value used for accrual | STATE, TIMING | premiumRecipient or depositors (directional) |
| [OZ-4] | REFUTED | N/A | N/A | N/A |
| [OZ-5] | CONFIRMED | Owner can sweep dust morpho shares | ACCESS, BALANCE | Owner |
| [OZ-6] | CONFIRMED | Gas overhead on every operation | N/A | N/A |

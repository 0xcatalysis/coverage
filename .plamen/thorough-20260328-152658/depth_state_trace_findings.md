# Depth State Trace Findings

## DEPTH ANALYSIS: State Trace

---

### Target 1: [RS1-1] gateGracePeriod Extends Insurance Window Past ClaimManager maturityTime

**Source Finding(s)**: RS1-1 (HIGH)
**Breadth Claim**: Vault uses effectiveMaturity (raw + gateGracePeriod) for _isPolicyActive; ClaimManager enforces raw maturityTime; claims in grace window silently fail with 0 payout.

#### State Graph
```
gateGracePeriod
  +-- READ BY: _isPolicyActive() (CoveredVaultAccrual.sol:156), _activeElapsedFrom() (CoveredVaultAccrual.sol:124)
  +-- WRITTEN BY: setMorphoGateActive(false) (CoveredVaultAdmin.sol:181)

_isPolicyActive() result
  +-- READ BY: _computeInsurance() (CoveredVaultWrapper.sol:328), calculateShortfall() (CoveredVaultWrapper.sol:418)

ClaimManager maturityTime enforcement
  +-- ClaimManager.sol:307: block.timestamp <= metadata.maturityTime (raw, NO grace extension)
```

#### Enforcement Points
| Function | Line | Check Present? | Correct Operator? | All Paths? |
|----------|------|----------------|-------------------|------------|
| _isPolicyActive | 156-158 | YES (effectiveMaturity) | `<` correct | Yes |
| ClaimManager._fileClaimWithMetadata | 307 | YES (raw maturityTime) | `<=` correct | Yes |
| _activeElapsedFrom | 124 | YES (effectiveMaturity) | N/A (duration calc) | Yes |

#### Analysis

**Trace to Termination [TRACE:_withdraw() in grace window -> _computeInsurance -> _isPolicyActive() == true -> shortfall > 0 -> _capAndApplyDeductible -> _claimInsurance -> fileClaim() -> ClaimManager L307 reverts "ClaimOutsideCoverageWindow" -> caught by try/catch L365-372 -> return 0]**

The exact mechanism is:

1. Owner activates then deactivates Morpho gate, adding `gateDuration` to `gateGracePeriod` (CoveredVaultAdmin.sol:181).
2. After raw `maturityTime` passes but before `maturityTime + gateGracePeriod`, the vault's `_isPolicyActive()` returns `true` (CoveredVaultAccrual.sol:156-158).
3. During this window, `_accruePremium()` continues accruing premium because `_activeElapsedFrom()` uses `effectiveMaturity` (L124).
4. If a user withdraws with a loss, `_computeInsurance()` proceeds because `_isPolicyActive() == true` (L328).
5. `_claimInsurance()` calls `claimManager.fileClaim()` (L365).
6. ClaimManager._fileClaimWithMetadata at L306-308 enforces `block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime` using **raw** maturityTime from PolicyManager (no grace period).
7. The call **reverts** with `ClaimOutsideCoverageWindow`.
8. The try/catch at L365-372 catches the revert, emits `ClaimManagerUnavailable`, and returns `payout = 0`.
9. User receives `netAssetsReceived` (Morpho proceeds minus premium) but **zero** insurance payout.
10. Premium was still deducted from the user's withdrawal: `pendingPremium += premiumForWithdrawal` (L578).

**[BOUNDARY:gateGracePeriod = 30 days -> user pays premium for 30 extra days with 0 insurance coverage]**

**[VARIATION:gateGracePeriod = 0 (no gate activation) -> _isPolicyActive() correctly returns false after maturityTime -> _computeInsurance returns 0 -> no premium accrual past maturity -> no gap]**

**Devil's Advocate**: What would make this exploitable? The owner is semi-trusted. The gate mechanism is designed for legitimate use (Morpho gate events). However, the owner could activate/deactivate the gate unnecessarily to extend the premium window past policy expiry. Users pay premium during the grace window but cannot collect insurance. This is a direct economic loss to users. A malicious owner could collect premium revenue without any corresponding insurance backing.

**Chain Check**: CS-1 (unbounded gateGracePeriod accumulation) directly enables this - the longer the accumulated grace period, the longer the window of paid-but-uncoverable exposure.

#### Verdict
- [x] CONFIRMED: The breadth finding is correct. There is a fundamental divergence between the vault's `_isPolicyActive()` (which uses effectiveMaturity = raw maturityTime + gateGracePeriod) and ClaimManager's maturity enforcement (which uses raw maturityTime). During the grace window, users pay premium but cannot collect insurance. The mechanism is a silent 0 return via try/catch, not a revert to the user. Evidence: [CODE] CoveredVaultAccrual.sol:156 vs ClaimManager.sol:307.

---

## Finding [DEPTH-ST-1]: gateGracePeriod Creates Premium-Paid / Insurance-Uncollectable Window

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear evidence), R5:check, R6:check, R8:check, R10:check, R12:check, R13:check]
**Depth Evidence**: [TRACE:_withdraw() in grace window -> _computeInsurance -> _isPolicyActive()==true -> fileClaim() reverts ClaimOutsideCoverageWindow -> try/catch returns 0], [BOUNDARY:gateGracePeriod=30d -> 30d premium paid with 0 coverage], [VARIATION:gateGracePeriod=0 -> no gap, confirms divergence is the root cause]
**Severity**: High
**Location**: CoveredVaultAccrual.sol:116-136,150-159; ClaimManager.sol:306-309
**Description**: The vault's `_isPolicyActive()` extends maturityTime by `gateGracePeriod`, but ClaimManager enforces the raw `maturityTime` from PolicyManager metadata. During the grace window (between raw maturityTime and effectiveMaturity), the vault accrues premium and treats users as insured, but `fileClaim()` reverts with `ClaimOutsideCoverageWindow`. The try/catch in `_claimInsurance` silently swallows this revert and returns 0 payout.

**Impact**: Users withdrawing during the grace window pay premium (deducted from withdrawal proceeds) but receive zero insurance payout. For a 30-day gate-induced grace period at 50% APR max premium rate, this is approximately 4.1% of principal paid as premium with no coverage. Users have no on-chain signal that insurance is unavailable during this window - `_isPolicyActive()` returns true.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:153-158 - Vault considers policy active during grace window
function _isPolicyActive() internal view returns (bool) {
    // ...
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
}

// ClaimManager.sol:306-308 - ClaimManager uses raw maturityTime
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
    ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, uint32(block.timestamp))
);
```

### Postcondition Analysis
**Postconditions Created**: Users lose premium payments during grace window without insurance coverage; totalPremiumLiability continues increasing; pendingPremium accumulates forfeited premium
**Postcondition Types**: STATE, BALANCE
**Who Benefits**: Premium recipient (owner/protocol) receives premium for a period where no insurance backing exists

---

### Target 2: [CS-2] totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals

**Source Finding(s)**: CS-2 (MEDIUM), SYNC_GAP 2
**Breadth Claim**: Deep-loss withdrawal where assetsReceived < uncappedPremium leaves phantom delta in totalPremiumLiability that deflates NAV for remaining holders.

#### State Graph
```
totalPremiumLiability
  +-- READ BY: totalAssets() (CoveredVaultWrapper.sol:108), _liabilityHeadroom() (CoveredVaultAccrual.sol:162),
  |            _accruedPremiumFor() -> _liabilityHeadroom (CoveredVaultAccrual.sol:102),
  |            maxWithdraw() (indirect via totalAssets/convertToAssets)
  +-- WRITTEN BY: _accruePremium() L66 (increment), _executeWithdrawal() L583 (decrement)

totalPremiumLiability decrement logic:
  L583: totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal)
  where premiumForWithdrawal = min(uncappedPremium, assetsReceived) [L149]
```

#### Enforcement Points
| Function | Line | Check Present? | Correct Operator? | All Paths? |
|----------|------|----------------|-------------------|------------|
| _accruePremium | 60-61 | YES (headroom cap) | Correct | Yes |
| _executeWithdrawal | 583 | YES (_safeSub) | Floors at 0 | Yes |
| _settleWithdrawalTransfer | 149 | YES (min cap) | Correct | Yes |

#### Analysis

**[TRACE:deep-loss withdrawal -> assetsReceived=50, uncappedPremium=100 -> premiumForWithdrawal=50 -> totalPremiumLiability -= 50 (phantom 50 remains) -> totalAssets() deflated by phantom 50]**

**Concrete example with [BOUNDARY] values:**
- Initial state: totalPrincipal = 1000, totalPremiumLiability = 100, morphoValue = 900 (10% loss)
- User A holds 100% of shares, uncappedPremium = 100
- Morpho returns assetsReceived = 900
- premiumForWithdrawal = min(100, 900) = 100, no phantom here (assetsReceived > uncappedPremium)

Now with severe loss:
- Initial: totalPrincipal = 1000, totalPremiumLiability = 200, morphoValue = 150
- User A has 50% shares, uncappedPremium = 100
- Morpho returns assetsReceived = 75 (pro-rata of 150)
- premiumForWithdrawal = min(100, 75) = 75
- totalPremiumLiability -= 75, now = 125
- Phantom delta = uncappedPremium - premiumForWithdrawal = 25

**[BOUNDARY:morphoValue=0 -> assetsReceived=0 -> premiumForWithdrawal=0 -> totalPremiumLiability not decremented at all -> 100% of user's uncappedPremium becomes phantom]**

After User A withdraws:
- totalPremiumLiability = 125 (should be ~100 for User B's share)
- totalAssets() = max(0, morphoValue - totalPremiumLiability - accruedPremium) = max(0, 75 - 125 - X) = 0
- User B's share price is now 0 even though Morpho holds 75 assets for them

**Impact assessment**: The phantom delta is bounded per withdrawal by `uncappedPremium - assetsReceived`. In the worst case (total loss, morphoValue = 0), the full uncappedPremium becomes phantom. Over multiple deep-loss withdrawals, the phantom accumulates additively.

**Self-correcting mechanism check**: Is there any mechanism that clears phantom liability?
- `_accruePremium()` only increments totalPremiumLiability.
- `_executeWithdrawal()` only decrements by premiumForWithdrawal (actual collected).
- `collectPremium()` does not touch totalPremiumLiability.
- No admin function resets totalPremiumLiability.
- **Conclusion: Phantom is PERMANENT**. It can only be offset if subsequent users' premiumForWithdrawal > their share of phantom (not possible since phantom represents "free" liability with no corresponding user debt).

**Devil's Advocate**: Is the phantom actually protective? The code comment at L579-582 says this prevents inflating totalAssets() by the forgiven amount. The alternative (decrementing by uncappedPremium) would increase totalAssets() above the actual assets backing the vault. So the phantom represents a conservative bias. However, it is OVERCORRECTIVE for remaining users: it deflates their NAV below their true share of Morpho assets. The remaining users' premium debt (computed via cumulativePremiumPerUnit - userPremiumDebt) is NOT phantom-inflated, creating a divergence between per-user accounting and aggregate accounting.

#### Verdict
- [x] CONFIRMED: The phantom totalPremiumLiability after deep-loss withdrawal is real and permanent. It deflates totalAssets() and share price for remaining holders. The semantic invariants Pass 2 Level 3 trace confirms this as persistent state corruption. Bounded by the magnitude of the deep-loss event.

---

## Finding [DEPTH-ST-2]: totalPremiumLiability Phantom Residual Permanently Deflates NAV After Deep-Loss Withdrawals

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R8:check, R10:check, R14:check]
**Depth Evidence**: [TRACE:deep-loss withdrawal -> premiumForWithdrawal=min(uncapped,received) -> phantom=uncapped-received stays in totalPremiumLiability permanently], [BOUNDARY:morphoValue=0 -> 100% phantom retention], [VARIATION:morphoValue=full -> no phantom (assetsReceived >= uncappedPremium)]
**Severity**: Medium
**Location**: CoveredVaultWrapper.sol:573-583, 106-109
**Description**: In deep-loss scenarios where `assetsReceived < uncappedPremium`, `totalPremiumLiability` is decremented only by `premiumForWithdrawal` (the actual premium collected), leaving a phantom delta of `uncappedPremium - premiumForWithdrawal`. This phantom residual permanently inflates `totalPremiumLiability`, deflating `totalAssets()` and share price for all remaining holders. No mechanism exists to clear this phantom.

**Impact**: Remaining depositors experience NAV deflation proportional to the phantom delta. In extreme cases (total Morpho loss), the phantom can drive `totalAssets()` to 0 even when Morpho still holds assets for remaining users, effectively locking them into zero-value shares. New depositors entering post-deep-loss get discounted shares but this does not benefit existing holders.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:149 - Deep-loss guard
premiumForWithdrawal_ = uncappedPremium_ < assetsReceived_ ? uncappedPremium_ : assetsReceived_;
// phantom = uncappedPremium_ - premiumForWithdrawal_ (not tracked, not subtracted from totalPremiumLiability)

// CoveredVaultWrapper.sol:583 - Only actual collected premium is subtracted
totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);

// CoveredVaultWrapper.sol:106-109 - Phantom inflates totalLiability, deflates totalAssets
function totalAssets() public view override returns (uint256) {
    uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
    return mv > totalLiability ? mv - totalLiability : 0;
}
```

### Postcondition Analysis
**Postconditions Created**: Permanent phantom inflation in totalPremiumLiability; deflated totalAssets(); deflated share price for remaining users
**Postcondition Types**: STATE, BALANCE
**Who Benefits**: No one benefits directly. New depositors get discounted entry but this socializes the phantom cost.

---

### Target 3: [CS-1 + PC1-4] Unbounded gateGracePeriod Accumulation

**Source Finding(s)**: CS-1 (MEDIUM)
**Breadth Claim**: Each gate activation adds gateGracePeriod increment; no cap; owner can extend effective maturity indefinitely.

#### State Graph
```
gateGracePeriod
  +-- READ BY: _isPolicyActive() L156, _activeElapsedFrom() L124
  +-- WRITTEN BY: setMorphoGateActive(false) L181 (increment only)
  +-- NEVER RESET: No function decrements or zeroes gateGracePeriod
```

#### Analysis

**[TRACE:setMorphoGateActive(true) at T=100 -> setMorphoGateActive(false) at T=200 -> gateGracePeriod += 100. Repeat N times -> gateGracePeriod += N*100]**

**[BOUNDARY:gateGracePeriod=MAX_UINT256 -> impossible practically but no check prevents arbitrarily large values. Realistic boundary: policy duration = 1 year, owner cycles gate 12 times with 30-day durations each -> gateGracePeriod = 360 days -> effective maturity extended by 360 days]**

Is there any mechanism that caps gateGracePeriod?
- No check in `setMorphoGateActive()` against any maximum.
- No check against remaining policy duration.
- No check against any absolute time limit.
- **The only natural bound is block.timestamp growth and uint256 overflow, which is effectively infinite.**

However: during each gate activation, `morphoGateActive = true` pauses premium accrual (CoveredVaultAccrual.sol:38). So each gate cycle:
1. Pauses premium accrual for the gate duration
2. Extends effectiveMaturity by the gate duration
3. Net premium impact: premium accrues during the grace window extension (post-gate, policy still "active"), compensating for the paused period

The critical issue: combined with DEPTH-ST-1, each additional unit of gateGracePeriod extends the insurance-uncollectable window. The owner can extend the premium-paid/insurance-uncollectable window without any hard limit.

**Can the owner extend past policy HARD EXPIRY?** There is no "hard expiry" concept. The raw `maturityTime` is stored in PolicyManager metadata and never changes. `_isPolicyActive()` in the vault always checks `block.timestamp < maturityTime + gateGracePeriod`. So yes, the owner can extend the vault's perception of an active policy indefinitely past the original maturity time. However, the ClaimManager never extends its window - it always uses raw maturityTime.

#### Verdict
- [x] CONFIRMED: gateGracePeriod accumulation is unbounded. Combined with DEPTH-ST-1, this allows indefinite extension of the premium-paid/insurance-uncollectable window.

---

## Finding [DEPTH-ST-3]: Unbounded gateGracePeriod Accumulation Enables Indefinite Premium-Paid Uncoverable Window

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R6:check, R8:check, R10:check, R14:check]
**Depth Evidence**: [TRACE:12 gate cycles of 30d each -> gateGracePeriod=360d -> 360d premium window past maturity with 0 insurance], [BOUNDARY:no cap on gateGracePeriod, uint256 max is theoretical limit], [VARIATION:0 gate cycles -> gateGracePeriod=0 -> no extension -> no gap]
**Severity**: Medium
**Location**: CoveredVaultAdmin.sol:178-181, CoveredVaultAccrual.sol:124,156-157
**Description**: `gateGracePeriod` is monotonically incremented by each gate activation/deactivation cycle (`gateGracePeriod += gateDuration`) with no upper bound. The owner can extend the vault's effective maturity indefinitely past the raw policy maturityTime. Combined with DEPTH-ST-1, this creates an unbounded window where users pay premium but cannot collect insurance.

**Impact**: A malicious or negligent owner can cycle the Morpho gate to accumulate an arbitrarily large `gateGracePeriod`, extending the premium-collection window indefinitely past the actual insurance coverage window. Users trapped in this extended window pay premium for non-existent coverage.

**Evidence**:
```solidity
// CoveredVaultAdmin.sol:178-181 - No cap check
} else if (!active && morphoGateActive && gateActivatedAt > 0) {
    uint256 gateDuration = block.timestamp - gateActivatedAt;
    gateGracePeriod += gateDuration;  // monotonically increasing, no max check
    gateActivatedAt = 0;
}
```

### Postcondition Analysis
**Postconditions Created**: Arbitrarily large gateGracePeriod; vault believes policy is active long after raw maturity
**Postcondition Types**: STATE, TIMING
**Who Benefits**: Premium recipient (owner/protocol) collects premium for uncovered period

---

### Target 4: [CS-5] deductibleBps/maxCoverableLossBps Retroactive Changes

**Source Finding(s)**: CS-5 (MEDIUM)
**Breadth Claim**: Parameters read at withdrawal time, not at loss-event time; admin can reduce maxCoverableLossBps after known loss to reduce payout.

#### State Graph
```
maxCoverableLossBps
  +-- READ BY: _capAndApplyDeductible() L631, maxDeposit() L469, onPolicyBound() L306,
  |            executeMaxCoverableLossBps() L63
  +-- WRITTEN BY: initialize() L86, executeMaxCoverableLossBps() L65

deductibleBps
  +-- READ BY: _capAndApplyDeductible() L633
  +-- WRITTEN BY: initialize() L87, executeDeductibleBps() L85
```

#### Enforcement Points
| Function | Line | Check Present? | Correct Operator? | All Paths? |
|----------|------|----------------|-------------------|------------|
| setMaxCoverableLossBps | 49 | YES (> 0, <= BPS_DENOMINATOR) | Correct | Yes |
| executeMaxCoverableLossBps | 60 | YES (> deductibleBps) | Correct | Yes |
| setDeductibleBps | 73 | YES (< BPS_DENOMINATOR) | Correct | Yes |
| executeDeductibleBps | 84 | YES (< maxCoverableLossBps) | Correct | Yes |

#### Analysis

**[TRACE:Loss event occurs -> owner proposes setMaxCoverableLossBps(100) (was 1000) -> waits 2 days -> executeMaxCoverableLossBps -> user withdraws -> _capAndApplyDeductible reads new maxCoverableLossBps=100 -> maxInsurance = basis * 100/10000 = 1% instead of 10%]**

**[VARIATION:deductibleBps increased from 100 to 900 -> deductibleAmt grows 9x -> payout reduced by 9x]**

**Timelock analysis**: Both parameters have STANDARD_DELAY = 2 days. This gives users a 2-day window to withdraw at the old parameters. However:
- Users may not be monitoring the blockchain for propose events.
- The 2-day window is shorter than many institutional decision-making cycles.
- If the Morpho gate is also active during this window, users cannot withdraw at all.

**Cross-interaction with gate**: If the owner simultaneously activates the Morpho gate AND proposes parameter changes:
1. Gate activation blocks withdrawals (MorphoRedeemReverted).
2. 2-day timelock elapses during gate period.
3. Owner deactivates gate and executes parameter change in same block.
4. Users can now withdraw but at reduced insurance terms.

**[BOUNDARY:maxCoverableLossBps=1 (minimum) -> maxInsurance = basis * 1/10000 -> near-zero insurance. deductibleBps=maxCoverableLossBps-1 -> deductible nearly equals cap -> near-zero payout]**

**Devil's Advocate**: The owner is semi-trusted with timelocked operations. This is by-design governance capability. However, the retroactive nature (applying to pre-existing losses) is the issue. The timelock provides mitigation but not full protection.

#### Verdict
- [x] CONFIRMED: Parameters are read at withdrawal time, allowing retroactive changes. The 2-day timelock provides partial mitigation but can be combined with gate activation to remove user exit options during the timelock window.

---

## Finding [DEPTH-ST-4]: Retroactive deductibleBps/maxCoverableLossBps Changes Compound with Morpho Gate to Remove User Exit Window

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R6:check, R8:check, R10:check, R13:check, R14:check]
**Depth Evidence**: [TRACE:gate active + propose maxCoverableLossBps(100) -> 2d elapses -> deactivate gate + execute in same block -> users face new terms with no exit window], [BOUNDARY:maxCoverableLossBps=1 -> near-zero insurance], [VARIATION:without gate -> users have 2-day exit window]
**Severity**: Medium
**Location**: CoveredVaultAdmin.sol:57-89, CoveredVaultWrapper.sol:628-635
**Description**: `maxCoverableLossBps` and `deductibleBps` are read at withdrawal time in `_capAndApplyDeductible()`, not at loss-event time. While timelocked with 2-day delay, the owner can activate the Morpho gate to block withdrawals during the timelock period, then execute the parameter change and deactivate the gate in the same transaction, leaving users no exit window at original terms.

**Impact**: Users' insurance coverage can be retroactively reduced after a known loss event, allowing the owner to minimize insurance payouts. The combination with gate activation removes the intended 2-day user exit window.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:630-634 - Parameters read live at withdrawal time
function _capAndApplyDeductible(uint256 shortfall, uint256 basis) private view returns (uint256) {
    uint256 maxInsurance = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR, Math.Rounding.Floor);
    // ... uses current storage value, not loss-event-time value
}
```

### Postcondition Analysis
**Postconditions Created**: Reduced insurance payout for pre-existing losses
**Postcondition Types**: STATE, BALANCE
**Who Benefits**: Protocol/owner (lower insurance payouts to users)

---

### Target 5: [AC-2 + AC-3] Claim Blocking Mechanism Interaction

**Source Finding(s)**: AC-2 (MEDIUM), AC-3 (MEDIUM)
**Breadth Claim**: Two independent claim-blocking mechanisms (premiumDefaulted and claimApprovalRequired) may compound denial-of-insurance risk.

#### State Graph
```
_claimApprovalRequired[policyId] (ClaimManager)
  +-- READ BY: fileClaim() L209 (require(!_claimApprovalRequired[policyId]))
  +-- WRITTEN BY: fileClaim() L235 (set true), approveNextClaim() L183 (set false)

premiumDefaulted (PolicyManager._policies[policyId].premiumDefaulted)
  +-- READ BY: _fileClaimWithMetadata() L297 (require(!metadata.premiumDefaulted))
  +-- WRITTEN BY: setPremiumDefaulted() via CoverPool.sol:147-149 -> PolicyManager.sol:333-338
```

#### Analysis

**Independence check**: These two mechanisms are checked sequentially in `fileClaim()`:
1. L209: `require(!_claimApprovalRequired[policyId], ClaimApprovalRequired(policyId))` - checked first
2. L297 (inside `_fileClaimWithMetadata`): `require(!metadata.premiumDefaulted, PremiumDefaulted(policyId))` - checked second

They are **independently sufficient** to block claims. Either one alone blocks the claim.

**Compounding analysis**: Both blocking mechanisms are set by the CoverPool curator (same actor):
- `setPremiumDefaulted`: Curator calls CoverPool.setPremiumDefaulted() -> PolicyManager.setPremiumDefaulted()
- `approveNextClaim`: Curator calls ClaimManager.approveNextClaim()
- `_claimApprovalRequired` auto-sets to true after each successful claim (L235)

**[TRACE:Scenario - Claim 1 succeeds -> _claimApprovalRequired=true -> Curator never calls approveNextClaim -> All subsequent claims blocked -> Curator also calls setPremiumDefaulted(true) -> Now BOTH gates are locked -> Even if curator approves next claim, premiumDefaulted still blocks]**

The interaction creates a **persistent denial state**: once `premiumDefaulted=true`, even clearing `_claimApprovalRequired` via `approveNextClaim()` does not restore claim ability. The curator must also call `setPremiumDefaulted(false)` to restore claims. Both are curator-controlled.

**CoveredVaultWrapper perspective**: The wrapper wraps `fileClaim()` in try/catch (L365). Both reverts (`ClaimApprovalRequired` and `PremiumDefaulted`) are caught and treated as `ClaimManagerUnavailable`. The user gets 0 insurance payout silently. The wrapper has no mechanism to distinguish between "ClaimManager unavailable" and "curator blocked claims."

**[BOUNDARY:Both flags true simultaneously -> claims blocked by either -> need to clear BOTH to restore -> different curator actions needed for each]**

**Devil's Advocate**: Is this a feature? The approval gate prevents rapid serial claiming. The premiumDefaulted flag prevents claims on defaulted policies. The compounding is expected administrative overhead, not a bug. However, the silent 0-return in the wrapper means users have no way to know why their claim failed or what action is needed to restore it.

#### Verdict
- [x] REFINED: The two mechanisms are independent but both curator-controlled. They compound to create a double-lock that requires two separate curator actions to clear. The real issue is not the interaction but that both blocking states are invisible to the wrapper and silently reduce payout to 0.

---

## Finding [DEPTH-ST-5]: Dual Claim-Blocking Mechanisms Create Silent Double-Lock Requiring Two Curator Actions

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R6:check, R8:check, R10:check, R12:check, R13:check]
**Depth Evidence**: [TRACE:claim1 succeeds -> _claimApprovalRequired=true -> curator sets premiumDefaulted=true -> now both gates locked -> approveNextClaim alone insufficient], [BOUNDARY:both flags true -> requires two distinct curator calls to restore], [TRACE:wrapper try/catch L365-372 -> both reverts caught silently -> user gets 0 payout]
**Severity**: Medium
**Location**: ClaimManager.sol:209,235,179-184,297; CoverPool.sol:147-149
**Description**: Two independent claim-blocking mechanisms (`_claimApprovalRequired` and `premiumDefaulted`) are both controlled by the CoverPool curator. After a successful claim sets `_claimApprovalRequired = true`, the curator must call `approveNextClaim()`. If the curator also sets `premiumDefaulted = true`, both gates must be independently cleared. The CoveredVaultWrapper's try/catch treats both reverts identically as "ClaimManager unavailable," providing no signal to users about the blocking reason or remediation path.

**Impact**: All users withdrawing while both flags are active receive 0 insurance payout. Since premium is still deducted from their withdrawal proceeds, this represents a direct economic loss. The dual-lock requires two distinct curator actions (approveNextClaim + setPremiumDefaulted(false)) that may not be coordinated.

### Postcondition Analysis
**Postconditions Created**: All claims blocked for policyId; premium still collected from users; users receive reduced withdrawal (net of premium, no insurance)
**Postcondition Types**: STATE, ACCESS
**Who Benefits**: Premium recipient continues collecting premium; users bear uninsured losses

---

### Target 6: [PC2-1] Quote startTime Staleness During Policy Binding

**Source Finding(s)**: PC2-1 (MEDIUM)
**Breadth Claim**: validateQuote checks startTime >= block.timestamp at bind time but startTime is set at quote creation; any delay makes quote invalid.

#### Analysis

**[TRACE:Quote signed at T=100 with startTime=100 -> Curator calls bindPolicyForRequest at T=101 -> validateQuote modifier L61: require(quote.startTime >= currentTimestamp) -> require(100 >= 101) -> REVERTS InvalidStartTime]**

This is a CoverPool.sol issue. The `validateQuote` modifier at L51-64 checks:
```solidity
require(quote.startTime >= currentTimestamp, InvalidStartTime(quote.startTime, uint32(currentTimestamp)));
```

If ANY block passes between quote signing and binding, the startTime is stale. The expirationTime field (L63) provides a separate validity window, but startTime itself must be >= block.timestamp.

**Mitigation check**: The quote signer could set `startTime` to a future timestamp to provide a binding window. This is a UX constraint, not a protocol vulnerability. The signer MUST set startTime >= expected bind time.

**[VARIATION:startTime set to block.timestamp+3600 (1 hour buffer) -> binding succeeds within 1 hour window]**

**Devil's Advocate**: This is working as designed - the startTime constraint ensures coverage doesn't start in the past. The signer knows the binding will happen in the future and should account for it. However, if the signer sets startTime = block.timestamp at signing time (reasonable expectation), any latency breaks binding.

#### Verdict
- [x] REFINED: The finding is valid as a UX/operational constraint but not an exploitable vulnerability. The signer must set startTime to a future timestamp to account for binding delay. This is a design choice that prioritizes temporal integrity over convenience.

---

## Finding [DEPTH-ST-6]: Quote startTime Must Exceed Bind-Time Block Timestamp, Creating Operational Constraint

**Verdict**: PARTIAL
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check(single entity), R6:check, R8:check, R10:check]
**Depth Evidence**: [TRACE:quote at T=100 with startTime=100 -> bind at T=101 -> reverts InvalidStartTime], [VARIATION:startTime=T+3600 -> succeeds within window], [BOUNDARY:startTime=block.timestamp at signing -> immediately stale]
**Severity**: Low
**Location**: CoverPool.sol:51-64
**Description**: The `validateQuote` modifier requires `quote.startTime >= block.timestamp` at binding time. Since startTime is set at quote creation, any block delay between signing and binding invalidates the quote if startTime equals the signing block's timestamp. The signer must account for binding latency by setting startTime to a future timestamp.

**Impact**: Operational friction for policy binding. Quotes become invalid quickly if startTime is not set with sufficient buffer. No direct fund loss.

### Precondition Analysis
**Missing Precondition**: Quote signer must set startTime > expected bind-time timestamp
**Precondition Type**: TIMING
**Why This Blocks**: If signer sets startTime correctly, binding succeeds

---

### Target 7: [RS2-1] Revoked Spec Remains Active in ClaimManager

**Source Finding(s)**: RS2-1 (MEDIUM)
**Breadth Claim**: revokeSpec clears _approvedSpecs but not _specs; resolveSpec reads _specs; revoked specs remain callable.

#### State Graph
```
_approvedSpecs[spec] (SpecRegistry)
  +-- READ BY: registerSpec() L118 (require approved for NEW registration)
  +-- WRITTEN BY: approveSpec() L77, revokeSpec() L86

_specs[coverPool][specId] (SpecRegistry)
  +-- READ BY: resolveSpec() L128, registerSpec() L108 (idempotency check)
  +-- WRITTEN BY: registerSpec() L120 (one-time write, immutable after)
```

#### Analysis

**[TRACE:Admin approves spec -> Pool registers spec for specId -> Admin revokes spec via revokeSpec() -> _approvedSpecs[spec]=false -> _specs[pool][specId] still = spec -> ClaimManager calls resolveSpec(pool, specId) -> returns spec -> evaluate() still callable]**

The key insight: `_specs` is intentionally immutable after registration. Once `registerSpec()` writes `_specs[coverPool][specId] = spec`, it can NEVER be changed (L110-115 enforce idempotency: if already registered, require same address).

`revokeSpec()` at L84-88 only clears `_approvedSpecs[spec] = false`. This prevents NEW registrations with this spec address but does NOT affect existing registrations.

`resolveSpec()` at L127-130 reads from `_specs`, NOT from `_approvedSpecs`. So revoked specs remain fully functional for existing policies.

**Is this by design?** The design context (design_context.md) states: "Revocation does not affect in-flight claims (resolveSpec is not gated by approval status)." Trust assumption #14 confirms: "SpecRegistry Admin (FULLY_TRUSTED): Controls which ISpec implementations can be registered. Revocation does not affect in-flight claims."

**[BOUNDARY:Admin revokes spec -> new policies cannot use it -> old policies still use it -> if spec has a bug, revocation does NOT prevent exploitation on existing policies]**

**Devil's Advocate**: If the admin discovers a spec has a vulnerability, revocation does NOT protect existing policies. The admin would need to pause ClaimManager (separate action) or somehow invalidate existing registrations. This is a gap in the defense-in-depth model.

#### Verdict
- [x] REFINED: The finding is correct that revoked specs remain callable for existing policies. However, this is explicitly documented as by-design (trust assumption #14). The real issue is that there is no mechanism to emergency-disable a compromised spec for existing policies other than pausing ClaimManager globally.

---

## Finding [DEPTH-ST-7]: Revoked Spec Remains Callable for Existing Policies - No Granular Emergency Disable

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R6:check(FULLY_TRUSTED admin), R8:check, R10:check, R13:check]
**Depth Evidence**: [TRACE:revokeSpec() clears _approvedSpecs only -> resolveSpec reads _specs -> revoked spec still evaluates claims], [BOUNDARY:compromised spec -> revocation does NOT block exploitation on existing policies], [VARIATION:with approval check in resolveSpec -> would block but break existing policies]
**Severity**: Medium
**Location**: SpecRegistry.sol:84-88, 127-130
**Description**: `revokeSpec()` clears `_approvedSpecs` preventing new registrations, but `resolveSpec()` reads from `_specs` which is immutable after first write. A revoked spec remains fully functional for all existing policies. There is no granular mechanism to emergency-disable a specific spec for existing policies without pausing the entire ClaimManager.

**Impact**: If a spec implementation is discovered to have a vulnerability (e.g., always returning `isPayable: true`), revoking it does not protect existing policies. The admin's only recourse is to pause ClaimManager, which blocks all claims for all policies.

**Evidence**:
```solidity
// SpecRegistry.sol:84-88 - Only clears approval
function revokeSpec(address spec) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(spec != address(0), InvalidSpec());
    _approvedSpecs[spec] = false;  // Does NOT touch _specs mapping
    emit SpecRevoked(spec);
}

// SpecRegistry.sol:127-130 - Reads _specs, not _approvedSpecs
function resolveSpec(address coverPool, bytes32 specId) external view override returns (ISpec spec) {
    spec = _specs[coverPool][specId];  // Revoked spec still here
    require(address(spec) != address(0), SpecNotRegistered(coverPool, specId));
}
```

### Postcondition Analysis
**Postconditions Created**: Revoked spec remains callable; claims evaluated by potentially compromised logic
**Postcondition Types**: ACCESS, STATE
**Who Benefits**: Attacker with access to a compromised spec can still trigger claims on existing policies

---

### Target 8: [PC4-2] poolFeeBps Read Live Enables Retroactive Fee Increase

**Source Finding(s)**: PC4-2 (MEDIUM)
**Breadth Claim**: poolFeeBps read from CoverPool at distribution time, not at accrual time; curator can front-run distribution.

#### State Graph
```
poolFeeBps (CoverPool)
  +-- READ BY: PremiumManager.distributePremium() L154
  +-- WRITTEN BY: CoverPool.setPoolFeeBps() L123-130 (no timelock, capped at 20%)
```

#### Analysis

**[TRACE:Premium accrued at poolFeeBps=500 (5%) over 30 days -> Curator calls setPoolFeeBps(2000) just before distributePremium -> PremiumManager reads poolFeeBps=2000 -> 20% fee applied to entire accrued amount -> restakers receive 80% instead of 95%]**

The `distributePremium()` at PremiumManager.sol:154 reads `poolFeeBps` live:
```solidity
uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();
```

There is no timelock on `setPoolFeeBps()` (CoverPool.sol:123-130). Only an admin role check and a cap at `_MAX_POOL_FEE_BPS = 2000` (20%).

**[BOUNDARY:poolFeeBps increased from 0 to 2000 -> restaker share reduced by 20% retroactively]**

**Mitigation**: `platformFeeBps + poolFeeBps <= _MAX_FEE_BPS (10000)` at PremiumManager.sol:160. So total fees cannot exceed 100%. With platformFeeBps capped at 2500 (25%), the worst case is 45% total fees.

**Devil's Advocate**: The curator is semi-trusted. The 20% cap provides an absolute bound on the fee. The impact is limited to 20% maximum retroactive fee increase.

#### Verdict
- [x] CONFIRMED: poolFeeBps is read live at distribution time with no timelock. The 20% cap bounds the impact but does not prevent retroactive fee increases on already-accrued premium.

---

## Finding [DEPTH-ST-8]: poolFeeBps Live Read at Distribution Enables Retroactive Fee Extraction

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R6:check, R8:check, R10:check, R14:check]
**Depth Evidence**: [TRACE:fee raised 5%->20% before distribution -> 15% retroactive extraction], [BOUNDARY:poolFeeBps max 2000 (20%) -> bounded], [VARIATION:timelock on setPoolFeeBps would prevent this]
**Severity**: Medium
**Location**: PremiumManager.sol:154, CoverPool.sol:123-130
**Description**: `PremiumManager.distributePremium()` reads `poolFeeBps` live from CoverPool at distribution time. Since `setPoolFeeBps()` has no timelock (only capped at 20%), the curator can increase the fee immediately before distribution to retroactively extract up to 20% of all accrued premium that was earned at a lower fee rate.

**Impact**: Up to 20% retroactive fee increase on already-accrued premium. Restakers receive less than expected based on the fee rate that was in effect during the premium accrual period.

### Postcondition Analysis
**Postconditions Created**: Premium distributed at inflated fee rate; restakers under-compensated
**Postcondition Types**: BALANCE
**Who Benefits**: Curator/feeRecipient receives inflated pool fee share

---

### Target 9: [PC1-1] maxWithdraw Double-Deducts Premium

**Source Finding(s)**: PC1-1 (LOW)
**Breadth Claim**: maxWithdraw deducts owedPremium from grossAssets which already excludes it via totalAssets().

#### Analysis

**[TRACE:maxWithdraw() L442-453 flow:**
1. `grossAssets = _convertToAssets(shares, Floor)` - converts shares to assets using totalAssets()
2. `totalAssets() = morphoValue - totalPremiumLiability - accruedPremium` (already excludes premium)
3. `owedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[owner])` - user's share of totalPremiumLiability
4. `totalDeductions = owedPremium + accruedPremium * fraction`
5. `return _safeSub(grossAssets, totalDeductions)` - deducts premium again

**The issue**: `grossAssets` is derived from `totalAssets()` which ALREADY subtracts `totalPremiumLiability` (which includes the user's `owedPremium` as a pro-rata share). Then `totalDeductions` subtracts `owedPremium` AGAIN. This double-counts the user's premium, understating `maxWithdraw()`.

**[BOUNDARY:owedPremium = 100, morphoValue = 1000, totalPremiumLiability = 200 -> totalAssets = 800 -> grossAssets based on 800 -> then subtract 100 again -> effective assets = 700 instead of correct ~800]**

This is a view function only. It does NOT affect actual withdrawal logic (which computes premium independently). The impact is limited to:
- Off-chain integrators using maxWithdraw() to determine withdrawal amounts
- ERC-4626 compliance violation (maxWithdraw should return the correct maximum)

#### Verdict
- [x] CONFIRMED: maxWithdraw() double-deducts premium, systematically understating the maximum withdrawable amount. View-only impact.

---

## Finding [DEPTH-ST-9]: maxWithdraw() Double-Deducts Premium Understating Maximum Withdrawable Assets

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R8:check(single-step view), R10:check, R13:check]
**Depth Evidence**: [TRACE:grossAssets from totalAssets() already excludes premium -> owedPremium subtracted again -> systematic understatement], [BOUNDARY:owedPremium=100 -> understatement = 100], [VARIATION:owedPremium=0 -> no double-deduction -> correct]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:442-453
**Description**: `maxWithdraw()` computes `grossAssets` from `_convertToAssets(shares)` which uses `totalAssets()` (already net of `totalPremiumLiability`). It then subtracts `owedPremium` (the user's share of `totalPremiumLiability`) again as part of `totalDeductions`. This double-counts premium, systematically understating the maximum withdrawable amount.

**Impact**: ERC-4626 maxWithdraw() returns incorrectly low values. Off-chain integrators may under-withdraw. No fund loss (actual withdrawal amounts are correct).

---

### Target 10: [PC1-2] _activeElapsedFrom Pre-Policy Catch-Up Window

**Source Finding(s)**: PC1-2 (LOW)
**Breadth Claim**: Active-policy branch returns block.timestamp - checkpoint without clamping to startTime; phantom pre-policy premium if lastPremiumAccrualTime predates startTime.

#### Analysis

**[TRACE:_activeElapsedFrom(checkpoint) at L116-136:**
```
if (_isPolicyActive()):
    return block.timestamp - checkpoint  // No startTime clamping!
```

If `checkpoint` (lastPremiumAccrualTime) is before `meta.startTime`:
- Active branch returns `block.timestamp - checkpoint` including pre-policy time
- This only matters on the FIRST accrual after policy becomes active

But: `_accruePremium()` is called on every deposit/withdraw/collectPremium. If ANY of these is called between initialization and policy binding, `lastPremiumAccrualTime` advances to `block.timestamp` (L32 of `_accruePremium()`). Since `policyBoundExecuted = false` before binding, `maxDeposit() = 0` and deposits are blocked, but `collectPremium()` can be called (no guard on policyBoundExecuted). Also, the initialize function sets `lastPremiumAccrualTime = block.timestamp` (L98).

**Key question**: Can there be a gap between `lastPremiumAccrualTime` and startTime?

**[TRACE:initialize() at T=100 -> lastPremiumAccrualTime=100 -> policy bound at T=200 with startTime=150 -> no deposit/collectPremium between T=100 and T=200 -> first deposit at T=250 -> _accruePremium called -> _isPolicyActive()=true -> _activeElapsedFrom(100) returns 250-100=150 -> but policy only active since T=150, so should be 100]**

The expired-policy branch (L120-134) DOES clamp to startTime: `activeStart = max(checkpoint, meta.startTime)`. But the active-policy branch (L117-118) does NOT. This creates a 50-second phantom premium window in the example above.

**[BOUNDARY:Gap between initialize and first deposit = 365 days -> phantom premium accrual for 365 days at policy start]**

**Mitigation**: In practice, `lastPremiumAccrualTime` is advanced to `block.timestamp` by ANY call to deposit/withdraw/collectPremium. The vulnerability requires NO interaction with the vault between initialization and the first post-binding action. If the policy is bound quickly after initialization and deposits start promptly, the gap is minimal.

#### Verdict
- [x] CONFIRMED: The active-policy branch of _activeElapsedFrom does not clamp to startTime, allowing phantom premium accrual for the gap between lastPremiumAccrualTime and startTime. The gap magnitude depends on operational timing between initialization and first user interaction.

---

## Finding [DEPTH-ST-10]: _activeElapsedFrom Pre-Policy Catch-Up Phantom Premium Accrual

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check(single entity), R8:check, R10:check]
**Depth Evidence**: [TRACE:checkpoint=T predates startTime -> active branch returns block.timestamp-T including pre-policy gap -> phantom premium], [BOUNDARY:365-day gap -> 365 days phantom accrual at first interaction], [VARIATION:expired branch correctly clamps to startTime -> confirms active branch is missing the clamp]
**Severity**: Low
**Location**: CoveredVaultAccrual.sol:116-136
**Description**: The active-policy branch of `_activeElapsedFrom()` returns `block.timestamp - checkpoint` without clamping the start to `meta.startTime`. If `lastPremiumAccrualTime` predates the policy startTime (possible if no vault interaction occurs between initialization and the first post-binding action), the first accrual includes phantom premium for the pre-policy gap period.

**Impact**: Users charged premium for a period before insurance coverage began. The magnitude depends on the gap between initialization and first interaction. Bounded by `_liabilityHeadroom()` cap.

---

### Target 11: [CS-4] Premium Rate Retroactive Change

**Source Finding(s)**: CS-4 (LOW)
**Breadth Claim**: New premiumRatePerSecond applies to all principal with only 2h notice.

#### Analysis

**[TRACE:executePremiumRate() L34-45:**
1. `_accruePremium()` called first (L37) - settles premium at OLD rate
2. `premiumRatePerSecond = newRate` (L41) - new rate effective immediately
3. All subsequent accruals use new rate on entire totalPrincipal

The 2h OPERATIONAL_DELAY (L28, OPERATIONAL_DELAY constant) is short but rate is capped at `MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991` (~50% APR). The `_accruePremium()` call before the rate change ensures no retroactive application to past time.

**[BOUNDARY:Rate change from 0 to MAX -> immediate jump to 50% APR -> 2h notice]**
**[VARIATION:STANDARD_DELAY (2 days) instead -> would give users reasonable exit window]**

The rate change is NOT retroactive in the time dimension (settled before change), but IS retroactive in the position dimension (applies to all existing positions immediately). Users who deposited at a low rate now face a high rate with minimal notice.

#### Verdict
- [x] CONFIRMED: Premium rate changes apply to all existing positions with only 2-hour notice. While the accrual is properly settled before the change (no time-retroactive application), existing depositors face new terms with minimal exit window.

---

## Finding [DEPTH-ST-11]: Premium Rate Change Applies to All Positions With 2-Hour Notice

**Verdict**: CONFIRMED
**Step Execution**: check1,2,3,4,5
**Rules Applied**: [R4:check(clear), R5:check, R6:check, R8:check, R10:check, R13:check]
**Depth Evidence**: [TRACE:executePremiumRate() settles at old rate first -> new rate applies to all totalPrincipal immediately], [BOUNDARY:0 to MAX_RATE -> 50% APR jump with 2h notice], [VARIATION:longer delay would provide exit window]
**Severity**: Low
**Location**: CoveredVaultAdmin.sol:34-44
**Description**: `executePremiumRate()` properly settles premium at the old rate before applying the new rate, but the OPERATIONAL_DELAY of only 2 hours provides minimal notice to existing depositors. The rate cap at ~50% APR bounds the worst case.

**Impact**: Existing depositors face new premium rate with only 2-hour notice. At maximum rate (~50% APR), this is approximately 0.011% of principal per 2 hours, bounded by the rate cap.

---

### Target 12: Semantic Invariant SYNC_GAP Validation

**Source Finding(s)**: Semantic Invariants Pass 1+2

#### SYNC_GAP 1: totalPrincipal lags userPrincipal during withdrawal
**Verdict**: Already confirmed benign (Informational). The stale window only affects view calls during the transaction. evaluate() does not read totalPrincipal. nonReentrant prevents exploitation.

#### SYNC_GAP 2: totalPremiumLiability phantom after deep-loss
**Verdict**: Covered by DEPTH-ST-2. CONFIRMED as persistent state corruption, Medium severity.

#### SYNC_GAP 3: sum(userMorphoShares) dust drift
**Verdict**: Confirmed benign (Informational). Final-withdrawal cap clears dust per-user. No material impact.

#### SYNC_GAP 4: lastKnownMorphoValue stale after gate deactivation
**Verdict**: Covered by CS-3 (existing finding, Low). Only manifests if Morpho still reverts post-gate-deactivation. Transient once Morpho recovers.

#### SYNC_GAP 5: _claimApprovalRequired silent 0 returns
**Verdict**: Covered by DEPTH-ST-5 (AC-2 + AC-3 interaction). CONFIRMED Medium severity.

#### CLUSTER_GAP: Premium Accrual cluster write completeness
**Analysis**: `_accruePremium()` writes `cumulativePremiumPerUnit` and `totalPremiumLiability` but skips `userPremiumDebt` and `pendingPremium`. This is by design - userPremiumDebt is only updated at deposit/withdrawal checkpoints, and pendingPremium only at withdrawal settlement. No function SHOULD write all 5 simultaneously. No new finding.

---

## Chain Summary

| Finding ID | Dangerous State | Postconditions | Precondition Type |
|---|---|---|---|
| DEPTH-ST-1 | Grace window: premium paid, insurance uncollectable | Users lose premium + 0 insurance; pendingPremium inflated | STATE + TIMING |
| DEPTH-ST-2 | Phantom totalPremiumLiability after deep loss | Permanent NAV deflation for remaining holders; inflated liability | STATE + BALANCE |
| DEPTH-ST-3 | Unbounded gateGracePeriod | Indefinitely extended premium window past maturity | STATE + TIMING |
| DEPTH-ST-4 | Gate + parameter change combo | Users have no exit window at original terms | STATE + TIMING + ACCESS |
| DEPTH-ST-5 | Dual claim-blocking flags both active | All claims blocked, two curator actions needed | STATE + ACCESS |
| DEPTH-ST-6 | Quote startTime stale at bind time | Policy binding fails; operational friction | TIMING |
| DEPTH-ST-7 | Revoked spec still callable | Claims evaluated by potentially compromised logic | ACCESS + STATE |
| DEPTH-ST-8 | poolFeeBps live read at distribution | Retroactive fee extraction up to 20% | BALANCE |
| DEPTH-ST-9 | maxWithdraw double premium deduction | Understated maxWithdraw for integrators | STATE |
| DEPTH-ST-10 | Pre-policy checkpoint gap | Phantom premium for pre-startTime period | STATE + TIMING |
| DEPTH-ST-11 | Premium rate 2h notice period | All positions face new rate with minimal notice | STATE + BALANCE |

## FINDING INDEX
| ID | Severity | Location | Title | Source |
|---|---|---|---|---|
| DEPTH-ST-1 | High | CoveredVaultAccrual.sol:116-159, ClaimManager.sol:306-309 | gateGracePeriod Creates Premium-Paid / Insurance-Uncollectable Window | RS1-1 |
| DEPTH-ST-2 | Medium | CoveredVaultWrapper.sol:573-583, 106-109 | totalPremiumLiability Phantom Residual Permanently Deflates NAV | CS-2, SYNC_GAP 2 |
| DEPTH-ST-3 | Medium | CoveredVaultAdmin.sol:178-181 | Unbounded gateGracePeriod Enables Indefinite Uncoverable Window | CS-1 |
| DEPTH-ST-4 | Medium | CoveredVaultAdmin.sol:57-89, CoveredVaultWrapper.sol:628-635 | Retroactive Parameter Changes Compound with Gate to Remove Exit Window | CS-5 |
| DEPTH-ST-5 | Medium | ClaimManager.sol:209,235,297; CoverPool.sol:147-149 | Dual Claim-Blocking Creates Silent Double-Lock | AC-2, AC-3 |
| DEPTH-ST-6 | Low | CoverPool.sol:51-64 | Quote startTime Operational Constraint | PC2-1 |
| DEPTH-ST-7 | Medium | SpecRegistry.sol:84-88, 127-130 | Revoked Spec Remains Callable | RS2-1 |
| DEPTH-ST-8 | Medium | PremiumManager.sol:154, CoverPool.sol:123-130 | poolFeeBps Live Read Enables Retroactive Fee | PC4-2 |
| DEPTH-ST-9 | Low | CoveredVaultWrapper.sol:442-453 | maxWithdraw Double-Deducts Premium | PC1-1 |
| DEPTH-ST-10 | Low | CoveredVaultAccrual.sol:116-136 | Pre-Policy Catch-Up Phantom Premium | PC1-2 |
| DEPTH-ST-11 | Low | CoveredVaultAdmin.sol:34-44 | Premium Rate 2h Notice Period | CS-4 |

# Depth Input: Edge Case Domain
# Agent: depth-edge-case
# Max 15 findings (prioritized by severity)

## Priority Findings for Edge Case Analysis

### [CS-6] LOW — cumulativePremiumPerUnit Precision Loss at Small totalPrincipal
Location: CoveredVaultAccrual.sol:63-64, CoveredVaultWrapper.sol:622-625
Root cause: mulDiv rounding in reward-per-token accumulator; dust under-collection when totalPrincipal is small
Verdict: PARTIAL | Precondition: very small totalPrincipal
Key question: What is the minimum totalPrincipal before precision loss becomes material? Can first depositor exploit this?

### [OZ-2] LOW — Deposits Accepted After Policy Maturity
Location: CoveredVaultWrapper.sol:467-469
Root cause: maxDeposit only checks policyBoundExecuted, not maturity; users can deposit after policy expires with no insurance
Verdict: CONFIRMED

### [OZ-5] LOW — rescueTokens Uses totalPrincipal>0 as Morpho Share Proxy
Location: CoveredVaultAdmin.sol:196-213
Root cause: rescue guard: if totalPrincipal==0, all tracked shares can be swept; but tracked shares ≠ 0 when totalPrincipal == 0 (dust)
Verdict: CONFIRMED | Evidence: [TRACE][BOUNDARY]
Key question: What exactly happens at the zero-deposit boundary?

### [CS-9] LOW — depositCap Reopens After Withdrawals
Location: CoveredVaultWrapper.sol:467-469
Root cause: depositCap = coverageLimit * 10000 / maxCoverableLossBps; after loss event, users withdraw, cap reopens; new depositors unknowingly enter a loss-event protocol
Verdict: CONFIRMED

### [PC2-3] LOW — bindPolicy Calls onPolicyBound After Setting Bound Status
Location: PolicyManager.sol:L299-L306, CoveredVaultWrapper.sol:L282-L309
Root cause: single-use policyBoundExecuted guard; misconfigured vault hook permanently blocks re-binding
Verdict: CONFIRMED

### [RS3-2] LOW — Same-Block evidenceHash Collision Denies Second Claim
Location: CoveredVaultWrapper.sol:358, ClaimManager.sol:293
Root cause: evidenceHash uses block.timestamp; same-block same-user same-cappedClaim collision → second claim denied
Verdict: PARTIAL | Precondition: same block, same user, same cappedClaim amount

### [CS-3] LOW — Stale lastKnownMorphoValue During Gate
Location: CoveredVaultAccrual.sol:39-47, 139-147
Root cause: lastKnownMorphoValue cached at gate activation; may be stale if Morpho started failing before gate activation
Verdict: PARTIAL

### [OZ-1] LOW — Oracle Revert Causes DoS on Policy Binding
Location: PolicyManager.sol:266-274
Root cause: No try/catch on Chainlink oracle call; oracle failure = full bindPolicy DoS
Verdict: PARTIAL | Precondition: oracle failure OR stale price

### [PC1-2] LOW — _activeElapsedFrom Pre-Policy Window
Location: CoveredVaultAccrual.sol:116-136
Root cause: missing startTime clamp; phantom pre-policy premium accrual
Verdict: CONFIRMED

## ZERO_STATE_RETURN Injectable Questions:
1. What happens when totalPrincipal == 0 and a new depositor arrives? Does cumulativePremiumPerUnit carry forward, creating immediate premium debt?
2. What happens when ALL users withdraw (totalPrincipal → 0) then new users deposit? Is the state clean or corrupted?
3. Does the 6-decimal offset (_decimalsOffset=6) fully prevent share inflation attacks at first deposit?
4. What if depositCap opens to exactly 0 (when coverageLimit=0)? Does deposit revert or accept zero?
5. Is there a state where the vault accepts deposits but immediately cannot redeem (e.g., policy expired + gate active simultaneously)?

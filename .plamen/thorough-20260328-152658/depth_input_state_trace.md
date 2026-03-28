# Depth Input: State Trace Domain
# Agent: depth-state-trace
# Max 15 findings (prioritized by severity)

## Priority Findings for State Trace Analysis

### [RS1-1] HIGH — gateGracePeriod Extends Insurance Window Past ClaimManager maturityTime
Location: CoveredVaultAccrual.sol:116-136, ClaimManager.sol:306-309
Root cause: Vault uses effectiveMaturity (raw + gateGracePeriod) for _isPolicyActive; ClaimManager enforces raw maturityTime; all grace-window claims silently fail (0 payout)
Verdict: CONFIRMED | Evidence: R4,R5,R6,R8,R10,R12,R13 all applied
Key question: Exact code path for "0 payout" in grace window — is it a revert, event, or silent 0?

### [CS-2] MEDIUM — totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals
Location: CoveredVaultWrapper.sol:574-583, 106-109
Root cause: _withdraw decrements totalPremiumLiability by min(uncappedPremium, assetsReceived); deep-loss withdrawal where assetsReceived < uncappedPremium leaves phantom delta; cumulative effect deflates NAV for remaining holders
Verdict: CONFIRMED | Evidence: [BOUNDARY][TRACE]
Key question: How large can this phantom delta become? Is it bounded by any cap?

### [CS-1] MEDIUM — Unbounded gateGracePeriod Accumulation
Location: CoveredVaultAdmin.sol:178-181, CoveredVaultAccrual.sol:124,156-157
Root cause: Each gate activation adds gateGracePeriod increment to storage; no cap; owner can extend effective maturity indefinitely
Verdict: CONFIRMED | Evidence: [TRACE]
Key question: Combined with PC1-4 (setMorphoGateActive multiple activations), can effective maturity be extended past policy expiry?

### [CS-5] MEDIUM — deductibleBps/maxCoverableLossBps Retroactive Changes
Location: CoveredVaultAdmin.sol:57-89, CoveredVaultWrapper.sol:628-635
Root cause: Parameters read at withdrawal time, not at loss-event time; admin can reduce maxCoverableLossBps after a known loss to retroactively reduce payout
Verdict: CONFIRMED | Evidence: [BOUNDARY][VARIATION]
Key question: Is there a timelock on these changes? Can front-running reduce payout?

### [AC-2] MEDIUM — Curator Can Block Claims via setPremiumDefaulted
Location: CoverPool.sol:147-149, ClaimManager.sol:297
Root cause: premiumDefaulted=true → _claimApprovalRequired returns false but claim check uses different path → 0 payout via try/catch
Verdict: CONFIRMED
Key question: Does premiumDefaulted affect ANY pending claims or only new ones?

### [AC-3] MEDIUM — Claim Approval Gate Race Condition
Location: ClaimManager.sol:179-235
Root cause: _claimApprovalRequired set true after each payout; multi-claim policy silently blocked until curator resets; creates race for first-claimer advantage
Verdict: CONFIRMED
Key question: Can a malicious depositor exploit the race to deny other claimants?

### [PC2-1] MEDIUM — Quote startTime Staleness During Policy Binding
Location: CoverPool.sol:L61, PolicyManager.sol:L155-L203
Root cause: validateQuote checks startTime >= block.timestamp at bind time but startTime set at quote creation; any delay makes quote invalid
Verdict: CONFIRMED | Evidence: [BOUNDARY][TRACE][VARIATION]
Key question: Is there any mechanism to extend quote validity or re-quote?

### [RS2-1] MEDIUM — Revoked Spec Remains Active in ClaimManager
Location: SpecRegistry.sol:84-88, 127-130
Root cause: revokeSpec clears _approvedSpecs but not _specs; resolveSpec reads _specs; revoked specs remain callable
Verdict: CONFIRMED
Key question: Can a revoked spec be triggered after revocation to block/manipulate claims?

### [PC4-2] MEDIUM — poolFeeBps Read Live Enables Retroactive Fee Increase
Location: PremiumManager.sol:154, CoverPool.sol:123-130
Root cause: poolFeeBps read from CoverPool at distribution time not at accrual time; curator can front-run distribution
Verdict: CONFIRMED | Evidence: [TRACE][VARIATION][BOUNDARY]

### [CS-4] LOW — Premium Rate Retroactive Change
Location: CoveredVaultAdmin.sol:34-44
Root cause: New premiumRatePerSecond applies to all principal; only 2h operational notice
Verdict: CONFIRMED

### [PC1-1] LOW — maxWithdraw Double-Deducts Premium
Location: CoveredVaultWrapper.sol:442-453
Root cause: maxWithdraw deducts owedPremium from grossAssets which already excludes it via totalAssets()
Verdict: CONFIRMED | Evidence: [BOUNDARY][VARIATION][TRACE]

### [PC1-2] LOW — _activeElapsedFrom Pre-Policy Catch-Up Window
Location: CoveredVaultAccrual.sol:116-136
Root cause: active-policy branch returns block.timestamp-checkpoint without clamping to startTime; phantom pre-policy premium if lastPremiumAccrualTime predates startTime
Verdict: CONFIRMED | Evidence: [BOUNDARY][VARIATION][TRACE]

## Semantic Invariant Focus (from Pass 1+2):
- SYNC_GAP 1: totalPrincipal lags userPrincipal during withdrawal — trace whether CS-2 is the mechanism
- SYNC_GAP 2: totalPremiumLiability phantom after deep-loss — recursive Level 0→3 impact confirmed
- CLUSTER_GAP: Premium Accrual cluster — which functions write cumulativePremiumPerUnit but skip totalPremiumLiability?

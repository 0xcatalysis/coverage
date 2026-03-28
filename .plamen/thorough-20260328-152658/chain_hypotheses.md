# Chain Hypotheses

## Chain Summary Table

| Chain ID | Finding A (Blocked/Partial) | Missing Precondition | Finding B (Enabler) | Postcondition Match | Chain Severity |
|----------|---------------------------|---------------------|---------------------|---------------------|----------------|
| CH-1 | H-3 (phantom liability) | Deep-loss event causing withdrawal under-recovery | H-8 (retroactive deductible/maxLoss) | Reduced maxCoverableLossBps deepens effective loss | Medium (compounding) |
| CH-2 | H-7 (amountOutMin=1 sandwich) | QuoterV2 revert causing quoteSwap=0 | H-5 (fee-tier desync) | Fee desync causes quote to revert or return inaccurate value, triggering fallback | High |
| CH-3 | H-1 (grace window uninsured) | Accumulated gateGracePeriod extending maturity | H-2 (unbounded gateGracePeriod) | Each gate toggle adds more uninsured window, compounding premium loss | High |
| CH-4 | H-3 (phantom liability) | Deep-loss withdrawal creating phantom residual | H-1 (grace window uninsured) | Loss event during grace window (where premium accrues but claims fail) guarantees deep-loss withdrawals that create phantom | High |
| CH-5 | H-15 (previewRedeem overstates) | Per-user premium not in preview | H-3 (phantom liability) | Phantom residual inflates totalPremiumLiability, further widening gap between preview and actual | Medium (compounding) |
| CH-6 | H-9 (curator blocks claims) | Curator sets premiumDefaulted=true | H-13 (retroactive poolFeeBps) | Curator blocks claims AND extracts retroactive fees in same transaction sequence | High |
| CH-7 | H-4 (excess swap stranded) | Favorable swap output exceeds remainingPayout | H-7 (amountOutMin=1 sandwich) | When amountOutMin=1, swap execution produces unpredictable output; if output > remaining, surplus stranded. However if sandwich succeeds, output is LESS. Orthogonal interaction. | Medium (weak) |

## Detailed Chain Hypotheses

---

## Chain Hypothesis CH-1
### Blocked Finding (A)
- **ID**: H-3, **Title**: totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals
- **Original Verdict**: CONFIRMED, **Missing Precondition**: Requires deep-loss event where assetsReceived < uncappedPremium, **Type**: STATE, BALANCE

### Enabler Finding (B)
- **ID**: H-8, **Title**: Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout
- **Original Verdict**: CONFIRMED, **Postcondition Created**: Owner reduces maxCoverableLossBps after loss event, reducing insurance payout, which means users receive even less assetsReceived relative to their uncappedPremium, deepening the loss gap, **Type**: STATE, BALANCE

### Chain Match
- **Match Strength**: MODERATE
- **Match Reasoning**: H-8 deepens the effective loss experienced by users. When owner reduces maxCoverableLossBps after a loss event, the insurance payout covers less of the loss. Users withdrawing receive fewer assets. This widens the gap between uncappedPremium and premiumForWithdrawal in H-3's phantom calculation, creating a LARGER phantom residual. The two bugs compound: retroactive param change (H-8) amplifies phantom liability (H-3).

### Combined Attack Sequence
1. [H-8]: Morpho loss event occurs. Owner changes maxCoverableLossBps from 50% to 25% before users withdraw.
2. [H-3]: Users withdraw during deep-loss. Insurance payout is calculated with reduced maxCoverableLossBps (25% instead of 50%), so assetsReceived is even lower.
3. totalPremiumLiability decremented by small premiumForWithdrawal; larger uncappedPremium delta remains as phantom.
4. **Impact**: Phantom residual is amplified because the retroactive param change made the loss deeper. Remaining holders face compounded NAV deflation.

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| Medium | Medium | Medium (compounding -- same tier but amplified impact) |

No severity upgrade because both are already Medium and the chain amplifies magnitude, not category. However the chain makes the combined dollar impact larger than either alone.

---

## Chain Hypothesis CH-2
### Blocked Finding (A)
- **ID**: H-7, **Title**: amountOutMin Falls to 1 When QuoterV2 Reverts, Enabling Near-Total Sandwich
- **Original Verdict**: CONFIRMED, **Missing Precondition**: QuoterV2 must revert for quoteSwap to return 0, **Type**: EXTERNAL

### Enabler Finding (B)
- **ID**: H-5, **Title**: UniswapV3Adapter Fee-Tier Desync Between Quote and Swap
- **Original Verdict**: CONFIRMED, **Postcondition Created**: Fee-tier desync causes quote() to use wrong fee tier. If the new fee tier pool has no liquidity for the quote path, the quote call reverts. The try/catch in quoteSwap catches this revert and returns 0., **Type**: EXTERNAL, STATE

### Chain Match
- **Match Strength**: STRONG
- **Match Reasoning**: H-5's fee-tier desync directly creates the precondition for H-7. When admin calls setPairFee to update the fee tier, quote() reads the new pairFees but swap() uses the old stored calldata fee. If the new fee tier pool has insufficient liquidity for the quoted token pair, quoteSwap's try/catch catches the revert and returns 0. This directly triggers H-7's amountOutMin=1 path, enabling near-total sandwich extraction. The desync is admin-triggered (semi-trusted) but the sandwich is executed by external MEV bots.

### Combined Attack Sequence
1. [H-5]: Admin calls setPairFee(tokenA, tokenB, newFee) to migrate to a different fee tier. Route calldata retains old fee.
2. quoteSwap calls quote() which uses newFee. If the newFee pool lacks liquidity, quote reverts.
3. [H-7]: quoteSwap's try/catch returns 0. amountOutMin set to max(0, 1) = 1.
4. MEV bot detects the swap with amountOutMin=1 and sandwiches it.
5. **Impact**: Claim payout reduced to ~1 wei. Claimant loses near-entire insurance payout.

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| Medium | High | High |

Chain severity = max(Medium, High) = High. The chain makes H-7's "QuoterV2 must fail" precondition much more likely because H-5 creates a deterministic path to quote failure (admin setPairFee without route update). This is an admin-triggered chain with MEV extraction endpoint. Impact > $10k likely for any meaningful claim, profitability > 2x for MEV bot.

---

## Chain Hypothesis CH-3
### Blocked Finding (A)
- **ID**: H-1, **Title**: gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues
- **Original Verdict**: CONFIRMED, **Missing Precondition**: Requires accumulated gateGracePeriod to extend past raw maturityTime, **Type**: STATE, TIMING

### Enabler Finding (B)
- **ID**: H-2, **Title**: Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles
- **Original Verdict**: CONFIRMED, **Postcondition Created**: Each gate toggle cycle adds maturityTime - block.timestamp to gateGracePeriod with no cap. Multiple cycles create arbitrarily long grace extensions., **Type**: STATE, TIMING

### Chain Match
- **Match Strength**: STRONG
- **Match Reasoning**: H-2 directly amplifies H-1. Without H-2, H-1 requires a single gate activation near maturity to create a meaningful grace window. With H-2, multiple legitimate gate activations (even early in the policy lifecycle) accumulate, creating an arbitrarily long grace window. This transforms H-1 from "users lose premium during one grace window" to "users can lose premium for an arbitrarily long post-maturity period."

### Combined Attack Sequence
1. [H-2]: Owner activates morphoGate 3 times during policy lifetime (legitimate Morpho issues). Each activation adds remaining maturity to gateGracePeriod. After 3 cycles early in policy: gateGracePeriod may exceed policy duration.
2. [H-1]: effectiveMaturity = maturityTime + gateGracePeriod extends far past raw maturityTime. Users continue accruing premium for the full extended period.
3. ClaimManager enforces raw maturityTime. Any loss event after raw maturityTime but before effectiveMaturity results in claims being rejected while premium was being collected.
4. **Impact**: Users lose arbitrarily large premium amounts (proportional to accumulated gateGracePeriod) with zero insurance coverage.

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| High | Medium | High |

Chain severity remains High (already highest constituent). The chain increases MAGNITUDE of H-1 by making the uninsured window unbounded rather than bounded by a single gate cycle. This elevates the dollar impact significantly.

---

## Chain Hypothesis CH-4
### Blocked Finding (A)
- **ID**: H-3, **Title**: totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals
- **Original Verdict**: CONFIRMED, **Missing Precondition**: Requires deep-loss event during active policy, **Type**: STATE

### Enabler Finding (B)
- **ID**: H-1, **Title**: gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues
- **Original Verdict**: CONFIRMED, **Postcondition Created**: During grace window, premium accrues but claims fail. If a Morpho loss occurs during this window, users cannot claim insurance but MUST withdraw with the full premium debt. This guarantees deep-loss withdrawals (assetsReceived < uncappedPremium) because there is no insurance payout to offset the loss., **Type**: STATE, BALANCE

### Chain Match
- **Match Strength**: STRONG
- **Match Reasoning**: H-1's uninsured grace window guarantees H-3's precondition. During normal insured operation, a Morpho loss triggers insurance payouts that offset losses, so assetsReceived may still cover uncappedPremium. But during the grace window (H-1), insurance claims fail. Users withdrawing after a grace-window loss event receive reduced assetsReceived (no insurance offset) while owing full uncappedPremium. This creates the maximum phantom residual in totalPremiumLiability. The two findings create a compounding loop: premium accrues without coverage (H-1) and phantom residual deflates NAV (H-3).

### Combined Attack Sequence
1. [H-1 + H-2]: gateGracePeriod accumulates, creating extended uninsured window past raw maturityTime.
2. Morpho vault suffers loss during the grace window.
3. Users attempt to file claims -- ClaimManager rejects (raw maturityTime enforced).
4. [H-3]: Users withdraw without insurance offset. assetsReceived is severely reduced. totalPremiumLiability decremented by tiny premiumForWithdrawal. Phantom residual = uncappedPremium - premiumForWithdrawal remains permanently.
5. **Impact**: Remaining holders face permanent NAV deflation from phantom residual, ON TOP of the actual Morpho loss, ON TOP of paying premium for zero coverage.

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| Medium | High | High |

Chain severity upgraded from H-3's Medium to High. The chain combines three impacts: (1) premium paid without coverage, (2) no insurance payout on loss, (3) permanent phantom NAV deflation for remaining holders. Combined impact exceeds either finding alone.

---

## Chain Hypothesis CH-5
### Blocked Finding (A)
- **ID**: H-15, **Title**: previewRedeem/previewWithdraw Overstates Proceeds (ERC-4626 Spec Violation)
- **Original Verdict**: CONFIRMED, **Missing Precondition**: The overstatement magnitude depends on per-user premium debt, **Type**: STATE

### Enabler Finding (B)
- **ID**: H-3, **Title**: totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals
- **Original Verdict**: CONFIRMED, **Postcondition Created**: Phantom residual permanently depresses totalAssets(), which is used in share-to-asset conversion. This means previewRedeem overstates EVEN MORE because the actual totalAssets is lower than what preview calculates (preview does not account for phantom inflation in totalPremiumLiability)., **Type**: STATE

### Chain Match
- **Match Strength**: MODERATE
- **Match Reasoning**: H-3's phantom residual inflates totalPremiumLiability beyond what is economically justified. Since totalAssets = morphoValue - totalPremiumLiability - accrued, the phantom deflates totalAssets. previewRedeem (H-15) already overstates by not deducting per-user premium. With H-3, the gap between previewed and actual proceeds widens further because the share price used in preview is based on a totalAssets that includes the phantom deflation's effects. However, the primary overstatement in H-15 is the per-user premium omission, not the phantom. The phantom amplifies but is not the primary driver.

### Combined Attack Sequence
1. [H-3]: Deep-loss withdrawal creates phantom residual in totalPremiumLiability.
2. totalAssets() permanently depressed for remaining holders.
3. [H-15]: Integrator calls previewRedeem. Gets value based on share price but without per-user premium deduction.
4. Integrator executes redeem. Receives less than preview indicated due to both premium deduction AND phantom-deflated totalAssets.
5. **Impact**: ERC-4626 integrators see a wider-than-expected shortfall. Could cause downstream protocol failures (e.g., insufficient collateral for a lending protocol using the vault shares).

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| Medium | Medium | Medium (compounding) |

No severity upgrade -- both are Medium and the chain amplifies magnitude rather than changing impact category.

---

## Chain Hypothesis CH-6
### Blocked Finding (A)
- **ID**: H-9, **Title**: Curator Can Permanently Block Claims via setPremiumDefaulted
- **Original Verdict**: CONFIRMED, **Missing Precondition**: Curator must choose to act against depositor interest, **Type**: ACCESS

### Enabler Finding (B)
- **ID**: H-13, **Title**: poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction
- **Original Verdict**: CONFIRMED, **Postcondition Created**: Curator can extract retroactive fees from accumulated premium by spiking poolFeeBps before distribution, **Type**: ACCESS, BALANCE

### Chain Match
- **Match Strength**: MODERATE
- **Match Reasoning**: Both findings involve curator acting against depositor interest. The chain is: curator blocks claims (H-9) to protect their staking position, THEN retroactively extracts premium fees (H-13) from the accumulated premium pool. The curator profits twice: (1) by preventing insurance payouts that would reduce their staked collateral, and (2) by extracting higher fees from the premium that was collected during the now-uninsured period. The missing precondition for both is "curator acts maliciously" -- the same actor controls both paths, making the combined attack a single curator action sequence.

### Combined Attack Sequence
1. [H-9]: Loss event occurs. Curator calls setPremiumDefaulted(true), blocking all claims. Insurance payouts = 0.
2. Premium continues accruing (premium rate unchanged, policy still "active" from vault perspective).
3. [H-13]: Curator calls setPoolFeeBps to maximum allowed, then calls distributeBatch.
4. **Impact**: Depositors pay premium with zero coverage AND curator extracts inflated fees. Curator profits from: (a) protected staking collateral, (b) inflated pool fees on accumulated premium.

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| Medium | Medium | High |

Severity upgraded to High. Combined impact: depositors lose insurance coverage AND overpay fees. The same actor (curator) controls both steps, making the attack sequence highly likely once the curator decides to act maliciously. Combined impact > $10k on any meaningful pool.

---

## Chain Hypothesis CH-7
### Blocked Finding (A)
- **ID**: H-4, **Title**: Excess Swap Output Permanently Stranded in ClaimManager
- **Original Verdict**: CONFIRMED, **Missing Precondition**: Swap must produce output exceeding remainingPayout, **Type**: STATE

### Enabler Finding (B)
- **ID**: H-7, **Title**: amountOutMin Falls to 1 When QuoterV2 Reverts
- **Original Verdict**: CONFIRMED, **Postcondition Created**: amountOutMin=1 allows swap to execute at any output level, **Type**: EXTERNAL, BALANCE

### Chain Match
- **Match Strength**: WEAK
- **Match Reasoning**: These findings are ORTHOGONAL rather than chaining. H-7 enables sandwich attacks that REDUCE swap output (MEV extraction). H-4 requires swap output to EXCEED remainingPayout. If H-7's sandwich succeeds, swap output is minimized, making H-4's excess surplus impossible. If H-7's sandwich fails or is incomplete, the swap may produce excess -- but then H-7 is not the enabler. The two are opposing forces on the same swap output variable.

### Combined Attack Sequence
1. Not a true chain -- orthogonal interaction. H-7 and H-4 cannot both manifest on the same swap execution. Either MEV extracts value (H-7 active, H-4 irrelevant) or swap produces excess (H-4 active, H-7 not triggered).

### Severity Reassessment
| Original A | Original B | Chain Severity |
|------------|------------|----------------|
| High | Medium | N/A (not a true chain) |

No severity change. These findings remain independent.

---

## Additional Investigated Pairs (No Chain Found)

### H-8 (retroactive deductible) + H-1 (maturity mismatch)
**Investigation**: H-8 requires owner to change params during active loss. H-1 involves grace window where claims fail. If owner changes deductibleBps AND loss occurs during grace window, users get reduced payout (H-8) AND claims are rejected (H-1). But these are not chaining -- H-1 blocks claims entirely, making H-8's payout reduction irrelevant. H-1 supersedes H-8 during the grace window.
**Result**: H-1 is a strict superset of H-8's impact during grace window. No chain -- H-1 already covers the worse outcome.

### BLIND-C-1 (renounceOwnership) + H-5 (fee tier desync)
**Investigation**: If UniswapV3Adapter owner renounces ownership, setPairFee becomes permanently uncallable. This means fee tier can NEVER be updated, which means the desync described in H-5 can NEVER be triggered (setPairFee creates the desync). renounceOwnership actually PREVENTS H-5 from manifesting, not enables it. However, it also means routes can never be updated, causing permanent stale routes.
**Result**: Opposing interaction. renounceOwnership prevents H-5 but creates permanent route staleness (already covered by H-32 and H-50).

### BLIND-C-2 (PREMIUM_COLLECTOR_ROLE never granted) + H-3 (phantom liability)
**Investigation**: If PREMIUM_COLLECTOR_ROLE is never granted to PremiumCollector, premium distribution cannot execute. Premium accumulates in PremiumManager but is never distributed. This does NOT affect totalPremiumLiability (which is tracked in CoveredVaultWrapper, not PremiumManager). The phantom residual in H-3 occurs in the CoveredVaultWrapper's accounting, independent of premium distribution.
**Result**: No chain -- H-18 (PREMIUM_COLLECTOR_ROLE) affects premium distribution, not phantom liability accounting.

### RS2-1/H-12 (revoked spec) + AC-2/H-9 (curator blocks claims)
**Investigation**: Both involve claim denial through different mechanisms. H-12 allows spec manipulation to reject claims via spec logic. H-9 blocks claims via setPremiumDefaulted returning 0 payout. These are parallel attack vectors on the same target (claim denial), not a chain. Same actor class (curator/spec-admin) controls both. They do not enable each other -- either alone suffices to deny claims.
**Result**: Parallel vectors, not a chain. Both already covered as independent findings.

### H-39 (post-expiry catch-up) + H-1 (grace window)
**Investigation**: H-39 charges premium past maturity when no interaction occurs between maturity and first post-maturity interaction. H-1 extends effective maturity via gateGracePeriod. With H-1, the effective maturity is later, so the "no interaction" window between effective maturity and first interaction is shorter. H-1 actually REDUCES H-39's impact because _isPolicyActive returns true longer (less post-maturity inactive accrual). However, users pay premium during H-1's grace window AND H-39's catch-up. The compound is: premium accrues both during uninsured grace (H-1) and post-effective-maturity catch-up (H-39).
**Result**: Partial compounding. Both charge premium during uninsured periods. However H-39's accrual window starts AFTER H-1's window ends (they are sequential, not overlapping). The total premium overcharge is additive but through different mechanisms. Not a true chain -- independent findings with cumulative impact.

---

## Findings Status Update

| Finding | Original Severity | Chain Upgrade? | New Severity | Reason |
|---------|-------------------|----------------|-------------|--------|
| H-3 | Medium | CH-1 (compounding with H-8) | Medium | Amplified magnitude but not category change |
| H-3 | Medium | CH-4 (enabled by H-1) | **High** | Grace window guarantees deep-loss + no insurance = maximum phantom |
| H-7 | Medium | CH-2 (enabled by H-5) | **High** | Fee desync creates deterministic path to quote failure, enabling sandwich |
| H-1 | High | CH-3 (amplified by H-2) | High | Already High; magnitude amplified by unbounded accumulation |
| H-15 | Medium | CH-5 (compounding with H-3) | Medium | Amplified magnitude only |
| H-9 | Medium | CH-6 (combined with H-13) | **High** | Curator combines claim denial + retroactive fee extraction |
| H-4 | High | CH-7 (orthogonal to H-7) | High | No chain; remains independent |

**Net upgrades: 3 findings upgraded (H-3 Medium->High via CH-4, H-7 Medium->High via CH-2, H-9 Medium->High via CH-6)**

---

## Verification Priority Order

1. **CH-2** (H-5 fee desync -> H-7 sandwich) -- STRONG match, deterministic chain, High severity, direct fund loss path. Verify: does setPairFee desync actually cause quote revert? Trace quoteSwap try/catch to amountOutMin=1.
2. **CH-4** (H-1 grace window -> H-3 phantom) -- STRONG match, High severity, compounding permanent NAV damage. Verify: trace withdrawal during grace-window loss event through _settleWithdrawalTransfer.
3. **CH-6** (H-9 claim block + H-13 retroactive fees) -- MODERATE match, High severity (upgraded), curator dual-profit path. Verify: can curator execute setPremiumDefaulted + setPoolFeeBps + distributeBatch in single tx sequence?
4. **CH-3** (H-2 unbounded accumulation -> H-1 uninsured window) -- STRONG match, High severity (existing), magnitude amplifier. Verify: trace multiple setMorphoGateActive cycles and gateGracePeriod growth.
5. **CH-1** (H-8 retroactive params -> H-3 phantom amplification) -- MODERATE match, Medium severity, compounding. Verify: trace withdrawal with changed params through phantom calculation.
6. **CH-5** (H-3 phantom -> H-15 preview overstatement) -- MODERATE match, Medium severity, ERC-4626 integration risk. Verify: compare previewRedeem output before and after phantom residual accumulation.
7. **CH-7** (H-4 excess stranded vs H-7 sandwich) -- WEAK match, orthogonal. No verification needed -- opposing forces.

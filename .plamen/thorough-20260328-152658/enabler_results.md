# Enabler Enumeration Results

## PHASE 0: Enabler Enumeration (Rule 12)

### STEP 0a: Dangerous States Extracted

| # | Finding ID | Dangerous State S | Current Known Path(s) to S | Actor Category |
|---|-----------|-------------------|---------------------------|----------------|
| 1 | RS1-1 | Grace window: premium accrues but ClaimManager rejects claims (maturity mismatch) | Owner activates morphoGateActive multiple times → gateGracePeriod accumulates → effectiveMaturity > raw maturityTime | Semi-trusted role (owner gate toggle) |
| 2 | CS-2 / SGI-1 | totalPremiumLiability phantom residual (permanent NAV deflation) | Deep-loss event → user withdrawal → premiumForWithdrawal < uncappedPremium → delta stuck | Natural operation (loss event + withdrawal) |
| 3 | PC3-1 | Excess swap output stranded in ClaimManager | Collateral swap yields more than remainingPayout → surplus locked | Natural operation (favorable swap) |
| 4 | PC3-2 / DEPTH-EX-4 | Fee-tier desync between quote and swap in UniswapV3Adapter | Admin calls setPairFee after route configured → pairFees updated but stored calldata frozen | Semi-trusted role (admin setPairFee) |
| 5 | PC4-1 | Stale unlimited approval on old RewardsManager | Admin calls setRewardsManager → old address retains unlimited allowance | Semi-trusted role (admin setRewardsManager) |
| 6 | TF-4 / DEX-1 | amountOutMin=1 when QuoterV2 reverts → near-total sandwich | QuoterV2 call reverts → quoteSwap returns 0 → amountOutMin = max(0,1) = 1 | External event (QuoterV2 failure) + External attacker (MEV) |
| 7 | AC-2 | Curator blocks all claims via setPremiumDefaulted | Curator calls setPremiumDefaulted(true) → ClaimManager returns 0 payout | Semi-trusted role (curator) |
| 8 | AC-3 / SGI-6 | Claim approval gate blocks concurrent claimants | _claimApprovalRequired set true after first payout → subsequent claims blocked until curator approves | Natural operation (multiple users claim) |
| 9 | CS-5 | Retroactive deductibleBps/maxCoverableLossBps change reduces insurance payout | Owner changes params during active loss → withdrawal reads new params → reduced payout | Semi-trusted role (owner param change) |
| 10 | RS2-1 | Revoked spec still callable by ClaimManager | Curator/admin revokes spec → _approvedSpecs cleared but _specs untouched → resolveSpec still returns spec | Semi-trusted role (spec admin revokeSpec) |

### STEP 0b: 5-Actor-Category Tables (Top 10 Dangerous States)

#### S1: Grace window uninsured premium (RS1-1, PC1-4, CS-1, SGI-2)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — setMorphoGateActive is onlyOwner | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | Owner calls setMorphoGateActive(true) multiple times during legitimate Morpho issues → gateGracePeriod accumulates | YES | RS1-1, PC1-4, CS-1 | N/A |
| 3 | Natural operation (normal protocol flow) | No path — gate must be explicitly activated by owner | NO | N/A | N/A |
| 4 | External event (Morpho incident) | Morpho downtime → owner activates gate legitimately → grace period accumulates across multiple incidents | YES | RS1-1 (covers this) | N/A |
| 5 | User action sequence | No path — users cannot trigger gate | NO | N/A | N/A |

#### S2: totalPremiumLiability phantom residual (CS-2, SGI-1, VA-6, DEPTH-EC-2)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — requires deep-loss event first | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | No direct path — phantom results from accounting design, not role action | NO | N/A | N/A |
| 3 | Natural operation (normal protocol flow) | Morpho loss event → users withdraw → phantom residual accumulates per withdrawal | YES | CS-2, SGI-1 | N/A |
| 4 | External event (Morpho exploit) | Morpho vault exploited → deep loss → withdrawals create phantom | YES | CS-2 (covers this) | N/A |
| 5 | User action sequence | Users withdraw during/after deep loss | YES | CS-2 (covers this) | N/A |

#### S3: Excess swap output stranded (PC3-1, RS2-3, DEX-4)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — cannot trigger claim process | NO | N/A | N/A |
| 2 | Semi-trusted role | No direct role path — outcome of swap math | NO | N/A | N/A |
| 3 | Natural operation | Collateral swap produces favorable output > remainingPayout → surplus locked | YES | PC3-1 | N/A |
| 4 | External event (price movement) | Token price movement between slashing preview and swap execution → favorable swap | YES | PC3-1 (covers) | N/A |
| 5 | User action sequence | User files claim → slashing → swap produces surplus | YES | PC3-1 (covers) | N/A |

#### S4: Fee-tier desync quote vs swap (PC3-2, DEPTH-EX-4)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — setPairFee is onlyOwner on UniswapV3Adapter | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | UniswapV3Adapter owner calls setPairFee after routes configured → desync | YES | PC3-2, DEPTH-EX-4 | N/A |
| 3 | Natural operation | Fee migration on Uniswap (e.g., pool moves to new fee tier) → admin updates pairFees but route calldata retains old fee | YES | PC3-2 | N/A |
| 4 | External event (Uniswap governance) | Uniswap fee tier changes → requires admin coordination | YES | PC3-2 (covers) | N/A |
| 5 | User action sequence | No path — users cannot trigger fee changes | NO | N/A | N/A |

#### S5: Stale approval on old RewardsManager (PC4-1)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — cannot call setRewardsManager | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | Admin calls setRewardsManager(newAddr) → old address retains unlimited approval | YES | PC4-1 | N/A |
| 3 | Natural operation | Migration to new RewardsManager leaves stale approval | YES | PC4-1 (covers) | N/A |
| 4 | External event | RewardsManager compromise → attacker uses stale approval to drain PremiumManager | YES | PC4-1 (covers) | N/A |
| 5 | User action sequence | No path | NO | N/A | N/A |

#### S6: amountOutMin=1 sandwich (TF-4, DEX-1)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | MEV bot sandwiches claim swap when QuoterV2 fails | YES | TF-4, DEX-1 | N/A |
| 2 | Semi-trusted role | No additional path beyond what external attacker does | NO | N/A | N/A |
| 3 | Natural operation | QuoterV2 reverts due to gas, network congestion, or pool state → quoteSwap returns 0 | YES | TF-4 | N/A |
| 4 | External event | QuoterV2 contract upgrade/pause → systematic quote failure | YES | TF-4 (covers) | N/A |
| 5 | User action sequence | User files claim → swap path encounters QuoterV2 failure | YES | TF-4 (covers) | N/A |

#### S7: Curator blocks claims (AC-2, DST-3)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — setPremiumDefaulted is curator-only | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | Curator calls setPremiumDefaulted(true) | YES | AC-2 | N/A |
| 3 | Natural operation | No path — requires explicit curator action | NO | N/A | N/A |
| 4 | External event (loss event) | Morpho loss → curator wants to protect stake → blocks claims before users can file | YES | AC-2, DST-3 | N/A |
| 5 | User action sequence | No path | NO | N/A | N/A |

#### S8: Claim approval gate serialization (AC-3, SGI-6)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — cannot trigger approval gate | NO | N/A | N/A |
| 2 | Semi-trusted role | Curator enables claimApprovalRequired | YES | AC-3 | N/A |
| 3 | Natural operation | Multiple users withdraw during loss → first claim triggers gate → subsequent claims blocked | YES | SGI-6 | N/A |
| 4 | External event | Loss event + gate enabled → serialized claims | YES | SGI-6 (covers) | N/A |
| 5 | User action sequence | Multiple users claim concurrently | YES | SGI-6 (covers) | N/A |

#### S9: Retroactive deductible/loss params (CS-5, ITER2-ST-2)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — params are owner-set | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | Owner changes deductibleBps/maxCoverableLossBps during or after loss event → withdrawal reads new params | YES | CS-5, ITER2-ST-2 | N/A |
| 3 | Natural operation | No path — requires explicit owner action | NO | N/A | N/A |
| 4 | External event | Loss event occurs → owner adjusts params before users withdraw | YES | CS-5 (covers) | N/A |
| 5 | User action sequence | Users withdraw after param change → reduced payout | YES | CS-5 (covers) | N/A |

#### S10: Revoked spec still callable (RS2-1, ITER2-ST-3)

| # | Actor Category | Path to State S? | Reachable? | Existing Finding? | If Missing: New Finding |
|---|----------------|-------------------|------------|-------------------|------------------------|
| 1 | External attacker (permissionless) | No path — cannot revoke or register specs | NO | N/A | N/A |
| 2 | Semi-trusted role (within permissions) | Spec admin calls revokeSpec → only _approvedSpecs cleared, _specs untouched → ClaimManager resolveSpec still works | YES | RS2-1 | N/A |
| 3 | Natural operation | No path — revocation is explicit action | NO | N/A | N/A |
| 4 | External event | Spec becomes compromised → admin revokes → but claims still evaluate against it | YES | RS2-1 (covers) | N/A |
| 5 | User action sequence | No path | NO | N/A | N/A |

### STEP 0c: Cross-State Interactions

| State S1 | State S2 | Combined? | Combined Attack Path | Impact |
|----------|----------|-----------|---------------------|--------|
| S1 (grace window uninsured) | S2 (phantom premium residual) | YES | Gate accumulation extends premium accrual into uninsured window (S1) → if loss occurs during grace, deep-loss withdrawal creates phantom residual (S2) → double impact: users pay premium for uninsured period AND remaining holders face phantom NAV deflation | Premium loss + NAV deflation (compounded) |
| S7 (curator blocks claims) | S1 (grace window uninsured) | YES | Curator blocks claims (S7) during grace window when claims already fail at ClaimManager (S1) → redundant blocking, but curator can also block during normal insured period → more severe than S1 alone | Users completely unable to claim insurance (S7 is superset blocker) |
| S9 (retroactive params) | S2 (phantom residual) | YES | Owner reduces maxCoverableLossBps during loss (S9) → reduced payout → deeper effective loss → larger phantom residual in totalPremiumLiability (S2) | Compounded: reduced insurance + inflated phantom |
| S6 (amountOutMin=1 sandwich) | S3 (excess stranded) | PARTIAL | If MEV sandwich reduces swap output, less surplus is stranded (S3 effect reduced). But if QuoterV2 fails and swap still succeeds with more than needed, surplus still stranded. These are opposing rather than compounding. | Orthogonal — S6 reduces payout, S3 locks surplus |
| S4 (fee-tier desync) | S6 (amountOutMin=1) | YES | Fee desync (S4) causes quote to use wrong fee tier → quote may revert or return inaccurate value → falls back to amountOutMin=1 (S6) → sandwich attack enabled | Fee desync enables the sandwich path |

**New Enabler Findings: 0** — All dangerous states have existing findings covering all reachable actor categories. No gaps identified.

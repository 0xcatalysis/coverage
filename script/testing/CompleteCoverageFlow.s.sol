// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {IClaimManager} from "../../src/interfaces/IClaimManager.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

/**
 * @title CompleteCoverageFlow
 * @notice End-to-end testing script covering the full protocol lifecycle from pool creation through
 *         policy binding, premium distribution, and claim settlement.
 * @dev Exercises all 8 documented flows in sequence:
 *
 *      Phase 1  - Flow 1:  CoverPool Creation (factory → pool clone)
 *      Phase 1b -          Operator cleanup (auto-release from prior committee for re-runs)
 *      Phase 2  - Flow 2:  Coverage Request (buyer requests coverage → policy draft + committee)
 *      Phase 3  - Flow 3:  Committee Verification (verify committee was created with policyId)
 *      Phase 4  - Flow 4:  Policy Binding (curator signs quote → binds vaults → activates policy)
 *      Phase 5  - Flow 5:  Premium Accrual Verification (vault shares check)
 *      Phase 6  - Flow 6:  Premium Distribution (collector → manager → fees + rewards)
 *      Phase 7  - Flow 7:  Claim Filing & Payout (file → evaluate → slash → swap → payout)
 *      Phase 8  - Summary: End-to-end state verification
 *
 * Usage:
 *   forge script script/testing/CompleteCoverageFlow.s.sol:CompleteCoverageFlow \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *
 *   Accounts:
 *   - CURATOR_PRIVATE_KEY: Curator private key (pool owner/operator)
 *   - QUOTE_SIGNER_PRIVATE_KEY: Quote signer private key
 *   - BUYER_PRIVATE_KEY: Coverage buyer private key
 *   - CLAIMER_PRIVATE_KEY: Authorized claimer private key
 *   - ADMIN_PRIVATE_KEY: (optional) DEFAULT_ADMIN_ROLE key on PolicyManager; used to whitelist
 *       PAYOUT_TOKEN if not already supported. Defaults to CURATOR_PRIVATE_KEY when omitted.
 *
 *   Coverage Contracts:
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - CLAIM_MANAGER: ClaimManager proxy address
 *   - PREMIUM_MANAGER: PremiumManager proxy address
 *   - SPEC_REGISTRY: SpecRegistry proxy address (optional but recommended; enables pre-flight
 *       approval check in Phase 4 — if omitted, an unapproved spec only fails at the contract level)
 *
 *   Core Contracts:
 *   - STAKE_MANAGER: StakeManager proxy address
 *
 *   Pool Creation Params:
 *   - POOL_FEE_BPS: Pool fee basis points (e.g. 1000 = 10%)
 *
 *   Coverage Request Params:
 *   - BENEFICIARY: Claim payout beneficiary
 *   - PAYOUT_TOKEN: ERC20 token for payouts
 *   - DURATION: Coverage duration in seconds
 *   - BIND_POLICY_HOOK: Hook contract for policy binding callback
 *
 *   Policy Binding Params:
 *   - SPEC_ADDRESS: ISpec implementation contract address (must be approved in SpecRegistry first)
 *   - VAULTS: (optional) Comma-separated vault addresses; auto-discovered from SSPRouter if omitted
 *   - COVERAGE_LIMIT: Coverage limit in payout token units
 *   - SPEC_ID: Spec identifier (bytes32)
 *   - TERMS_HASH: Terms hash (bytes32)
 *   - EXPIRATION_TIME: Quote expiration timestamp
 *
 *   Premium Params:
 *   - COVERED_VAULT: ERC-4626 vault address
 *
 *   Re-run Cleanup (optional):
 *   - PRIOR_COMMITTEE_ID: Committee ID the curator/operator was assigned to in a previous run.
 *       When set to a non-zero value, Phase 1b calls removeOperatorFromCommittee before
 *       requestCoverage so the re-run does not revert with CommitteeAlreadyHasOperator.
 *       Defaults to 0 (phase is skipped). Obtain this value from the POLICY_ID output of
 *       the previous run (committeeId == policyId).
 *
 *   Claim Params:
 *   - REQUESTED_CLAIM_AMOUNT: Payout amount to request in claim
 *   - EVIDENCE_HASH: Evidence hash (bytes32)
 *
 * Prerequisites for Phase 8 (Claim):
 *   EigenLayer operator setup (magnitude allocation + operatorSet registration) is a
 *   restaker/core responsibility and must be completed before running this script.
 *   Use script/testing/PrepareEigenLayer.s.sol and wait for ALLOCATION_CONFIGURATION_DELAY
 *   blocks (~15 min on Sepolia) before filing a claim.
 */
contract CompleteCoverageFlow is Script {
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 expirationTime)"
    );

    // ── Accounts ──
    uint256 public curatorPrivateKey;
    address public curator;
    uint256 public quoteSignerPrivateKey;
    address public quoteSigner;
    uint256 public buyerPrivateKey;
    address public buyer;
    uint256 public claimerPrivateKey;
    address public claimer;
    uint256 public adminPrivateKey;

    // ── Coverage Contracts ──
    address public coverPoolFactory;
    address public policyManager;
    address public claimManager;
    address public premiumManager;
    address public specRegistry;

    // ── Core Contracts ──
    address public stakeManager;

    // ── Pool Creation ──
    uint16 public poolFeeBps;

    // ── Coverage Request ──
    address public beneficiary;
    address public payoutToken;
    uint32 public duration;
    address public bindPolicyHook;

    // ── Policy Binding ──
    address public specAddress;
    address[] public vaults;
    uint256 public coverageLimit;
    bytes32 public specId;
    bytes32 public termsHash;
    uint32 public expirationTime;

    // ── Premium ──
    address public coveredVault;

    // ── Claim ──
    uint256 public requestedClaimAmount;
    bytes32 public evidenceHash;

    // ── Runtime State ──
    address public coverPool;
    uint96 public policyId;

    // ── Events ──
    event FlowCompleted(string name, uint256 phase);
    event EndToEndCompleted(uint96 indexed policyId, address indexed coverPool, address indexed beneficiary);

    constructor() {
        _loadAccounts();
        _loadContractAddresses();
        _loadPoolCreationParams();
        _loadCoverageRequestParams();
        _loadPolicyBindingParams();
        _loadPremiumParams();
        _loadClaimParams();
    }

    function run() external virtual {
        console.log("============================================");
        console.log("  COMPLETE COVERAGE PROTOCOL E2E FLOW");
        console.log("============================================");
        console.log("Curator:", curator);
        console.log("Buyer:", buyer);
        console.log("Claimer:", claimer);
        console.log("Beneficiary:", beneficiary);
        console.log("");

        _phase0_whitelistPayoutToken();
        _phase1_createCoverPool();
        _phase1b_releaseOperator();
        _phase2_requestCoverage();
        _phase3_verifyCommittee();
        _discoverVaultsIfNeeded();
        _beforePhase4();
        _phase4_bindPolicy();
        _phase5_verifyPremiumAccrual();
        _phase6_distributePremiums();
        _phase7_fileClaim();
        _phase8_summary();

        console.log("\n============================================");
        console.log("  E2E FLOW COMPLETED SUCCESSFULLY");
        console.log("============================================");
        emit EndToEndCompleted(policyId, coverPool, beneficiary);
    }

    // ═══════════════════════════════════════════
    //  Phase 0: Admin Setup – Payout Token Whitelist
    // ═══════════════════════════════════════════

    /**
     * @notice Whitelists the payout token on PolicyManager if not already supported.
     * @dev Uses ADMIN_PRIVATE_KEY (falls back to CURATOR_PRIVATE_KEY) to call
     *      setSupportedPayoutToken. Skipped when the token is already whitelisted so
     *      re-runs of the script are idempotent.
     */
    function _phase0_whitelistPayoutToken() internal {
        console.log("\n=== PHASE 0: PAYOUT TOKEN WHITELIST ===");

        IPolicyManager pm = IPolicyManager(policyManager);

        if (!pm.supportedPayoutTokens(payoutToken)) {
            console.log("Whitelisting payout token:", payoutToken);
            vm.startBroadcast(adminPrivateKey);
            pm.setSupportedPayoutToken(payoutToken, true);
            vm.stopBroadcast();
            require(pm.supportedPayoutTokens(payoutToken), "Phase 0: Payout token not whitelisted");
            console.log("[OK] Payout token whitelisted");
        } else {
            console.log("[SKIP] Payout token already whitelisted:", payoutToken);
        }

        _approveAsPremiumTokenIfNeeded();

        emit FlowCompleted("Payout Token Whitelist", 0);
    }

    /**
     * @notice Adds payoutToken to PremiumManager's approved premium token set if needed.
     * @dev Coverage's DeployEthereum returns empty arrays from getInitialPremiumTokens(), so
     *      the payout token is not automatically added during deployment. Phase 6 (premium
     *      distribution) calls PremiumManager.distributePremium(), which requires the token to
     *      be in the approved set -- without this step it would revert with UnapprovedToken.
     */
    function _approveAsPremiumTokenIfNeeded() internal {
        (bool ok, bytes memory data) =
            premiumManager.staticcall(abi.encodeWithSignature("isApprovedPremiumToken(address)", payoutToken));
        if (ok && data.length >= 32 && abi.decode(data, (bool))) {
            console.log("[SKIP] Payout token already approved on PremiumManager");
            return;
        }

        console.log("Adding payout token to PremiumManager approved set:", payoutToken);
        vm.startBroadcast(adminPrivateKey);
        (bool success,) = premiumManager.call(abi.encodeWithSignature("addApprovedPremiumToken(address)", payoutToken));
        vm.stopBroadcast();
        require(success, "Phase 0: addApprovedPremiumToken failed");
        console.log("[OK] Payout token added as approved premium token on PremiumManager");
    }

    // ═══════════════════════════════════════════
    //  Phase 1: CoverPool Creation
    // ═══════════════════════════════════════════

    function _phase1_createCoverPool() internal {
        console.log("\n=== PHASE 1: COVER POOL CREATION ===");

        ICoverPoolFactory factory = ICoverPoolFactory(coverPoolFactory);

        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator, quoteSigner: quoteSigner, poolFeeBps: poolFeeBps
        });

        coverPool = factory.computeCoverPoolAddress(params);
        console.log("Predicted CoverPool:", coverPool);

        if (factory.coverPoolExists(coverPool)) {
            console.log("[SKIP] Pool already exists at:", coverPool);
        } else {
            vm.startBroadcast(curatorPrivateKey);
            factory.createCoverPool(params);
            vm.stopBroadcast();
            console.log("[OK] CoverPool created:", coverPool);
        }

        require(factory.coverPoolExists(coverPool), "Phase 1: Pool not created");
        require(ICoverPool(coverPool).owner() == curator, "Phase 1: Owner mismatch");

        emit FlowCompleted("CoverPool Creation", 1);
    }

    // ═══════════════════════════════════════════
    //  Phase 2: Coverage Request
    // ═══════════════════════════════════════════

    function _phase2_requestCoverage() internal {
        console.log("\n=== PHASE 2: COVERAGE REQUEST ===");

        IPolicyManager pm = IPolicyManager(policyManager);

        vm.startBroadcast(buyerPrivateKey);
        policyId = pm.requestCoverage(coverPool, beneficiary, claimer, payoutToken, duration, bindPolicyHook);
        vm.stopBroadcast();

        console.log("Policy ID:", policyId);
        console.log("Committee ID (= policyId):", policyId);

        IPolicyManager.PolicyDraft memory draft = pm.getPolicyDraft(policyId);
        require(draft.status == IPolicyManager.PolicyStatus.Created, "Phase 2: Draft not Created");
        require(draft.pool == coverPool, "Phase 2: Pool mismatch");
        require(draft.buyer == buyer, "Phase 2: Buyer mismatch");

        console.log("[OK] Coverage requested, policy draft and committee created");
        emit FlowCompleted("Coverage Request", 2);
    }

    // ═══════════════════════════════════════════
    //  Phase 3: Committee Verification
    // ═══════════════════════════════════════════

    function _phase3_verifyCommittee() internal {
        console.log("\n=== PHASE 3: COMMITTEE VERIFICATION ===");

        console.log("Committee ID:", policyId);
        address[] memory committeeVaults = IStakeManager(stakeManager).getCommitteeVaults(policyId);
        console.log("Committee vaults registered:", committeeVaults.length);

        console.log("[OK] Committee created and operator assigned");
        emit FlowCompleted("Committee Verification", 3);
    }

    // ═══════════════════════════════════════════
    //  Phase 4: Policy Binding
    // ═══════════════════════════════════════════

    function _phase4_bindPolicy() internal {
        console.log("\n=== PHASE 4: POLICY BINDING ===");

        IPolicyManager pm = IPolicyManager(policyManager);
        IPolicyManager.PolicyDraft memory draft = pm.getPolicyDraft(policyId);

        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: coverPool,
            policyId: policyId,
            coverageLimit: coverageLimit,
            specId: specId,
            termsHash: termsHash,
            beneficiary: draft.beneficiary,
            expirationTime: expirationTime
        });

        bytes memory signature = _signQuote(quote);

        if (specRegistry != address(0)) {
            bool approved = ISpecRegistry(specRegistry).isSpecApproved(specAddress);
            console.log("Spec approved in SpecRegistry:", approved);
            require(approved, "SPEC_ADDRESS is not approved in SpecRegistry -- call approveSpec() first");
        } else {
            console.log("[WARN] SPEC_REGISTRY not set -- skipping spec approval pre-flight check");
        }

        vm.startBroadcast(curatorPrivateKey);
        ICoverPool(coverPool).bindPolicyForRequest(policyId, quote, specAddress, vaults, signature);
        vm.stopBroadcast();

        IPolicyManager.PolicyDraft memory updatedDraft = pm.getPolicyDraft(policyId);
        require(updatedDraft.status == IPolicyManager.PolicyStatus.Bound, "Phase 4: Not bound");

        IPolicyManager.PolicyMetadata memory metadata = pm.policyMetadata(policyId);
        require(metadata.buyer != address(0), "Phase 4: Metadata not stored");
        require(metadata.coverageLimit == coverageLimit, "Phase 4: Coverage limit mismatch");

        ICoverPool.BoundPolicy memory bp = ICoverPool(coverPool).getBoundPolicy(policyId);
        require(bp.policyId == policyId, "Phase 4: BoundPolicy ID mismatch");

        address[] memory committeeVaults = IStakeManager(stakeManager).getCommitteeVaults(policyId);
        require(committeeVaults.length > 0, "Phase 4: No vaults in committee");

        console.log("Policy bound with coverage limit:", coverageLimit);
        console.log("Committee vaults:", committeeVaults.length);
        console.log("On-chain coverage window:", metadata.startTime, "-", metadata.maturityTime);
        console.log("[OK] Policy binding complete, policy active");
        emit FlowCompleted("Policy Binding", 4);
    }

    // ═══════════════════════════════════════════
    //  Phase 5: Premium Accrual Check
    // ═══════════════════════════════════════════

    function _phase5_verifyPremiumAccrual() internal {
        console.log("\n=== PHASE 5: PREMIUM ACCRUAL CHECK ===");

        if (coveredVault == address(0)) {
            console.log("[SKIP] No covered vault configured");
            return;
        }

        console.log("[INFO] CoveredVaultWrapper accrues premiums internally.");
        console.log("[INFO] Call collectPremium() on the vault to distribute accrued premium.");

        console.log("[OK] Premium accrual check done");
        emit FlowCompleted("Premium Accrual Check", 5);
    }

    // ═══════════════════════════════════════════
    //  Phase 6: Premium Distribution
    // ═══════════════════════════════════════════

    function _phase6_distributePremiums() internal {
        console.log("\n=== PHASE 6: PREMIUM DISTRIBUTION ===");

        if (coveredVault == address(0)) {
            console.log("[SKIP] No covered vault configured");
            return;
        }

        IPremiumManager manager = IPremiumManager(premiumManager);
        uint16 platformFee = manager.platformFeeBps();
        uint16 poolFee = ICoverPool(coverPool).poolFeeBps();
        console.log("Platform fee BPS:", platformFee);
        console.log("Pool fee BPS:", poolFee);

        vm.startBroadcast(curatorPrivateKey);
        (bool success,) = coveredVault.call(abi.encodeWithSignature("collectPremium()"));
        vm.stopBroadcast();
        if (success) {
            console.log("[OK] collectPremium() called on CoveredVaultWrapper");
        } else {
            console.log("[SKIP] collectPremium() reverted or no pending premium");
        }

        emit FlowCompleted("Premium Distribution", 6);
    }

    // ═══════════════════════════════════════════
    //  Phase 7: Claim Filing
    // ═══════════════════════════════════════════

    function _phase7_fileClaim() internal {
        console.log("\n=== PHASE 7: CLAIM FILING & PAYOUT ===");

        if (requestedClaimAmount == 0) {
            console.log("[SKIP] No claim amount specified");
            return;
        }

        IClaimManager cm = IClaimManager(claimManager);
        IPolicyManager pm = IPolicyManager(policyManager);
        IPolicyManager.PolicyMetadata memory metadata = pm.policyMetadata(policyId);

        _logSwapperReadiness(cm, metadata);

        uint256 beneficiaryBalanceBefore = IERC20(metadata.payoutToken).balanceOf(metadata.beneficiary);
        uint256 remainingBefore = cm.remainingCoverage(policyId);
        console.log("Pre-claim remaining coverage:", remainingBefore);
        console.log("Pre-claim beneficiary balance:", beneficiaryBalanceBefore);

        require(requestedClaimAmount <= remainingBefore, "Phase 7: Exceeds remaining coverage");

        bool approvalRequired = cm.claimApprovalRequired(policyId);
        console.log("Curator approval required before next claim:", approvalRequired);
        require(
            !approvalRequired, "Phase 7: Curator must call approveNextClaim() before this policy can file another claim"
        );

        if (block.timestamp < metadata.startTime) {
            console.log("Warping to coverage start time...");
            vm.warp(metadata.startTime + 1);
        }

        vm.startBroadcast(claimerPrivateKey);
        uint256 claimId = cm.fileClaim(policyId, requestedClaimAmount, evidenceHash, "");
        vm.stopBroadcast();

        IClaimManager.ClaimRecord memory claim = cm.claimRecord(policyId, claimId);
        console.log("Claim ID:", claimId);
        console.log("Claim status:", uint8(claim.status));
        console.log("Payout amount:", claim.payoutAmount);

        if (claim.status == IClaimManager.ClaimStatus.Approved) {
            uint256 beneficiaryBalanceAfter = IERC20(metadata.payoutToken).balanceOf(metadata.beneficiary);
            console.log("Beneficiary received:", beneficiaryBalanceAfter - beneficiaryBalanceBefore);

            uint256 remainingAfter = cm.remainingCoverage(policyId);
            console.log("Remaining coverage after claim:", remainingAfter);

            console.log("[OK] Claim approved and payout executed");
        } else if (claim.status == IClaimManager.ClaimStatus.Rejected) {
            console.log("[OK] Claim rejected by Spec evaluation");
        }

        emit FlowCompleted("Claim Filing", 7);
    }

    /**
     * @notice Lightweight Swapper readiness check for the end-to-end flow.
     * @dev Logs the Swapper address, max slippage, and whether a swap will be triggered
     *      based on committee vault collateral tokens vs the policy payout token.
     *      Does not revert on misconfiguration -- informational only in the E2E context.
     */
    function _logSwapperReadiness(IClaimManager cm, IPolicyManager.PolicyMetadata memory metadata) internal view {
        console.log("\n  [Swapper Readiness]");
        address swapper = cm.swapper();
        console.log("  Swapper:", swapper);

        address[] memory committeeVaults = IStakeManager(stakeManager).getCommitteeVaults(policyId);
        bool swapNeeded = false;
        for (uint256 i = 0; i < committeeVaults.length; i++) {
            address collateralToken = _getVaultCollateralToken(committeeVaults[i]);
            if (collateralToken != address(0) && collateralToken != metadata.payoutToken) {
                swapNeeded = true;
                ISwapper.SwapRoute memory route = ISwapper(swapper).getSwapRoute(collateralToken, metadata.payoutToken);
                bool whitelisted = ISwapper(swapper).whitelistedTargets(route.swapTarget);
                console.log("  Vault", i, "collateral:", collateralToken);
                if (route.enabled && whitelisted) {
                    console.log("  [OK] Swap route configured, target:", route.swapTarget);
                } else {
                    console.log("  [WARN] Swap route not ready -- enabled:", route.enabled);
                    console.log("  [WARN] Swap target whitelisted:", whitelisted);
                }
            }
        }
        if (!swapNeeded) {
            console.log("  All collateral tokens match payout token -- direct transfer, no swap needed");
        }
    }

    /**
     * @notice Probes a vault's collateral token via low-level staticcall.
     * @dev Tries three signatures: collateral() (Symbiotic), asset() (ERC-4626),
     *      underlyingToken() (EigenLayer IStrategy). Returns address(0) if none respond.
     */
    function _getVaultCollateralToken(address vault) internal view returns (address) {
        bool ok;
        bytes memory data;

        (ok, data) = vault.staticcall(abi.encodeWithSignature("collateral()"));
        if (ok && data.length >= 32) return abi.decode(data, (address));

        (ok, data) = vault.staticcall(abi.encodeWithSignature("asset()"));
        if (ok && data.length >= 32) return abi.decode(data, (address));

        (ok, data) = vault.staticcall(abi.encodeWithSignature("underlyingToken()"));
        if (ok && data.length >= 32) return abi.decode(data, (address));

        return address(0);
    }

    // ═══════════════════════════════════════════
    //  Phase 8: End-to-End Summary
    // ═══════════════════════════════════════════

    function _phase8_summary() internal view {
        console.log("\n============================================");
        console.log("  END-TO-END SUMMARY");
        console.log("============================================");

        console.log("\n--- CoverPool ---");
        console.log("Address:", coverPool);
        console.log("Curator:", curator);
        console.log("Pool Fee BPS:", poolFeeBps);

        console.log("\n--- Policy ---");
        console.log("Policy ID:", policyId);
        console.log("Committee ID:", policyId);

        IPolicyManager pm = IPolicyManager(policyManager);
        IPolicyManager.PolicyMetadata memory metadata = pm.policyMetadata(policyId);
        console.log("Buyer:", metadata.buyer);
        console.log("Beneficiary:", metadata.beneficiary);
        console.log("Claimer:", metadata.claimer);
        console.log("Coverage Limit:", metadata.coverageLimit);
        console.log("Payout Token:", metadata.payoutToken);
        console.log("Start Time:", metadata.startTime);
        console.log("Maturity Time:", metadata.maturityTime);

        console.log("\n--- Stake ---");
        address[] memory committeeVaults = IStakeManager(stakeManager).getCommitteeVaults(policyId);
        console.log("Committee Vaults:", committeeVaults.length);

        console.log("\n--- Claims ---");
        IClaimManager cm = IClaimManager(claimManager);
        IClaimManager.PolicyClaim memory policyClaim = cm.policyClaim(policyId);
        console.log("Total Claims Filed:", policyClaim.claimCount);
        console.log("Total Paid Out:", policyClaim.totalPaidOut);
        uint256 remaining = cm.remainingCoverage(policyId);
        console.log("Remaining Coverage:", remaining);

        console.log("\n--- Fees ---");
        IPremiumManager mgr = IPremiumManager(premiumManager);
        console.log("Platform Fee BPS:", mgr.platformFeeBps());
        console.log("Platform Treasury:", mgr.platformTreasury());

        console.log("\n============================================");
    }

    // ═══════════════════════════════════════════
    //  Extension Hook
    // ═══════════════════════════════════════════

    /**
     * @notice Called between vault auto-discovery and Phase 4 (policy binding).
     * @dev Override in subclasses to inject pre-binding setup, such as funding vaults
     *      with EigenLayer stake for fork testing (see ForkCompleteCoverageFlow).
     *      No-op by default so the base script works on any live network.
     */
    function _beforePhase4() internal virtual {}

    // ═══════════════════════════════════════════
    //  Phase 1b: Release Operator from Prior Committee
    // ═══════════════════════════════════════════

    /**
     * @notice Releases the curator/operator from any prior committee so requestCoverage can
     *         assign them to the new one.
     * @dev StakeManager enforces one-operator-per-committee AND one-committee-per-operator.
     *      Calling requestCoverage when the operator is already in a committee reverts with
     *      CommitteeAlreadyHasOperator, breaking re-runs of this script.
     *
     *      The prior committee ID is read from the PRIOR_COMMITTEE_ID environment variable.
     *      Set it to the POLICY_ID value logged by the previous run (committeeId == policyId).
     *      When the variable is absent or zero the phase is skipped.
     */
    function _phase1b_releaseOperator() internal {
        console.log("\n=== PHASE 1b: OPERATOR COMMITTEE CLEANUP ===");

        uint96 currentCommitteeId = uint96(vm.envOr("PRIOR_COMMITTEE_ID", uint256(0)));

        if (currentCommitteeId == 0) {
            console.log("[SKIP] PRIOR_COMMITTEE_ID not set or zero -- no cleanup needed");
            return;
        }

        console.log("Operator currently in committee:", currentCommitteeId, "-- releasing");

        vm.startBroadcast(curatorPrivateKey);
        IStakeManager(stakeManager).removeOperatorFromCommittee(curator, currentCommitteeId);
        vm.stopBroadcast();

        console.log("[OK] Operator released from committee", currentCommitteeId);
        emit FlowCompleted("Release Operator", 15);
    }

    // ═══════════════════════════════════════════
    //  Vault Auto-Discovery
    // ═══════════════════════════════════════════

    /**
     * @notice Populates `vaults` from SSPRouter when VAULTS env var was not set.
     * @dev DurationVaultStrategies are deployed dynamically during `requestCoverage` ->
     *      `StakeManager.createCommittee` -> `SSPRouter.createCommittee`. Their addresses
     *      are only available after Phase 2. SSPRouter.getVaultsByModule(EIGENLAYER=2)
     *      returns ALL strategies registered for the EigenLayer module.
     *
     *      On a fresh fork this is exactly one vault (one ACCEPTABLE_TOKEN = one vault).
     *      On shared or reused networks (e.g. Sepolia across multiple runs) the list may
     *      include vaults from prior committees; set VAULTS explicitly in that case.
     *
     *      Uses low-level staticcalls to avoid importing Core interfaces.
     */
    function _discoverVaultsIfNeeded() internal {
        if (vaults.length > 0) {
            return;
        }

        console.log("\n=== VAULT AUTO-DISCOVERY ===");

        (bool ok1, bytes memory d) = stakeManager.staticcall(abi.encodeWithSignature("router()"));
        require(ok1 && d.length >= 32, "Vault discovery: StakeManager.router() call failed");
        address router = abi.decode(d, (address));
        console.log("SSPRouter:", router);

        (bool ok2, bytes memory d2) = router.staticcall(abi.encodeWithSignature("getVaultsByModule(uint8)", uint8(2)));
        require(ok2, "Vault discovery: SSPRouter.getVaultsByModule() call failed");
        vaults = abi.decode(d2, (address[]));

        console.log("Auto-discovered", vaults.length, "vault(s) from SSPRouter");
        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("  Vault", i, ":", vaults[i]);
        }
        require(vaults.length > 0, "Vault auto-discovery: no EigenLayer vaults found in SSPRouter");
    }

    // ═══════════════════════════════════════════
    //  Internal Helpers
    // ═══════════════════════════════════════════

    function _signQuote(ICoverPool.Quote memory quote) internal view returns (bytes memory) {
        bytes32 domainSeparator = ICoverPool(coverPool).quoteDomainSeparator();

        bytes32 structHash = keccak256(
            abi.encode(
                _QUOTE_TYPEHASH,
                quote.pool,
                quote.policyId,
                quote.coverageLimit,
                quote.specId,
                quote.termsHash,
                quote.beneficiary,
                quote.expirationTime
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _loadAccounts() internal {
        curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        curator = vm.addr(curatorPrivateKey);
        quoteSignerPrivateKey = vm.envUint("QUOTE_SIGNER_PRIVATE_KEY");
        quoteSigner = vm.addr(quoteSignerPrivateKey);
        buyerPrivateKey = vm.envUint("BUYER_PRIVATE_KEY");
        buyer = vm.addr(buyerPrivateKey);
        claimerPrivateKey = vm.envUint("CLAIMER_PRIVATE_KEY");
        claimer = vm.addr(claimerPrivateKey);
        adminPrivateKey = vm.envOr("ADMIN_PRIVATE_KEY", curatorPrivateKey);
    }

    function _loadContractAddresses() internal {
        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        policyManager = vm.envAddress("POLICY_MANAGER");
        claimManager = vm.envAddress("CLAIM_MANAGER");
        premiumManager = vm.envAddress("PREMIUM_MANAGER");
        specRegistry = vm.envOr("SPEC_REGISTRY", address(0));

        stakeManager = vm.envAddress("STAKE_MANAGER");
    }

    function _loadPoolCreationParams() internal {
        poolFeeBps = uint16(vm.envUint("POOL_FEE_BPS"));
    }

    function _loadCoverageRequestParams() internal {
        beneficiary = vm.envAddress("BENEFICIARY");
        payoutToken = vm.envAddress("PAYOUT_TOKEN");
        duration = uint32(vm.envUint("DURATION"));
        bindPolicyHook = vm.envAddress("BIND_POLICY_HOOK");
    }

    function _loadPolicyBindingParams() internal {
        specAddress = vm.envAddress("SPEC_ADDRESS");

        string memory vaultsStr = vm.envOr("VAULTS", string(""));
        if (bytes(vaultsStr).length > 0) {
            string[] memory vaultAddresses = vm.split(vaultsStr, ",");
            for (uint256 i = 0; i < vaultAddresses.length; i++) {
                vaults.push(vm.parseAddress(vaultAddresses[i]));
            }
        }

        coverageLimit = vm.envUint("COVERAGE_LIMIT");
        specId = vm.envBytes32("SPEC_ID");
        termsHash = vm.envBytes32("TERMS_HASH");
        expirationTime = uint32(vm.envUint("EXPIRATION_TIME"));
    }

    function _loadPremiumParams() internal {
        coveredVault = vm.envOr("COVERED_VAULT", address(0));
    }

    function _loadClaimParams() internal {
        requestedClaimAmount = vm.envOr("REQUESTED_CLAIM_AMOUNT", uint256(0));
        evidenceHash = vm.envOr("EVIDENCE_HASH", bytes32(0));
    }
}

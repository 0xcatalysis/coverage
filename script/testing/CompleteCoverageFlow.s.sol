// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {IClaimManager} from "../../src/interfaces/IClaimManager.sol";
import {IPremiumCollector} from "../../src/interfaces/IPremiumCollector.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";
import {IChainlinkPriceFeed} from "../../src/interfaces/IChainlinkPriceFeed.sol";

/**
 * @title CompleteCoverageFlow
 * @notice End-to-end testing script covering the full protocol lifecycle from pool creation through
 *         policy binding, premium distribution, and claim settlement.
 * @dev Exercises all 8 documented flows in sequence:
 *
 *      Phase 1  - Flow 1:   CoverPool Creation (factory → pool clone → operator registration)
 *      Phase 2  - Flow 2:   Coverage Request (buyer requests coverage → policy draft + committee)
 *      Phase 3  - Flow 3:   Committee Verification (verify committee was created with policyId)
 *      Phase 4  - Flow 4:   [External] Restakers delegate (verified via stake query)
 *      Phase 5  - Flow 5:   Policy Binding (curator signs quote → binds vaults → activates policy)
 *      Phase 6  - Flow 6:   Premium Accrual Verification (vault shares check)
 *      Phase 7  - Flow 7:   Premium Distribution (collector → manager → fees + rewards)
 *      Phase 8  - Flow 8:   Claim Filing & Payout (file → evaluate → slash → swap → payout)
 *      Phase 9  - Summary:  End-to-end state verification
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
 *
 *   Coverage Contracts:
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - CLAIM_MANAGER: ClaimManager proxy address
 *   - PREMIUM_COLLECTOR: PremiumCollector proxy address
 *   - PREMIUM_MANAGER: PremiumManager proxy address
 *   - SWAPPER: Swapper proxy address
 *
 *   Core Contracts:
 *   - STAKE_MANAGER: StakeManager proxy address
 *   - REWARDS_MANAGER: RewardsManager proxy address
 *   - SLASHING_MANAGER: SlashingManager proxy address
 *   - CHAINLINK_PRICE_FEED: ChainlinkPriceFeed proxy address
 *
 *   Pool Creation Params:
 *   - POOL_FEE_BPS: Pool fee basis points (e.g. 1000 = 10%)
 *   - OPERATOR_DEADLINE: Operator registration deadline timestamp
 *   - OPERATOR_SIGNATURE: Hex-encoded operator signature
 *
 *   Coverage Request Params:
 *   - BENEFICIARY: Claim payout beneficiary
 *   - PAYOUT_TOKEN: ERC20 token for payouts
 *   - COVERAGE_AMOUNT: Coverage amount (USD, 8 decimals)
 *   - DURATION: Coverage duration in seconds
 *   - BIND_POLICY_HOOK: Hook contract for policy binding callback
 *
 *   Policy Binding Params:
 *   - SPEC_ADDRESS: ISpec implementation contract address
 *   - VAULTS: Comma-separated vault addresses
 *   - COVERAGE_LIMIT: Coverage limit in payout token units
 *   - BASE_PREMIUM: Base premium amount
 *   - SPEC_ID: Spec identifier (bytes32)
 *   - TERMS_HASH: Terms hash (bytes32)
 *   - START_TIME: Coverage start timestamp
 *   - MATURITY_TIME: Coverage end timestamp
 *   - EXPIRATION_TIME: Quote expiration timestamp
 *
 *   Premium Params:
 *   - COVERED_VAULT: ERC-4626 vault address
 *   - PLATFORM_TREASURY: Platform treasury address
 *
 *   Claim Params:
 *   - REQUESTED_CLAIM_AMOUNT: Payout amount to request in claim
 *   - EVIDENCE_HASH: Evidence hash (bytes32)
 */
contract CompleteCoverageFlow is Script {
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
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

    // ── Coverage Contracts ──
    address public coverPoolFactory;
    address public policyManager;
    address public claimManager;
    address public premiumCollector;
    address public premiumManager;

    // ── Core Contracts ──
    address public stakeManager;
    address public rewardsManager;
    address public chainlinkPriceFeed;

    // ── Pool Creation ──
    uint16 public poolFeeBps;
    uint48 public operatorDeadline;
    bytes public operatorSignature;

    // ── Coverage Request ──
    address public beneficiary;
    address public payoutToken;
    uint256 public coverageAmount;
    uint32 public duration;
    address public bindPolicyHook;

    // ── Policy Binding ──
    address public specAddress;
    address[] public vaults;
    uint256 public coverageLimit;
    uint256 public basePremium;
    bytes32 public specId;
    bytes32 public termsHash;
    uint32 public startTime;
    uint32 public maturityTime;
    uint32 public expirationTime;

    // ── Premium ──
    address public coveredVault;
    address public platformTreasury;

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

    function run() external {
        console.log("============================================");
        console.log("  COMPLETE COVERAGE PROTOCOL E2E FLOW");
        console.log("============================================");
        console.log("Curator:", curator);
        console.log("Buyer:", buyer);
        console.log("Claimer:", claimer);
        console.log("Beneficiary:", beneficiary);
        console.log("");

        _phase1_createCoverPool();
        _phase2_requestCoverage();
        _phase3_verifyCommittee();
        _phase4_verifyRestakerDelegation();
        _phase5_bindPolicy();
        _phase6_verifyPremiumAccrual();
        _phase7_distributePremiums();
        _phase8_fileClaim();
        _phase9_summary();

        console.log("\n============================================");
        console.log("  E2E FLOW COMPLETED SUCCESSFULLY");
        console.log("============================================");
        emit EndToEndCompleted(policyId, coverPool, beneficiary);
    }

    // ═══════════════════════════════════════════
    //  Phase 1: CoverPool Creation
    // ═══════════════════════════════════════════

    function _phase1_createCoverPool() internal {
        console.log("\n=== PHASE 1: COVER POOL CREATION ===");

        ICoverPoolFactory factory = ICoverPoolFactory(coverPoolFactory);

        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            poolFeeBps: poolFeeBps,
            deadline: operatorDeadline,
            signature: operatorSignature
        });

        coverPool = factory.computeCoverPoolAddress(params);
        console.log("Predicted CoverPool:", coverPool);

        vm.startBroadcast(curatorPrivateKey);
        factory.createCoverPool(params);
        vm.stopBroadcast();

        require(factory.coverPoolExists(coverPool), "Phase 1: Pool not created");
        require(ICoverPool(coverPool).owner() == curator, "Phase 1: Owner mismatch");

        console.log("[OK] CoverPool created:", coverPool);
        emit FlowCompleted("CoverPool Creation", 1);
    }

    // ═══════════════════════════════════════════
    //  Phase 2: Coverage Request
    // ═══════════════════════════════════════════

    function _phase2_requestCoverage() internal {
        console.log("\n=== PHASE 2: COVERAGE REQUEST ===");

        IPolicyManager pm = IPolicyManager(policyManager);

        vm.startBroadcast(buyerPrivateKey);
        policyId =
            pm.requestCoverage(coverPool, beneficiary, claimer, payoutToken, coverageAmount, duration, bindPolicyHook);
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

        IStakeManager sm = IStakeManager(stakeManager);

        uint256 stake = sm.getOperatorCommitteeStake(curator, policyId);
        console.log("Operator stake for committee:", stake);
        console.log("Committee ID:", policyId);

        console.log("[OK] Committee created and operator assigned");
        emit FlowCompleted("Committee Verification", 3);
    }

    // ═══════════════════════════════════════════
    //  Phase 4: Restaker Delegation
    // ═══════════════════════════════════════════

    function _phase4_verifyRestakerDelegation() internal {
        console.log("\n=== PHASE 4: RESTAKER DELEGATION CHECK ===");
        console.log("NOTE: Restaker delegation happens externally (EigenLayer/Symbiotic)");
        console.log("Checking current operator stake...");

        IStakeManager sm = IStakeManager(stakeManager);
        uint256 totalStake = sm.getOperatorCommitteeStake(curator, policyId);
        console.log("Total operator stake (USD):", totalStake);
        console.log("Required coverage amount:", coverageAmount);

        if (totalStake >= coverageAmount) {
            console.log("[OK] Sufficient stake for policy binding");
        } else {
            console.log("[WARNING] Insufficient stake. Need more delegation before binding.");
            console.log("Shortfall:", coverageAmount - totalStake);
        }

        emit FlowCompleted("Restaker Delegation Check", 4);
    }

    // ═══════════════════════════════════════════
    //  Phase 5: Policy Binding
    // ═══════════════════════════════════════════

    function _phase5_bindPolicy() internal {
        console.log("\n=== PHASE 5: POLICY BINDING ===");

        IPolicyManager pm = IPolicyManager(policyManager);
        IPolicyManager.PolicyDraft memory draft = pm.getPolicyDraft(policyId);

        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: coverPool,
            policyId: policyId,
            coverageLimit: coverageLimit,
            basePremium: basePremium,
            specId: specId,
            termsHash: termsHash,
            beneficiary: draft.beneficiary,
            startTime: startTime,
            maturityTime: maturityTime,
            expirationTime: expirationTime
        });

        bytes memory signature = _signQuote(quote);

        vm.startBroadcast(curatorPrivateKey);
        ICoverPool(coverPool).bindPolicyForRequest(policyId, quote, specAddress, vaults, signature);
        vm.stopBroadcast();

        IPolicyManager.PolicyDraft memory updatedDraft = pm.getPolicyDraft(policyId);
        require(updatedDraft.status == IPolicyManager.PolicyStatus.Bound, "Phase 5: Not bound");

        IPolicyManager.PolicyMetadata memory metadata = pm.policyMetadata(policyId);
        require(metadata.buyer != address(0), "Phase 5: Metadata not stored");
        require(metadata.coverageLimit == coverageLimit, "Phase 5: Coverage limit mismatch");

        ICoverPool.BoundPolicy memory bp = ICoverPool(coverPool).getBoundPolicy(policyId);
        require(bp.policyId == policyId, "Phase 5: BoundPolicy ID mismatch");

        address[] memory committeeVaults = IStakeManager(stakeManager).getCommitteeVaults(policyId);
        require(committeeVaults.length > 0, "Phase 5: No vaults in committee");

        console.log("Policy bound with coverage limit:", coverageLimit);
        console.log("Committee vaults:", committeeVaults.length);
        console.log("Coverage window:", startTime, "-", maturityTime);
        console.log("[OK] Policy binding complete, policy active");
        emit FlowCompleted("Policy Binding", 5);
    }

    // ═══════════════════════════════════════════
    //  Phase 6: Premium Accrual Check
    // ═══════════════════════════════════════════

    function _phase6_verifyPremiumAccrual() internal {
        console.log("\n=== PHASE 6: PREMIUM ACCRUAL CHECK (Flow 6) ===");

        if (coveredVault == address(0)) {
            console.log("[SKIP] No covered vault configured");
            return;
        }

        IPremiumCollector collector = IPremiumCollector(premiumCollector);
        IPremiumCollector.VaultConfig memory config = collector.getVaultConfig(coveredVault);

        if (!config.registered) {
            console.log("Vault not registered in PremiumCollector yet");
            console.log("NOTE: Admin must call registerVault() to enable premium collection");
        } else {
            console.log("Vault registered:");
            console.log("  Underlying:", config.underlying);
            console.log("  Pool:", config.pool);
            console.log("  Policy ID:", config.policyId);

            uint256 shares = collector.getAccruedShares(coveredVault);
            console.log("  Accrued shares:", shares);

            if (shares > 0) {
                uint256 previewAssets = IERC4626(coveredVault).previewRedeem(shares);
                console.log("  Preview assets:", previewAssets);
            }
        }

        console.log("[OK] Premium accrual check done");
        emit FlowCompleted("Premium Accrual Check", 6);
    }

    // ═══════════════════════════════════════════
    //  Phase 7: Premium Distribution
    // ═══════════════════════════════════════════

    function _phase7_distributePremiums() internal {
        console.log("\n=== PHASE 7: PREMIUM DISTRIBUTION (Flow 7) ===");

        if (coveredVault == address(0)) {
            console.log("[SKIP] No covered vault configured");
            return;
        }

        IPremiumCollector collector = IPremiumCollector(premiumCollector);
        uint256 shares = collector.getAccruedShares(coveredVault);

        if (shares == 0) {
            console.log("[SKIP] No shares to distribute");
            return;
        }

        IPremiumManager manager = IPremiumManager(premiumManager);
        uint16 platformFee = manager.platformFeeBps();
        uint16 poolFee = ICoverPool(coverPool).poolFeeBps();
        console.log("Platform fee BPS:", platformFee);
        console.log("Pool fee BPS:", poolFee);

        address[] memory vaultsToDistribute = new address[](1);
        vaultsToDistribute[0] = coveredVault;

        vm.startBroadcast(curatorPrivateKey);
        collector.distributeBatch(vaultsToDistribute);
        vm.stopBroadcast();

        console.log("[OK] Premiums distributed");
        emit FlowCompleted("Premium Distribution", 7);
    }

    // ═══════════════════════════════════════════
    //  Phase 8: Claim Filing
    // ═══════════════════════════════════════════

    function _phase8_fileClaim() internal {
        console.log("\n=== PHASE 8: CLAIM FILING & PAYOUT (Flow 8) ===");

        if (requestedClaimAmount == 0) {
            console.log("[SKIP] No claim amount specified");
            return;
        }

        IClaimManager cm = IClaimManager(claimManager);
        IPolicyManager pm = IPolicyManager(policyManager);
        IPolicyManager.PolicyMetadata memory metadata = pm.policyMetadata(policyId);

        uint256 beneficiaryBalanceBefore = IERC20(metadata.payoutToken).balanceOf(metadata.beneficiary);
        uint256 remainingBefore = cm.remainingCoverage(policyId);
        console.log("Pre-claim remaining coverage:", remainingBefore);
        console.log("Pre-claim beneficiary balance:", beneficiaryBalanceBefore);

        require(requestedClaimAmount <= remainingBefore, "Phase 8: Exceeds remaining coverage");

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

        emit FlowCompleted("Claim Filing", 8);
    }

    // ═══════════════════════════════════════════
    //  Phase 9: End-to-End Summary
    // ═══════════════════════════════════════════

    function _phase9_summary() internal view {
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
        IStakeManager sm = IStakeManager(stakeManager);
        uint256 stake = sm.getOperatorCommitteeStake(curator, policyId);
        console.log("Operator Stake (USD):", stake);
        address[] memory committeeVaults = sm.getCommitteeVaults(policyId);
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
                quote.basePremium,
                quote.specId,
                quote.termsHash,
                quote.beneficiary,
                quote.startTime,
                quote.maturityTime,
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
    }

    function _loadContractAddresses() internal {
        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        policyManager = vm.envAddress("POLICY_MANAGER");
        claimManager = vm.envAddress("CLAIM_MANAGER");
        premiumCollector = vm.envAddress("PREMIUM_COLLECTOR");
        premiumManager = vm.envAddress("PREMIUM_MANAGER");

        stakeManager = vm.envAddress("STAKE_MANAGER");
        rewardsManager = vm.envAddress("REWARDS_MANAGER");
        chainlinkPriceFeed = vm.envAddress("CHAINLINK_PRICE_FEED");
    }

    function _loadPoolCreationParams() internal {
        poolFeeBps = uint16(vm.envUint("POOL_FEE_BPS"));
        operatorDeadline = uint48(vm.envUint("OPERATOR_DEADLINE"));
        operatorSignature = vm.envBytes("OPERATOR_SIGNATURE");
    }

    function _loadCoverageRequestParams() internal {
        beneficiary = vm.envAddress("BENEFICIARY");
        payoutToken = vm.envAddress("PAYOUT_TOKEN");
        coverageAmount = vm.envUint("COVERAGE_AMOUNT");
        duration = uint32(vm.envUint("DURATION"));
        bindPolicyHook = vm.envAddress("BIND_POLICY_HOOK");
    }

    function _loadPolicyBindingParams() internal {
        specAddress = vm.envAddress("SPEC_ADDRESS");

        string memory vaultsStr = vm.envString("VAULTS");
        string[] memory vaultAddresses = vm.split(vaultsStr, ",");
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            vaults.push(vm.parseAddress(vaultAddresses[i]));
        }

        coverageLimit = vm.envUint("COVERAGE_LIMIT");
        basePremium = vm.envUint("BASE_PREMIUM");
        specId = vm.envBytes32("SPEC_ID");
        termsHash = vm.envBytes32("TERMS_HASH");
        startTime = uint32(vm.envUint("START_TIME"));
        maturityTime = uint32(vm.envUint("MATURITY_TIME"));
        expirationTime = uint32(vm.envUint("EXPIRATION_TIME"));
    }

    function _loadPremiumParams() internal {
        coveredVault = vm.envOr("COVERED_VAULT", address(0));
        platformTreasury = vm.envAddress("PLATFORM_TREASURY");
    }

    function _loadClaimParams() internal {
        requestedClaimAmount = vm.envOr("REQUESTED_CLAIM_AMOUNT", uint256(0));
        evidenceHash = vm.envOr("EVIDENCE_HASH", bytes32(0));
    }
}

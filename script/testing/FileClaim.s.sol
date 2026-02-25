// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IClaimManager} from "../../src/interfaces/IClaimManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {IChainlinkPriceFeed} from "../../src/interfaces/IChainlinkPriceFeed.sol";
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";

/**
 * @title FileClaim
 * @notice Files a claim against a bound policy, triggering spec evaluation, slashing, swapping, and payout.
 * @dev Corresponds to Document Flow 8 – Claim Payouts:
 *      8a. Claim is filed by the authorized claimer via ClaimManager
 *      8b. ClaimManager evaluates the Spec and if approved:
 *      8c. Slashing executes via SlashingManager (per committeeId = policyId)
 *          - Slashed assets transferred to ClaimManager
 *      8d. If needed, assets are converted to payoutToken via Swapper
 *      8e. Payout released to beneficiary
 *
 * Usage:
 *   forge script script/testing/FileClaim.s.sol:FileClaim \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - CLAIMER_PRIVATE_KEY: Private key of the authorized claimer
 *   - CLAIM_MANAGER: ClaimManager proxy address
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - STAKE_MANAGER: StakeManager proxy address (from core)
 *   - CHAINLINK_PRICE_FEED: ChainlinkPriceFeed proxy address (from core)
 *   - POLICY_ID: Policy ID to file claim against
 *   - REQUESTED_AMOUNT: Requested payout amount in payout token terms
 *   - EVIDENCE_HASH: Hash of claim evidence (bytes32 hex, e.g. IPFS CID hash)
 *   - ADDITIONAL_DATA: Optional hex-encoded additional data for Spec evaluation (default: "0x")
 *
 * Prerequisites:
 *   - Policy must be bound and in active coverage window (startTime <= now <= maturityTime)
 *   - Caller must be the policy's designated claimer
 *   - Requested amount must not exceed remaining coverage
 *   - Spec must be registered in SpecRegistry for the pool
 *   - Sufficient restaker stake must be slashable
 */
contract FileClaim is Script {
    /// @notice Claimer address
    address public claimer;

    /// @notice Claimer's private key
    uint256 public claimerPrivateKey;

    /// @notice ClaimManager proxy address
    address public claimManager;

    /// @notice PolicyManager proxy address
    address public policyManager;

    /// @notice StakeManager proxy address
    address public stakeManager;

    /// @notice ChainlinkPriceFeed proxy address
    address public chainlinkPriceFeed;

    /// @notice Policy ID to claim against
    uint96 public policyId;

    /// @notice Requested payout amount
    uint256 public requestedAmount;

    /// @notice Evidence hash
    bytes32 public evidenceHash;

    /// @notice Additional Spec evaluation data
    bytes public additionalData;

    /// @notice Contract instances
    IClaimManager public claimManagerContract;
    IPolicyManager public policyManagerContract;
    IStakeManager public stakeManagerContract;
    IChainlinkPriceFeed public priceFeedContract;

    /// @notice Emitted when claim is filed and processed
    event ClaimProcessed(
        uint96 indexed policyId, uint256 indexed claimId, IClaimManager.ClaimStatus status, uint256 payoutAmount
    );

    constructor() {
        claimerPrivateKey = vm.envUint("CLAIMER_PRIVATE_KEY");
        claimer = vm.addr(claimerPrivateKey);

        claimManager = vm.envAddress("CLAIM_MANAGER");
        policyManager = vm.envAddress("POLICY_MANAGER");
        stakeManager = vm.envAddress("STAKE_MANAGER");
        chainlinkPriceFeed = vm.envAddress("CHAINLINK_PRICE_FEED");
        policyId = uint96(vm.envUint("POLICY_ID"));
        requestedAmount = vm.envUint("REQUESTED_AMOUNT");
        evidenceHash = vm.envBytes32("EVIDENCE_HASH");
        additionalData = vm.envOr("ADDITIONAL_DATA", bytes(""));

        claimManagerContract = IClaimManager(claimManager);
        policyManagerContract = IPolicyManager(policyManager);
        stakeManagerContract = IStakeManager(stakeManager);
        priceFeedContract = IChainlinkPriceFeed(chainlinkPriceFeed);
    }

    function run() external {
        console.log("=== FLOW 8: CLAIM FILING & PAYOUT ===");
        console.log("Claimer:", claimer);
        console.log("ClaimManager:", claimManager);
        console.log("Policy ID:", policyId);
        console.log("Requested Amount:", requestedAmount);
        console.log("Evidence Hash:", vm.toString(evidenceHash));

        IPolicyManager.PolicyMetadata memory metadata = _verifyPrerequisites();
        _preClaimSnapshot(metadata);
        uint256 claimId = _fileClaim();
        _verifyClaimResult(metadata, claimId);

        console.log("\n=== CLAIM FILING & PAYOUT COMPLETED ===");
    }

    function _verifyPrerequisites() internal view returns (IPolicyManager.PolicyMetadata memory metadata) {
        console.log("\n--- Phase 1: Prerequisites ---");

        metadata = policyManagerContract.policyMetadata(policyId);
        console.log("Policy buyer:", metadata.buyer);
        console.log("Policy beneficiary:", metadata.beneficiary);
        console.log("Policy claimer:", metadata.claimer);
        console.log("Policy pool:", metadata.pool);
        console.log("Policy payoutToken:", metadata.payoutToken);
        console.log("Policy coverageLimit:", metadata.coverageLimit);
        console.log("Policy startTime:", metadata.startTime);
        console.log("Policy maturityTime:", metadata.maturityTime);

        require(metadata.buyer != address(0), "Policy not found");
        require(claimer == metadata.claimer, "Caller is not the authorized claimer");

        require(
            block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime, "Outside coverage window"
        );
        console.log("Current time:", block.timestamp);
        console.log("[OK] Within coverage window");

        uint256 remaining = claimManagerContract.remainingCoverage(policyId);
        console.log("Remaining coverage:", remaining);
        require(requestedAmount <= remaining, "Requested exceeds remaining coverage");
        console.log("[OK] Requested amount within remaining coverage");

        uint256 operatorStake = stakeManagerContract.getOperatorCommitteeStake(policyId);
        console.log("Operator stake (USD):", operatorStake);

        uint256 requestedUSD = priceFeedContract.getUSDValue(metadata.payoutToken, requestedAmount);
        console.log("Requested payout USD value:", requestedUSD);

        console.log("[OK] Prerequisites verified");
    }

    function _preClaimSnapshot(IPolicyManager.PolicyMetadata memory metadata) internal view {
        console.log("\n--- Phase 2: Pre-Claim Snapshot ---");

        IClaimManager.PolicyClaim memory policyClaim = claimManagerContract.policyClaim(policyId);
        console.log("Total claims filed:", policyClaim.claimCount);
        console.log("Total paid out:", policyClaim.totalPaidOut);

        uint256 beneficiaryBalance = IERC20(metadata.payoutToken).balanceOf(metadata.beneficiary);
        console.log("Beneficiary payout token balance:", beneficiaryBalance);
    }

    function _fileClaim() internal returns (uint256 claimId) {
        console.log("\n--- Phase 3: Filing Claim ---");
        console.log("Policy ID:", policyId);
        console.log("Requested Amount:", requestedAmount);
        console.log("Evidence Hash:", vm.toString(evidenceHash));

        vm.startBroadcast(claimerPrivateKey);

        claimId = claimManagerContract.fileClaim(policyId, requestedAmount, evidenceHash, additionalData);

        vm.stopBroadcast();

        console.log("Claim ID:", claimId);
    }

    function _verifyClaimResult(IPolicyManager.PolicyMetadata memory metadata, uint256 claimId) internal {
        console.log("\n--- Phase 4: Claim Result ---");

        IClaimManager.ClaimRecord memory claim = claimManagerContract.claimRecord(policyId, claimId);

        console.log("Claim status:", uint8(claim.status));
        console.log("Claim reporter:", claim.reporter);
        console.log("Claim filed at:", claim.filedAt);
        console.log("Claim resolved at:", claim.resolvedAt);
        console.log("Claim requested amount:", claim.requestedAmount);
        console.log("Claim payout amount:", claim.payoutAmount);

        if (claim.status == IClaimManager.ClaimStatus.Approved) {
            console.log("\n[APPROVED] Claim was approved and paid");
            console.log("Payout amount:", claim.payoutAmount);

            uint256 beneficiaryBalance = IERC20(metadata.payoutToken).balanceOf(metadata.beneficiary);
            console.log("Beneficiary payout token balance (after):", beneficiaryBalance);

            IClaimManager.PolicyClaim memory policyClaim = claimManagerContract.policyClaim(policyId);
            console.log("Total paid out (cumulative):", policyClaim.totalPaidOut);

            uint256 remainingCoverage = claimManagerContract.remainingCoverage(policyId);
            console.log("Remaining coverage:", remainingCoverage);

            emit ClaimProcessed(policyId, claimId, IClaimManager.ClaimStatus.Approved, claim.payoutAmount);
        } else if (claim.status == IClaimManager.ClaimStatus.Rejected) {
            console.log("\n[REJECTED] Claim was rejected by Spec evaluation");
            emit ClaimProcessed(policyId, claimId, IClaimManager.ClaimStatus.Rejected, 0);
        } else {
            console.log("\n[UNEXPECTED] Unexpected claim status");
        }

        _printSummary(metadata, claim);
    }

    function _printSummary(
        IPolicyManager.PolicyMetadata memory metadata,
        IClaimManager.ClaimRecord memory claim
    )
        internal
        view
    {
        console.log("\n=== CLAIM SUMMARY ===");
        console.log("Policy ID:", policyId);
        console.log("Pool:", metadata.pool);
        console.log("Beneficiary:", metadata.beneficiary);
        console.log("Payout Token:", metadata.payoutToken);
        console.log("Coverage Limit:", metadata.coverageLimit);
        console.log("Requested:", claim.requestedAmount);
        console.log("Paid Out:", claim.payoutAmount);

        uint256 remaining = claimManagerContract.remainingCoverage(policyId);
        console.log("Remaining Coverage:", remaining);
        console.log("====================");
    }
}

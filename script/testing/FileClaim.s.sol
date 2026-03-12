// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IClaimManager} from "../../src/interfaces/IClaimManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ISlashingManager} from "../../src/interfaces/ISlashingManager.sol";
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

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
 *      Phase 2 (Swapper Readiness) inspects each committee vault's collateral token and
 *      checks whether a swap route is configured for any collateral/payout token mismatch.
 *      This surfaces misconfigurations before broadcasting so operators can fix them first.
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
 *   - If collateral token != payout token: swap route must be configured in Swapper
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
        policyId = uint96(vm.envUint("POLICY_ID"));
        requestedAmount = vm.envUint("REQUESTED_AMOUNT");
        evidenceHash = vm.envBytes32("EVIDENCE_HASH");
        additionalData = vm.envOr("ADDITIONAL_DATA", bytes(""));

        claimManagerContract = IClaimManager(claimManager);
        policyManagerContract = IPolicyManager(policyManager);
        stakeManagerContract = IStakeManager(stakeManager);
    }

    function run() external {
        console.log("=== FLOW 8: CLAIM FILING & PAYOUT ===");
        console.log("Claimer:", claimer);
        console.log("ClaimManager:", claimManager);
        console.log("Policy ID:", policyId);
        console.log("Requested Amount:", requestedAmount);
        console.log("Evidence Hash:", vm.toString(evidenceHash));

        IPolicyManager.PolicyMetadata memory metadata = _verifyPrerequisites();
        _checkSwapperReadiness(metadata);
        _preClaimSnapshot(metadata);
        uint256 claimId = _fileClaim();
        _verifyClaimResult(metadata, claimId);

        console.log("\n=== CLAIM FILING & PAYOUT COMPLETED ===");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 1: Prerequisites
    // ─────────────────────────────────────────────────────────────────────────

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

        console.log("[OK] Prerequisites verified");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 2: Swapper Readiness
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Checks whether the Swapper is configured for the collateral-to-payout swap.
     * @dev Probes each committee vault's collateral token and verifies a swap route exists
     *      for any token that differs from the policy's payout token. Also calls quoteSwap
     *      with the vault's token-native stake as amountIn (mirroring _computeVaultSlashes).
     *      Surfaces misconfigurations before broadcast so the operator can fix them without
     *      wasting gas.
     */
    function _checkSwapperReadiness(IPolicyManager.PolicyMetadata memory metadata) internal {
        console.log("\n--- Phase 2: Swapper Readiness ---");

        address swapper = claimManagerContract.swapper();
        console.log("Swapper:", swapper);

        (address[] memory vaults, address[] memory tokens, uint256[] memory stakes) = _previewSlashingData(metadata);
        console.log("Committee vaults:", vaults.length);

        bool swapNeeded = false;
        bool allRoutesOk = true;

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("  Vault", i, ":", vaults[i]);
            if (tokens[i] == address(0)) {
                console.log("  [WARNING] Collateral token unknown -- skipping");
                continue;
            }
            console.log("    Collateral token       :", tokens[i]);
            console.log("    Stake (token-native)   :", stakes[i]);

            if (tokens[i] == metadata.payoutToken) {
                console.log("    Collateral == payout token -- direct transfer, no swap needed");
                continue;
            }

            swapNeeded = true;
            console.log("    Collateral != payout token -- swap required");

            bool routeOk = _checkVaultSwapRoute(swapper, tokens[i], metadata.payoutToken, stakes[i]);
            if (!routeOk) allRoutesOk = false;
        }

        if (!swapNeeded) {
            console.log("[OK] All vaults share payout token -- direct transfer path, Swapper not exercised");
        } else if (allRoutesOk) {
            console.log("[OK] Swapper ready -- all required routes configured and targets whitelisted");
        } else {
            revert("Swapper misconfigured: fix swap routes before filing claim");
        }
    }

    /**
     * @notice Checks and logs a single vault's swap route and quotes the expected output.
     * @dev amountIn is the vault's token-native stake; using requestedAmount would be wrong
     *      when collateral and payout token decimals differ.
     * @return ok True when the route is enabled and its target is whitelisted.
     */
    function _checkVaultSwapRoute(
        address swapper,
        address collateralToken,
        address payoutToken,
        uint256 stake
    )
        internal
        returns (bool ok)
    {
        ISwapper.SwapRoute memory route = ISwapper(swapper).getSwapRoute(collateralToken, payoutToken);
        if (!route.enabled) {
            console.log("    [FAIL] Swap route not enabled for this collateral -> payout pair");
            console.log("    tokenIn :", collateralToken);
            console.log("    tokenOut:", payoutToken);
            return false;
        }
        if (!ISwapper(swapper).whitelistedTargets(route.swapTarget)) {
            console.log("    [FAIL] Swap target not whitelisted:", route.swapTarget);
            return false;
        }
        console.log("    [OK] Swap route enabled, target whitelisted:", route.swapTarget);

        uint16 slippageBps = claimManagerContract.maxSwapSlippageBps();
        uint256 quotedOut = stake > 0 ? ISwapper(swapper).quoteSwap(collateralToken, payoutToken, stake) : 0;
        uint256 amountOutMin = quotedOut > 0 ? quotedOut * (10_000 - slippageBps) / 10_000 : 0;
        console.log("    QuoteSwap output for full stake      :", quotedOut);
        console.log("    Min output after slippage            :", amountOutMin);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 3: Pre-Claim Snapshot
    // ─────────────────────────────────────────────────────────────────────────

    function _preClaimSnapshot(IPolicyManager.PolicyMetadata memory metadata) internal view {
        console.log("\n--- Phase 3: Pre-Claim Snapshot ---");

        IClaimManager.PolicyClaim memory policyClaim = claimManagerContract.policyClaim(policyId);
        console.log("Total claims filed:", policyClaim.claimCount);
        console.log("Total paid out:", policyClaim.totalPaidOut);

        uint256 beneficiaryBalance = IERC20(metadata.payoutToken).balanceOf(metadata.beneficiary);
        console.log("Beneficiary payout token balance:", beneficiaryBalance);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 4: Filing Claim
    // ─────────────────────────────────────────────────────────────────────────

    function _fileClaim() internal returns (uint256 claimId) {
        console.log("\n--- Phase 4: Filing Claim ---");
        console.log("Policy ID:", policyId);
        console.log("Requested Amount:", requestedAmount);
        console.log("Evidence Hash:", vm.toString(evidenceHash));

        vm.startBroadcast(claimerPrivateKey);

        claimId = claimManagerContract.fileClaim(policyId, requestedAmount, evidenceHash, additionalData);

        vm.stopBroadcast();

        console.log("Claim ID:", claimId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 5: Claim Result
    // ─────────────────────────────────────────────────────────────────────────

    function _verifyClaimResult(IPolicyManager.PolicyMetadata memory metadata, uint256 claimId) internal {
        console.log("\n--- Phase 5: Claim Result ---");

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

            _logSwapMetrics(metadata, claim);

            emit ClaimProcessed(policyId, claimId, IClaimManager.ClaimStatus.Approved, claim.payoutAmount);
        } else if (claim.status == IClaimManager.ClaimStatus.Rejected) {
            console.log("\n[REJECTED] Claim was rejected by Spec evaluation");
            emit ClaimProcessed(policyId, claimId, IClaimManager.ClaimStatus.Rejected, 0);
        } else {
            console.log("\n[UNEXPECTED] Unexpected claim status");
        }

        _printSummary(metadata, claim);
    }

    /**
     * @notice Logs effective exchange rate and realized slippage for the swap path.
     * @dev Replicates the proportional logic from _computeVaultSlashes using previewSlashing
     *      stake data as amountIn for quoteSwap (collateral-token-native units). This produces
     *      a meaningful expected output regardless of decimal differences between collateral
     *      and payout tokens. Only meaningful when at least one vault collateral differs from
     *      payout token.
     */
    function _logSwapMetrics(
        IPolicyManager.PolicyMetadata memory metadata,
        IClaimManager.ClaimRecord memory claim
    )
        internal
    {
        address[] memory vaults = stakeManagerContract.getCommitteeVaults(policyId);
        bool swapOccurred = false;
        for (uint256 i = 0; i < vaults.length; i++) {
            address collateralToken = _getVaultCollateralToken(vaults[i]);
            if (collateralToken != address(0) && collateralToken != metadata.payoutToken) {
                swapOccurred = true;
                break;
            }
        }

        if (!swapOccurred) {
            console.log("\n[Swap Metrics] Direct transfer path used -- no swap occurred");
            return;
        }

        console.log("\n[Swap Metrics] Swap path exercised");
        address swapper = claimManagerContract.swapper();
        uint16 slippageBps = claimManagerContract.maxSwapSlippageBps();

        (, address[] memory previewTokens, uint256[] memory previewStakes) = _previewSlashingData(metadata);

        uint256 totalPayoutEquiv = 0;
        uint256[] memory payoutEquivs = new uint256[](previewStakes.length);
        for (uint256 i = 0; i < previewStakes.length; i++) {
            if (previewStakes[i] == 0) continue;
            payoutEquivs[i] = previewTokens[i] == metadata.payoutToken
                ? previewStakes[i]
                : ISwapper(swapper).quoteSwap(previewTokens[i], metadata.payoutToken, previewStakes[i]);
            totalPayoutEquiv += payoutEquivs[i];
        }

        uint256 quotedExpected = 0;
        if (totalPayoutEquiv > 0) {
            for (uint256 i = 0; i < previewStakes.length; i++) {
                if (previewStakes[i] == 0 || payoutEquivs[i] == 0) continue;
                uint256 proportionalSlash = previewStakes[i] * claim.requestedAmount / totalPayoutEquiv;
                if (proportionalSlash == 0) continue;
                quotedExpected += previewTokens[i] == metadata.payoutToken
                    ? proportionalSlash
                    : ISwapper(swapper).quoteSwap(previewTokens[i], metadata.payoutToken, proportionalSlash);
            }
        }

        uint256 minExpected = quotedExpected > 0 ? quotedExpected * (10_000 - slippageBps) / 10_000 : 0;

        console.log("  Requested amount         :", claim.requestedAmount);
        console.log("  Quote-expected output    :", quotedExpected);
        console.log("  Min after slippage       :", minExpected);
        console.log("  Slippage BPS             :", slippageBps);
        console.log("  Actual payout            :", claim.payoutAmount);

        if (claim.payoutAmount >= claim.requestedAmount) {
            console.log("  [OK] Payout >= requested amount (favorable swap)");
        } else if (minExpected > 0 && claim.payoutAmount >= minExpected) {
            console.log("  [OK] Payout within slippage tolerance");
        } else {
            console.log("  [WARNING] Payout may be below expected -- verify swap configuration");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Summary
    // ─────────────────────────────────────────────────────────────────────────

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

        console.log("\n--- Swap Configuration ---");
        address swapper = claimManagerContract.swapper();
        console.log("Swapper:", swapper);

        address[] memory vaults = stakeManagerContract.getCommitteeVaults(policyId);
        bool swapPath = false;
        for (uint256 i = 0; i < vaults.length; i++) {
            address collateralToken = _getVaultCollateralToken(vaults[i]);
            if (collateralToken != address(0) && collateralToken != metadata.payoutToken) {
                swapPath = true;
                break;
            }
        }
        console.log("Swap path exercised:", swapPath);
        console.log("====================");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the owner of a pool contract via low-level staticcall.
     * @param pool Pool contract to query.
     * @return Address of the owner, or address(0) if the call fails.
     */
    function _getPoolOwner(address pool) internal view returns (address) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return address(0);
    }

    /**
     * @notice Fetches per-vault stake preview data from the SlashingManager.
     * @dev Centralises the previewSlashing call used by _checkSwapperReadiness and
     *      _logSwapMetrics so the operator derivation is not duplicated inline.
     */
    function _previewSlashingData(IPolicyManager.PolicyMetadata memory metadata)
        internal
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory stakes)
    {
        address slashingMgr = claimManagerContract.slashingManager();
        address operator = _getPoolOwner(metadata.pool);
        return ISlashingManager(slashingMgr).previewSlashing(policyId, operator);
    }

    /**
     * @notice Probes a vault's collateral token via low-level staticcall.
     * @dev Tries three function signatures covering the three vault standards in use:
     *      - `collateral()` -- Symbiotic IVaultStorage
     *      - `asset()`      -- ERC-4626 standard (e.g. EigenLayer DurationVaultStrategy)
     *      - `underlyingToken()` -- EigenLayer IStrategy
     *      Returns address(0) if none respond with a valid address.
     * @param vault Vault contract to probe.
     * @return collateralToken Address of the collateral token, or address(0) if unknown.
     */
    function _getVaultCollateralToken(address vault) internal view returns (address collateralToken) {
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
}

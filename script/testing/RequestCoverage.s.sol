// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";

/**
 * @title RequestCoverage
 * @notice Requests coverage from a CoverPool via PolicyManager, creating a policy draft and committee.
 * @dev Corresponds to Document Flow 2 – Covered Vault Deployment and Policy Creation:
 *      2a. Covered Vault requests coverage via PolicyManager with parameters
 *      2b. PolicyManager creates a draft policy for the given CoveredVault
 *
 *      And Flow 3 – Committee Creation:
 *      3a. StakeManager creates a dedicated committee with committeeId = policyId
 *      3b. SSPRouter deploys Duration Vaults for acceptable tokens on EigenLayer
 *
 * Usage:
 *   forge script script/testing/RequestCoverage.s.sol:RequestCoverage \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - BUYER_PRIVATE_KEY: Private key of the coverage buyer (covered vault / adapter)
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - COVER_POOL: CoverPool address to request coverage from
 *   - BENEFICIARY: Address to receive claim payouts
 *   - CLAIMER: Address authorized to trigger claims
 *   - PAYOUT_TOKEN: ERC20 token for claim payouts
 *   - COVERAGE_AMOUNT: Coverage amount (stake requirement in USD with 8 decimals)
 *   - DURATION: Coverage duration in seconds (e.g. 2592000 = 30 days)
 *   - BIND_POLICY_HOOK: Callback contract invoked when policy is bound (e.g. adapter address)
 *
 * Prerequisites:
 *   - CoverPool must exist in the CoverPoolFactory registry
 *   - Buyer must have funds for premium payments (collected separately)
 *   - bindPolicyHook must implement IBindPolicyHook interface
 *   - PAYOUT_TOKEN must be whitelisted on PolicyManager via setSupportedPayoutToken(); run:
 *       cast send $POLICY_MANAGER "setSupportedPayoutToken(address,bool)" \
 *         $PAYOUT_TOKEN true --private-key $ADMIN_PRIVATE_KEY --rpc-url $RPC_URL
 */
contract RequestCoverage is Script {
    /// @notice Buyer address derived from private key
    address public buyer;

    /// @notice Buyer's private key for signing transactions
    uint256 public buyerPrivateKey;

    /// @notice PolicyManager proxy address
    address public policyManager;

    /// @notice CoverPoolFactory proxy address
    address public coverPoolFactory;

    /// @notice CoverPool to request coverage from
    address public coverPool;

    /// @notice Beneficiary address for claim payouts
    address public beneficiary;

    /// @notice Claimer address authorized to trigger claims
    address public claimer;

    /// @notice ERC20 token for payouts
    address public payoutToken;

    /// @notice Coverage amount (stake requirement, USD 8 decimals)
    uint256 public coverageAmount;

    /// @notice Coverage duration in seconds
    uint32 public duration;

    /// @notice Callback invoked when policy is bound
    address public bindPolicyHook;

    /// @notice PolicyManager contract instance
    IPolicyManager public policyManagerContract;

    /// @notice CoverPoolFactory contract instance
    ICoverPoolFactory public factoryContract;

    /// @notice Emitted when coverage is requested
    event CoverageRequestCreated(
        uint96 indexed policyId, address indexed pool, address indexed buyer, uint256 coverageAmount, uint32 duration
    );

    constructor() {
        buyerPrivateKey = vm.envUint("BUYER_PRIVATE_KEY");
        buyer = vm.addr(buyerPrivateKey);

        policyManager = vm.envAddress("POLICY_MANAGER");
        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        coverPool = vm.envAddress("COVER_POOL");
        beneficiary = vm.envAddress("BENEFICIARY");
        claimer = vm.envAddress("CLAIMER");
        payoutToken = vm.envAddress("PAYOUT_TOKEN");
        coverageAmount = vm.envUint("COVERAGE_AMOUNT");
        duration = uint32(vm.envUint("DURATION"));
        bindPolicyHook = vm.envAddress("BIND_POLICY_HOOK");

        policyManagerContract = IPolicyManager(policyManager);
        factoryContract = ICoverPoolFactory(coverPoolFactory);
    }

    function run() external {
        console.log("=== FLOW 2-3: REQUEST COVERAGE & COMMITTEE CREATION ===");
        console.log("Buyer:", buyer);
        console.log("PolicyManager:", policyManager);
        console.log("CoverPool:", coverPool);
        console.log("Beneficiary:", beneficiary);
        console.log("Claimer:", claimer);
        console.log("Payout Token:", payoutToken);
        console.log("Coverage Amount:", coverageAmount);
        console.log("Duration (seconds):", duration);
        console.log("BindPolicyHook:", bindPolicyHook);

        _verifyPoolExists();
        _verifyPayoutTokenSupported();

        vm.startBroadcast(buyerPrivateKey);

        uint96 policyId = policyManagerContract.requestCoverage(
            coverPool, beneficiary, claimer, payoutToken, coverageAmount, duration, bindPolicyHook
        );

        vm.stopBroadcast();

        console.log("\n--- Result ---");
        console.log("Policy ID:", policyId);

        _verifyDraft(policyId);

        console.log("\n=== COVERAGE REQUEST & COMMITTEE CREATION COMPLETED ===");
        console.log("Committee ID (same as Policy ID):", policyId);
        console.log("Next: Restakers delegate to Duration Vaults, then curator binds policy");
        emit CoverageRequestCreated(policyId, coverPool, buyer, coverageAmount, duration);
    }

    function _verifyPoolExists() internal view {
        bool exists = factoryContract.coverPoolExists(coverPool);
        console.log("CoverPool exists:", exists);
        require(exists, "CoverPool not found in factory");
    }

    function _verifyPayoutTokenSupported() internal view {
        bool supported = policyManagerContract.supportedPayoutTokens(payoutToken);
        console.log("Payout token whitelisted:", supported);
        require(
            supported,
            string.concat(
                "Payout token not whitelisted on PolicyManager. Run: cast send $POLICY_MANAGER ",
                "\"setSupportedPayoutToken(address,bool)\" $PAYOUT_TOKEN true --private-key $ADMIN_PRIVATE_KEY"
            )
        );
    }

    function _verifyDraft(uint96 policyId) internal view {
        console.log("\n--- Draft Verification ---");

        IPolicyManager.PolicyDraft memory draft = policyManagerContract.getPolicyDraft(policyId);

        console.log("Draft pool:", draft.pool);
        require(draft.pool == coverPool, "Draft pool mismatch");

        console.log("Draft buyer:", draft.buyer);
        require(draft.buyer == buyer, "Draft buyer mismatch");

        console.log("Draft beneficiary:", draft.beneficiary);
        require(draft.beneficiary == beneficiary, "Draft beneficiary mismatch");

        console.log("Draft claimer:", draft.claimer);
        require(draft.claimer == claimer, "Draft claimer mismatch");

        console.log("Draft payoutToken:", draft.payoutToken);
        require(draft.payoutToken == payoutToken, "Draft payoutToken mismatch");

        console.log("Draft coverageAmount:", draft.coverageAmount);
        require(draft.coverageAmount == coverageAmount, "Draft coverageAmount mismatch");

        console.log("Draft duration:", draft.duration);
        require(draft.duration == duration, "Draft duration mismatch");

        console.log("Draft status:", uint8(draft.status));
        require(draft.status == IPolicyManager.PolicyStatus.Created, "Draft status not Created");

        console.log("Draft bindPolicyHook:", draft.bindPolicyHook);
        require(draft.bindPolicyHook == bindPolicyHook, "Draft bindPolicyHook mismatch");

        console.log("[SUCCESS] Policy draft verified");
    }
}

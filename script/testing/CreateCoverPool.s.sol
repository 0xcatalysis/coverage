// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

/// @dev Minimal EigenLayer DelegationManager interface used only for operator registration.
interface IDelegationManager {
    function registerAsOperator(
        address delegationApprover,
        uint32 allocationDelay,
        string calldata metadataURI
    )
        external;
    function isOperator(address operator) external view returns (bool);
}

/**
 * @title CreateCoverPool
 * @notice Creates a CoverPool via CoverPoolFactory and registers the curator as an operator.
 * @dev Corresponds to Document Flow 1 – CoverPool Creation:
 *      1a. Curator creates a CoverPool from CoverPoolFactory
 *      1b. CoverPool curator registers itself as the operator of Catalysis AVS/Network
 *
 * Usage:
 *   forge script script/testing/CreateCoverPool.s.sol:CreateCoverPool \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - CURATOR_PRIVATE_KEY: Private key of the curator (will be pool owner/operator)
 *   - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *   - QUOTE_SIGNER: Address authorized to sign coverage quotes
 *   - POOL_FEE_BPS: Pool fee in basis points (e.g. 1000 = 10%, max 2000 = 20%)
 *
 * Optional Environment Variables (EigenLayer operator registration):
 *   - EIGEN_DELEGATION_MANAGER: EigenLayer DelegationManager address. When set,
 *     the script also registers the curator as an EigenLayer operator, which is a
 *     prerequisite for PrepareBindPolicy and BindPolicy flows.
 *   - DELEGATION_APPROVER: Address that must approve delegations (default: address(0)).
 *   - ALLOCATION_DELAY: Delay in blocks before EigenLayer allocations take effect
 *     (default: 0).
 *   - METADATA_URI: Operator metadata URI emitted in EigenLayer (default: "").
 *
 * Prerequisites:
 *   - Curator must have CREATOR_ROLE on CoverPoolFactory (or caller must be the CREATOR)
 *   - For EigenLayer operators: curator must be registered in the EigenLayer DelegationManager
 */
contract CreateCoverPool is Script {
    /// @notice Curator address derived from private key
    address public curator;

    /// @notice Curator's private key for signing transactions
    uint256 public curatorPrivateKey;

    /// @notice CoverPoolFactory proxy address
    address public coverPoolFactory;

    /// @notice Quote signer address
    address public quoteSigner;

    /// @notice Pool fee in basis points
    uint16 public poolFeeBps;

    /// @notice EigenLayer DelegationManager address (optional; triggers EL registration)
    address public eigenDelegationManager;

    /// @notice EigenLayer delegation approver (optional; default zero address)
    address public delegationApprover;

    /// @notice EigenLayer allocation delay in blocks (optional; default 0)
    uint32 public allocationDelay;

    /// @notice EigenLayer operator metadata URI (optional)
    string public metadataURI;

    /// @notice CoverPoolFactory contract instance
    ICoverPoolFactory public factoryContract;

    /// @notice Emitted when cover pool is created
    event CoverPoolCreated(address indexed coverPool, address indexed curator, address quoteSigner, uint16 poolFeeBps);

    constructor() {
        curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        curator = vm.addr(curatorPrivateKey);

        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        quoteSigner = vm.envAddress("QUOTE_SIGNER");
        poolFeeBps = uint16(vm.envUint("POOL_FEE_BPS"));

        // EigenLayer registration params (all optional)
        eigenDelegationManager = vm.envOr("EIGEN_DELEGATION_MANAGER", address(0));
        delegationApprover = vm.envOr("DELEGATION_APPROVER", address(0));
        allocationDelay = uint32(vm.envOr("ALLOCATION_DELAY", uint256(0)));
        metadataURI = vm.envOr("METADATA_URI", string(""));

        factoryContract = ICoverPoolFactory(coverPoolFactory);
    }

    function run() external {
        console.log("=== FLOW 1: COVER POOL CREATION ===");
        console.log("Curator:", curator);
        console.log("CoverPoolFactory:", coverPoolFactory);
        console.log("Quote Signer:", quoteSigner);
        console.log("Pool Fee BPS:", poolFeeBps);

        // ------------------------------------------------------------------
        // Optional: register curator as an EigenLayer operator
        // ------------------------------------------------------------------
        if (eigenDelegationManager != address(0)) {
            _registerEigenLayerOperator();
        }

        // ------------------------------------------------------------------
        // Create the CoverPool
        // ------------------------------------------------------------------
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator, quoteSigner: quoteSigner, poolFeeBps: poolFeeBps
        });

        // Predict the deterministic address before creation
        address predictedPool = factoryContract.computeCoverPoolAddress(params);
        console.log("Predicted Pool Address:", predictedPool);

        uint256 totalPoolsBefore = factoryContract.totalCoverPools();
        console.log("Total Pools Before:", totalPoolsBefore);

        vm.startBroadcast(curatorPrivateKey);

        factoryContract.createCoverPool(params);

        vm.stopBroadcast();

        _verifyCreation(predictedPool, totalPoolsBefore);

        console.log("\n=== COVER POOL CREATION COMPLETED ===");
        emit CoverPoolCreated(predictedPool, curator, quoteSigner, poolFeeBps);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /**
     * @dev Registers the curator as an EigenLayer operator if not already registered.
     *      Requires EIGEN_DELEGATION_MANAGER to be set.
     */
    function _registerEigenLayerOperator() internal {
        console.log("\n--- EigenLayer Operator Registration ---");
        console.log("DelegationManager:", eigenDelegationManager);

        IDelegationManager dm = IDelegationManager(eigenDelegationManager);

        bool alreadyRegistered = dm.isOperator(curator);
        if (alreadyRegistered) {
            console.log("[SKIP] Curator is already an EigenLayer operator");
            return;
        }

        console.log("Registering curator as EigenLayer operator...");
        console.log("  Delegation Approver:", delegationApprover);
        console.log("  Allocation Delay:", allocationDelay);
        console.log("  Metadata URI:", metadataURI);

        vm.startBroadcast(curatorPrivateKey);
        dm.registerAsOperator(delegationApprover, allocationDelay, metadataURI);
        vm.stopBroadcast();

        require(dm.isOperator(curator), "EigenLayer operator registration failed");
        console.log("[SUCCESS] Curator registered as EigenLayer operator");
    }

    function _verifyCreation(address predictedPool, uint256 totalPoolsBefore) internal view {
        console.log("\n--- Verification ---");

        uint256 totalPoolsAfter = factoryContract.totalCoverPools();
        console.log("Total Pools After:", totalPoolsAfter);
        require(totalPoolsAfter == totalPoolsBefore + 1, "Pool count did not increase");

        bool exists = factoryContract.coverPoolExists(predictedPool);
        console.log("Pool exists in factory:", exists);
        require(exists, "Pool not found in factory");

        ICoverPool pool = ICoverPool(predictedPool);
        address owner = pool.owner();
        console.log("Pool owner (curator):", owner);
        require(owner == curator, "Pool owner mismatch");

        uint16 fee = pool.poolFeeBps();
        console.log("Pool fee BPS:", fee);
        require(fee == poolFeeBps, "Pool fee mismatch");

        console.log("[SUCCESS] CoverPool created and verified");
    }
}

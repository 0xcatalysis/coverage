// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

/**
 * @title CreateCoverPool
 * @notice Creates a CoverPool via CoverPoolFactory.
 * @dev Corresponds to Document Flow 1 – CoverPool Creation:
 *      1a. Curator creates a CoverPool from CoverPoolFactory
 *
 *      On EigenLayer, duration vaults act as operators -- the curator does NOT need to call
 *      registerAsOperator. Duration vaults are auto-deployed by SSPRouter.createCommittee()
 *      and register themselves as EigenLayer operators during deployment.
 *      Symbiotic operator registration (out of scope for e2e testing) is handled separately.
 *
 *      Ownership: The CoverPool owner (curator) is set at creation time and cannot be changed
 *      post-deployment. CURATOR_ADDRESS MUST be the intended long-term owner of the pool — on
 *      mainnet this should be a multisig, not the deployer EOA. The broadcaster (--keystore
 *      signer) only needs CREATOR_ROLE on CoverPoolFactory; it does not become the pool owner.
 *
 * Usage:
 *   forge script script/testing/CreateCoverPool.s.sol:CreateCoverPool \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS:          Public address of the keystore signer (used with --keystore flag).
 *   - COVER_POOL_FACTORY:        CoverPoolFactory proxy address
 *   - QUOTE_SIGNER:              Address authorized to sign coverage quotes
 *   - POOL_FEE_BPS:              Pool fee in basis points (e.g. 500 = 5%, max 2000 = 20%)
 *
 * Optional Environment Variables:
 *   - CURATOR_ADDRESS:           CoverPool owner/curator. Defaults to DEPLOYER_ADDRESS. Set to a
 *                                multisig for production — the pool owner is immutable post-deploy.
 *   - COVER_POOL_FACTORY_CREATOR: Holder of CREATOR_ROLE on CoverPoolFactory. Defaults to ADMIN,
 *                                then DEPLOYER_ADDRESS. On mainnet this is the multisig — omit
 *                                --broadcast and submit the calldata via Safe.
 *
 * Prerequisites:
 *   - COVER_POOL_FACTORY_CREATOR (or ADMIN) must hold CREATOR_ROLE on CoverPoolFactory
 */
contract CreateCoverPool is Script {
    /// @notice CoverPool owner — set at creation time, immutable post-deploy.
    address public curator;

    /// @notice Address of the keystore signer that broadcasts the transaction.
    address public deployer;

    /// @notice Holder of CREATOR_ROLE on CoverPoolFactory. Defaults to ADMIN then deployer.
    address public creator;

    /// @notice CoverPoolFactory proxy address
    address public coverPoolFactory;

    /// @notice Quote signer address
    address public quoteSigner;

    /// @notice Pool fee in basis points
    uint16 public poolFeeBps;

    /// @notice CoverPoolFactory contract instance
    ICoverPoolFactory public factoryContract;

    /// @notice Emitted when cover pool is created
    event CoverPoolCreated(address indexed coverPool, address indexed curator, address quoteSigner, uint16 poolFeeBps);

    constructor() {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // Pool owner: defaults to deployer so existing testnet flows need no change,
        // but on mainnet set CURATOR_ADDRESS to a multisig so the hot signer never
        // owns the pool.
        curator = vm.envOr("CURATOR_ADDRESS", deployer);

        // CREATOR_ROLE holder: after coverage deploy with ADMIN != deployer, ADMIN holds this role.
        // On mainnet ADMIN is the multisig; omit --broadcast and submit the calldata via Safe.
        address admin = vm.envOr("ADMIN", deployer);
        creator = vm.envOr("COVER_POOL_FACTORY_CREATOR", admin);

        coverPoolFactory = vm.envAddress("COVER_POOL_FACTORY");
        quoteSigner = vm.envAddress("QUOTE_SIGNER");
        poolFeeBps = uint16(vm.envUint("POOL_FEE_BPS"));

        require(curator != address(0), "CURATOR_ADDRESS must not be zero address");
        factoryContract = ICoverPoolFactory(coverPoolFactory);
    }

    function run() external {
        console.log("=== FLOW 1: COVER POOL CREATION ===");
        console.log("Keystore signer (deployer):", deployer);
        console.log("Broadcaster (CREATOR_ROLE holder):", creator);
        console.log("Curator (pool owner):", curator);
        console.log("CoverPoolFactory:", coverPoolFactory);
        console.log("Quote Signer:", quoteSigner);
        console.log("Pool Fee BPS:", poolFeeBps);

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

        vm.startBroadcast(creator);

        factoryContract.createCoverPool(params);

        vm.stopBroadcast();

        _verifyCreation(predictedPool, totalPoolsBefore);

        console.log("\n=== COVER POOL CREATION COMPLETED ===");
        emit CoverPoolCreated(predictedPool, curator, quoteSigner, poolFeeBps);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

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

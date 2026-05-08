// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

/// @dev Minimal view interfaces — no full imports needed.
interface IAccessControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IPausable {
    function paused() external view returns (bool);
}

interface IStakeManagerView {
    function coverPoolFactory() external view returns (address);
    function router() external view returns (address);
}

interface ISlashingManagerView {
    function claimManager() external view returns (address);
    function sspRouter() external view returns (address);
    function stakeManager() external view returns (address);
}

interface IRewardsManagerView {
    function premiumManager() external view returns (address);
    function sspRouter() external view returns (address);
}

interface ISSPRouterView {
    function stakeManager() external view returns (address);
    function rewardsManager() external view returns (address);
    function slashingManager() external view returns (address);
    // moduleType: 1 = EIGENLAYER, 2 = SYMBIOTIC
    function getAdapter(uint8 moduleType) external view returns (address);
    function getVaultModule(address vault) external view returns (uint8);
}

interface IOraclePriceFeedView {
    function getUSDValue(address token, uint256 amount) external view returns (uint256);
}

interface IAdapterView {
    function chainlinkPriceFeed() external view returns (address);
}

interface IPolicyManagerView {
    function stakeManager() external view returns (address);
    function oraclePriceFeed() external view returns (address);
}

interface IClaimManagerView {
    function slashingManager() external view returns (address);
    function premiumManager() external view returns (address);
    function oraclePriceFeed() external view returns (address);
    function priceDeviationToleranceBps() external view returns (uint16);
}

interface IPremiumManagerView {
    function rewardsManager() external view returns (address);
    function CLAIM_MANAGER_ROLE() external view returns (bytes32);
}

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

interface ICoverPoolFactoryView {
    function stakeManager() external view returns (address);
}

/**
 * @title VerifySepoliaConfig
 * @notice Reads and prints the live on-chain configuration of all Sepolia contracts,
 *         verifying every cross-contract wiring and ACL needed for each E2E testing flow.
 *
 * @dev Run view-only; no transactions are broadcast.
 *
 *      Coverage:
 *        Flow 1  – CreateCoverPool:       CoverPoolFactory not paused, stakeManager wired
 *        Flow 2-3– RequestCoverage:       StakeManager roles + wiring, SSPRouter adapters
 *        Flow 4  – PrepareBindPolicy:     Adapter oraclePriceFeed, SSPRouter adapters
 *        Flow 5  – BindPolicy:            SSPRouter vault module registration
 *        Flow 6-7– DistributePremium:     RewardsManager wiring + PREMIUM_MANAGER_ROLE
 *        Flow 8  – FileClaim:             SlashingManager wiring + ClaimManager↔PremiumManager
 *
 *      Output:
 *        [OK]   – value matches expected
 *        [FAIL] – misconfigured; must be fixed before testing
 *
 *      Usage:
 *        forge script script/VerifySepoliaConfig.s.sol --rpc-url $SEPOLIA_RPC_URL
 */
contract VerifySepoliaConfig is Script {
    // ── Coverage contracts
    // ──────────────────────────────────────────────────
    address internal constant COVER_POOL_FACTORY = 0x43c1AC362f88f461d2CF358D6fF76C833585B830;
    address internal constant POLICY_MANAGER = 0x48Ded2CB83623d5dE7D51Eab045A452bA70C2A35;
    address internal constant CLAIM_MANAGER = 0x568191F923C10A5447d8349eFD63687836D52099;
    address internal constant PREMIUM_MANAGER = 0xD75357f1AA43d87edA20A128D1A525FF320cB743;

    // ── Core contracts
    // ──────────────────────────────────────────────────────
    address internal constant STAKE_MANAGER = 0xF26d310D98b9eB0B20d96B605d9Af15bC31f5c32;
    address internal constant SLASHING_MANAGER = 0xF397bbFDB272b31366D472Fcdbf4DC0982ec8714;
    address internal constant REWARDS_MANAGER = 0x6A0823fC61F970BB8a52cF95BfB8F32265Ada8b8;
    address internal constant SSP_ROUTER = 0xf68c72E92f9BdB7Cdba2AF4026Bab8DC22781148;
    address internal constant EIGEN_ADAPTER = 0xB4bB09dcE1C1D9d987D5dc0dC2c8770D4fbBD49b;
    address internal constant ORACLE_PRICE_FEED = 0x2b48F18f73C66075168b727524c99aFE12814417;

    // ── Known E2E vault (EigenLayer wstETH DurationVaultStrategy, deployed by SSPRouter) ──
    address internal constant WSTETH_EL_STRATEGY = 0x7db0C347645bE3E19Af87d72E6220361cdD2428D;

    // ── Reference token
    // ─────────────────────────────────────────────────────
    address internal constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    // ── Roles
    // ────────────────────────────────────────────────────────────────
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    bytes32 internal constant CLAIM_MANAGER_ROLE = keccak256("CLAIM_MANAGER_ROLE");
    bytes32 internal constant PREMIUM_MANAGER_ROLE = keccak256("PREMIUM_MANAGER_ROLE");

    // ── SSPRouter module type enum values (ISSPRouter.SSPModuleType) ─────────
    uint8 internal constant MODULE_EIGENLAYER = 2;

    uint256 internal _failures;

    function run() external {
        require(block.chainid == 11_155_111, "Must run on Sepolia");

        console2.log("=== VerifySepoliaConfig ===");
        console2.log("Block:", block.number);
        console2.log("");

        _checkFlow1_createCoverPool();
        _checkFlow2_3_requestCoverage();
        _checkFlow4_prepareBindPolicy();
        _checkFlow5_bindPolicy();
        _checkFlow6_7_distributePremium();
        _checkFlow8_fileClaim();

        console2.log("");
        if (_failures == 0) {
            console2.log("[ALL OK] All", uint256(27), "checks passed. Configuration is complete for E2E testing.");
        } else {
            console2.log("[INCOMPLETE]", _failures, "check(s) failed. See [FAIL] lines above.");
            console2.log("  Fix: run cast send commands in docs/deployment/CoreAdminActions-Sepolia.md");
        }
        console2.log("=========================================");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 1 – CreateCoverPool
    //  Requires: CoverPoolFactory not paused, stakeManager set to new core
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow1_createCoverPool() internal {
        console2.log("--- Flow 1: CreateCoverPool ---");

        _checkFalse("CoverPoolFactory not paused", IPausable(COVER_POOL_FACTORY).paused());
        _check("CoverPoolFactory.stakeManager", ICoverPoolFactoryView(COVER_POOL_FACTORY).stakeManager(), STAKE_MANAGER);

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 2-3 – RequestCoverage
    //  Requires: StakeManager POLICY_MANAGER_ROLE, coverPoolFactory, router
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow2_3_requestCoverage() internal {
        console2.log("--- Flows 2-3: RequestCoverage ---");

        _check("PolicyManager.stakeManager", IPolicyManagerView(POLICY_MANAGER).stakeManager(), STAKE_MANAGER);
        _checkRole(
            "StakeManager: POLICY_MANAGER_ROLE -> PolicyManager", STAKE_MANAGER, POLICY_MANAGER_ROLE, POLICY_MANAGER
        );
        _check("StakeManager.coverPoolFactory", IStakeManagerView(STAKE_MANAGER).coverPoolFactory(), COVER_POOL_FACTORY);
        _check("StakeManager.router", IStakeManagerView(STAKE_MANAGER).router(), SSP_ROUTER);
        // SSPRouter must have EigenLayer adapter so createCommittee can deploy operator sets
        _check(
            "SSPRouter.getAdapter(EIGENLAYER)", ISSPRouterView(SSP_ROUTER).getAdapter(MODULE_EIGENLAYER), EIGEN_ADAPTER
        );

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 4 – PrepareBindPolicy
    //  Requires: SSPRouter EigenLayer adapter, price feed on EigenAdapter
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow4_prepareBindPolicy() internal {
        console2.log("--- Flow 4: PrepareBindPolicy ---");

        _check(
            "SSPRouter.getAdapter(EIGENLAYER)", ISSPRouterView(SSP_ROUTER).getAdapter(MODULE_EIGENLAYER), EIGEN_ADAPTER
        );
        _check("EigenAdapter.chainlinkPriceFeed", IAdapterView(EIGEN_ADAPTER).chainlinkPriceFeed(), ORACLE_PRICE_FEED);

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 5 – BindPolicy
    //  Requires: vault module registered in SSPRouter (for addCommitteeVaults)
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow5_bindPolicy() internal {
        console2.log("--- Flow 5: BindPolicy ---");

        _check("PolicyManager.oraclePriceFeed", IPolicyManagerView(POLICY_MANAGER).oraclePriceFeed(), ORACLE_PRICE_FEED);

        // addCommitteeVaults checks getVaultModule != NONE for each vault
        uint8 module = ISSPRouterView(SSP_ROUTER).getVaultModule(WSTETH_EL_STRATEGY);
        if (module == MODULE_EIGENLAYER) {
            console2.log("[OK] SSPRouter.getVaultModule(WSTETH_EL_STRATEGY): EIGENLAYER (2)");
        } else if (module == 0) {
            console2.log("[FAIL] SSPRouter.getVaultModule(WSTETH_EL_STRATEGY): NONE -- vault not registered");
            console2.log("  Fix: SSPRouter.registerVaultModule(WSTETH_EL_STRATEGY, EIGENLAYER=2)");
            _failures++;
        } else {
            console2.log("[FAIL] SSPRouter.getVaultModule(WSTETH_EL_STRATEGY): unexpected module type:", module);
            _failures++;
        }

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flows 6-7 – DistributePremium
    //  Requires: PremiumManager → RewardsManager address + PREMIUM_MANAGER_ROLE
    //  Requires: PremiumManager has approved RewardsManager for WETH (via approveSpender)
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow6_7_distributePremium() internal {
        console2.log("--- Flows 6-7: DistributePremium ---");

        _check("PremiumManager.rewardsManager", IPremiumManagerView(PREMIUM_MANAGER).rewardsManager(), REWARDS_MANAGER);

        uint256 allowance = IERC20Allowance(WETH).allowance(PREMIUM_MANAGER, REWARDS_MANAGER);
        if (allowance == type(uint256).max) {
            console2.log("[OK] PremiumManager.allowance(WETH, RewardsManager): unlimited");
        } else if (allowance > 0) {
            console2.log("[OK] PremiumManager.allowance(WETH, RewardsManager):", allowance);
        } else {
            console2.log("[FAIL] PremiumManager has not approved RewardsManager for WETH");
            console2.log("  Fix: PremiumManager.approveSpender(WETH, RewardsManager, type(uint256).max)");
            _failures++;
        }
        _checkRole(
            "RewardsManager: PREMIUM_MANAGER_ROLE -> PremiumManager",
            REWARDS_MANAGER,
            PREMIUM_MANAGER_ROLE,
            PREMIUM_MANAGER
        );
        _check("RewardsManager.premiumManager", IRewardsManagerView(REWARDS_MANAGER).premiumManager(), PREMIUM_MANAGER);
        _check("RewardsManager.sspRouter", IRewardsManagerView(REWARDS_MANAGER).sspRouter(), SSP_ROUTER);
        _check("SSPRouter.rewardsManager", ISSPRouterView(SSP_ROUTER).rewardsManager(), REWARDS_MANAGER);

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 8 – FileClaim
    //  Requires: ClaimManager → SlashingManager address + CLAIM_MANAGER_ROLE,
    //            SlashingManager → SSPRouter + StakeManager
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow8_fileClaim() internal {
        console2.log("--- Flow 8: FileClaim ---");

        _check("ClaimManager.slashingManager", IClaimManagerView(CLAIM_MANAGER).slashingManager(), SLASHING_MANAGER);
        _check("ClaimManager.premiumManager", IClaimManagerView(CLAIM_MANAGER).premiumManager(), PREMIUM_MANAGER);
        _check("ClaimManager.oraclePriceFeed", IClaimManagerView(CLAIM_MANAGER).oraclePriceFeed(), ORACLE_PRICE_FEED);
        uint16 toleranceBps = IClaimManagerView(CLAIM_MANAGER).priceDeviationToleranceBps();
        if (toleranceBps > 0) {
            console2.log("[OK] ClaimManager.priceDeviationToleranceBps:", toleranceBps, "bps");
        } else {
            console2.log("[FAIL] ClaimManager.priceDeviationToleranceBps is 0 -- initializeV2 not called?");
            _failures++;
        }
        _checkRole(
            "PremiumManager: CLAIM_MANAGER_ROLE -> ClaimManager",
            PREMIUM_MANAGER,
            IPremiumManagerView(PREMIUM_MANAGER).CLAIM_MANAGER_ROLE(),
            CLAIM_MANAGER
        );
        _checkRole(
            "SlashingManager: CLAIM_MANAGER_ROLE -> ClaimManager", SLASHING_MANAGER, CLAIM_MANAGER_ROLE, CLAIM_MANAGER
        );
        _check("SlashingManager.claimManager", ISlashingManagerView(SLASHING_MANAGER).claimManager(), CLAIM_MANAGER);
        _check("SlashingManager.sspRouter", ISlashingManagerView(SLASHING_MANAGER).sspRouter(), SSP_ROUTER);
        _check("SlashingManager.stakeManager", ISlashingManagerView(SLASHING_MANAGER).stakeManager(), STAKE_MANAGER);
        _check("SSPRouter.slashingManager", ISSPRouterView(SSP_ROUTER).slashingManager(), SLASHING_MANAGER);
        _check("SSPRouter.stakeManager", ISSPRouterView(SSP_ROUTER).stakeManager(), STAKE_MANAGER);

        try IOraclePriceFeedView(ORACLE_PRICE_FEED).getUSDValue(WETH, 1e18) returns (uint256 usdValue) {
            if (usdValue > 0) {
                console2.log("[OK] OraclePriceFeed.getUSDValue(WETH, 1e18):", usdValue, "(USD, 8 dec)");
            } else {
                console2.log("[FAIL] OraclePriceFeed.getUSDValue(WETH) returned 0 -- WETH feed not registered");
                _failures++;
            }
        } catch {
            console2.log("[FAIL] OraclePriceFeed.getUSDValue(WETH) reverted -- WETH feed not registered");
            _failures++;
        }

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _check(string memory label, address got, address expected) internal {
        if (got == expected) {
            console2.log("[OK]", label, ":", got);
        } else {
            console2.log("[FAIL]", label);
            console2.log("      expected:", expected);
            console2.log("      got:     ", got);
            _failures++;
        }
    }

    function _checkRole(string memory label, address contractAddr, bytes32 role, address account) internal {
        bool granted = IAccessControl(contractAddr).hasRole(role, account);
        if (granted) {
            console2.log("[OK]", label);
        } else {
            console2.log("[FAIL]", label, "(role not granted)");
            _failures++;
        }
    }

    /// @dev Asserts `condition` is false (e.g. paused() == false).
    function _checkFalse(string memory label, bool condition) internal {
        if (!condition) {
            console2.log("[OK]", label);
        } else {
            console2.log("[FAIL]", label, "(should be false)");
            _failures++;
        }
    }
}

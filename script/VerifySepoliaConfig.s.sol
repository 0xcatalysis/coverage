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

interface IChainlinkPriceFeedView {
    function getUSDValue(address token, uint256 amount) external view returns (uint256);
}

interface IAdapterView {
    function chainlinkPriceFeed() external view returns (address);
}

interface IPolicyManagerView {
    function stakeManager() external view returns (address);
}

interface IClaimManagerView {
    function slashingManager() external view returns (address);
    function chainlinkPriceFeed() external view returns (address);
}

interface IPremiumManagerView {
    function rewardsManager() external view returns (address);
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
 *        Flow 4  – PrepareBindPolicy:     Adapter chainlinkPriceFeed, SSPRouter adapters
 *        Flow 5  – BindPolicy:            SSPRouter vault module registration
 *        Flow 6-7– DistributePremium:     RewardsManager wiring + PREMIUM_MANAGER_ROLE
 *        Flow 8  – FileClaim:             SlashingManager wiring + CLAIM_MANAGER_ROLE + price feed
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
    address internal constant COVER_POOL_FACTORY = 0x99E28c60FA0C0476fb867Cf5b5663b6bcC1C923E;
    address internal constant POLICY_MANAGER = 0xaA254C2C00F1dF3635e47F51cA1fe1fD04335742;
    address internal constant CLAIM_MANAGER = 0xecB428fe7895377EFfE2Bf9189d24e34a8Bdf9A6;
    address internal constant PREMIUM_MANAGER = 0x746DAa7Eb8D2a4407C19b4D9Cc2Cd6B839dbB720;

    // ── Core contracts
    // ──────────────────────────────────────────────────────
    address internal constant STAKE_MANAGER = 0x3dB3ca70f23CeF23c7fEDB36dF6019B5ECB5Cb0c;
    address internal constant SLASHING_MANAGER = 0x4609a19E40f8262b3E42dEC45AACf18961fd4143;
    address internal constant REWARDS_MANAGER = 0xF4cdFcD4bb8c1ABa3F79AFF9303429cAf79052a9;
    address internal constant SSP_ROUTER = 0xc2F3906Bb57c8Db7DF2DddF0f2CEc521fE6834f8;
    address internal constant EIGEN_ADAPTER = 0xA28871e253C972A96003D3f432CA4170f4ae2A78;
    address internal constant SYMBIOTIC_ADAPTER = 0x533115b15C3c41e42652c35694a20eb6F7b2cbD2;
    address internal constant CHAINLINK_PRICE_FEED = 0x2c0334283E06839Eb9Ab01f091Dca4A98443d120;

    // ── Known E2E vault (EigenLayer WETH DurationVaultStrategy, deployed by SSPRouter) ──
    address internal constant WETH_EL_STRATEGY = 0x424246eF71b01ee33aA33aC590fd9a0855F5eFbc;

    // ── Reference token
    // ─────────────────────────────────────────────────────
    address internal constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    // ── Roles
    // ────────────────────────────────────────────────────────────────
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    bytes32 internal constant CLAIM_MANAGER_ROLE = keccak256("CLAIM_MANAGER_ROLE");
    bytes32 internal constant PREMIUM_MANAGER_ROLE = keccak256("PREMIUM_MANAGER_ROLE");

    // ── SSPRouter module type enum values (ISSPRouter.SSPModuleType) ─────────
    uint8 internal constant MODULE_SYMBIOTIC = 1;
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
            console2.log("[ALL OK] All", uint256(26), "checks passed. Configuration is complete for E2E testing.");
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
    //  Requires: SSPRouter adapters, price feeds on both adapters
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow4_prepareBindPolicy() internal {
        console2.log("--- Flow 4: PrepareBindPolicy ---");

        _check(
            "SSPRouter.getAdapter(EIGENLAYER)", ISSPRouterView(SSP_ROUTER).getAdapter(MODULE_EIGENLAYER), EIGEN_ADAPTER
        );
        _check(
            "SSPRouter.getAdapter(SYMBIOTIC)",
            ISSPRouterView(SSP_ROUTER).getAdapter(MODULE_SYMBIOTIC),
            SYMBIOTIC_ADAPTER
        );
        _check(
            "EigenAdapter.chainlinkPriceFeed", IAdapterView(EIGEN_ADAPTER).chainlinkPriceFeed(), CHAINLINK_PRICE_FEED
        );
        _check(
            "SymbioticAdapter.chainlinkPriceFeed",
            IAdapterView(SYMBIOTIC_ADAPTER).chainlinkPriceFeed(),
            CHAINLINK_PRICE_FEED
        );

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 5 – BindPolicy
    //  Requires: vault module registered in SSPRouter (for addCommitteeVaults)
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow5_bindPolicy() internal {
        console2.log("--- Flow 5: BindPolicy ---");

        // addCommitteeVaults checks getVaultModule != NONE for each vault
        uint8 module = ISSPRouterView(SSP_ROUTER).getVaultModule(WETH_EL_STRATEGY);
        if (module == MODULE_EIGENLAYER) {
            console2.log("[OK] SSPRouter.getVaultModule(WETH_EL_STRATEGY): EIGENLAYER (2)");
        } else if (module == 0) {
            console2.log("[FAIL] SSPRouter.getVaultModule(WETH_EL_STRATEGY): NONE -- vault not registered");
            console2.log("  Fix: SSPRouter.registerVaultModule(WETH_EL_STRATEGY, EIGENLAYER=2)");
            _failures++;
        } else {
            console2.log("[FAIL] SSPRouter.getVaultModule(WETH_EL_STRATEGY): unexpected module type:", module);
            _failures++;
        }

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flows 6-7 – DistributePremium
    //  Requires: PremiumManager → RewardsManager address + PREMIUM_MANAGER_ROLE
    //  Requires: PremiumManager has approved SSPRouter for WETH (via approveSpender)
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow6_7_distributePremium() internal {
        console2.log("--- Flows 6-7: DistributePremium ---");

        _check("PremiumManager.rewardsManager", IPremiumManagerView(PREMIUM_MANAGER).rewardsManager(), REWARDS_MANAGER);

        uint256 allowance = IERC20Allowance(WETH).allowance(PREMIUM_MANAGER, SSP_ROUTER);
        if (allowance == type(uint256).max) {
            console2.log("[OK] PremiumManager.allowance(WETH, SSPRouter): unlimited");
        } else if (allowance > 0) {
            console2.log("[OK] PremiumManager.allowance(WETH, SSPRouter):", allowance);
        } else {
            console2.log("[FAIL] PremiumManager has not approved SSPRouter for WETH");
            console2.log("  Fix: PremiumManager.approveSpender(WETH, SSPRouter, type(uint256).max)");
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
    //            ChainlinkPriceFeed WETH feed, SlashingManager → SSPRouter + StakeManager
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow8_fileClaim() internal {
        console2.log("--- Flow 8: FileClaim ---");

        _check("ClaimManager.slashingManager", IClaimManagerView(CLAIM_MANAGER).slashingManager(), SLASHING_MANAGER);
        _check(
            "ClaimManager.chainlinkPriceFeed",
            IClaimManagerView(CLAIM_MANAGER).chainlinkPriceFeed(),
            CHAINLINK_PRICE_FEED
        );
        _checkRole(
            "SlashingManager: CLAIM_MANAGER_ROLE -> ClaimManager", SLASHING_MANAGER, CLAIM_MANAGER_ROLE, CLAIM_MANAGER
        );
        _check("SlashingManager.claimManager", ISlashingManagerView(SLASHING_MANAGER).claimManager(), CLAIM_MANAGER);
        _check("SlashingManager.sspRouter", ISlashingManagerView(SLASHING_MANAGER).sspRouter(), SSP_ROUTER);
        _check("SlashingManager.stakeManager", ISlashingManagerView(SLASHING_MANAGER).stakeManager(), STAKE_MANAGER);
        _check("SSPRouter.slashingManager", ISSPRouterView(SSP_ROUTER).slashingManager(), SLASHING_MANAGER);
        _check("SSPRouter.stakeManager", ISSPRouterView(SSP_ROUTER).stakeManager(), STAKE_MANAGER);

        try IChainlinkPriceFeedView(CHAINLINK_PRICE_FEED).getUSDValue(WETH, 1e18) returns (uint256 usdValue) {
            if (usdValue > 0) {
                console2.log("[OK] ChainlinkPriceFeed.getUSDValue(WETH, 1e18):", usdValue, "(USD, 8 dec)");
            } else {
                console2.log("[FAIL] ChainlinkPriceFeed.getUSDValue(WETH) returned 0 -- WETH feed not registered");
                _failures++;
            }
        } catch {
            console2.log("[FAIL] ChainlinkPriceFeed.getUSDValue(WETH) reverted -- WETH feed not registered");
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

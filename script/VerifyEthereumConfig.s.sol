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
    function getAdapter(uint8 moduleType) external view returns (address);
    function getVaultModule(address vault) external view returns (uint8);
}

interface IOraclePriceFeedView {
    function getUSDValue(address token, uint256 amount) external view returns (uint256);
    function hasPriceFeed(address token) external view returns (bool);
}

interface IAdapterView {
    function oraclePriceFeed() external view returns (address);
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

interface ISwapperView {
    function claimManager() external view returns (address);
    function PAUSER_ROLE() external view returns (bytes32);
}

/**
 * @title VerifyEthereumConfig
 * @notice Reads and prints the live on-chain configuration of all Ethereum mainnet Coverage
 *         contracts, verifying every cross-contract wiring and ACL needed for full operation.
 *
 * @dev Run view-only; no transactions are broadcast.
 *
 *      Checks include all Sepolia checks plus:
 *        - DEFAULT_ADMIN_ROLE held by TimelockController (not multisig) on coverage proxies
 *        - OraclePriceFeed WETH feed registered (hasPriceFeed + getUSDValue)
 *        - ClaimManager V2 storage initialized (priceDeviationToleranceBps > 0)
 *        - Swapper.claimManager wired (CYS3-06)
 *
 *      Output:
 *        [OK]   – value matches expected
 *        [FAIL] – misconfigured; must be fixed before operation
 *
 *      Optional env vars:
 *        PAUSER: When set, also verifies PAUSER_ROLE is granted to this address on all 6 proxies.
 *
 *      Usage:
 *        forge script script/VerifyEthereumConfig.s.sol --rpc-url $ETHEREUM_RPC_URL
 */
contract VerifyEthereumConfig is Script {
    // ── Coverage contracts (canonical mainnet addresses — CreateX deployment)
    // ─────────────
    address internal constant COVER_POOL_FACTORY = 0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66;
    address internal constant POLICY_MANAGER = 0xfb771BE75365D2a1D32be198e03ce8a2125e2699;
    address internal constant CLAIM_MANAGER = 0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45;
    address internal constant PREMIUM_MANAGER = 0xEc7322D6754709d5001B710ec4fB2547a89B3aD1;
    address internal constant SPEC_REGISTRY = 0x90EfF742958dd4c54ede3ED365375a14077D0A58;
    address internal constant SWAPPER = 0x148Bfe2330cEe4f227addb47736a105DB427dc31;

    // ── Core contracts (canonical mainnet addresses — CreateX deployment)
    // ─────────────────
    address internal constant STAKE_MANAGER = 0x5be5220F81e76e0CF6089fb7E7aE9eF48a8D64Be;
    address internal constant SLASHING_MANAGER = 0x7Bc39bf135eF3c30E542C196719c91455ff489f0;
    address internal constant REWARDS_MANAGER = 0x8ae0F0B94fe782D7F055B04d4699c3cc01632b46;
    address internal constant SSP_ROUTER = 0xF39E592E93A7a925a57464e0120B555A25590486;
    address internal constant EIGEN_ADAPTER = 0xe6168092892E545701D92BEe10149178bE0EEDF4;
    address internal constant ORACLE_PRICE_FEED = 0x57F750E3B8e095A5b3AE96030F0cac5dFe2f8A16;

    // ── Governance
    // ────────────────────────────────────────────────────────────────────────
    address internal constant TIMELOCK = 0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7;
    address internal constant MULTISIG = 0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c;

    // ── Reference token (mainnet WETH)
    // ────────────────────────────────────────────────────
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ── Roles
    // ─────────────────────────────────────────────────────────────────────────────
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    bytes32 internal constant CLAIM_MANAGER_ROLE = keccak256("CLAIM_MANAGER_ROLE");
    bytes32 internal constant PREMIUM_MANAGER_ROLE = keccak256("PREMIUM_MANAGER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ── SSPRouter module type
    // ─────────────────────────────────────────────────────────────
    uint8 internal constant MODULE_EIGENLAYER = 2;

    uint256 internal _failures;

    function run() external {
        require(block.chainid == 1, "Must run on Ethereum mainnet");

        console2.log("=== VerifyEthereumConfig ===");
        console2.log("Block:", block.number);
        console2.log("");

        _checkAdminModel();
        _checkFlow1_createCoverPool();
        _checkFlow2_3_requestCoverage();
        _checkFlow4_prepareBindPolicy();
        _checkFlow5_bindPolicy();
        _checkFlow6_7_distributePremium();
        _checkFlow8_fileClaim();

        address pauser = vm.envOr("PAUSER", address(0));
        if (pauser != address(0)) {
            _checkPauserRole(pauser);
        }

        console2.log("");
        if (_failures == 0) {
            console2.log("[ALL OK] All checks passed. Mainnet configuration is correct.");
        } else {
            console2.log("[INCOMPLETE]", _failures, "check(s) failed. See [FAIL] lines above.");
        }
        console2.log("=========================================");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Admin model
    //  Coverage proxies: TimelockController holds DEFAULT_ADMIN_ROLE
    //  Core proxies: multisig holds DEFAULT_ADMIN_ROLE directly (no Timelock)
    // ─────────────────────────────────────────────────────────────────────────

    function _checkAdminModel() internal {
        console2.log("--- Admin Model ---");

        address[6] memory covProxies =
            [SWAPPER, CLAIM_MANAGER, POLICY_MANAGER, PREMIUM_MANAGER, COVER_POOL_FACTORY, SPEC_REGISTRY];
        string[6] memory covNames =
            ["Swapper", "ClaimManager", "PolicyManager", "PremiumManager", "CoverPoolFactory", "SpecRegistry"];

        for (uint256 i = 0; i < covProxies.length; ++i) {
            _checkRole(
                string.concat(covNames[i], ": DEFAULT_ADMIN_ROLE -> Timelock"),
                covProxies[i],
                DEFAULT_ADMIN_ROLE,
                TIMELOCK
            );
        }

        // Core: DEFAULT_ADMIN_ROLE on multisig (no Timelock for core — confirmed on-chain)
        _checkRole(
            "SlashingManager: DEFAULT_ADMIN_ROLE -> Multisig (core has no Timelock)",
            SLASHING_MANAGER,
            DEFAULT_ADMIN_ROLE,
            MULTISIG
        );

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 1 – CreateCoverPool
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow1_createCoverPool() internal {
        console2.log("--- Flow 1: CreateCoverPool ---");

        _checkFalse("CoverPoolFactory not paused", IPausable(COVER_POOL_FACTORY).paused());
        _check("CoverPoolFactory.stakeManager", ICoverPoolFactoryView(COVER_POOL_FACTORY).stakeManager(), STAKE_MANAGER);

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flows 2-3 – RequestCoverage
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow2_3_requestCoverage() internal {
        console2.log("--- Flows 2-3: RequestCoverage ---");

        _check("PolicyManager.stakeManager", IPolicyManagerView(POLICY_MANAGER).stakeManager(), STAKE_MANAGER);
        _checkRole(
            "StakeManager: POLICY_MANAGER_ROLE -> PolicyManager", STAKE_MANAGER, POLICY_MANAGER_ROLE, POLICY_MANAGER
        );
        _check("StakeManager.coverPoolFactory", IStakeManagerView(STAKE_MANAGER).coverPoolFactory(), COVER_POOL_FACTORY);
        _check("StakeManager.router", IStakeManagerView(STAKE_MANAGER).router(), SSP_ROUTER);
        _check(
            "SSPRouter.getAdapter(EIGENLAYER)", ISSPRouterView(SSP_ROUTER).getAdapter(MODULE_EIGENLAYER), EIGEN_ADAPTER
        );

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 4 – PrepareBindPolicy
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow4_prepareBindPolicy() internal {
        console2.log("--- Flow 4: PrepareBindPolicy ---");

        _check(
            "SSPRouter.getAdapter(EIGENLAYER)", ISSPRouterView(SSP_ROUTER).getAdapter(MODULE_EIGENLAYER), EIGEN_ADAPTER
        );
        _check("EigenAdapter.oraclePriceFeed", IAdapterView(EIGEN_ADAPTER).oraclePriceFeed(), ORACLE_PRICE_FEED);

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flow 5 – BindPolicy
    // ─────────────────────────────────────────────────────────────────────────

    function _checkFlow5_bindPolicy() internal {
        console2.log("--- Flow 5: BindPolicy ---");

        _check("PolicyManager.oraclePriceFeed", IPolicyManagerView(POLICY_MANAGER).oraclePriceFeed(), ORACLE_PRICE_FEED);
        _check("Swapper.claimManager", ISwapperView(SWAPPER).claimManager(), CLAIM_MANAGER);

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Flows 6-7 – DistributePremium
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
            console2.log("[FAIL] ClaimManager.priceDeviationToleranceBps is 0 -- initializeV2 not called");
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

        // Mainnet: WETH feed must be registered and returning a non-zero price
        bool hasFeed = IOraclePriceFeedView(ORACLE_PRICE_FEED).hasPriceFeed(WETH);
        if (hasFeed) {
            console2.log("[OK] OraclePriceFeed.hasPriceFeed(WETH): true");
        } else {
            console2.log("[FAIL] OraclePriceFeed.hasPriceFeed(WETH): false -- WETH feed not registered");
            _failures++;
        }

        try IOraclePriceFeedView(ORACLE_PRICE_FEED).getUSDValue(WETH, 1e18) returns (uint256 usdValue) {
            if (usdValue > 0) {
                console2.log("[OK] OraclePriceFeed.getUSDValue(WETH, 1e18):", usdValue, "(USD, 8 dec)");
            } else {
                console2.log("[FAIL] OraclePriceFeed.getUSDValue(WETH) returned 0");
                _failures++;
            }
        } catch {
            console2.log("[FAIL] OraclePriceFeed.getUSDValue(WETH) reverted (stale or missing feed)");
            _failures++;
        }

        console2.log("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PAUSER_ROLE — optional, enabled when PAUSER env var is set
    // ─────────────────────────────────────────────────────────────────────────

    function _checkPauserRole(address pauser) internal {
        console2.log("--- PAUSER_ROLE checks (PAUSER =", pauser, ") ---");

        address[6] memory proxies =
            [SWAPPER, CLAIM_MANAGER, POLICY_MANAGER, PREMIUM_MANAGER, COVER_POOL_FACTORY, SPEC_REGISTRY];
        string[6] memory names =
            ["Swapper", "ClaimManager", "PolicyManager", "PremiumManager", "CoverPoolFactory", "SpecRegistry"];

        for (uint256 i = 0; i < proxies.length; ++i) {
            _checkRole(string.concat(names[i], ": PAUSER_ROLE -> pauser"), proxies[i], PAUSER_ROLE, pauser);
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

    function _checkFalse(string memory label, bool condition) internal {
        if (!condition) {
            console2.log("[OK]", label);
        } else {
            console2.log("[FAIL]", label, "(should be false)");
            _failures++;
        }
    }
}

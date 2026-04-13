// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";

/// @title DeployCoveredVaultWrapper
/// @notice Deploys a CoveredVaultWrapper on top of an already-deployed Morpho V2 vault.
///
/// @dev Architecture:
///      User → CoveredVaultWrapper (ERC-4626, UUPS proxy)
///               → Morpho V2 vault (pre-existing, passed via MORPHO_VAULT env var)
///
/// @dev Deployment flow (2 steps):
///
///   Step 1 — Deploy CoveredVaultWrapper (UUPS proxy)
///     • Initializes with pre-existing Morpho vault address
///
///   Step 2 — Transfer wrapper ownership to final admin
///
/// @dev Usage:
///   1. Copy `.env.example` to `.env` and fill in all values.
///   2. Run:
///      forge script script/adapter/DeployCoveredVaultWrapper.s.sol:DeployCoveredVaultWrapper \
///        --rpc-url <RPC_URL> \
///        --broadcast \
///        --verify \
///        -vvvv
contract DeployCoveredVaultWrapper is Script {
    /*//////////////////////////////////////////////////////////////
                         CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    struct Config {
        // ── Morpho infrastructure (pre-existing) ──
        address morphoVault;
        // ── Catalysis protocol ──
        address claimManager;
        address coverPool;
        // ── Wrapper config ──
        uint16 maxCoverableLossBps;
        uint16 deductibleBps;
        address premiumRecipient;
        // ── Vault metadata ──
        string vaultName;
        string vaultSymbol;
        // ── Ownership ──
        address catalysisOwner; // final owner of the wrapper
    }

    /*//////////////////////////////////////////////////////////////
                            RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Config memory cfg = _loadConfig();
        _validateConfig(cfg);

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== CoveredVaultWrapper Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Morpho vault:", cfg.morphoVault);

        vm.startBroadcast(deployer);

        // Step 1: Deploy CoveredVaultWrapper
        CoveredVaultWrapper wrapper_ = _step1_deployWrapper(cfg, deployer);

        // Step 2: Transfer wrapper ownership to final admin
        _step2_transferOwnership(cfg, address(wrapper_));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Morpho V2 Vault:", cfg.morphoVault);
        console.log("CoveredVaultWrapper:", address(wrapper_));
        console.log("Pending owner (must call acceptOwnership):", cfg.catalysisOwner);
        console.log("=== Done ===");
    }

    /*//////////////////////////////////////////////////////////////
              STEP 1: DEPLOY COVEREDVAULTWRAPPER
    //////////////////////////////////////////////////////////////*/

    function _step1_deployWrapper(Config memory cfg, address deployer) internal returns (CoveredVaultWrapper wrapper_) {
        bytes memory initData = abi.encodeCall(
            CoveredVaultWrapper.initialize,
            (
                cfg.morphoVault,
                cfg.claimManager,
                cfg.coverPool,
                cfg.maxCoverableLossBps,
                cfg.deductibleBps,
                cfg.premiumRecipient,
                deployer,
                cfg.vaultName,
                cfg.vaultSymbol
            )
        );

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy("CoveredVaultWrapper.sol", initData, deployOpts);
        wrapper_ = CoveredVaultWrapper(proxy);
        console.log("Step 1: CoveredVaultWrapper (UUPS proxy) deployed at:", address(wrapper_));
    }

    /*//////////////////////////////////////////////////////////////
              STEP 2: TRANSFER WRAPPER OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function _step2_transferOwnership(Config memory cfg, address wrapper_) internal {
        console.log("Step 2: Proposing wrapper ownership transfer to:", cfg.catalysisOwner);
        (bool ok, bytes memory ret) =
            wrapper_.call(abi.encodeWithSignature("transferOwnership(address)", cfg.catalysisOwner));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        console.log("  - Wrapper ownership transfer proposed to:", cfg.catalysisOwner);
        console.log("  - IMPORTANT: ownership is NOT yet transferred.");
        console.log("  - The new owner must call acceptOwnership() to complete the transfer.");
    }

    /*//////////////////////////////////////////////////////////////
                       CONFIGURATION LOADER
    //////////////////////////////////////////////////////////////*/

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.morphoVault = vm.envAddress("MORPHO_VAULT");
        cfg.claimManager = vm.envAddress("CLAIM_MANAGER");
        cfg.coverPool = vm.envAddress("COVER_POOL");
        cfg.maxCoverableLossBps = uint16(vm.envUint("MAX_COVERABLE_LOSS_BPS"));
        cfg.deductibleBps = uint16(vm.envUint("DEDUCTIBLE_BPS"));
        cfg.premiumRecipient = vm.envAddress("PREMIUM_RECIPIENT");
        cfg.vaultName = vm.envString("VAULT_NAME");
        cfg.vaultSymbol = vm.envString("VAULT_SYMBOL");
        cfg.catalysisOwner = vm.envAddress("CATALYSIS_OWNER");
    }

    function _validateConfig(Config memory cfg) internal pure {
        require(cfg.morphoVault != address(0), "MORPHO_VAULT not set");
        require(cfg.claimManager != address(0), "CLAIM_MANAGER not set");
        require(cfg.coverPool != address(0), "COVER_POOL not set");
        require(cfg.maxCoverableLossBps > 0 && cfg.maxCoverableLossBps <= 10_000, "Invalid MAX_COVERABLE_LOSS_BPS");
        require(cfg.deductibleBps < cfg.maxCoverableLossBps, "DEDUCTIBLE_BPS must be less than MAX_COVERABLE_LOSS_BPS");
        require(cfg.premiumRecipient != address(0), "PREMIUM_RECIPIENT not set");
        require(bytes(cfg.vaultName).length > 0, "VAULT_NAME not set");
        require(bytes(cfg.vaultSymbol).length > 0, "VAULT_SYMBOL not set");
        require(cfg.catalysisOwner != address(0), "CATALYSIS_OWNER not set");
    }
}

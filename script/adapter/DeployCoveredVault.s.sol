// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CatalysisCoverAdapter} from "../../src/defi/adapters/morpho/CatalysisCoverAdapter.sol";
import {IVaultV2} from "../../src/defi/interfaces/Morpho/IVaultV2.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";

/// @notice Minimal interface for Morpho VaultV2Factory
interface IVaultV2Factory {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
    function isVaultV2(address vault) external view returns (bool);
}

/// @title DeployCoveredVault
/// @notice Deploys a Morpho V2 Covered Vault + CatalysisCoverAdapter in one atomic script.
///
/// @dev Deployment flow (5 steps):
///
///   Step 1 — Deploy Covered Vault & temporary roles
///     • createVaultV2() via factory
///     • setCurator(deployer)  — temporary, transferred in step 5
///     • setIsAllocator(deployer, true) — temporary, revoked in step 5
///     • setName() / setSymbol()
///
///   Step 2 — Deploy CatalysisCoverAdapter
///     • constructor(parentVault, underlyingVault, claimManager,
///       coverPool, maxCoverableLossBps)
///     • policyId is set later via onPolicyBound hook when the policy is bound
///
///   Step 3 — Curator & allocator settings
///     • addAdapter(adapter) + relative cap
///     • setManagementFee(fee)
///     • setManagementFeeRecipient(treasury)
///     • setForceDeallocatePenalty (optional)
///     • setLiquidityAdapterAndData(adapter, "")
///     • setMaxRate (optional)
///     NOTE: absoluteCap is NOT set here — it is set by the onPolicyBound hook
///
///   Step 4 — Abdicate essential setter functions
///     • abdicate(setPerformanceFeeRecipient.selector)
///     • abdicate(addAdapter.selector)
///     • abdicate(removeAdapter.selector)
///
///   Step 5 — Renounce deployer roles & transfer ownership
///     • setIsAllocator(deployer, false)
///     • setCurator(adapter) — adapter needs Curator role for onPolicyBound hook
///     • setOwner(catalysisOwner)
///     NOTE: After onPolicyBound executes, owner should transfer curator to final recipient
///
/// @dev Usage:
///   1. Copy `.env.example` to `.env` and fill in all values.
///   2. Run:
///      forge script script/DeployCoveredVault.s.sol:DeployCoveredVault \
///        --rpc-url <RPC_URL> \
///        --broadcast \
///        --verify \
///        -vvvv
contract DeployCoveredVault is Script {
    /*//////////////////////////////////////////////////////////////
                         CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    struct Config {
        // ── Morpho V2 Factory ──
        address vaultV2Factory;
        // ── Underlying vault (ERC4626, e.g. Steakhouse USDC) ──
        address underlyingVault;
        // ── Catalysis protocol addresses ──
        address claimManager;
        address coverPool;
        // ── Adapter config ──
        uint16 maxCoverableLossBps;
        // ── Vault metadata ──
        string vaultName;
        string vaultSymbol;
        // ── Fees ──
        uint96 managementFee;
        address managementFeeRecipient;
        // ── Optional ──
        uint256 forceDeallocatePenalty; // 0 = skip
        uint256 maxRate; // 0 = skip
        address catalysisOwner;
    }

    /*//////////////////////////////////////////////////////////////
                            RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Config memory cfg = _loadConfig();
        _validateConfig(cfg);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Catalysis Covered Vault Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Underlying vault:", cfg.underlyingVault);

        vm.startBroadcast(deployerPrivateKey);

        // ════════════════════════════════════════════════════════
        // Step 1: Deploy Covered Vault & set temporary roles
        // ════════════════════════════════════════════════════════
        address coveredVault = _step1_deployCoveredVault(cfg, deployer);

        // ════════════════════════════════════════════════════════
        // Step 2: Deploy CatalysisCoverAdapter
        // ════════════════════════════════════════════════════════
        CatalysisCoverAdapter adapter = _step2_deployAdapter(cfg, coveredVault);

        // ════════════════════════════════════════════════════════
        // Step 3: Curator & allocator settings
        // ════════════════════════════════════════════════════════
        _step3_configureCuratorSettings(cfg, coveredVault, address(adapter));

        // ════════════════════════════════════════════════════════
        // Step 4: Abdicate essential setter functions
        // ════════════════════════════════════════════════════════
        _step4_abdicateSetters(coveredVault);

        // ════════════════════════════════════════════════════════
        // Step 5: Renounce deployer roles & transfer ownership
        // ════════════════════════════════════════════════════════
        _step5_renounceAndTransfer(cfg, coveredVault, deployer, address(adapter));

        vm.stopBroadcast();

        // ── Log summary ──
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Covered Vault:", coveredVault);
        console.log("Adapter:", address(adapter));
        console.log("Adapter ID:", vm.toString(adapter.adapterId()));
        console.log("Owner:", cfg.catalysisOwner);
        console.log("=== Done ===");
    }

    /*//////////////////////////////////////////////////////////////
                     STEP 1: DEPLOY COVERED VAULT
    //////////////////////////////////////////////////////////////*/

    function _step1_deployCoveredVault(Config memory cfg, address deployer) internal returns (address coveredVault) {
        // 1a. Get underlying asset
        address asset = IVaultV2(cfg.underlyingVault).asset();
        console.log("Asset:", asset);

        // 1b. Create V2 vault via factory
        bytes32 salt = keccak256(abi.encodePacked(deployer, cfg.underlyingVault, block.timestamp));
        coveredVault = IVaultV2Factory(cfg.vaultV2Factory).createVaultV2(deployer, asset, salt);
        console.log("Step 1: Covered Vault deployed at:", coveredVault);

        // 1c. Set deployer as curator (temporary)
        _call(coveredVault, abi.encodeWithSignature("setCurator(address)", deployer));
        console.log("  - Deployer set as curator");

        // 1d. Set deployer as allocator (temporary) — timelocked
        _submitAndExec(coveredVault, abi.encodeWithSignature("setIsAllocator(address,bool)", deployer, true));
        console.log("  - Deployer set as allocator");

        // 1e. Set vault name
        _call(coveredVault, abi.encodeWithSignature("setName(string)", cfg.vaultName));
        console.log("  - Name set:", cfg.vaultName);

        // 1f. Set vault symbol
        _call(coveredVault, abi.encodeWithSignature("setSymbol(string)", cfg.vaultSymbol));
        console.log("  - Symbol set:", cfg.vaultSymbol);
    }

    /*//////////////////////////////////////////////////////////////
                   STEP 2: DEPLOY ADAPTER
    //////////////////////////////////////////////////////////////*/

    function _step2_deployAdapter(
        Config memory cfg,
        address coveredVault
    )
        internal
        returns (CatalysisCoverAdapter adapter)
    {
        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "CatalysisCoverAdapter.sol",
            abi.encodeCall(
                CatalysisCoverAdapter.initialize,
                (coveredVault, cfg.underlyingVault, cfg.claimManager, cfg.coverPool, cfg.maxCoverableLossBps)
            ),
            deployOpts
        );
        adapter = CatalysisCoverAdapter(proxy);
        console.log("Step 2: Adapter (UUPS proxy) deployed at:", address(adapter));
    }

    /*//////////////////////////////////////////////////////////////
              STEP 3: CURATOR & ALLOCATOR SETTINGS
    //////////////////////////////////////////////////////////////*/

    function _step3_configureCuratorSettings(Config memory cfg, address coveredVault, address adapter) internal {
        console.log("Step 3: Configuring curator settings...");

        // 3a. Register adapter
        _submitAndExec(coveredVault, abi.encodeWithSignature("addAdapter(address)", adapter));
        console.log("  - Adapter registered");

        // 3b. Set adapter caps
        // Note: absoluteCap is NOT set here — it will be set by the onPolicyBound hook
        // when PolicyManager binds the policy. The hook calculates:
        //   absoluteCap = (BPS_DENOMINATOR / maxCoverableLossBps) * coverageLimit
        bytes memory idData = CatalysisCoverAdapter(adapter).idData();
        _submitAndExec(coveredVault, abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18));
        console.log("  - Adapter relative cap set (absolute cap set via onPolicyBound hook)");

        // 3c. Set management fee (insurance premium)
        _submitAndExec(coveredVault, abi.encodeWithSignature("setManagementFee(uint96)", cfg.managementFee));
        console.log("  - Management fee set:", cfg.managementFee);

        // 3d. Set management fee recipient (Catalysis Treasury)
        _submitAndExec(
            coveredVault, abi.encodeWithSignature("setManagementFeeRecipient(address)", cfg.managementFeeRecipient)
        );
        console.log("  - Management fee recipient set:", cfg.managementFeeRecipient);

        // 3e. Set force deallocate penalty (optional)
        if (cfg.forceDeallocatePenalty > 0) {
            _submitAndExec(
                coveredVault,
                abi.encodeWithSignature(
                    "setForceDeallocatePenalty(address,uint256)", adapter, cfg.forceDeallocatePenalty
                )
            );
            console.log("  - Force deallocate penalty set:", cfg.forceDeallocatePenalty);
        }

        // 3f. Set adapter as liquidity adapter (auto-allocate on deposit, auto-deallocate on withdraw)
        IVaultV2(coveredVault).setLiquidityAdapterAndData(adapter, "");
        console.log("  - Liquidity adapter set");

        // 3g. Set max APR (optional)
        if (cfg.maxRate > 0) {
            _call(coveredVault, abi.encodeWithSignature("setMaxRate(uint256)", cfg.maxRate));
            console.log("  - Max rate set:", cfg.maxRate);
        }
    }

    /*//////////////////////////////////////////////////////////////
                 STEP 4: ABDICATE SETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _step4_abdicateSetters(address coveredVault) internal {
        console.log("Step 4: Abdicating setter functions...");

        // 4a. Abdicate setPerformanceFeeRecipient
        bytes4 perfFeeRecipientSelector = bytes4(keccak256("setPerformanceFeeRecipient(address)"));
        _submitAndExec(coveredVault, abi.encodeWithSignature("abdicate(bytes4)", perfFeeRecipientSelector));
        console.log("  - Abdicated setPerformanceFeeRecipient");

        // 4b. Abdicate addAdapter
        bytes4 addAdapterSelector = bytes4(keccak256("addAdapter(address)"));
        _submitAndExec(coveredVault, abi.encodeWithSignature("abdicate(bytes4)", addAdapterSelector));
        console.log("  - Abdicated addAdapter");

        // 4c. Abdicate removeAdapter
        bytes4 removeAdapterSelector = bytes4(keccak256("removeAdapter(address)"));
        _submitAndExec(coveredVault, abi.encodeWithSignature("abdicate(bytes4)", removeAdapterSelector));
        console.log("  - Abdicated removeAdapter");
    }

    /*//////////////////////////////////////////////////////////////
             STEP 5: RENOUNCE ROLES & TRANSFER OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function _step5_renounceAndTransfer(
        Config memory cfg,
        address coveredVault,
        address deployer,
        address adapter
    )
        internal
    {
        console.log("Step 5: Renouncing roles and transferring ownership...");

        // 5a. Renounce allocator role
        _submitAndExec(coveredVault, abi.encodeWithSignature("setIsAllocator(address,bool)", deployer, false));
        console.log("  - Deployer allocator revoked");

        // 5b. Set adapter as curator (so onPolicyBound hook can call submit + increaseAbsoluteCap)
        // Note: After onPolicyBound executes, the owner should transfer curator to the final recipient
        _call(coveredVault, abi.encodeWithSignature("setCurator(address)", adapter));
        console.log("  - Curator set to adapter:", adapter);

        // 5c. Transfer owner role
        _call(coveredVault, abi.encodeWithSignature("setOwner(address)", cfg.catalysisOwner));
        console.log("  - Owner transferred to:", cfg.catalysisOwner);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Submit timelocked data then execute it (timelock=0 on fresh vault)
    function _submitAndExec(address vault, bytes memory data) internal {
        _call(vault, abi.encodeWithSignature("submit(bytes)", data));
        _call(vault, data);
    }

    /// @dev Low-level call with revert forwarding
    function _call(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                       CONFIGURATION LOADER
    //////////////////////////////////////////////////////////////*/

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.vaultV2Factory = vm.envAddress("VAULT_V2_FACTORY");
        cfg.underlyingVault = vm.envAddress("UNDERLYING_VAULT");
        cfg.claimManager = vm.envAddress("CLAIM_MANAGER");
        cfg.coverPool = vm.envAddress("COVER_POOL");
        cfg.maxCoverableLossBps = uint16(vm.envUint("MAX_COVERABLE_LOSS_BPS"));
        cfg.vaultName = vm.envString("VAULT_NAME");
        cfg.vaultSymbol = vm.envString("VAULT_SYMBOL");
        cfg.managementFee = uint96(vm.envUint("MANAGEMENT_FEE"));
        cfg.managementFeeRecipient = vm.envAddress("MANAGEMENT_FEE_RECIPIENT");
        cfg.catalysisOwner = vm.envAddress("CATALYSIS_OWNER");

        // Optional parameters (default to 0 if not set)
        cfg.forceDeallocatePenalty = vm.envOr("FORCE_DEALLOCATE_PENALTY", uint256(0));
        cfg.maxRate = vm.envOr("MAX_RATE", uint256(0));
    }

    function _validateConfig(Config memory cfg) internal pure {
        require(cfg.vaultV2Factory != address(0), "VAULT_V2_FACTORY not set");
        require(cfg.underlyingVault != address(0), "UNDERLYING_VAULT not set");
        require(cfg.claimManager != address(0), "CLAIM_MANAGER not set");
        require(cfg.coverPool != address(0), "COVER_POOL not set");
        require(cfg.maxCoverableLossBps > 0 && cfg.maxCoverableLossBps <= 10_000, "Invalid MAX_COVERABLE_LOSS_BPS");
        require(bytes(cfg.vaultName).length > 0, "VAULT_NAME not set");
        require(bytes(cfg.vaultSymbol).length > 0, "VAULT_SYMBOL not set");
        require(cfg.managementFeeRecipient != address(0), "MANAGEMENT_FEE_RECIPIENT not set");
        require(cfg.catalysisOwner != address(0), "CATALYSIS_OWNER not set");
    }
}

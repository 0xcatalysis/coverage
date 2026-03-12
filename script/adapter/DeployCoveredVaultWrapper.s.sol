// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {IVaultV2} from "../../src/defi/interfaces/Morpho/IVaultV2.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";

/// @notice Minimal interface for Morpho VaultV2Factory
interface IVaultV2Factory {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
}

/// @notice Minimal interface for MorphoVaultV1Adapter (off-the-shelf)
interface IMorphoVaultV1Adapter {
    function idData() external view returns (bytes memory);
}

/// @title DeployCoveredVaultWrapper
/// @notice Deploys a CoveredVaultWrapper on top of a fresh Morpho V2 vault + MorphoVaultV1Adapter.
///
/// @dev Architecture deployed:
///      User → CoveredVaultWrapper (ERC-4626, UUPS proxy)
///               → Morpho V2 vault (fees=0, sole depositor=wrapper)
///                   → MorphoVaultV1Adapter (off-the-shelf, no custom code)
///                       → Underlying ERC-4626 yield source
///
/// @dev Deployment flow (5 steps):
///
///   Step 1 — Deploy Morpho V2 vault
///     • createVaultV2() via factory (owner = deployer)
///     • setCurator(deployer), setIsAllocator(deployer, true), setName(), setSymbol()
///
///   Step 2 — Deploy MorphoVaultV1Adapter via Morpho factory pointing to underlying ERC-4626
///     • (off-the-shelf adapter — no custom code)
///
///   Step 3 — Configure Morpho V2 vault
///     • setManagementFee(0), setPerformanceFee(0)
///     • addAdapter(morphoAdapter)
///     • setLiquidityAdapterAndData(morphoAdapter, "")
///
///   Step 4 — Deploy CoveredVaultWrapper (UUPS proxy)
///     • pass MorphoVaultV1Adapter.idData() as adapterIdData
///
///   Step 5 — Finalize roles
///     • abdicate: setPerformanceFeeRecipient, addAdapter, removeAdapter
///     • setCurator(finalAdmin), setOwner(finalAdmin)
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
        // ── Morpho infrastructure ──
        address vaultV2Factory;
        address morphoAdapterFactory; // factory that creates MorphoVaultV1Adapters
        // ── Underlying yield source ──
        address underlyingVault;
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

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== CoveredVaultWrapper Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Underlying vault:", cfg.underlyingVault);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Morpho V2 vault
        address morphoVault_ = _step1_deployMorphoVault(cfg, deployer);

        // Step 2: Deploy MorphoVaultV1Adapter
        address morphoAdapter = _step2_deployMorphoAdapter(cfg, morphoVault_, deployer);

        // Step 3: Configure Morpho V2 vault
        _step3_configureMorphoVault(morphoVault_, morphoAdapter);

        // Step 4: Deploy CoveredVaultWrapper
        CoveredVaultWrapper wrapper_ = _step4_deployWrapper(cfg, morphoVault_, deployer);

        // Step 5: Finalize roles
        _step5_finalizeRoles(cfg, morphoVault_, deployer, address(wrapper_));

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Morpho V2 Vault:", morphoVault_);
        console.log("MorphoVaultV1Adapter:", morphoAdapter);
        console.log("CoveredVaultWrapper:", address(wrapper_));
        console.log("Owner:", cfg.catalysisOwner);
        console.log("=== Done ===");
    }

    /*//////////////////////////////////////////////////////////////
                   STEP 1: DEPLOY MORPHO V2 VAULT
    //////////////////////////////////////////////////////////////*/

    function _step1_deployMorphoVault(Config memory cfg, address deployer) internal returns (address morphoVault_) {
        address asset = IVaultV2(cfg.underlyingVault).asset();
        console.log("Asset:", asset);

        bytes32 salt = keccak256(abi.encodePacked(deployer, cfg.underlyingVault, block.timestamp));
        morphoVault_ = IVaultV2Factory(cfg.vaultV2Factory).createVaultV2(deployer, asset, salt);
        console.log("Step 1: Morpho V2 vault deployed at:", morphoVault_);

        _call(morphoVault_, abi.encodeWithSignature("setCurator(address)", deployer));
        _submitAndExec(morphoVault_, abi.encodeWithSignature("setIsAllocator(address,bool)", deployer, true));
        _call(morphoVault_, abi.encodeWithSignature("setName(string)", cfg.vaultName));
        _call(morphoVault_, abi.encodeWithSignature("setSymbol(string)", cfg.vaultSymbol));
    }

    /*//////////////////////////////////////////////////////////////
                STEP 2: DEPLOY MORPHOVAULV1ADAPTER
    //////////////////////////////////////////////////////////////*/

    function _step2_deployMorphoAdapter(
        Config memory cfg,
        address morphoVault_,
        address deployer
    )
        internal
        returns (address adapter)
    {
        // The MorphoVaultV1Adapter factory call signature may vary by deployment.
        // This uses a common pattern; adjust if the factory API differs.
        bytes32 salt = keccak256(abi.encodePacked(deployer, cfg.underlyingVault, block.timestamp, "adapter"));
        (bool ok, bytes memory ret) = cfg.morphoAdapterFactory
            .call(
                abi.encodeWithSignature(
                    "createAdapter(address,address,bytes32)", morphoVault_, cfg.underlyingVault, salt
                )
            );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        adapter = abi.decode(ret, (address));
        console.log("Step 2: MorphoVaultV1Adapter deployed at:", adapter);
    }

    /*//////////////////////////////////////////////////////////////
              STEP 3: CONFIGURE MORPHO V2 VAULT
    //////////////////////////////////////////////////////////////*/

    function _step3_configureMorphoVault(address morphoVault_, address morphoAdapter) internal {
        console.log("Step 3: Configuring Morpho V2 vault...");

        // Zero out fees (premiums collected at wrapper level)
        _submitAndExec(morphoVault_, abi.encodeWithSignature("setManagementFee(uint96)", uint96(0)));
        _submitAndExec(morphoVault_, abi.encodeWithSignature("setPerformanceFee(uint96)", uint96(0)));
        console.log("  - Management + performance fees set to 0");

        // Register MorphoVaultV1Adapter
        _submitAndExec(morphoVault_, abi.encodeWithSignature("addAdapter(address)", morphoAdapter));
        console.log("  - MorphoVaultV1Adapter registered");

        // Set relative cap to 100% of vault TVL
        bytes memory idData = IMorphoVaultV1Adapter(morphoAdapter).idData();
        _submitAndExec(morphoVault_, abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18));
        console.log("  - Relative cap set to 100%");

        // Set adapter as liquidity source
        IVaultV2(morphoVault_).setLiquidityAdapterAndData(morphoAdapter, "");
        console.log("  - Liquidity adapter set to MorphoVaultV1Adapter");
    }

    /*//////////////////////////////////////////////////////////////
              STEP 4: DEPLOY COVEREDVAULTWRAPPER
    //////////////////////////////////////////////////////////////*/

    function _step4_deployWrapper(
        Config memory cfg,
        address morphoVault_,
        address deployer
    )
        internal
        returns (CoveredVaultWrapper wrapper_)
    {
        bytes memory initData = _buildInitData(cfg, morphoVault_, deployer);

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy("CoveredVaultWrapper.sol", initData, deployOpts);
        wrapper_ = CoveredVaultWrapper(proxy);
        console.log("Step 4: CoveredVaultWrapper (UUPS proxy) deployed at:", address(wrapper_));
    }

    function _buildInitData(
        Config memory cfg,
        address morphoVault_,
        address deployer
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            CoveredVaultWrapper.initialize,
            (
                morphoVault_,
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
    }

    /*//////////////////////////////////////////////////////////////
            STEP 5: FINALIZE ROLES
    //////////////////////////////////////////////////////////////*/

    function _step5_finalizeRoles(
        Config memory cfg,
        address morphoVault_,
        address deployer,
        address wrapper_
    )
        internal
    {
        console.log("Step 5: Finalizing roles...");

        // Abdicate setPerformanceFeeRecipient (no performance fee)
        bytes4 perfFeeRecipientSelector = bytes4(keccak256("setPerformanceFeeRecipient(address)"));
        _submitAndExec(morphoVault_, abi.encodeWithSignature("abdicate(bytes4)", perfFeeRecipientSelector));

        // Abdicate addAdapter / removeAdapter (adapter set is frozen)
        bytes4 addAdapterSelector = bytes4(keccak256("addAdapter(address)"));
        _submitAndExec(morphoVault_, abi.encodeWithSignature("abdicate(bytes4)", addAdapterSelector));

        bytes4 removeAdapterSelector = bytes4(keccak256("removeAdapter(address)"));
        _submitAndExec(morphoVault_, abi.encodeWithSignature("abdicate(bytes4)", removeAdapterSelector));
        console.log("  - Setter functions abdicated");

        // Revoke deployer allocator role
        _submitAndExec(morphoVault_, abi.encodeWithSignature("setIsAllocator(address,bool)", deployer, false));
        console.log("  - Deployer allocator revoked");

        // Transfer Morpho vault curator and ownership to final admin
        _call(morphoVault_, abi.encodeWithSignature("setCurator(address)", cfg.catalysisOwner));
        console.log("  - Morpho vault curator set to:", cfg.catalysisOwner);

        _call(morphoVault_, abi.encodeWithSignature("setOwner(address)", cfg.catalysisOwner));
        console.log("  - Morpho vault ownership transferred to:", cfg.catalysisOwner);

        // Transfer wrapper ownership
        // Note: CoveredVaultWrapper.transferOwnership() (OZ Ownable) is used here
        _call(wrapper_, abi.encodeWithSignature("transferOwnership(address)", cfg.catalysisOwner));
        console.log("  - Wrapper ownership transferred to:", cfg.catalysisOwner);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPERS
    //////////////////////////////////////////////////////////////*/

    function _submitAndExec(address vault, bytes memory data) internal {
        _call(vault, abi.encodeWithSignature("submit(bytes)", data));
        _call(vault, data);
    }

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
        cfg.morphoAdapterFactory = vm.envAddress("MORPHO_ADAPTER_FACTORY");
        cfg.underlyingVault = vm.envAddress("UNDERLYING_VAULT");
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
        require(cfg.vaultV2Factory != address(0), "VAULT_V2_FACTORY not set");
        require(cfg.morphoAdapterFactory != address(0), "MORPHO_ADAPTER_FACTORY not set");
        require(cfg.underlyingVault != address(0), "UNDERLYING_VAULT not set");
        require(cfg.claimManager != address(0), "CLAIM_MANAGER not set");
        require(cfg.coverPool != address(0), "COVER_POOL not set");
        require(cfg.maxCoverableLossBps > 0 && cfg.maxCoverableLossBps <= 10_000, "Invalid MAX_COVERABLE_LOSS_BPS");
        require(cfg.deductibleBps < 10_000, "Invalid DEDUCTIBLE_BPS");
        require(cfg.premiumRecipient != address(0), "PREMIUM_RECIPIENT not set");
        require(bytes(cfg.vaultName).length > 0, "VAULT_NAME not set");
        require(bytes(cfg.vaultSymbol).length > 0, "VAULT_SYMBOL not set");
        require(cfg.catalysisOwner != address(0), "CATALYSIS_OWNER not set");
    }
}

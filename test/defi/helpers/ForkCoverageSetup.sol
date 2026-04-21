// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {CoverPool} from "coverage/CoverPool.sol";
import {CoverPoolFactory} from "coverage/CoverPoolFactory.sol";
import {PolicyManager} from "coverage/PolicyManager.sol";
import {PremiumManager} from "coverage/PremiumManager.sol";
import {ClaimManager} from "coverage/ClaimManager.sol";
import {SpecRegistry} from "coverage/SpecRegistry.sol";
import {Swapper} from "coverage/Swapper.sol";
import {UniswapV3Adapter} from "coverage/swappers/UniswapV3Adapter.sol";
import {MockSpec} from "coverage/mocks/MockSpec.sol";

import {ICoverPool} from "coverage/interfaces/ICoverPool.sol";

import {CoveredVaultWrapper} from "../../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

/// @notice Minimal interfaces for live Core contracts (avoids sibling-repo dependency)
interface IVaultV2Factory {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
}

interface IStakeManagerFork {
    function setCoverPoolFactory(address coverPoolFactory) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ISlashingManagerFork {
    function setClaimManager(address claimManager) external;
}

interface IRewardsManagerFork {
    function setPremiumManager(address premiumManager) external;
}

interface ISSPRouterFork {
    function setStakeRecipient(address stakeRecipient) external;
    function getCommitteeVaultsByModule(uint96 committeeId, uint8 moduleType) external view returns (address[] memory);
}

interface IChainlinkPriceFeedFork {
    function hasPriceFeed(address token) external view returns (bool);
    function registerPriceFeed(address token, address aggregator, uint256 stalenessThreshold) external;
    function getUSDValue(address token, uint256 amount) external view returns (uint256);
}

interface IDelegationManagerFork {
    struct SignatureWithExpiry {
        bytes signature;
        uint256 expiry;
    }

    function delegatedTo(address staker) external view returns (address);
    function delegateTo(address operator, SignatureWithExpiry calldata sig, bytes32 approverSalt) external;
}

interface IStrategyManagerFork {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256);
}

/**
 * @title ForkCoverageSetup
 * @notice Abstract base for fork tests that deploy fresh Coverage contracts wired to the
 *         live Ethereum mainnet Catalysis Core deployment (docs/deployment/Ethereum-Mainnet.md).
 *
 * @dev Setup order in every setUp():
 *        _deployCoverageStack()  → deploy Coverage proxies, wire internal roles
 *        _advancePolicyId()      → skip past live committee IDs to avoid CommitteeAlreadyExists
 *        _wireCoverageToLiveCore() → impersonate MASTER_ADMIN for 5 Core-side wiring calls
 *
 *      Live mainnet invariants verified at FORK_BLOCK:
 *        - MASTER_ADMIN holds all required roles; delay() == 0 on all Core contracts.
 *        - hasPriceFeed(WETH) == true; hasPriceFeed(USDC) == false (register in setUp).
 *        - SSPRouter acceptableTokens = [wstETH]; DurationVaultStrategy collateral is wstETH.
 *        - SSPRouter EIGENLAYER module type = 2 (NONE=0, SYMBIOTIC=1, EIGENLAYER=2).
 */
abstract contract ForkCoverageSetup is Test {
    /*//////////////////////////////////////////////////////////////
                    LIVE MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @dev Catalysis Core (docs/deployment/Ethereum-Mainnet.md)
    address internal constant STAKE_MANAGER = 0x5be5220F81e76e0CF6089fb7E7aE9eF48a8D64Be;
    address internal constant SLASHING_MANAGER = 0x7Bc39bf135eF3c30E542C196719c91455ff489f0;
    address internal constant REWARDS_MANAGER = 0x8ae0F0B94fe782D7F055B04d4699c3cc01632b46;
    address internal constant SSP_ROUTER = 0xF39E592E93A7a925a57464e0120B555A25590486;
    address internal constant CHAINLINK_PRICEFEED = 0x57F750E3B8e095A5b3AE96030F0cac5dFe2f8A16;
    address internal constant MASTER_ADMIN = 0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c;

    /// @dev EigenLayer
    address internal constant EIGEN_STRATEGY_MANAGER = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
    address internal constant EIGEN_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    /// @dev Morpho V2
    address internal constant VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;

    /// @dev Uniswap V3
    address internal constant UNISWAP_SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    /// @dev Tokens
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WETH_STAKED = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH

    /// @dev Chainlink aggregators
    address internal constant ETH_USD_AGGREGATOR = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_AGGREGATOR = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    /// @dev All live Core addresses are non-empty at this block (Core deployed ~24_875_000).
    uint256 internal constant FORK_BLOCK = 24_900_000;

    /// @dev Live SSPRouter: NONE=0, SYMBIOTIC=1, EIGENLAYER=2. Verified from VaultModuleRegistered events.
    uint8 internal constant SSP_MODULE_EIGENLAYER = 2;

    /// @dev Matches CoverPool._QUOTE_TYPEHASH
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 expirationTime)"
    );

    /*//////////////////////////////////////////////////////////////
                    DEPLOYED FRESH EACH RUN
    //////////////////////////////////////////////////////////////*/

    CoverPool internal coverPoolImplementation;
    CoverPoolFactory internal coverPoolFactory;
    PolicyManager internal policyManager;
    PremiumManager internal premiumManager;
    ClaimManager internal claimManager;
    SpecRegistry internal specRegistry;
    Swapper internal swapper;
    MockSpec internal mockSpec;

    uint256 internal quoteSignerKey;
    address internal quoteSigner;

    bool internal forkActive;

    /*//////////////////////////////////////////////////////////////
                    FORK SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Forks mainnet at FORK_BLOCK. Gracefully sets forkActive=false when ETHEREUM_RPC_URL is unset.
    function _forkMainnet() internal {
        try vm.createSelectFork("mainnet", FORK_BLOCK) {
            forkActive = true;
        } catch {
            forkActive = false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    COVERAGE STACK DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys all Coverage contracts behind plain ERC1967 proxies.
     * @dev Mirrors src/Deploy.s.sol but uses new()+ERC1967Proxy (no CreateX) and keeps the test
     *      contract as DEFAULT_ADMIN_ROLE and CoverPoolFactory CREATOR_ROLE. Live Core addresses
     *      (StakeManager, SlashingManager, etc.) are wired in directly.
     */
    function _deployCoverageStack() internal {
        quoteSignerKey = uint256(keccak256("fork-quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);

        address deployer = address(this);

        Swapper swapperImpl = new Swapper();
        swapper = Swapper(
            payable(address(
                    new ERC1967Proxy(
                        address(swapperImpl), abi.encodeCall(Swapper.initialize, (deployer, deployer, deployer, WETH))
                    )
                ))
        );

        PremiumManager pmImpl = new PremiumManager();
        premiumManager = PremiumManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(PremiumManager.initialize, (deployer, REWARDS_MANAGER, deployer, 500))
                )
            )
        );

        // PolicyManager initialized with deployer placeholders for claimManager/coverPoolFactory;
        // patched below after those contracts are deployed (mirrors Deploy.s.sol pattern).
        PolicyManager pmImplContract = new PolicyManager();
        policyManager = PolicyManager(
            address(
                new ERC1967Proxy(
                    address(pmImplContract),
                    abi.encodeCall(
                        PolicyManager.initialize,
                        (deployer, STAKE_MANAGER, deployer, deployer, CHAINLINK_PRICEFEED, new address[](0))
                    )
                )
            )
        );

        SpecRegistry srImpl = new SpecRegistry();
        specRegistry = SpecRegistry(
            address(new ERC1967Proxy(address(srImpl), abi.encodeCall(SpecRegistry.initialize, (deployer, address(0)))))
        );

        ClaimManager cmImpl = new ClaimManager();
        claimManager = ClaimManager(
            payable(address(
                    new ERC1967Proxy(
                        address(cmImpl),
                        abi.encodeCall(
                            ClaimManager.initialize,
                            (
                                deployer,
                                address(specRegistry),
                                SLASHING_MANAGER,
                                address(swapper),
                                address(policyManager)
                            )
                        )
                    )
                ))
        );
        claimManager.setPremiumManager(address(premiumManager));
        policyManager.setClaimManager(address(claimManager));

        coverPoolImplementation = new CoverPool();

        CoverPoolFactory cpfImpl = new CoverPoolFactory();
        coverPoolFactory = CoverPoolFactory(
            address(
                new ERC1967Proxy(
                    address(cpfImpl),
                    abi.encodeCall(
                        CoverPoolFactory.initialize,
                        (
                            deployer,
                            deployer,
                            address(coverPoolImplementation),
                            address(policyManager),
                            STAKE_MANAGER,
                            address(specRegistry)
                        )
                    )
                )
            )
        );

        policyManager.setCoverPoolFactory(address(coverPoolFactory));
        specRegistry.setCoverPoolFactory(address(coverPoolFactory));

        IAccessControl(address(swapper)).grantRole(swapper.SWAP_EXECUTOR_ROLE(), address(claimManager));
        IAccessControl(address(swapper)).revokeRole(swapper.SWAP_EXECUTOR_ROLE(), deployer);
        IAccessControl(address(premiumManager)).grantRole(premiumManager.CLAIM_MANAGER_ROLE(), address(claimManager));
    }

    /**
     * @notice Advances PolicyManager._nextPolicyId to 1_000_000 to avoid colliding with live
     *         StakeManager committee IDs (which start at 1 from the live Coverage deployment).
     * @dev Slot 2 packs coverPoolFactory (bits 0-159) and _nextPolicyId (bits 160-255);
     *      we preserve coverPoolFactory while writing the new policyId offset.
     */
    function _advancePolicyId() internal {
        uint256 packedSlot = (uint256(1_000_000) << 160) | uint256(uint160(address(coverPoolFactory)));
        vm.store(address(policyManager), bytes32(uint256(2)), bytes32(packedSlot));
    }

    /*//////////////////////////////////////////////////////////////
                    CORE <-> COVERAGE WIRING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Replays the 5 Core-side calls from WireCoreContracts.s.sol as MASTER_ADMIN,
     *         then approves the live RewardsManager to pull tokens from PremiumManager.
     */
    function _wireCoverageToLiveCore() internal {
        vm.deal(MASTER_ADMIN, 1 ether);
        vm.startPrank(MASTER_ADMIN);
        IStakeManagerFork(STAKE_MANAGER).setCoverPoolFactory(address(coverPoolFactory));
        IAccessControl(STAKE_MANAGER).grantRole(keccak256("POLICY_MANAGER_ROLE"), address(policyManager));
        ISlashingManagerFork(SLASHING_MANAGER).setClaimManager(address(claimManager));
        IRewardsManagerFork(REWARDS_MANAGER).setPremiumManager(address(premiumManager));
        ISSPRouterFork(SSP_ROUTER).setStakeRecipient(address(claimManager));
        vm.stopPrank();

        premiumManager.approveSpender(USDC, REWARDS_MANAGER, type(uint256).max);
        premiumManager.approveSpender(WETH, REWARDS_MANAGER, type(uint256).max);
    }

    /// @notice Idempotent: registers a Chainlink price feed on the live ChainlinkPriceFeed if missing.
    function _registerChainlinkFeedIfMissing(address token, address aggregator, uint256 staleness) internal {
        if (!IChainlinkPriceFeedFork(CHAINLINK_PRICEFEED).hasPriceFeed(token)) {
            vm.deal(MASTER_ADMIN, address(MASTER_ADMIN).balance + 1 ether);
            vm.startPrank(MASTER_ADMIN);
            IChainlinkPriceFeedFork(CHAINLINK_PRICEFEED).registerPriceFeed(token, aggregator, staleness);
            vm.stopPrank();
        }
    }

    /// @notice Whitelists a token as both a payout token and an approved premium token.
    function _whitelistPayoutToken(address token) internal {
        policyManager.setSupportedPayoutToken(token, true);
        premiumManager.addApprovedPremiumToken(token);
    }

    /// @notice Deploys MockSpec and approves it in SpecRegistry.
    function _deploySpec() internal {
        mockSpec = new MockSpec();
        specRegistry.approveSpec(address(mockSpec));
    }

    /// @notice Deploys a UniswapV3Adapter and registers a tokenIn→tokenOut route on the fresh Swapper.
    function _registerSwapRoute(address tokenIn, address tokenOut, uint24 poolFee) internal {
        UniswapV3Adapter adapter = new UniswapV3Adapter(UNISWAP_SWAP_ROUTER02, UNISWAP_QUOTER_V2, address(swapper));
        swapper.setSwapTargetWhitelist(address(adapter), true);
        swapper.setSwapRoute(
            tokenIn,
            tokenOut,
            address(adapter),
            true,
            abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0))
        );
    }

    /// @notice Creates a fresh Morpho V2 vault via the live factory and assigns curator.
    function _deployMorphoVaultV2(address owner, address curator, address asset) internal returns (IVaultV2 vault) {
        vm.prank(owner);
        vault =
            IVaultV2(IVaultV2Factory(VAULT_V2_FACTORY).createVaultV2(owner, asset, bytes32(uint256(block.timestamp))));
        vm.prank(owner);
        vault.setCurator(curator);
    }

    /**
     * @notice Deploys a CoveredVaultWrapper UUPS proxy with premiumRecipient = fresh PremiumManager.
     */
    function _deployCoveredVaultWrapper(
        address morphoVault_,
        address coverPool_,
        uint16 maxCoverableLossBps_,
        uint16 deductibleBps_,
        address owner_,
        string memory name_,
        string memory symbol_
    )
        internal
        returns (CoveredVaultWrapper wrapper)
    {
        Options memory opts;
        opts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredVaultWrapper.sol",
            abi.encodeCall(
                CoveredVaultWrapper.initialize,
                (
                    morphoVault_,
                    address(claimManager),
                    coverPool_,
                    maxCoverableLossBps_,
                    deductibleBps_,
                    address(premiumManager),
                    owner_,
                    name_,
                    symbol_
                )
            ),
            opts
        );
        wrapper = CoveredVaultWrapper(proxy);
    }

    /*//////////////////////////////////////////////////////////////
                    EIGENLAYER VAULT DISCOVERY + STAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Snapshot the global EigenLayer vault count BEFORE requestCoverage.
    function _eigenLayerVaultCount() internal view returns (uint256) {
        return _getEigenLayerVaultsGlobal().length;
    }

    function _getEigenLayerVaultsGlobal() internal view returns (address[] memory) {
        (bool ok, bytes memory d) =
            SSP_ROUTER.staticcall(abi.encodeWithSignature("getVaultsByModule(uint8)", SSP_MODULE_EIGENLAYER));
        require(ok, "getVaultsByModule failed");
        return abi.decode(d, (address[]));
    }

    /**
     * @notice Returns the DurationVaultStrategies created since the snapshot.
     * @dev committeeModuleVaults is only populated by setCommitteeVaults (inside bindPolicyForRequest),
     *      so pre-bind vault discovery must use this snapshot-delta approach instead of
     *      getCommitteeVaultsByModule.
     */
    function _discoverNewEigenLayerVaults(uint256 snapshotCount) internal view returns (address[] memory) {
        address[] memory allVaults = _getEigenLayerVaultsGlobal();
        require(allVaults.length > snapshotCount, "no new EigenLayer vaults deployed");
        uint256 newCount = allVaults.length - snapshotCount;
        address[] memory newVaults = new address[](newCount);
        for (uint256 i = 0; i < newCount; i++) {
            newVaults[i] = allVaults[snapshotCount + i];
        }
        return newVaults;
    }

    /// @notice Returns the underlying token of a DurationVaultStrategy (wstETH on live mainnet).
    function _vaultUnderlyingToken(address vault) internal view returns (address token) {
        (bool ok, bytes memory d) = vault.staticcall(abi.encodeWithSignature("underlyingToken()"));
        require(ok && d.length >= 32, "underlyingToken() call failed");
        token = abi.decode(d, (address));
    }

    /// @notice Returns the collateral amount such that getUSDValue(token, amount) >= 2× getUSDValue(USDC, usdcAmount).
    function _collateralAmountFor2xCoverage(
        address collateralToken,
        uint256 usdcAmount
    )
        internal
        view
        returns (uint256 collateralAmount)
    {
        IChainlinkPriceFeedFork feed = IChainlinkPriceFeedFork(CHAINLINK_PRICEFEED);
        uint256 targetUSD = feed.getUSDValue(USDC, usdcAmount) * 2;
        uint256 tokenDecimals = 10 ** IERC20Metadata(collateralToken).decimals();
        uint256 tokenPriceUSD = feed.getUSDValue(collateralToken, tokenDecimals);
        collateralAmount = (targetUSD * tokenDecimals + tokenPriceUSD - 1) / tokenPriceUSD;
    }

    /**
     * @notice Delegates depositor to vault and deposits collateral into the DurationVaultStrategy.
     * @dev The vault registers itself as an EigenLayer operator; stakers must delegate to it.
     *      Delegation must happen before the StrategyManager approval to avoid OnlyUnderlyingToken().
     */
    function _fundEigenLayerStake(address vault, address depositor, uint256 collateralAmount) internal {
        address collateralToken = _vaultUnderlyingToken(vault);
        deal(collateralToken, depositor, collateralAmount);

        vm.startPrank(depositor);
        IDelegationManagerFork.SignatureWithExpiry memory sig =
            IDelegationManagerFork.SignatureWithExpiry({signature: "", expiry: 0});
        if (IDelegationManagerFork(EIGEN_DELEGATION_MANAGER).delegatedTo(depositor) != vault) {
            IDelegationManagerFork(EIGEN_DELEGATION_MANAGER).delegateTo(vault, sig, bytes32(0));
        }
        IERC20(collateralToken).approve(EIGEN_STRATEGY_MANAGER, collateralAmount);
        IStrategyManagerFork(EIGEN_STRATEGY_MANAGER).depositIntoStrategy(vault, collateralToken, collateralAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    POLICY BINDING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Signs a quote and calls bindPolicyForRequest as the curator (test contract).
     * @dev spec and beneficiary are separated: beneficiary is in the policy draft; spec is
     *      registered in SpecRegistry by bindPolicyForRequest.
     */
    function _bindPolicy(
        uint96 policyId,
        address pool,
        address spec,
        uint256 coverageLimit,
        address beneficiary,
        bytes32 specId,
        bytes32 termsHash,
        address[] memory vaults
    )
        internal
    {
        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: pool,
            policyId: policyId,
            coverageLimit: coverageLimit,
            specId: specId,
            termsHash: termsHash,
            beneficiary: beneficiary,
            expirationTime: uint32(block.timestamp + 1 days)
        });
        ICoverPool(pool).bindPolicyForRequest(policyId, quote, spec, vaults, _signQuote(quote, pool));
    }

    /*//////////////////////////////////////////////////////////////
                    EIP-712 SIGNING
    //////////////////////////////////////////////////////////////*/

    function _signQuote(ICoverPool.Quote memory quote, address pool) internal view returns (bytes memory) {
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", ICoverPool(pool).quoteDomainSeparator(), _hashQuote(quote)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashQuote(ICoverPool.Quote memory quote) internal pure returns (bytes32) {
        return EfficientHashLib.hash(
            uint256(QUOTE_TYPEHASH),
            uint256(uint160(quote.pool)),
            uint256(quote.policyId),
            quote.coverageLimit,
            uint256(quote.specId),
            uint256(quote.termsHash),
            uint256(uint160(quote.beneficiary)),
            uint256(quote.expirationTime)
        );
    }
}

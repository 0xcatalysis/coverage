// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PolicyManager} from "coverage/PolicyManager.sol";
import {CoverPool} from "coverage/CoverPool.sol";
import {ICoverPool} from "coverage/interfaces/ICoverPool.sol";
import {CoveredVaultWrapper} from "../../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {MockClaimManager} from "../mocks/Mocks.sol";
import {
    MockStakeManager,
    MockCoverPoolFactory,
    MockSpecRegistry,
    MockBindPolicyHook,
    MockChainlinkPriceFeed
} from "../mocks/CoverageMocks.sol";

/// @title RealCoverageSetup
/// @notice Abstract base contract that deploys real PolicyManager + real CoverPool for adapter tests
/// @dev Replaces MockPolicyManager and MockCoverPool with real implementations.
///      MockClaimManager is retained because the real ClaimManager.fileClaim() requires deep dependencies
///      (ChainlinkPriceFeed, SlashingManager, Swapper) that are external to the coverage protocol.
///      Peripheral mocks (StakeManager, CoverPoolFactory, SpecRegistry) are lightweight shims.
abstract contract RealCoverageSetup is Test {
    // ── Real contracts ──
    PolicyManager internal policyManager;
    CoverPool internal coverPool;

    // ── Lightweight mocks ──
    MockClaimManager internal claimManager;
    MockStakeManager internal mockStakeManager;
    MockCoverPoolFactory internal mockCoverPoolFactory;
    MockSpecRegistry internal mockSpecRegistry;
    MockBindPolicyHook internal mockBindPolicyHook;
    MockChainlinkPriceFeed internal mockChainlinkPriceFeed;

    // ── EIP-712 quote signing ──
    uint256 internal quoteSignerKey;
    address internal quoteSigner;

    // ── Constants ──
    bytes32 internal constant SPEC_ID = keccak256("morpho-spec");
    bytes32 internal constant TERMS_HASH = keccak256("terms");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
    );

    /// @notice Deploys the real PolicyManager (behind ERC1967Proxy) and real CoverPool (via Clones)
    /// @param admin Address that receives DEFAULT_ADMIN_ROLE on PolicyManager
    /// @param curator_ Address that owns the CoverPool (acts as operator)
    function _deployRealCoverage(address admin, address curator_) internal {
        // ── Peripheral mocks ──
        mockStakeManager = new MockStakeManager();
        mockCoverPoolFactory = new MockCoverPoolFactory();
        mockSpecRegistry = new MockSpecRegistry();
        mockBindPolicyHook = new MockBindPolicyHook();

        // ── EIP-712 signer ──
        quoteSignerKey = uint256(keccak256("quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);

        // ── Deploy MockClaimManager with pre-computed PolicyManager proxy address ──
        // Nonce layout: +0 = MockClaimManager, +1 = MockChainlinkPriceFeedDefi, +2 = PolicyManager impl,
        //               +3 = ERC1967Proxy (= PM proxy)
        uint256 nonce = vm.getNonce(address(this));
        address expectedPmProxy = vm.computeCreateAddress(address(this), nonce + 3);
        claimManager = new MockClaimManager(expectedPmProxy);

        // ── Deploy MockChainlinkPriceFeed (returns 0 so totalStake >= 0 always passes) ──
        mockChainlinkPriceFeed = new MockChainlinkPriceFeed();

        // ── Deploy real PolicyManager behind UUPS proxy ──
        PolicyManager pmImpl = new PolicyManager();
        PolicyManager pm = PolicyManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(
                        PolicyManager.initialize,
                        (
                            admin,
                            address(mockStakeManager),
                            address(claimManager),
                            address(mockCoverPoolFactory),
                            address(mockChainlinkPriceFeed),
                            new address[](0)
                        )
                    )
                )
            )
        );
        require(address(pm) == expectedPmProxy, "PM proxy address mismatch");
        policyManager = pm;

        // ── Deploy real CoverPool via minimal proxy clone ──
        CoverPool cpImpl = new CoverPool();
        CoverPool pool = CoverPool(Clones.clone(address(cpImpl)));
        pool.initialize(
            curator_,
            quoteSigner,
            address(pm),
            address(mockStakeManager),
            address(mockSpecRegistry),
            0 // poolFeeBps
        );
        coverPool = pool;

        // ── Register pool in factory ──
        mockCoverPoolFactory.register(address(pool));
    }

    /// @notice Creates a policy draft and binds it through the real PolicyManager + CoverPool flow
    /// @param beneficiary Address that receives claim payouts
    /// @param claimer Address authorized to file claims
    /// @param payoutToken ERC20 token used for claim payouts
    /// @param coverageLimit Maximum payout notional (in payout token units)
    /// @param startTime Policy coverage start timestamp
    /// @param maturityTime Policy coverage end timestamp
    /// @param buyer Address requesting coverage
    /// @param bindPolicyHook_ Hook contract notified on bind
    /// @return policyId_ The bound policy ID
    function _createAndBindPolicy(
        address beneficiary,
        address claimer,
        address payoutToken,
        uint256 coverageLimit,
        uint32 startTime,
        uint32 maturityTime,
        address buyer,
        address bindPolicyHook_
    )
        internal
        returns (uint96 policyId_)
    {
        vm.prank(buyer);
        policyId_ = policyManager.requestCoverage(
            address(coverPool), beneficiary, claimer, payoutToken, maturityTime - startTime, bindPolicyHook_
        );

        _bindPolicy(policyId_, beneficiary, coverageLimit, startTime, maturityTime);
    }

    function _bindPolicy(
        uint96 policyId_,
        address beneficiary,
        uint256 coverageLimit,
        uint32 startTime,
        uint32 maturityTime
    )
        private
    {
        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: address(coverPool),
            policyId: policyId_,
            coverageLimit: coverageLimit,
            basePremium: 0,
            specId: SPEC_ID,
            termsHash: TERMS_HASH,
            beneficiary: beneficiary,
            startTime: startTime,
            maturityTime: maturityTime,
            expirationTime: maturityTime
        });

        bytes memory signature = _signQuote(quote);

        address[] memory vaults = new address[](1);
        vaults[0] = address(0xDEAD);

        vm.prank(coverPool.owner());
        coverPool.bindPolicyForRequest(policyId_, quote, beneficiary, vaults, signature);
    }

    /// @notice Signs a CoverPool quote using the quoteSignerKey
    function _signQuote(ICoverPool.Quote memory quote) internal view returns (bytes memory) {
        bytes32 structHash = _hashQuote(quote);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", coverPool.quoteDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Replicates CoverPool._hashQuote using EfficientHashLib (matches CoverPool._QUOTE_TYPEHASH)
    function _hashQuote(ICoverPool.Quote memory quote) internal pure returns (bytes32) {
        return EfficientHashLib.hash(
            uint256(QUOTE_TYPEHASH),
            uint256(uint160(quote.pool)),
            uint256(quote.policyId),
            quote.coverageLimit,
            quote.basePremium,
            uint256(quote.specId),
            uint256(quote.termsHash),
            uint256(uint160(quote.beneficiary)),
            uint256(quote.startTime),
            uint256(quote.maturityTime),
            uint256(quote.expirationTime)
        );
    }

    /// @notice Deploys CoveredVaultWrapper behind a UUPS proxy using the Upgrades library
    function _deployWrapperProxy(
        address morphoVault_,
        address claimManager_,
        address coverPool_,
        uint16 maxCoverableLossBps_,
        uint16 deductibleBps_,
        address premiumRecipient_,
        address owner_,
        string memory name_,
        string memory symbol_
    )
        internal
        returns (CoveredVaultWrapper)
    {
        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredVaultWrapper.sol",
            abi.encodeCall(
                CoveredVaultWrapper.initialize,
                (
                    morphoVault_,
                    claimManager_,
                    coverPool_,
                    maxCoverableLossBps_,
                    deductibleBps_,
                    premiumRecipient_,
                    owner_,
                    name_,
                    symbol_
                )
            ),
            deployOpts
        );
        return CoveredVaultWrapper(proxy);
    }

    /// @notice Helper: set premium rate in tests, bypassing the 2-day timelock (L-04).
    /// @dev Triggers collectPremium() to settle any pending premium at the old rate
    ///      (mirrors the old setPremiumRate behavior), then directly writes the new rate
    ///      and advances lastPremiumAccrualTime to avoid stale timestamps.
    ///      Caller prank must NOT be active when calling this.
    ///      Storage slots verified via `forge inspect CoveredVaultWrapper storageLayout`:
    ///        premiumRatePerSecond = slot 57, lastPremiumAccrualTime = slot 58.
    function _setPremiumRate(CoveredVaultWrapper w, uint256 newRate, address caller_) internal {
        // Settle any pending premium at the old rate (mirrors old setPremiumRate behavior)
        w.collectPremium();
        // Directly write the new rate and advance lastPremiumAccrualTime
        vm.store(address(w), bytes32(uint256(57)), bytes32(newRate));
        vm.store(address(w), bytes32(uint256(58)), bytes32(block.timestamp));
    }
}

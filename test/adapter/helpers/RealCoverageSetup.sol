// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {PolicyManager} from "coverage/PolicyManager.sol";
import {CoverPool} from "coverage/CoverPool.sol";
import {ICoverPool} from "coverage/interfaces/ICoverPool.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {IClaimManager} from "coverage/interfaces/IClaimManager.sol";
import {CatalysisCoverAdapter} from "../../../src/adapter/adapters/vault/CatalysisCoverAdapter.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {MockClaimManager} from "../mocks/Mocks.sol";
import {MockStakeManager, MockCoverPoolFactory, MockSpecRegistry, MockBindPolicyHook} from "../mocks/CoverageMocks.sol";

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
        // Nonce layout: +0 = MockClaimManager, +1 = PolicyManager impl, +2 = ERC1967Proxy (= PM proxy)
        uint256 nonce = vm.getNonce(address(this));
        address expectedPmProxy = vm.computeCreateAddress(address(this), nonce + 2);
        claimManager = new MockClaimManager(expectedPmProxy);

        // ── Deploy real PolicyManager behind UUPS proxy ──
        PolicyManager pmImpl = new PolicyManager();
        PolicyManager pm = PolicyManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(
                        PolicyManager.initialize,
                        (admin, address(mockStakeManager), address(claimManager), address(mockCoverPoolFactory))
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
    /// @dev Uses the full requestCoverage → signQuote → bindPolicyForRequest pipeline
    /// @param beneficiary Address that receives claim payouts (typically the adapter address)
    /// @param claimer Address authorized to file claims (typically the adapter address)
    /// @param payoutToken ERC20 token used for claim payouts
    /// @param coverageAmount Stake requirement (in USD 8 decimals)
    /// @param coverageLimit Maximum payout notional (in payout token units)
    /// @param startTime Policy coverage start timestamp
    /// @param maturityTime Policy coverage end timestamp
    /// @param buyer Address requesting coverage (typically the curator)
    /// @param bindPolicyHook_ Address of the hook contract to be notified on bind (typically the adapter)
    /// @return policyId_ The bound policy ID
    function _createAndBindPolicy(
        address beneficiary,
        address claimer,
        address payoutToken,
        uint256 coverageAmount,
        uint256 coverageLimit,
        uint32 startTime,
        uint32 maturityTime,
        address buyer,
        address bindPolicyHook_
    )
        internal
        returns (uint96 policyId_)
    {
        // 1. Request coverage (creates draft) — uses claimer, payoutToken, buyer (freed after this call)
        vm.prank(buyer);
        policyId_ = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            claimer,
            payoutToken,
            coverageAmount,
            maturityTime - startTime, // duration
            bindPolicyHook_
        );

        // 2-5. Build quote, sign, and bind policy
        _bindPolicy(policyId_, beneficiary, coverageAmount, coverageLimit, startTime, maturityTime);
    }

    /// @notice Builds a quote, signs it, and binds the policy through the CoverPool
    function _bindPolicy(
        uint96 policyId_,
        address beneficiary,
        uint256 coverageAmount,
        uint256 coverageLimit,
        uint32 startTime,
        uint32 maturityTime
    )
        private
    {
        // 2. Build quote
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
            expirationTime: maturityTime // quote valid until maturity
        });

        // 3. Sign quote (EIP-712)
        bytes memory signature = _signQuote(quote);

        // 4. Set sufficient operator stake
        address curator_ = coverPool.owner();
        mockStakeManager.setOperatorStake(curator_, policyId_, coverageAmount);

        // 5. Bind policy (as curator = pool admin)
        address[] memory vaults = new address[](1);
        vaults[0] = address(0xDEAD); // placeholder vault for committee

        vm.prank(curator_);
        coverPool.bindPolicyForRequest(
            policyId_,
            quote,
            beneficiary, // spec address = beneficiary (adapter implements ISpec)
            vaults,
            signature
        );
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

    /// @notice Deploys CatalysisCoverAdapter behind a UUPS proxy using the Upgrades library
    function _deployAdapterProxy(
        address parentVault_,
        address underlyingVault_,
        address claimManager_,
        address coverPool_,
        uint16 maxCoverableLossBps_
    )
        internal
        returns (CatalysisCoverAdapter)
    {
        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "CatalysisCoverAdapter.sol",
            abi.encodeCall(
                CatalysisCoverAdapter.initialize,
                (parentVault_, underlyingVault_, claimManager_, coverPool_, maxCoverableLossBps_)
            ),
            deployOpts
        );
        return CatalysisCoverAdapter(proxy);
    }
}

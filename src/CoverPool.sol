// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {IPolicyManager} from "./interfaces/IPolicyManager.sol";
import {ISpec} from "./interfaces/ISpec.sol";
import {ISpecRegistry} from "./interfaces/ISpecRegistry.sol";
import {IStakeManager} from "./interfaces/IStakeManager.sol";

/**
 * @title CoverPool
 * @notice Curator-controlled pool that validates coverage quotes and records bound policy metadata.
 * @dev Designed for use behind minimal proxy clones. Uses AccessControlDefaultAdminRules for secure
 *      2-step admin transfers with configurable delay, and EIP-712 signed quotes for deterministic
 *      policy commits. Each policy represents coverage from a single pool. The curator is the default
 *      admin and can manage all pool configuration and roles with a time-delayed transfer mechanism.
 */
// slither-disable-next-line unimplemented-functions
contract CoverPool is AccessControlDefaultAdminRulesUpgradeable, EIP712Upgradeable, PausableUpgradeable, ICoverPool {
    bytes32 public constant override QUOTE_SIGNER_ROLE = keccak256("QUOTE_SIGNER_ROLE");

    string private constant _NAME = "Catalysis Cover Pool";
    string private constant _VERSION = "1";
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
    );

    uint16 private constant _MAX_POOL_FEE_BPS = 2000; // 20%

    address public override policyManager;
    address public override stakeManager;
    address public override specRegistry;
    address public override feeRecipient;
    uint16 public override poolFeeBps;
    mapping(bytes32 policyCommit => bool bound) public override boundPolicyCommits;

    mapping(uint96 policyId => BoundPolicy policy) private boundPolicies;

    /**
     * @dev Ensures incoming quote matches pool metadata and timing constraints before processing.
     * @param quote Raw quote payload supplied by PolicyManager or validation callers.
     */
    modifier validateQuote(Quote calldata quote) {
        require(quote.pool == address(this), PoolAddressMismatch(address(this), quote.pool));
        require(quote.coverageLimit != 0, InvalidCoverageLimit());
        require(quote.specId != bytes32(0), InvalidSpecId());
        require(quote.termsHash != bytes32(0), InvalidTermsHash());
        require(quote.beneficiary != address(0), InvalidBeneficiary());
        require(quote.startTime < quote.maturityTime, InvalidCoverageWindow());

        uint256 currentTimestamp = block.timestamp;
        // forge-lint: disable-next-line(unsafe-typecast)
        require(quote.startTime >= currentTimestamp, InvalidStartTime(quote.startTime, uint32(currentTimestamp)));
        // forge-lint: disable-next-line(unsafe-typecast)
        require(quote.expirationTime >= currentTimestamp, QuoteExpired(quote.expirationTime, uint32(currentTimestamp)));
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @inheritdoc ICoverPool
     */
    function initialize(
        address curator_,
        address quoteSigner_,
        address policyManager_,
        address stakeManager_,
        address specRegistry_,
        uint16 poolFeeBps_
    )
        external
        initializer
    {
        require(
            curator_ != address(0) && policyManager_ != address(0) && quoteSigner_ != address(0)
                && stakeManager_ != address(0) && specRegistry_ != address(0),
            ZeroAddress()
        );
        require(poolFeeBps_ <= _MAX_POOL_FEE_BPS, InvalidFeeBps());

        __AccessControlDefaultAdminRules_init(24 hours, curator_);
        __EIP712_init(_NAME, _VERSION);
        __Pausable_init();

        _grantRole(QUOTE_SIGNER_ROLE, quoteSigner_);

        policyManager = policyManager_;
        stakeManager = stakeManager_;
        specRegistry = specRegistry_;
        poolFeeBps = poolFeeBps_;
        feeRecipient = curator_;
    }

    /**
     * @inheritdoc ICoverPool
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ICoverPool
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ICoverPool
     */
    function setPoolFeeBps(uint16 poolFeeBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolFeeBps_ <= _MAX_POOL_FEE_BPS, InvalidFeeBps());

        uint16 previousPoolFeeBps = poolFeeBps;
        poolFeeBps = poolFeeBps_;

        emit PoolFeeBpsSet(previousPoolFeeBps, poolFeeBps_);
    }

    /**
     * @inheritdoc ICoverPool
     */
    function setFeeRecipient(address feeRecipient_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(feeRecipient_ != address(0), ZeroAddress());

        address previousFeeRecipient = feeRecipient;
        feeRecipient = feeRecipient_;

        emit FeeRecipientSet(previousFeeRecipient, feeRecipient_);
    }

    /**
     * @inheritdoc ICoverPool
     */
    function bindPolicyForRequest(
        uint96 policyId,
        Quote calldata quote,
        address spec,
        address[] calldata vaults,
        bytes calldata signature
    )
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        IPolicyManager.PolicyDraft memory draft = IPolicyManager(policyManager).getPolicyDraft(policyId);
        require(draft.pool == address(this), PoolAddressMismatch(address(this), draft.pool));
        require(draft.status == IPolicyManager.PolicyStatus.Created, IPolicyManager.InvalidPolicyStatus(draft.status));
        require(quote.pool == address(this), PoolAddressMismatch(address(this), quote.pool));
        require(quote.policyId == draft.policyId, PolicyIdMismatch(draft.policyId, quote.policyId));
        require(quote.beneficiary == draft.beneficiary, BeneficiaryMismatch(draft.beneficiary, quote.beneficiary));
        _validateVaults(vaults);

        bytes32 policyCommit = _verifyQuote(quote, signature);
        BoundPolicy memory boundPolicy = _recordBoundPolicy(policyId, policyCommit, quote);

        emit PolicyForRequestBound(policyId, vaults.length);

        ISpecRegistry(specRegistry).registerSpec(quote.specId, ISpec(spec));

        // Add vaults to committee in core contracts using policyId as committeeId (1:1 mapping).
        IStakeManager(stakeManager).addCommitteeVaults(draft.policyId, vaults);

        IPolicyManager(policyManager)
            .bindPolicy(
                IPolicyManager.BindPolicyRequest({
                    policyId: policyId,
                    buyer: draft.buyer,
                    beneficiary: draft.beneficiary,
                    claimer: draft.claimer,
                    payoutToken: draft.payoutToken,
                    coverageAmount: draft.coverageAmount,
                    quote: quote,
                    signature: signature
                }),
                boundPolicy
            );
    }

    /**
     * @inheritdoc ICoverPool
     */
    function quoteDomainSeparator() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @inheritdoc ICoverPool
     */
    function getBoundPolicy(uint96 policyId) external view override returns (BoundPolicy memory policy) {
        policy = boundPolicies[policyId];
        require(policy.policyId != 0, PolicyNotFound(policyId));
    }

    /**
     * @inheritdoc ICoverPool
     */
    function hasBoundPolicy(uint96 policyId) external view override returns (bool) {
        return boundPolicies[policyId].policyId != 0;
    }

    /**
     * @dev See {AccessControlDefaultAdminRulesUpgradeable-grantRole}.
     */
    function grantRole(
        bytes32 role,
        address account
    )
        public
        override (AccessControlDefaultAdminRulesUpgradeable, IAccessControl)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        super.grantRole(role, account);
    }

    /**
     * @dev See {AccessControlDefaultAdminRulesUpgradeable-revokeRole}.
     */
    function revokeRole(
        bytes32 role,
        address account
    )
        public
        override (AccessControlDefaultAdminRulesUpgradeable, IAccessControl)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        super.revokeRole(role, account);
    }

    /**
     * @notice Validates that the vaults array is non-empty and contains no zero addresses.
     * @param vaults Array of vault addresses to validate.
     */
    function _validateVaults(address[] calldata vaults) private pure {
        uint256 vaultsLength = vaults.length;
        require(vaultsLength != 0, EmptyVaults());
        for (uint256 i = 0; i < vaultsLength; ++i) {
            require(vaults[i] != address(0), ZeroAddress());
        }
    }

    /**
     * @notice Locks coverage for a validated policy commit.
     * @dev Each binding represents a complete policy from this pool.
     * @param policyId Incremental identifier for the policy.
     * @param policyCommit Deterministic hash representing the policy.
     * @param quote Quote that has been validated for binding.
     * @return boundPolicy BoundPolicy metadata describing the pool's coverage allocation.
     */
    function _recordBoundPolicy(
        uint96 policyId,
        bytes32 policyCommit,
        Quote calldata quote
    )
        private
        whenNotPaused
        returns (BoundPolicy memory boundPolicy)
    {
        require(policyCommit != bytes32(0), InvalidPolicyCommit());

        bytes32 calculatedPolicyCommit = _hashQuote(quote);
        require(calculatedPolicyCommit == policyCommit, PolicyCommitMismatch(calculatedPolicyCommit, policyCommit));
        require(!boundPolicyCommits[policyCommit], PolicyAlreadyBound(policyCommit));

        boundPolicyCommits[policyCommit] = true;

        boundPolicy = BoundPolicy({
            policyId: policyId,
            policyCommit: policyCommit,
            specId: quote.specId,
            termsHash: quote.termsHash,
            coverageLimit: quote.coverageLimit,
            beneficiary: quote.beneficiary,
            startTime: quote.startTime,
            maturityTime: quote.maturityTime
        });

        boundPolicies[policyId] = boundPolicy;
    }

    /**
     * @notice Verify the quote with signature validation.
     * @param quote Quote struct to verify.
     * @param signature EIP-712 signature to validate.
     * @return policyCommit Deterministic hash representing the policy.
     */
    function _verifyQuote(
        Quote calldata quote,
        bytes calldata signature
    )
        private
        view
        validateQuote(quote)
        whenNotPaused
        returns (bytes32 policyCommit)
    {
        policyCommit = _hashQuote(quote);
        bytes32 digest = _hashTypedDataV4(policyCommit);

        address signer = ECDSA.recover(digest, signature);
        require(hasRole(QUOTE_SIGNER_ROLE, signer), InvalidQuoteSignature());
    }

    /**
     * @dev Computes the struct hash for a quote payload, re-used for policy commits.
     * @param quote Quote payload to hash.
     * @return struct hash encoded as bytes32.
     */
    function _hashQuote(Quote calldata quote) private pure returns (bytes32) {
        return EfficientHashLib.hash(
            uint256(_QUOTE_TYPEHASH),
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
}

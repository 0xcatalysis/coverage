// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IOwnable2Step} from "./interfaces/IOwnable2Step.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";

/**
 * @title CoverPool
 * @notice Curator-controlled pool that validates coverage quotes and records bound policy metadata.
 * @dev Designed for use behind minimal proxy clones. Leverages AccessControl for role separation
 *      and EIP-712 signed quotes for deterministic policy commits. Each policy represents coverage
 *      from a single pool.
 */
// slither-disable-next-line unimplemented-functions
contract CoverPool is
    Initializable,
    Ownable2StepUpgradeable,
    AccessControlUpgradeable,
    EIP712Upgradeable,
    PausableUpgradeable,
    ICoverPool
{
    bytes32 public constant override POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    bytes32 public constant override QUOTE_SIGNER_ROLE = keccak256("QUOTE_SIGNER_ROLE");

    string private constant _NAME = "Catalysis Cover Pool";
    string private constant _VERSION = "1";
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "QuoteData(address pool,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address payoutReceiver,uint96 committeeId,address operator,uint64 startTime,uint64 maturityTime,uint64 quoteExpiry)"
    );

    uint16 private constant _MAX_POOL_FEE_BPS = 2000; // 20%

    uint16 public override poolFeeBps;
    mapping(bytes32 policyCommit => bool bound) public override boundPolicyCommits;

    mapping(bytes32 policyId => BoundPolicy policy) private boundPolicies;

    /**
     * @dev Ensures incoming quote data matches pool metadata and timing constraints before processing.
     * @param quote Raw quote payload supplied by PolicyManager or validation callers.
     */
    modifier validateQuoteData(QuoteData calldata quote) {
        require(quote.pool == address(this), PoolAddressMismatch(address(this), quote.pool));
        require(quote.coverageLimit != 0, InvalidCoverageLimit());
        require(quote.specId != bytes32(0), InvalidSpecId());
        require(quote.payoutReceiver != address(0) && quote.operator != address(0), InvalidQuoteRecipient());
        require(quote.startTime < quote.maturityTime, InvalidCoverageWindow());

        uint256 currentTimestamp = block.timestamp;
        require(quote.quoteExpiry >= currentTimestamp, QuoteExpired(quote.quoteExpiry, currentTimestamp));
        _;
    }

    /**
     * @dev Prevents direct interaction with the default admin role outside ownership transfers.
     */
    modifier nonAdminRole(bytes32 role) {
        require(role != DEFAULT_ADMIN_ROLE, ICoverPool.DefaultAdminImmutable());
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
        address policyManager_,
        address quoteSigner_,
        uint16 poolFeeBps_
    )
        external
        initializer
    {
        require(curator_ != address(0) && policyManager_ != address(0) && quoteSigner_ != address(0), ZeroAddress());
        require(poolFeeBps_ <= _MAX_POOL_FEE_BPS, InvalidFeeBps());

        __Ownable_init(curator_);
        __Ownable2Step_init();
        __AccessControl_init();
        __EIP712_init(_NAME, _VERSION);
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, curator_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager_);
        _grantRole(QUOTE_SIGNER_ROLE, quoteSigner_);

        poolFeeBps = poolFeeBps_;
    }

    /**
     * @inheritdoc ICoverPool
     */
    function pause() external override onlyOwner {
        _pause();
    }

    /**
     * @inheritdoc ICoverPool
     */
    function unpause() external override onlyOwner {
        _unpause();
    }

    /**
     * @inheritdoc ICoverPool
     */
    function setPoolFeeBps(uint16 poolFeeBps_) external override onlyOwner {
        require(poolFeeBps_ <= _MAX_POOL_FEE_BPS, InvalidFeeBps());

        uint16 previousPoolFeeBps = poolFeeBps;
        poolFeeBps = poolFeeBps_;

        emit PoolFeeBpsSet(previousPoolFeeBps, poolFeeBps_);
    }

    /**
     * @inheritdoc ICoverPool
     */
    function bindPolicy(
        bytes32 policyCommit,
        QuoteData calldata quote,
        bytes calldata signature
    )
        external
        override
        onlyRole(POLICY_MANAGER_ROLE)
        validateQuoteData(quote)
        whenNotPaused
        returns (BoundPolicy memory boundPolicy)
    {
        require(policyCommit != bytes32(0), InvalidPolicyCommit());

        bytes32 calculatedPolicyCommit = _validateQuote(quote, signature);
        require(calculatedPolicyCommit == policyCommit, PolicyCommitMismatch(calculatedPolicyCommit, policyCommit));
        require(!boundPolicyCommits[policyCommit], PolicyAlreadyBound(policyCommit));

        boundPolicyCommits[policyCommit] = true;

        bytes32 policyId = _derivePolicyId(policyCommit);

        boundPolicy = BoundPolicy({
            policyId: policyId,
            specId: quote.specId,
            termsHash: quote.termsHash,
            coverageLimit: quote.coverageLimit,
            payoutReceiver: quote.payoutReceiver,
            committeeId: quote.committeeId,
            operator: quote.operator,
            startTime: quote.startTime,
            maturityTime: quote.maturityTime
        });

        boundPolicies[policyId] = boundPolicy;

        emit PolicyBound(policyCommit, policyId, quote.coverageLimit);
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
    function getBoundPolicy(bytes32 policyId) external view override returns (BoundPolicy memory policy) {
        policy = boundPolicies[policyId];
        require(policy.policyId != bytes32(0), PolicyNotFound(policyId));
    }

    /**
     * @inheritdoc ICoverPool
     */
    function validateQuote(
        QuoteData calldata quote,
        bytes calldata signature
    )
        external
        view
        override
        validateQuoteData(quote)
        whenNotPaused
        returns (bytes32)
    {
        return _validateQuote(quote, signature);
    }

    /**
     * @inheritdoc IOwnable2Step
     */
    function owner() public view override (IOwnable2Step, OwnableUpgradeable) returns (address) {
        return super.owner();
    }

    /**
     * @inheritdoc IOwnable2Step
     */
    function pendingOwner() public view override (IOwnable2Step, Ownable2StepUpgradeable) returns (address) {
        return super.pendingOwner();
    }

    /**
     * @inheritdoc IOwnable2Step
     */
    function transferOwnership(address newOwner) public override (IOwnable2Step, Ownable2StepUpgradeable) {
        super.transferOwnership(newOwner);
    }

    /**
     * @inheritdoc IOwnable2Step
     */
    function acceptOwnership() public override (IOwnable2Step, Ownable2StepUpgradeable) {
        super.acceptOwnership();
    }

    /**
     * @inheritdoc AccessControlUpgradeable
     * @dev Restricted to the owner; DEFAULT_ADMIN_ROLE cannot be delegated manually.
     */
    function grantRole(
        bytes32 role,
        address account
    )
        public
        override (AccessControlUpgradeable, IAccessControl)
        onlyOwner
        nonAdminRole(role)
    {
        _grantRole(role, account);
    }

    /**
     * @inheritdoc AccessControlUpgradeable
     * @dev Restricted to the owner; DEFAULT_ADMIN_ROLE cannot be revoked manually.
     */
    function revokeRole(
        bytes32 role,
        address account
    )
        public
        override (AccessControlUpgradeable, IAccessControl)
        onlyOwner
        nonAdminRole(role)
    {
        _revokeRole(role, account);
    }

    /**
     * @inheritdoc AccessControlUpgradeable
     * @dev DEFAULT_ADMIN_ROLE cannot be renounced; ownership transfer handles admin rotation.
     */
    function renounceRole(
        bytes32 role,
        address callerConfirmation
    )
        public
        override (AccessControlUpgradeable, IAccessControl)
        nonAdminRole(role)
    {
        super.renounceRole(role, callerConfirmation);
    }

    /**
     * @dev Syncs AccessControl admin membership with ownership transfers.
     * @param newOwner Address that will assume ownership of the contract.
     */
    function _transferOwnership(address newOwner) internal override {
        address oldOwner = owner();
        super._transferOwnership(newOwner);

        if (oldOwner != address(0)) {
            _revokeRole(DEFAULT_ADMIN_ROLE, oldOwner);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
    }

    /**
     * @dev Validates a quote signature and returns the policy commit hash.
     * @param quote Quote payload associated with the signature.
     * @param signature EIP-712 signature produced by an authorized quote signer.
     * @return policyCommit Deterministic commit hash derived from the quote.
     */
    function _validateQuote(
        QuoteData calldata quote,
        bytes calldata signature
    )
        private
        view
        returns (bytes32 policyCommit)
    {
        policyCommit = _hashQuote(quote);
        bytes32 digest = _hashTypedDataV4(policyCommit);

        address signer = ECDSA.recover(digest, signature);
        require(hasRole(QUOTE_SIGNER_ROLE, signer), QuoteSignatureInvalid());
    }

    /**
     * @dev Derives a pool-specific identifier for storing bound policy metadata.
     * @param policyCommit Commit hash associated with the bound policy.
     * @return policyId Unique identifier produced for the bound policy.
     */
    function _derivePolicyId(bytes32 policyCommit) private view returns (bytes32 policyId) {
        policyId = keccak256(abi.encodePacked(address(this), policyCommit));
    }

    /**
     * @dev Computes the struct hash for a quote payload, re-used for policy commits.
     * @param quote Quote payload to hash.
     * @return struct hash encoded as bytes32.
     */
    function _hashQuote(QuoteData calldata quote) private pure returns (bytes32) {
        return EfficientHashLib.hash(
            uint256(_QUOTE_TYPEHASH),
            uint256(uint160(quote.pool)),
            quote.coverageLimit,
            quote.basePremium,
            uint256(quote.specId),
            uint256(quote.termsHash),
            uint256(uint160(quote.payoutReceiver)),
            uint256(quote.committeeId),
            uint256(uint160(quote.operator)),
            uint256(quote.startTime),
            uint256(quote.maturityTime),
            uint256(quote.quoteExpiry)
        );
    }
}

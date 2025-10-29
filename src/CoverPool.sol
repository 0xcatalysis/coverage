// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";

/**
 * @title CoverPool
 * @notice Curator-controlled pool that validates coverage quotes and records bound policy metadata.
 * @dev Designed for use behind minimal proxy clones. Leverages AccessControl for role separation
 *      and EIP-712 signed quotes for deterministic policy commits.
 */
contract CoverPool is Initializable, AccessControlUpgradeable, EIP712Upgradeable, ICoverPool {
    bytes32 public constant override CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant override POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");

    string private constant _NAME = "Catalysis Cover Pool";
    string private constant _VERSION = "1";
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "QuoteData(uint256 poolId,uint256 coverageLimit,uint256 basePremium,uint256 riskBufferDeposit,bytes32 specId,bytes32 termsHash,address payoutAddress,uint96 committeeId,address operator,uint64 startTime,uint64 maturityTime,uint64 quoteExpiry)"
    );

    uint256 public override poolId;
    address public override curator;
    address public override quoteSigner;
    mapping(bytes32 policyCommit => bool bound) public override policyCommitBound;

    mapping(bytes32 poolPolicyId => BoundPolicy policy) private _poolPolicies;

    /**
     * @dev Ensures incoming quote data matches pool metadata and timing constraints before processing.
     * @param quote Raw quote payload supplied by PolicyManager or validation callers.
     */
    modifier validateQuoteInputs(QuoteData calldata quote) {
        require(quote.poolId == poolId, PoolIdMismatch(poolId, quote.poolId));
        require(quote.coverageLimit != 0, InvalidCoverageLimit());
        require(quote.payoutAddress != address(0) && quote.operator != address(0), InvalidQuoteRecipient());
        require(quote.startTime < quote.maturityTime, InvalidCoverageWindow());

        uint256 currentTimestamp = block.timestamp;
        require(quote.quoteExpiry >= currentTimestamp, QuoteExpired(quote.quoteExpiry, currentTimestamp));
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
        uint256 poolId_,
        address admin_,
        address curator_,
        address policyManager,
        address quoteSigner_
    )
        external
        initializer
    {
        require(poolId_ != 0, InvalidPoolId());
        require(admin_ != address(0) && curator_ != address(0) && policyManager != address(0), ZeroAddress());
        require(quoteSigner_ != address(0), QuoteSignerNotSet());

        __AccessControl_init();
        __EIP712_init(_NAME, _VERSION);

        poolId = poolId_;
        curator = curator_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CURATOR_ROLE, curator_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager);

        quoteSigner = quoteSigner_;
    }

    /**
     * @inheritdoc ICoverPool
     */
    function setQuoteSigner(address newSigner) external override onlyRole(CURATOR_ROLE) {
        require(newSigner != address(0), ZeroAddress());
        quoteSigner = newSigner;
        emit QuoteSignerSet(newSigner);
    }

    /**
     * @inheritdoc ICoverPool
     */
    function bindPolicy(
        bytes32 policyCommit,
        QuoteData calldata quote
    )
        external
        override
        onlyRole(POLICY_MANAGER_ROLE)
        validateQuoteInputs(quote)
        returns (BoundPolicy memory boundPolicy)
    {
        require(policyCommit != bytes32(0), InvalidPolicyCommit());

        bytes32 expectedCommit = _hashQuote(quote);
        require(expectedCommit == policyCommit, PolicyCommitMismatch(expectedCommit, policyCommit));

        require(!policyCommitBound[policyCommit], PolicyAlreadyBound(policyCommit));
        policyCommitBound[policyCommit] = true;

        bytes32 poolPolicyId = _derivePoolPolicyId(policyCommit);

        boundPolicy = BoundPolicy({
            poolPolicyId: poolPolicyId,
            specId: quote.specId,
            termsHash: quote.termsHash,
            coverageLimit: quote.coverageLimit,
            payoutAddress: quote.payoutAddress,
            committeeId: quote.committeeId,
            operator: quote.operator,
            startTime: quote.startTime,
            maturityTime: quote.maturityTime
        });

        _poolPolicies[poolPolicyId] = boundPolicy;

        emit PolicyBound(policyCommit, poolPolicyId, quote.coverageLimit);
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
    function getPoolPolicy(bytes32 poolPolicyId) external view override returns (BoundPolicy memory policy) {
        policy = _poolPolicies[poolPolicyId];
        require(policy.poolPolicyId != bytes32(0), PolicyNotFound(poolPolicyId));
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
        validateQuoteInputs(quote)
        returns (bytes32 policyCommit)
    {
        require(quoteSigner != address(0), QuoteSignerNotSet());

        policyCommit = _hashQuote(quote);
        bytes32 digest = _hashTypedDataV4(policyCommit);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != quoteSigner) {
            revert QuoteSignatureInvalid();
        }
    }

    /**
     * @dev Computes the struct hash for a quote payload, re-used for policy commits.
     * @param quote Quote payload to hash.
     * @return struct hash encoded as bytes32.
     */
    function _hashQuote(QuoteData calldata quote) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _QUOTE_TYPEHASH,
                quote.poolId,
                quote.coverageLimit,
                quote.basePremium,
                quote.riskBufferDeposit,
                quote.specId,
                quote.termsHash,
                quote.payoutAddress,
                quote.committeeId,
                quote.operator,
                quote.startTime,
                quote.maturityTime,
                quote.quoteExpiry
            )
        );
    }

    /**
     * @dev Derives a pool-specific identifier for storing bound policy metadata.
     * @param policyCommit Commit hash associated with the bound policy.
     * @return poolPolicyId Unique identifier produced for the pool slice.
     */
    function _derivePoolPolicyId(bytes32 policyCommit) private view returns (bytes32 poolPolicyId) {
        poolPolicyId = keccak256(abi.encodePacked(address(this), policyCommit));
    }
}

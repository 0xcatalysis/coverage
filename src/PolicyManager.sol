// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPolicyManager} from "./interfaces/IPolicyManager.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {IPremiumManager} from "./interfaces/IPremiumManager.sol";
import {IPolicy} from "./interfaces/IPolicy.sol";

/**
 * @title PolicyManager
 * @notice Single entrypoint for binding coverage policies, orchestrating quote validation,
 *         premium settlement, and policy NFT minting.
 * @dev Integrates with CoverPool for quote validation, PremiumManager for premium collection,
 *      and Policy for minting soulbound receipts.
 */
// slither-disable-next-line unimplemented-functions
contract PolicyManager is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IPolicyManager
{
    /// @dev Maximum allowed combined fees (platform + pool) in basis points (10% = 1000 bps).
    uint16 private constant _MAX_TOTAL_FEE_BPS = 1000;

    address public override premiumManager;
    address public override policy;
    uint16 public override platformFeeBps;
    uint256 private _nextPolicyId;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PolicyManager with role assignments and dependency wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address of the PremiumManager contract.
     * @param policy_ Address of the Policy contract.
     * @param platformFeeBps_ Initial platform fee in basis points.
     */
    function initialize(
        address admin_,
        address premiumManager_,
        address policy_,
        uint16 platformFeeBps_
    )
        external
        initializer
    {
        require(admin_ != address(0) && premiumManager_ != address(0) && policy_ != address(0), ZeroAddress());
        require(platformFeeBps_ <= _MAX_TOTAL_FEE_BPS, InvalidPlatformFee(platformFeeBps_));

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        premiumManager = premiumManager_;
        policy = policy_;
        platformFeeBps = platformFeeBps_;
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function setPremiumManager(address premiumManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(premiumManager_ != address(0), ZeroAddress());
        premiumManager = premiumManager_;
        emit PremiumManagerSet(premiumManager_);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function setPolicy(address policy_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(policy_ != address(0), ZeroAddress());
        policy = policy_;
        emit PolicyContractSet(policy_);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function setPlatformFee(uint16 platformFeeBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(platformFeeBps_ <= _MAX_TOTAL_FEE_BPS, InvalidPlatformFee(platformFeeBps_));
        platformFeeBps = platformFeeBps_;
        emit PlatformFeeSet(platformFeeBps_);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function bindPolicy(BindPolicyRequest calldata request) external override nonReentrant whenNotPaused {
        _validateRequest(request);

        uint256 policyId = ++_nextPolicyId;

        ICoverPool.QuoteData calldata quote = request.quote;
        bytes32 policyCommit = ICoverPool(quote.pool).validateQuote(quote, request.signature);
        require(policyCommit != bytes32(0), InvalidPolicyCommit());

        ICoverPool.BoundPolicy memory boundPolicy =
            ICoverPool(quote.pool).bindPolicy(policyCommit, quote, request.signature);

        IPremiumManager.PremiumAllocation memory allocation = IPremiumManager.PremiumAllocation({
            policyId: policyId,
            policyCommit: policyCommit,
            basePremium: quote.basePremium,
            buyer: request.buyer,
            committeeId: boundPolicy.committeeId,
            premiumToken: request.premiumToken,
            platformFeeBps: platformFeeBps,
            startTime: boundPolicy.startTime,
            maturityTime: boundPolicy.maturityTime,
            poolShare: IPremiumManager.PoolShare({
                coverPool: quote.pool,
                poolFeeBps: ICoverPool(quote.pool).poolFeeBps(),
                poolFeeRecipient: ICoverPool(quote.pool).owner(),
                operator: boundPolicy.operator,
                grossPremium: quote.basePremium
            })
        });

        IPremiumManager(premiumManager).collectPremium(allocation);

        IPolicy.PolicyMetadata memory metadata = IPolicy.PolicyMetadata({
            buyer: request.buyer,
            committeeId: boundPolicy.committeeId,
            beneficiary: request.beneficiary,
            startTime: boundPolicy.startTime,
            premiumToken: request.premiumToken,
            maturityTime: boundPolicy.maturityTime,
            basePremium: quote.basePremium,
            payoutToken: request.payoutToken,
            pool: quote.pool,
            coverageLimit: boundPolicy.coverageLimit,
            payoutReceiver: boundPolicy.payoutReceiver,
            operator: boundPolicy.operator,
            poolPolicyId: boundPolicy.policyId,
            specId: boundPolicy.specId,
            termsHash: boundPolicy.termsHash,
            policyCommit: policyCommit
        });

        IPolicy(policy).mintPolicy(request.buyer, policyId, metadata);

        emit PolicyBound(
            policyId,
            request.buyer,
            request.beneficiary,
            quote.pool,
            boundPolicy.coverageLimit,
            quote.basePremium,
            policyCommit
        );
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function paused() public view override (IPolicyManager, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Validates bind policy request data before processing.
     * @param request Bind policy request to validate.
     */
    function _validateRequest(BindPolicyRequest calldata request) private view {
        require(
            request.buyer != address(0) && request.beneficiary != address(0) && request.premiumToken != address(0)
                && request.payoutToken != address(0),
            ZeroAddress()
        );
        require(request.quote.pool != address(0), InvalidQuotePool());
        require(request.quote.coverageLimit != 0, InvalidCoverageLimit());
        require(request.quote.basePremium != 0, InvalidBasePremium());
        require(
            request.quote.startTime < request.quote.maturityTime && request.quote.maturityTime > block.timestamp,
            InvalidCoverageWindow(request.quote.startTime, request.quote.maturityTime)
        );
    }
}

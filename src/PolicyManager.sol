// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPolicyManager} from "./interfaces/IPolicyManager.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";
import {IPremiumManager} from "./interfaces/IPremiumManager.sol";
import {IPolicy} from "./interfaces/IPolicy.sol";
import {IStakeManager} from "./interfaces/IStakeManager.sol";

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
    /// @dev Maximum allowed combined fees (platform + pool) in basis points (25% = 2500 bps).
    uint16 private constant _MAX_TOTAL_FEE_BPS = 2500;

    address public override premiumManager;
    address public override policy;
    address public override stakeManager;
    address public override claimManager;
    address public override coverPoolFactory;
    uint16 public override platformFeeBps;

    uint256 private _nextPolicyId;
    mapping(uint256 policyId => PolicyDraft draft) private _policyDrafts;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PolicyManager with role assignments and dependency wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address of the PremiumManager contract.
     * @param policy_ Address of the Policy contract.
     * @param stakeManager_ Address of the StakeManager contract.
     * @param claimManager_ Address of the ClaimManager contract.
     * @param coverPoolFactory_ Address of the CoverPoolFactory contract.
     * @param platformFeeBps_ Initial platform fee in basis points.
     */
    function initialize(
        address admin_,
        address premiumManager_,
        address policy_,
        address stakeManager_,
        address claimManager_,
        address coverPoolFactory_,
        uint16 platformFeeBps_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && premiumManager_ != address(0) && policy_ != address(0)
                && stakeManager_ != address(0) && claimManager_ != address(0) && coverPoolFactory_ != address(0),
            ZeroAddress()
        );
        require(platformFeeBps_ <= _MAX_TOTAL_FEE_BPS, InvalidPlatformFee(platformFeeBps_));

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        premiumManager = premiumManager_;
        policy = policy_;
        stakeManager = stakeManager_;
        claimManager = claimManager_;
        coverPoolFactory = coverPoolFactory_;
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
    function setStakeManager(address stakeManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stakeManager_ != address(0), ZeroAddress());
        stakeManager = stakeManager_;
        emit StakeManagerSet(stakeManager_);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function setClaimManager(address claimManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(claimManager_ != address(0), ZeroAddress());
        claimManager = claimManager_;
        emit ClaimManagerSet(claimManager_);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function setCoverPoolFactory(address coverPoolFactory_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(coverPoolFactory_ != address(0), ZeroAddress());
        coverPoolFactory = coverPoolFactory_;
        emit CoverPoolFactorySet(coverPoolFactory_);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function createPolicyDraft(
        address pool,
        address beneficiary,
        address claimer,
        address premiumToken,
        address payoutToken,
        uint256 coverageAmount
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 policyId)
    {
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(pool), InvalidCoverPool(pool));
        require(
            beneficiary != address(0) && claimer != address(0) && premiumToken != address(0)
                && payoutToken != address(0),
            ZeroAddress()
        );
        require(coverageAmount != 0, InvalidCoverageAmount());

        address poolOperator = ICoverPool(pool).poolOperator();
        require(poolOperator != address(0), InvalidPoolOperator());

        policyId = ++_nextPolicyId;
        require(policyId <= type(uint96).max, PolicyIdOverflow());

        uint96 committeeId = uint96(policyId);

        _policyDrafts[policyId] = PolicyDraft({
            pool: pool,
            buyer: msg.sender,
            beneficiary: beneficiary,
            claimer: claimer,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            coverageAmount: coverageAmount,
            committeeId: committeeId,
            status: PolicyStatus.Created
        });

        emit PolicyDraftCreated(policyId, pool, msg.sender, beneficiary, claimer, coverageAmount);

        IStakeManager(stakeManager).createCommittee(committeeId, coverageAmount);
        IStakeManager(stakeManager).addOperatorToCommittee(poolOperator, committeeId);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function cancelPolicyDraft(uint256 policyId) external override nonReentrant whenNotPaused {
        PolicyDraft storage draft = _policyDrafts[policyId];
        require(draft.status != PolicyStatus.None, PolicyDraftNotFound(policyId));
        require(draft.status == PolicyStatus.Created, InvalidPolicyStatus(draft.status));
        require(draft.buyer == msg.sender, NotPolicyBuyer(msg.sender));

        draft.status = PolicyStatus.Cancelled;
        emit PolicyDraftCancelled(policyId, draft.pool);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function bindPolicy(BindPolicyRequest calldata request) external override nonReentrant whenNotPaused {
        _validateRequest(request);

        uint256 policyId = request.policyId;
        PolicyDraft storage draft = _policyDrafts[policyId];
        require(draft.status != PolicyStatus.None, PolicyDraftNotFound(policyId));
        require(draft.pool == msg.sender, PolicyIdNotReserved(policyId));
        require(draft.status == PolicyStatus.Created, InvalidPolicyStatus(draft.status));

        ICoverPool.Quote calldata quote = request.quote;
        uint96 committeeId = quote.committeeId;
        require(uint96(policyId) == committeeId, InvalidCommitteeId());

        draft.status = PolicyStatus.Bound;

        uint256 totalStake = IStakeManager(stakeManager).getOperatorCommitteeStake(quote.operator, committeeId);
        require(
            totalStake >= request.coverageAmount, InsufficientStake(committeeId, request.coverageAmount, totalStake)
        );

        require(IStakeManager(stakeManager).getCommitteeVaults(committeeId).length > 0, NoVaultsBound(committeeId));

        bytes32 policyCommit = ICoverPool(quote.pool).verifyQuote(quote, request.signature);
        require(policyCommit != bytes32(0), InvalidPolicyCommit());

        ICoverPool.BoundPolicy memory boundPolicy =
            ICoverPool(quote.pool).recordBoundPolicy(policyId, policyCommit, quote);

        IPremiumManager.PremiumAllocation memory allocation = IPremiumManager.PremiumAllocation({
            policyId: policyId,
            policyCommit: policyCommit,
            basePremium: quote.basePremium,
            buyer: request.buyer,
            committeeId: committeeId,
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
            committeeId: committeeId,
            beneficiary: request.beneficiary,
            claimer: request.claimer,
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
    function getPolicyDraft(uint256 policyId) external view override returns (PolicyDraft memory draft) {
        draft = _policyDrafts[policyId];
        require(draft.status != PolicyStatus.None, PolicyDraftNotFound(policyId));
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
            request.buyer != address(0) && request.beneficiary != address(0) && request.claimer != address(0)
                && request.premiumToken != address(0) && request.payoutToken != address(0),
            ZeroAddress()
        );
        require(request.policyId != 0, PolicyIdNotReserved(request.policyId));
        require(request.quote.pool != address(0), InvalidCoverPool(request.quote.pool));
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(msg.sender), InvalidCoverPool(msg.sender));
        require(request.quote.pool == msg.sender, UnauthorizedCaller());
        require(request.quote.committeeId != 0, InvalidCommitteeId());
        require(request.quote.coverageLimit != 0, InvalidCoverageLimit());
        require(request.quote.basePremium != 0, InvalidBasePremium());
        require(request.coverageAmount != 0, InvalidCoverageAmount());
        require(
            request.quote.startTime < request.quote.maturityTime && request.quote.maturityTime > block.timestamp,
            InvalidCoverageWindow(request.quote.startTime, request.quote.maturityTime)
        );
    }
}

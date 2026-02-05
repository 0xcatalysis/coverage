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
import {IStakeManager} from "./interfaces/IStakeManager.sol";

/**
 * @title PolicyManager
 * @notice Single entrypoint for binding coverage policies, orchestrating quote validation,
 *         premium settlement, and policy record storage.
 * @dev Integrates with CoverPool for quote validation and PremiumManager for premium collection.
 *      Stores policy metadata directly for efficient access by ClaimManager and other contracts.
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
    address public override stakeManager;
    address public override claimManager;
    address public override coverPoolFactory;
    uint16 public override platformFeeBps;

    uint96 private _nextPolicyId;
    mapping(uint96 policyId => PolicyDraft draft) private _policyDrafts;
    mapping(uint96 policyId => IPolicyManager.PolicyMetadata) private _policies;
    mapping(bytes32 policyCommit => bool registered) private _registeredPolicyCommits;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PolicyManager with role assignments and dependency wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address of the PremiumManager contract.
     * @param stakeManager_ Address of the StakeManager contract.
     * @param claimManager_ Address of the ClaimManager contract.
     * @param coverPoolFactory_ Address of the CoverPoolFactory contract.
     * @param platformFeeBps_ Initial platform fee in basis points.
     */
    function initialize(
        address admin_,
        address premiumManager_,
        address stakeManager_,
        address claimManager_,
        address coverPoolFactory_,
        uint16 platformFeeBps_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && premiumManager_ != address(0) && stakeManager_ != address(0)
                && claimManager_ != address(0) && coverPoolFactory_ != address(0),
            ZeroAddress()
        );
        require(platformFeeBps_ <= _MAX_TOTAL_FEE_BPS, InvalidPlatformFee(platformFeeBps_));

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        premiumManager = premiumManager_;
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
    function requestCoverage(
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
        returns (uint96 policyId)
    {
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(pool), InvalidCoverPool(pool));
        require(
            beneficiary != address(0) && claimer != address(0) && premiumToken != address(0)
                && payoutToken != address(0),
            ZeroAddress()
        );
        require(coverageAmount != 0, InvalidCoverageAmount());

        address curator = ICoverPool(pool).owner();
        require(curator != address(0), InvalidPoolOperator());

        policyId = ++_nextPolicyId;

        uint96 committeeId = policyId;

        _policyDrafts[policyId] = PolicyDraft({
            pool: pool,
            buyer: msg.sender,
            beneficiary: beneficiary,
            claimer: claimer,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            operator: curator,
            coverageAmount: coverageAmount,
            committeeId: committeeId,
            status: PolicyStatus.Created
        });

        emit CoverageRequested(policyId, pool, msg.sender, beneficiary, claimer, coverageAmount);

        IStakeManager(stakeManager).createCommittee(committeeId, coverageAmount);
        IStakeManager(stakeManager).addOperatorToCommittee(curator, committeeId);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function cancelPolicyDraft(uint96 policyId) external override nonReentrant whenNotPaused {
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
        //slither-disable-start reentrancy-benign
        _validateRequest(request);

        uint96 policyId = request.policyId;
        PolicyDraft storage draft = _policyDrafts[policyId];
        require(draft.status != PolicyStatus.None, PolicyDraftNotFound(policyId));
        require(draft.pool == msg.sender, UnauthorizedCaller());
        require(draft.status == PolicyStatus.Created, InvalidPolicyStatus(draft.status));

        require(
            request.buyer == draft.buyer && request.beneficiary == draft.beneficiary && request.claimer == draft.claimer
                && request.premiumToken == draft.premiumToken && request.payoutToken == draft.payoutToken
                && request.coverageAmount == draft.coverageAmount,
            RequestDraftMismatch()
        );

        ICoverPool.Quote calldata quote = request.quote;
        uint96 committeeId = quote.committeeId;
        require(policyId == committeeId, InvalidCommitteeId());

        draft.status = PolicyStatus.Bound;

        require(IStakeManager(stakeManager).getCommitteeVaults(committeeId).length > 0, NoVaultsBound(committeeId));

        uint256 totalStake = IStakeManager(stakeManager).getOperatorCommitteeStake(quote.operator, committeeId);
        require(
            totalStake >= request.coverageAmount, InsufficientStake(committeeId, request.coverageAmount, totalStake)
        );

        bytes32 policyCommit = ICoverPool(quote.pool).verifyQuote(quote, request.signature);
        require(policyCommit != bytes32(0), InvalidPolicyCommit());
        require(!_registeredPolicyCommits[policyCommit], PolicyCommitAlreadyRegistered(policyCommit));

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

        IPolicyManager.PolicyMetadata memory metadata = IPolicyManager.PolicyMetadata({
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

        _registeredPolicyCommits[policyCommit] = true;
        _policies[policyId] = metadata;

        emit PolicyBound(
            policyId,
            request.buyer,
            request.beneficiary,
            quote.pool,
            boundPolicy.coverageLimit,
            quote.basePremium,
            policyCommit
        );

        emit PolicyRegistered(
            policyId,
            request.buyer,
            quote.pool,
            boundPolicy.startTime,
            boundPolicy.maturityTime,
            boundPolicy.coverageLimit,
            policyCommit
        );
        //slither-disable-end reentrancy-benign
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function getPolicyDraft(uint96 policyId) external view override returns (PolicyDraft memory draft) {
        draft = _policyDrafts[policyId];
        require(draft.status != PolicyStatus.None, PolicyDraftNotFound(policyId));
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function policyMetadata(uint96 policyId)
        external
        view
        override
        returns (IPolicyManager.PolicyMetadata memory metadata)
    {
        metadata = _policies[policyId];
        require(metadata.buyer != address(0), PolicyNotFound(policyId));
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

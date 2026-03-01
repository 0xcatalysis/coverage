// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPolicyManager} from "./interfaces/IPolicyManager.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "./interfaces/ICoverPoolFactory.sol";
import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {IBindPolicyHook} from "./interfaces/IBindPolicyHook.sol";

/**
 * @title PolicyManager
 * @notice Single entrypoint for binding coverage policies, orchestrating quote validation,
 *         and policy record storage.
 * @dev Integrates with CoverPool for quote validation. Premium collection is handled separately
 *      by PremiumCollector and PremiumManager. Stores policy metadata directly for efficient
 *      access by ClaimManager and other contracts.
 */
// slither-disable-next-line unimplemented-functions
contract PolicyManager is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IPolicyManager
{
    address public override stakeManager;
    address public override claimManager;
    address public override coverPoolFactory;

    uint96 private _nextPolicyId;
    mapping(uint96 policyId => PolicyDraft draft) private _policyDrafts;
    mapping(uint96 policyId => IPolicyManager.PolicyMetadata) private _policies;
    mapping(bytes32 policyCommit => bool registered) private _registeredPolicyCommits;
    mapping(address token => bool supported) public override supportedPayoutTokens;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PolicyManager with role assignments, dependency wiring, and
     *         optional initial payout token whitelist.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param stakeManager_ Address of the StakeManager contract.
     * @param claimManager_ Address of the ClaimManager contract.
     * @param coverPoolFactory_ Address of the CoverPoolFactory contract.
     * @param initialPayoutTokens_ Payout tokens marked as supported on deployment.
     */
    function initialize(
        address admin_,
        address stakeManager_,
        address claimManager_,
        address coverPoolFactory_,
        address[] calldata initialPayoutTokens_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && stakeManager_ != address(0) && claimManager_ != address(0)
                && coverPoolFactory_ != address(0),
            ZeroAddress()
        );

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        stakeManager = stakeManager_;
        claimManager = claimManager_;
        coverPoolFactory = coverPoolFactory_;

        uint256 tokensLength = initialPayoutTokens_.length;
        for (uint256 i = 0; i < tokensLength; ++i) {
            address token = initialPayoutTokens_[i];
            require(token != address(0), ZeroAddress());
            supportedPayoutTokens[token] = true;
        }
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
    function setSupportedPayoutToken(address token, bool supported) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), ZeroAddress());
        supportedPayoutTokens[token] = supported;
        emit PayoutTokenSet(token, supported);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function requestCoverage(
        address pool,
        address beneficiary,
        address claimer,
        address payoutToken,
        uint256 coverageAmount,
        uint32 duration,
        address bindPolicyHook
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint96 policyId)
    {
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(pool), InvalidCoverPool(pool));
        require(beneficiary != address(0) && claimer != address(0) && payoutToken != address(0), ZeroAddress());
        require(supportedPayoutTokens[payoutToken], UnsupportedPayoutToken(payoutToken));
        require(coverageAmount != 0, InvalidCoverageAmount());
        require(duration != 0, InvalidDuration());
        require(bindPolicyHook != address(0), InvalidBindPolicyHook());

        try IERC165(bindPolicyHook).supportsInterface(type(IBindPolicyHook).interfaceId) returns (bool supported) {
            require(supported, InvalidBindPolicyHook());
        } catch {
            revert InvalidBindPolicyHook();
        }

        address curator = ICoverPool(pool).owner();
        require(curator != address(0), InvalidPoolOperator());

        policyId = ++_nextPolicyId;

        _policyDrafts[policyId] = PolicyDraft({
            pool: pool,
            buyer: msg.sender,
            beneficiary: beneficiary,
            claimer: claimer,
            payoutToken: payoutToken,
            coverageAmount: coverageAmount,
            duration: duration,
            policyId: policyId,
            status: PolicyStatus.Created,
            bindPolicyHook: bindPolicyHook
        });

        emit CoverageRequested(policyId, pool, msg.sender, beneficiary, claimer, coverageAmount, duration);

        // Create committee in core contracts using policyId as committeeId (1:1 mapping).
        IStakeManager(stakeManager).createCommittee(policyId, coverageAmount, pool, duration);
        IStakeManager(stakeManager).addOperatorToCommittee(curator, policyId);
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

        address curator = ICoverPool(draft.pool).owner();
        IStakeManager(stakeManager).removeOperatorFromCommittee(curator, policyId);

        emit PolicyDraftCancelled(policyId, draft.pool);
    }

    /**
     * @inheritdoc IPolicyManager
     */
    function bindPolicy(
        BindPolicyRequest calldata request,
        ICoverPool.BoundPolicy calldata boundPolicy
    )
        external
        override
        nonReentrant
        whenNotPaused
    {
        //slither-disable-start reentrancy-benign
        _validateRequest(request);

        uint96 policyId = request.policyId;
        PolicyDraft storage draft = _policyDrafts[policyId];
        require(draft.status != PolicyStatus.None, PolicyDraftNotFound(policyId));
        require(draft.pool == msg.sender, UnauthorizedCaller());
        require(draft.status == PolicyStatus.Created, InvalidPolicyStatus(draft.status));

        require(
            request.buyer == draft.buyer && request.beneficiary == draft.beneficiary && request.claimer == draft.claimer
                && request.payoutToken == draft.payoutToken && request.coverageAmount == draft.coverageAmount,
            RequestDraftMismatch()
        );

        ICoverPool.Quote calldata quote = request.quote;
        require(policyId == quote.policyId, InvalidPolicyId());

        require(
            boundPolicy.maturityTime - boundPolicy.startTime == draft.duration,
            DurationMismatch(draft.duration, uint32(boundPolicy.maturityTime - boundPolicy.startTime))
        );

        draft.status = PolicyStatus.Bound;

        // Query core contracts using policyId as committeeId (1:1 mapping).
        require(IStakeManager(stakeManager).getCommitteeVaults(policyId).length > 0, NoVaultsBound(policyId));

        uint256 totalStake = IStakeManager(stakeManager).getCommitteeTotalStakeUSD(policyId);
        require(totalStake >= request.coverageAmount, InsufficientStake(policyId, request.coverageAmount, totalStake));

        bytes32 policyCommit = boundPolicy.policyCommit;
        require(policyCommit != bytes32(0), InvalidPolicyCommit());
        require(!_registeredPolicyCommits[policyCommit], PolicyCommitAlreadyRegistered(policyCommit));

        IPolicyManager.PolicyMetadata memory metadata = IPolicyManager.PolicyMetadata({
            buyer: request.buyer,
            policyId: policyId,
            beneficiary: request.beneficiary,
            claimer: request.claimer,
            startTime: boundPolicy.startTime,
            maturityTime: boundPolicy.maturityTime,
            payoutToken: request.payoutToken,
            pool: quote.pool,
            coverageLimit: boundPolicy.coverageLimit,
            specId: boundPolicy.specId,
            termsHash: boundPolicy.termsHash,
            policyCommit: policyCommit
        });

        _registeredPolicyCommits[policyCommit] = true;
        _policies[policyId] = metadata;

        address hook = draft.bindPolicyHook;

        emit PolicyBound(
            policyId, request.buyer, request.beneficiary, quote.pool, boundPolicy.coverageLimit, policyCommit, hook
        );

        IBindPolicyHook(hook).onPolicyBound(policyId, boundPolicy.coverageLimit);
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
                && request.payoutToken != address(0),
            ZeroAddress()
        );
        require(request.quote.pool != address(0), InvalidCoverPool(request.quote.pool));
        require(ICoverPoolFactory(coverPoolFactory).coverPoolExists(msg.sender), InvalidCoverPool(msg.sender));
        require(request.quote.pool == msg.sender, UnauthorizedCaller());
        require(request.quote.policyId != 0, InvalidPolicyId());
        require(request.quote.coverageLimit != 0, InvalidCoverageLimit());
        require(request.coverageAmount != 0, InvalidCoverageAmount());
        require(
            request.quote.startTime < request.quote.maturityTime && request.quote.maturityTime > block.timestamp,
            InvalidCoverageWindow(request.quote.startTime, request.quote.maturityTime)
        );
    }
}

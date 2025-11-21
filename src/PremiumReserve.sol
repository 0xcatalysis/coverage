// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPremiumReserve} from "./interfaces/IPremiumReserve.sol";
import {IRewardsManager} from "./interfaces/IRewardsManager.sol";

/**
 * @title PremiumReserve
 * @notice Holds restaker premiums until maturity or claim execution.
 */
// slither-disable-next-line unimplemented-functions
contract PremiumReserve is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IPremiumReserve
{
    using SafeERC20 for IERC20;

    bytes32 public constant override PREMIUM_MANAGER_ROLE = keccak256("PREMIUM_MANAGER_ROLE");
    bytes32 public constant override CLAIM_MANAGER_ROLE = keccak256("CLAIM_MANAGER_ROLE");
    bytes32 public constant override POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    bytes private constant _COVERAGE_POLICY_TASK = "COVERAGE_POLICY";

    mapping(uint256 => EscrowAccount) private _escrows;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the reserve and configures role assignments.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address granted PREMIUM_MANAGER_ROLE.
     * @param claimManager_ Address granted CLAIM_MANAGER_ROLE.
     * @param policyManager_ Address granted POLICY_MANAGER_ROLE.
     */
    function initialize(
        address admin_,
        address premiumManager_,
        address claimManager_,
        address policyManager_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && premiumManager_ != address(0) && claimManager_ != address(0)
                && policyManager_ != address(0),
            ZeroAddress()
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PREMIUM_MANAGER_ROLE, premiumManager_);
        _grantRole(CLAIM_MANAGER_ROLE, claimManager_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager_);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function openEscrow(EscrowPosition calldata position)
        external
        override
        whenNotPaused
        onlyRole(PREMIUM_MANAGER_ROLE)
    {
        require(position.premiumToken != address(0) && position.buyer != address(0), ZeroAddress());
        require(position.pool != address(0) && position.operator != address(0), InvalidPoolData());
        require(position.policyCommit != bytes32(0), InvalidPolicyCommit());
        require(position.restakerPremiumTotal != 0, ZeroRestakerPremium());
        require(
            position.startTime < position.maturityTime, InvalidCoverageWindow(position.startTime, position.maturityTime)
        );

        EscrowAccount storage escrow = _escrows[position.policyId];
        require(escrow.premiumToken == address(0), EscrowAlreadyExists(position.policyId));

        escrow.restakerPremiumTotal = position.restakerPremiumTotal;
        escrow.premiumToken = position.premiumToken;
        escrow.buyer = position.buyer;
        escrow.pool = position.pool;
        escrow.operator = position.operator;
        escrow.policyCommit = position.policyCommit;
        escrow.startTime = position.startTime;
        escrow.maturityTime = position.maturityTime;
        escrow.claimLocked = false;
        escrow.released = false;

        emit EscrowOpened(position.policyId, position.premiumToken, position.restakerPremiumTotal);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function setClaimLockStatus(
        uint256 policyId,
        bool locked
    )
        external
        override
        whenNotPaused
        onlyRole(CLAIM_MANAGER_ROLE)
    {
        EscrowAccount storage escrow = _escrow(policyId);
        require(!escrow.released, EscrowAlreadyReleased(policyId));

        escrow.claimLocked = locked;
        emit ClaimLockStatusSet(policyId, locked);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function payClaim(
        uint256 policyId,
        address payoutRecipient,
        uint256 settledAmount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(CLAIM_MANAGER_ROLE)
    {
        require(payoutRecipient != address(0), ZeroAddress());
        require(settledAmount != 0, ZeroSettledAmount());

        EscrowAccount storage escrow = _escrow(policyId);
        require(!escrow.released, EscrowAlreadyReleased(policyId));
        require(escrow.claimLocked, EscrowNotLocked(policyId));

        uint256 available = escrow.restakerPremiumTotal;
        require(available >= settledAmount, InsufficientEscrow(policyId, settledAmount, available));

        escrow.restakerPremiumTotal -= settledAmount;
        IERC20(escrow.premiumToken).safeTransfer(payoutRecipient, settledAmount);

        emit ClaimPaid(policyId, settledAmount);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function releaseEscrow(
        uint256 policyId,
        address rewardsManager
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(POLICY_MANAGER_ROLE)
    {
        require(rewardsManager != address(0), ZeroAddress());

        EscrowAccount storage escrow = _escrow(policyId);
        require(!escrow.released, EscrowAlreadyReleased(policyId));
        require(!escrow.claimLocked, EscrowLocked(policyId));
        require(block.timestamp >= escrow.maturityTime, MaturityNotReached(policyId, escrow.maturityTime));

        uint256 totalRestakerPayout = escrow.restakerPremiumTotal;
        if (totalRestakerPayout != 0) {
            IERC20(escrow.premiumToken).safeTransfer(rewardsManager, totalRestakerPayout);
            // slither-disable-next-line calls-loop
            IRewardsManager(rewardsManager)
                .distributeRewards(_COVERAGE_POLICY_TASK, escrow.operator, escrow.policyCommit, totalRestakerPayout);

            emit PremiumReleased(policyId, rewardsManager, totalRestakerPayout);
        }

        escrow.restakerPremiumTotal = 0;
        escrow.released = true;
        emit EscrowReleased(policyId, block.timestamp);
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function escrowPosition(uint256 policyId) external view override returns (EscrowPosition memory position) {
        EscrowAccount storage escrow = _escrow(policyId);

        position.policyId = policyId;
        position.policyCommit = escrow.policyCommit;
        position.restakerPremiumTotal = escrow.restakerPremiumTotal;
        position.premiumToken = escrow.premiumToken;
        position.buyer = escrow.buyer;
        position.pool = escrow.pool;
        position.operator = escrow.operator;
        position.startTime = escrow.startTime;
        position.maturityTime = escrow.maturityTime;
        position.claimLocked = escrow.claimLocked;
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function isEscrowReleased(uint256 policyId) external view override returns (bool) {
        EscrowAccount storage escrow = _escrows[policyId];
        return escrow.released;
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function isEscrowLocked(uint256 policyId) external view override returns (bool) {
        EscrowAccount storage escrow = _escrows[policyId];
        return escrow.claimLocked;
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function getRemainingPremium(uint256 policyId) external view override returns (uint256) {
        EscrowAccount storage escrow = _escrows[policyId];
        return escrow.restakerPremiumTotal;
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function getPool(uint256 policyId) external view override returns (address) {
        EscrowAccount storage escrow = _escrows[policyId];
        return escrow.pool;
    }

    /**
     * @inheritdoc IPremiumReserve
     */
    function paused() public view override (IPremiumReserve, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Loads an escrow account from storage, reverting when the policy has no escrow.
     * @dev This helper centralizes the not-found guard so that all internal callers receive a
     *      consistent error surface.
     * @param policyId Identifier of the policy whose escrow should be returned.
     * @return escrow Storage pointer to the located escrow account.
     */
    function _escrow(uint256 policyId) private view returns (EscrowAccount storage escrow) {
        escrow = _escrows[policyId];
        require(escrow.premiumToken != address(0), EscrowNotFound(policyId));
    }
}

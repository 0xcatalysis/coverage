// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultAccrual} from "./CoveredVaultAccrual.sol";
import {IVaultV2} from "../../interfaces/Morpho/IVaultV2.sol";
import {IAlerts as IA} from "../../interfaces/IAlerts.sol";
import {IEvents as IE} from "../../interfaces/IEvents.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CoveredVaultAdmin
/// @notice Timelocked parameter setters, UUPS upgrade governance, Morpho gate, and rescue for CoveredVaultWrapper.
/// @dev All owner-only administrative functions. Uses differentiated timelocks:
///      - UPGRADE_DELAY (7 days) for UUPS logic upgrades
///      - STANDARD_DELAY (2 days) for coverage-term changes
///      - OPERATIONAL_DELAY (2 hours) for rate parameters needing fast stress response
abstract contract CoveredVaultAdmin is CoveredVaultAccrual {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                    TIMELOCKED PARAMETER SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes a new premium rate. Call executePremiumRate() after the delay to apply.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function setPremiumRate(uint256 newRate) external override onlyOwner {
        require(newRate <= MAX_PREMIUM_RATE_PER_SECOND, IA.InvalidParameters());
        pendingPremiumRateTimestamp = _propose(pendingPremiumRateTimestamp, "premiumRate", OPERATIONAL_DELAY);
        pendingPremiumRate = newRate;
        emit IE.PremiumRateProposed(newRate, pendingPremiumRateTimestamp);
    }

    /// @notice Applies a pending premium rate change after the operational timelock elapses.
    function executePremiumRate() external override onlyOwner {
        _requireTimelockReady(pendingPremiumRateTimestamp);
        // Settle any premium accrued at the old rate before switching.
        _accruePremium();
        lastPremiumAccrualTime = block.timestamp;
        uint256 oldRate = premiumRatePerSecond;
        uint256 newRate = pendingPremiumRate;
        premiumRatePerSecond = newRate;
        pendingPremiumRate = 0;
        pendingPremiumRateTimestamp = 0;
        emit IE.PremiumRateExecuted(oldRate, newRate);
    }

    /// @dev Call executeMaxCoverableLossBps() after the delay to apply the pending value.
    function setMaxCoverableLossBps(uint16 newBps) external override onlyOwner {
        require(newBps > 0 && newBps <= BPS_DENOMINATOR, IA.InvalidMaxCoverableLoss());
        pendingMaxCoverableLossTimestamp =
            _propose(pendingMaxCoverableLossTimestamp, "maxCoverableLossBps", STANDARD_DELAY);
        pendingMaxCoverableLossBps = newBps;
        emit IE.MaxCoverableLossBpsProposed(newBps, pendingMaxCoverableLossTimestamp);
    }

    /// @notice Applies a pending maxCoverableLossBps change after the standard timelock elapses.
    function executeMaxCoverableLossBps() external override onlyOwner {
        _requireTimelockReady(pendingMaxCoverableLossTimestamp);
        uint16 newBps = pendingMaxCoverableLossBps;
        uint16 oldBps = maxCoverableLossBps;
        if (policyBoundExecuted) {
            depositCap = (coverageLimit * BPS_DENOMINATOR) / uint256(newBps);
        }
        maxCoverableLossBps = newBps;
        pendingMaxCoverableLossBps = 0;
        pendingMaxCoverableLossTimestamp = 0;
        emit IE.MaxCoverableLossBpsExecuted(oldBps, newBps);
    }

    /// @dev Call executeUnderlyingExpectedLossBps() after the delay to apply the pending value.
    function setUnderlyingExpectedLossBps(uint256 newBps) external override onlyOwner {
        require(newBps <= MAX_EXPECTED_LOSS_BPS, IA.InvalidParameters());
        pendingExpectedLossTimestamp =
            _propose(pendingExpectedLossTimestamp, "underlyingExpectedLossBps", OPERATIONAL_DELAY);
        pendingExpectedLossBps = newBps;
        emit IE.UnderlyingExpectedLossBpsProposed(newBps, pendingExpectedLossTimestamp);
    }

    /// @notice Applies a pending underlyingExpectedLossBps change after the operational timelock elapses.
    function executeUnderlyingExpectedLossBps() external override onlyOwner {
        _requireTimelockReady(pendingExpectedLossTimestamp);
        // Settle accrual at the old rate before switching, same as setPremiumRate.
        _accruePremium();
        lastPremiumAccrualTime = block.timestamp;
        uint256 oldBps = underlyingExpectedLossBps;
        uint256 newBps = pendingExpectedLossBps;
        underlyingExpectedLossBps = newBps;
        pendingExpectedLossBps = 0;
        pendingExpectedLossTimestamp = 0;
        emit IE.UnderlyingExpectedLossBpsExecuted(oldBps, newBps);
    }

    /// @dev Call executeDeductibleBps() after the delay to apply the pending value.
    function setDeductibleBps(uint16 newBps) external override onlyOwner {
        require(newBps < BPS_DENOMINATOR, IA.InvalidParameters());
        pendingDeductibleTimestamp = _propose(pendingDeductibleTimestamp, "deductibleBps", STANDARD_DELAY);
        pendingDeductibleBps = newBps;
        emit IE.DeductibleBpsProposed(newBps, pendingDeductibleTimestamp);
    }

    /// @notice Applies a pending deductibleBps change after the standard timelock elapses.
    function executeDeductibleBps() external override onlyOwner {
        _requireTimelockReady(pendingDeductibleTimestamp);
        uint16 oldBps = deductibleBps;
        uint16 newBps = pendingDeductibleBps;
        deductibleBps = newBps;
        pendingDeductibleBps = 0;
        pendingDeductibleTimestamp = 0;
        emit IE.DeductibleBpsExecuted(oldBps, newBps);
    }

    /// @dev Now uses propose/execute pattern consistent with all other parameter changes.
    function setPremiumRecipient(address newRecipient) external override onlyOwner {
        require(newRecipient != address(0), IA.ZeroAddress());
        pendingPremiumRecipientTimestamp =
            _propose(pendingPremiumRecipientTimestamp, "premiumRecipient", STANDARD_DELAY);
        pendingPremiumRecipient = newRecipient;
        emit IE.PremiumRecipientProposed(newRecipient, pendingPremiumRecipientTimestamp);
    }

    /// @notice Applies a pending premium recipient change after the standard timelock elapses.
    function executePremiumRecipient() external override onlyOwner {
        _requireTimelockReady(pendingPremiumRecipientTimestamp);
        address oldRecipient = premiumRecipient;
        address newRecipient = pendingPremiumRecipient;
        premiumRecipient = newRecipient;
        pendingPremiumRecipient = address(0);
        pendingPremiumRecipientTimestamp = 0;
        emit IE.PremiumRecipientExecuted(oldRecipient, newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                    UUPS UPGRADE GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Clear all pending timelocked proposals on ownership transfer.
    function acceptOwnership() public override {
        super.acceptOwnership();
        pendingPremiumRateTimestamp = 0;
        pendingDeductibleTimestamp = 0;
        pendingMaxCoverableLossTimestamp = 0;
        pendingExpectedLossTimestamp = 0;
        pendingUpgradeTimestamp = 0;
        pendingImplementation = address(0);
        pendingPremiumRecipientTimestamp = 0;
    }

    /// @notice Prevents ownership renunciation which would permanently brick all onlyOwner functions
    ///         and the UUPS upgrade path.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Proposes a UUPS upgrade with a 7-day timelock
    function proposeUpgrade(address newImplementation) external override onlyOwner {
        require(newImplementation != address(0), IA.ZeroAddress());
        pendingUpgradeTimestamp = _propose(pendingUpgradeTimestamp, "upgrade", UPGRADE_DELAY);
        pendingImplementation = newImplementation;
        emit IE.UpgradeProposed(newImplementation, pendingUpgradeTimestamp);
    }

    /// @notice Executes a pending UUPS upgrade after the 7-day timelock elapses
    function executeUpgrade() external override onlyOwner {
        _requireTimelockReady(pendingUpgradeTimestamp);
        address impl = pendingImplementation;
        emit IE.UpgradeExecuted(impl);
        // upgradeToAndCall → _authorizeUpgrade reads pendingImplementation, so clear AFTER the call.
        upgradeToAndCall(impl, "");
        pendingUpgradeTimestamp = 0;
        pendingImplementation = address(0);
    }

    /// @dev UUPS authorization gate. Since upgradeToAndCall is public on UUPSUpgradeable, this function
    ///      is the ONLY enforcement point — it must independently verify owner, timelock, and implementation match.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(
            newImplementation == pendingImplementation && pendingUpgradeTimestamp != 0
                && block.timestamp >= pendingUpgradeTimestamp,
            IA.NotAuthorizedUpgrader(msg.sender)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    MORPHO GATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Toggles Morpho gate status to pause/resume premium accrual.
    /// @dev On activation: records timestamp and caches Morpho value as fallback.
    ///      On deactivation: extends policy grace period by the gate duration.
    function setMorphoGateActive(bool active) external override onlyOwner {
        _accruePremium();
        if (active && !morphoGateActive) {
            // Gate activated — record timestamp and try to cache current Morpho value
            gateActivatedAt = block.timestamp;
            try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (
                uint256 val
            ) {
                lastKnownMorphoValue = val;
            } catch {}
        } else if (!active && morphoGateActive && gateActivatedAt > 0) {
            // Gate lifted — extend grace period by the gate duration
            uint256 gateDuration = block.timestamp - gateActivatedAt;
            gateGracePeriod += gateDuration;
            gateActivatedAt = 0;
        }
        morphoGateActive = active;
        emit IE.MorphoGateStatusUpdated(active);
    }

    /*//////////////////////////////////////////////////////////////
                    RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Rescues tokens accidentally sent to this contract
    /// @param token The ERC-20 token to rescue
    /// @param amount The amount to rescue
    /// @param to The address to send rescued tokens to
    function rescueTokens(address token, uint256 amount, address to) external override onlyOwner {
        require(to != address(0), IA.ZeroAddress());
        if (token == asset()) {
            // For the underlying asset: only allow sweeping balance above pendingPremium
            // Guard against underflow when pendingPremium > balance
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 reserved = pendingPremium;
            uint256 sweepable = balance >= reserved ? balance - reserved : 0;
            require(amount <= sweepable, IA.InvalidParameters());
        } else if (token == morphoVault) {
            // For Morpho shares: only allow sweeping surplus above tracked user shares
            uint256 balance = IVaultV2(morphoVault).balanceOf(address(this));
            uint256 trackedShares = totalPrincipal > 0 ? balance : 0; // conservative: if users exist, don't sweep
            require(amount <= balance - trackedShares, IA.InvalidParameters());
        }
        IERC20(token).safeTransfer(to, amount);
        emit IE.TokensRescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates that a timelocked proposal is ready to execute.
    function _requireTimelockReady(uint64 timestamp) private view {
        if (timestamp == 0) revert NoPendingChange();
        if (block.timestamp < timestamp) revert DelayNotElapsed();
    }

    /// @dev Shared propose logic: emits supersede event if overwriting, returns new execute-after timestamp.
    function _propose(uint64 currentTimestamp, bytes32 paramKey, uint256 delay) private returns (uint64 executeAfter) {
        if (currentTimestamp != 0) emit IE.ProposalSuperseded(paramKey);
        executeAfter = uint64(block.timestamp + delay);
    }
}

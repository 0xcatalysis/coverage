// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultStorage} from "./CoveredVaultStorage.sol";
import {IVaultV2} from "../../interfaces/Morpho/IVaultV2.sol";
import {IEvents as IE} from "../../interfaces/IEvents.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CoveredVaultAccrual
/// @notice Premium and expected-loss accrual engine for CoveredVaultWrapper.
/// @dev Implements the reward-per-token accumulator pattern for both premium and expected loss.
///      All time-windowing uses _activeElapsedFrom() as the single source of truth.
abstract contract CoveredVaultAccrual is CoveredVaultStorage {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                    PREMIUM / EXPECTED-LOSS ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Accrues premium and expected loss up to the current block, then advances the checkpoint.
    ///      Called on every deposit, withdraw, and collectPremium.
    // slither-disable-next-line incorrect-equality
    function _accruePremium() internal {
        uint256 checkpointTime = lastPremiumAccrualTime;

        // Always advance the timestamp unconditionally so that when a new policy is later bound,
        // there is no catch-up accrual for the inactive gap period.
        lastPremiumAccrualTime = block.timestamp;

        if (block.timestamp == checkpointTime) return;

        // Skip all accrual when Morpho gate is active (owner-toggled).
        // Timestamp is still advanced above to prevent catch-up accrual when gate is lifted.
        if (morphoGateActive) return;

        // Compute the active portion of the elapsed window via the shared helper.
        uint256 activeElapsed = _activeElapsedFrom(checkpointTime);

        if (activeElapsed == 0) return;

        // Fetch Morpho value once for both premium and EL caps.
        uint256 morphoValue = _morphoValue();
        lastKnownMorphoValue = morphoValue;

        // Cache hot storage reads
        uint256 _totalPrincipal = totalPrincipal;
        uint256 _elBps = underlyingExpectedLossBps;

        // Advance expected loss accumulator for the active elapsed period.
        if (_elBps > 0 && _totalPrincipal > 0) {
            uint256 elIncrement = _totalPrincipal.mulDiv(
                _elBps * activeElapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
            );
            // Cap totalExpectedLossLiability against morphoValue headroom
            uint256 elHeadroom = _liabilityHeadroom(morphoValue);
            if (elIncrement > elHeadroom) {
                // Cap per-unit accumulator proportionally when headroom is exhausted.
                uint256 cappingFactor = elHeadroom.mulDiv(WAD, elIncrement);
                cumulativeExpectedLossPerUnit += _elBps.mulDiv(
                    activeElapsed * cappingFactor, BPS_DENOMINATOR * 365 days
                );
                elIncrement = elHeadroom;
            } else {
                cumulativeExpectedLossPerUnit += _elBps.mulDiv(activeElapsed * WAD, BPS_DENOMINATOR * 365 days);
            }
            totalExpectedLossLiability += elIncrement;
        }

        // Compute accrued premium using the active elapsed window.
        uint256 accrued = _totalPrincipal > 0
            ? _totalPrincipal.mulDiv(premiumRatePerSecond * activeElapsed, WAD, Math.Rounding.Floor)
            : 0;

        if (accrued == 0) return;

        // Cap: combined liabilities must not exceed current Morpho value
        uint256 maxNewLiability = _liabilityHeadroom(morphoValue);
        if (accrued > maxNewLiability) accrued = maxNewLiability;
        if (accrued == 0) return;
        if (_totalPrincipal > 0) {
            cumulativePremiumPerUnit += accrued.mulDiv(WAD, _totalPrincipal);
        }
        totalPremiumLiability += accrued;
    }

    /// @notice Accrues and transfers any pending premium to premiumRecipient
    function collectPremium() external override nonReentrant {
        _accruePremium();
        uint256 pending = pendingPremium;
        if (pending > 0) {
            pendingPremium = 0;
            IERC20(asset()).safeTransfer(premiumRecipient, pending);
            emit IE.PremiumCollected(premiumRecipient, pending);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ACCRUAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns pending (uncheckpointed) expected-loss accrual for the current elapsed window.
    /// @dev Uses the same active-window logic as _accruedPremium() so totalAssets() remains consistent
    ///      with calculateShortfall() and does not overstate NAV between accrual checkpoints.
    // slither-disable-next-line incorrect-equality,dead-code
    function _accruedExpectedLossFor(uint256 morphoVal) internal view returns (uint256) {
        if (morphoGateActive) return 0;
        if (underlyingExpectedLossBps == 0 || totalPrincipal == 0) return 0;
        uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);
        if (elapsed == 0) return 0;
        uint256 accrued = totalPrincipal.mulDiv(
            underlyingExpectedLossBps * elapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
        );
        uint256 elHeadroom = _liabilityHeadroom(morphoVal);
        return accrued < elHeadroom ? accrued : elHeadroom;
    }

    /// @notice Returns accrued-but-unprocessed premium owed to premiumRecipient
    /// @dev Computes the active elapsed window:
    ///      - If policy is currently active: full [lastCheckpoint, now] window.
    ///      - If policy just expired and lastCheckpoint < maturityTime: only [lastCheckpoint, maturityTime].
    ///      - Otherwise: 0 (no phantom premium after expiry is fully settled).
    // slither-disable-next-line incorrect-equality
    function _accruedPremium() internal view returns (uint256) {
        return _accruedPremiumFor(_morphoValue());
    }

    // slither-disable-next-line incorrect-equality
    function _accruedPremiumFor(uint256 morphoVal) internal view returns (uint256) {
        if (morphoGateActive) return 0;
        if (totalPrincipal == 0 || premiumRatePerSecond == 0) return 0;
        uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);
        if (elapsed == 0) return 0;
        uint256 accrued = totalPrincipal.mulDiv(premiumRatePerSecond * elapsed, WAD, Math.Rounding.Floor);
        if (accrued == 0) return 0;
        uint256 maxNewLiability = _liabilityHeadroom(morphoVal);
        return accrued < maxNewLiability ? accrued : maxNewLiability;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the number of seconds that should count toward accrual starting from `checkpoint`.
    ///      - Policy active: full [checkpoint, now] window.
    ///      - Policy expired, checkpoint < maturityTime: only [max(checkpoint, startTime), maturityTime].
    ///      - No policy or window already settled: 0.
    ///      Single source of truth for the active-window calculation used by _accruedExpectedLoss,
    ///      _accruedPremium, _accruePremium, and _userTotalExpectedLoss.
    function _activeElapsedFrom(uint256 checkpoint) internal view returns (uint256) {
        if (_isPolicyActive()) {
            return block.timestamp - checkpoint;
        }
        if (policyId != 0) {
            IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);
            // Use effective maturity (raw + grace period) so that premium/EL accrues through
            // the gate grace window, consistent with _isPolicyActive().
            uint256 effectiveMaturity = uint256(meta.maturityTime) + gateGracePeriod;
            // Guard: only fire the catch-up branch after the policy has started.
            if (
                meta.buyer != address(0) && effectiveMaturity > checkpoint && block.timestamp >= uint256(meta.startTime)
            ) {
                uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
                if (effectiveMaturity > activeStart) {
                    return effectiveMaturity - activeStart;
                }
            }
        }
        return 0;
    }

    /// @notice Returns the total Morpho vault value, falling back to cached value on revert
    function _morphoValue() internal view returns (uint256) {
        try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (
            uint256 val
        ) {
            return val;
        } catch {
            return lastKnownMorphoValue;
        }
    }

    /// @notice Checks if the policy is currently active (bound and within coverage window)
    /// @dev Extends maturityTime by gateGracePeriod so users trapped behind a
    ///      Morpho gate retain insurance eligibility for the duration of the gate overlap.
    // slither-disable-next-line incorrect-equality
    function _isPolicyActive() internal view returns (bool) {
        if (policyId == 0) return false;
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
        uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
        return
            metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
    }

    /// @dev Maximum additional liability the protocol can absorb given the current Morpho value.
    function _liabilityHeadroom(uint256 morphoVal) internal view returns (uint256) {
        uint256 totalLiability = totalPremiumLiability + totalExpectedLossLiability;
        return morphoVal > totalLiability ? morphoVal - totalLiability : 0;
    }
}

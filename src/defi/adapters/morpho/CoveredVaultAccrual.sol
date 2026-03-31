// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultStorage} from "./CoveredVaultStorage.sol";
import {IVaultV2} from "../../interfaces/Morpho/IVaultV2.sol";
import {IEvents as IE} from "../../interfaces/IEvents.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {IPremiumManager} from "coverage/interfaces/IPremiumManager.sol";
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

    /// @dev Accrues premium up to the current block, then advances the checkpoint.
    ///      Called on every deposit, withdraw, and collectPremium.
    ///
    ///      IMPORTANT: `lastPremiumAccrualTime` is advanced unconditionally — even when the rate is
    ///      zero, no policy is bound, or the gate is active. This intentional design prevents
    ///      "catch-up" accrual when conditions change (e.g. a new policy is bound, the rate is set
    ///      from zero, or the gate is lifted). Without this, time that passed under non-accruing
    ///      conditions would be retroactively charged as premium.
    // slither-disable-next-line incorrect-equality
    function _accruePremium() internal {
        uint256 checkpointTime = lastPremiumAccrualTime;

        // Always advance the timestamp unconditionally — see NatDoc above for rationale.
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

        // Compute accrued premium using the active elapsed window.
        // Principal is scaled to 18-decimal precision before arithmetic so that sub-unit amounts
        // are not silently discarded for 6-decimal tokens (e.g. USDC). premiumScaleFactor == 1
        // for 18-decimal tokens, making this a no-op for those vaults.
        uint256 accrued = 0;
        if (_totalPrincipal > 0) {
            uint256 rateXtime = premiumRatePerSecond * activeElapsed;
            uint256 accruedWad = (_totalPrincipal * premiumScaleFactor).mulDiv(rateXtime, WAD, Math.Rounding.Floor)
                + premiumAccrualRemainder;
            // slither-disable-next-line divide-before-multiply
            accrued = accruedWad / premiumScaleFactor;
            premiumAccrualRemainder = accruedWad - accrued * premiumScaleFactor;
        } else {
            premiumAccrualRemainder = 0;
        }

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

    /// @notice Accrues and transfers any pending premium to premiumRecipient, then routes it
    ///         through PremiumManager so pool fees and restaker rewards are distributed correctly.
    /// @dev premiumRecipient must be set to the PremiumManager address.
    ///      The vault holds the routing context (coverPool, policyId) and calls distributePremium()
    ///      directly. distributePremium() is permissionless — the vault transfers tokens to
    ///      PremiumManager first, then calls distributePremium() in the same transaction.
    function collectPremium() external override nonReentrant {
        _accruePremium();
        uint256 pending = pendingPremium;
        if (pending > 0) {
            pendingPremium = 0;
            address assetAddr = asset();
            // Route through PremiumManager only when a policy is bound so that pool and
            // policyId context is valid. Before binding, premiums cannot accrue anyway
            // (premiumRatePerSecond defaults to 0 and lastPremiumAccrualTime is unset),
            // so this guard is a belt-and-suspenders safety check.
            //
            // Pull model: approve PremiumManager to pull `pending` tokens, then call
            // distributePremium. forceApprove avoids residual allowance from any prior
            // failed call.
            if (policyId != 0) {
                IERC20(assetAddr).forceApprove(premiumRecipient, pending);
                IPremiumManager(premiumRecipient).distributePremium(coverPool, policyId, assetAddr, pending);
            } else {
                IERC20(assetAddr).safeTransfer(premiumRecipient, pending);
            }
            emit IE.PremiumCollected(premiumRecipient, pending);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ACCRUAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        uint256 rateXtime = premiumRatePerSecond * elapsed;
        uint256 accruedWad =
            (totalPrincipal * premiumScaleFactor).mulDiv(rateXtime, WAD, Math.Rounding.Floor) + premiumAccrualRemainder;
        uint256 accrued = accruedWad / premiumScaleFactor;
        if (accrued == 0) return 0;
        uint256 maxNewLiability = _liabilityHeadroom(morphoVal);
        return accrued < maxNewLiability ? accrued : maxNewLiability;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the number of seconds that should count toward accrual starting from `checkpoint`.
    ///      - Policy active: full [checkpoint, now] window.
    ///      - Policy expired, checkpoint < maturityTime: only [max(checkpoint, policyStartTime), maturityTime].
    ///      - No policy or window already settled: 0.
    ///      Single source of truth for the active-window calculation used by
    ///      _accruedPremium and _accruePremium.
    ///
    ///      policyStartTime is set to block.timestamp in onPolicyBound, which is also when deposits
    ///      open and lastPremiumAccrualTime is initialised. Therefore checkpoint >= policyStartTime
    ///      always holds in practice and the clamp below is a no-op under normal operation; it is
    ///      retained as a defensive guard.
    function _activeElapsedFrom(uint256 checkpoint) internal view returns (uint256) {
        if (policyId == 0) return 0;
        // Fetch metadata for maturity time and existence check (buyer != address(0)).
        // startTime is no longer read from metadata — the wrapper uses policyStartTime instead.
        // Wrapped in try/catch so that a PolicyManager outage does not revert deposits, withdrawals,
        // or gate-management calls. Fallback: treat as no elapsed time (no accrual).
        try _policyManager.policyMetadata(policyId) returns (IPolicyManager.PolicyMetadata memory meta) {
            uint256 rawMaturity = uint256(meta.maturityTime);
            uint256 _policyStartTime = policyStartTime;
            if (meta.buyer != address(0) && block.timestamp >= _policyStartTime && block.timestamp < rawMaturity) {
                // Policy is active: clamp checkpoint to policyStartTime as a defensive guard.
                uint256 activeStart = checkpoint < _policyStartTime ? _policyStartTime : checkpoint;
                return block.timestamp - activeStart;
            }
            // Policy expired: cap at rawMaturity so premium does not accrue past the claim-eligible window.
            if (meta.buyer != address(0) && rawMaturity > checkpoint && block.timestamp >= _policyStartTime) {
                uint256 activeStart = checkpoint > _policyStartTime ? checkpoint : _policyStartTime;
                if (rawMaturity > activeStart) {
                    return rawMaturity - activeStart;
                }
            }
            return 0;
        } catch {
            return 0;
        }
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
    /// @dev Uses raw maturityTime from PolicyManager because ClaimManager enforces the raw policy
    ///      maturity for claim eligibility. Accepting a claim after raw maturity would be rejected
    ///      by ClaimManager regardless.
    // slither-disable-next-line incorrect-equality
    function _isPolicyActive() internal view returns (bool) {
        if (policyId == 0) return false;
        // Wrapped in try/catch so that a PolicyManager outage does not revert withdrawals.
        // Fallback: return false (no insurance payout) — a temporary degradation, not permanent loss.
        try _policyManager.policyMetadata(policyId) returns (IPolicyManager.PolicyMetadata memory metadata) {
            return metadata.buyer != address(0) && block.timestamp >= policyStartTime
                && block.timestamp < uint256(metadata.maturityTime);
        } catch {
            return false;
        }
    }

    /// @dev Maximum additional liability the protocol can absorb given the current Morpho value.
    function _liabilityHeadroom(uint256 morphoVal) internal view returns (uint256) {
        return morphoVal > totalPremiumLiability ? morphoVal - totalPremiumLiability : 0;
    }
}

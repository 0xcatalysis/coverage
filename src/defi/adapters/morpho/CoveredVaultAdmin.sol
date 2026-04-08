// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultAccrual} from "./CoveredVaultAccrual.sol";
import {IERC4626 as IMorphoVault} from "vault-v2/interfaces/IERC4626.sol";
import {IAlerts as IA} from "../../interfaces/IAlerts.sol";
import {IEvents as IE} from "../../interfaces/IEvents.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {IPremiumManager} from "coverage/interfaces/IPremiumManager.sol";
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
    ///         Exception: if the policy is bound but no rate has ever been applied (premiumRatePerSecond == 0),
    ///         the first call applies the rate immediately without a timelock.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function setPremiumRate(uint256 newRate) external override onlyOwner {
        require(newRate <= MAX_PREMIUM_RATE_PER_SECOND, IA.InvalidParameters());

        // Fast-path: policy is bound but no rate has been applied yet — apply immediately.
        if (policyBoundExecuted && premiumRatePerSecond == 0) {
            _accruePremium();
            pendingPremiumRate = 0;
            pendingPremiumRateTimestamp = 0;
            premiumRatePerSecond = newRate;
            emit IE.PremiumRateExecuted(0, newRate);
            return;
        }

        pendingPremiumRateTimestamp = _propose(pendingPremiumRateTimestamp, "premiumRate", OPERATIONAL_DELAY);
        pendingPremiumRate = newRate;
        emit IE.PremiumRateProposed(newRate, pendingPremiumRateTimestamp);
    }

    /// @notice Applies a pending premium rate change after the operational timelock elapses.
    function executePremiumRate() external override onlyOwner {
        _requireTimelockReady(pendingPremiumRateTimestamp);
        // Settle any premium accrued at the old rate before switching.
        _accruePremium();
        uint256 oldRate = premiumRatePerSecond;
        uint256 newRate = pendingPremiumRate;
        premiumRatePerSecond = newRate;
        pendingPremiumRate = 0;
        pendingPremiumRateTimestamp = 0;
        emit IE.PremiumRateExecuted(oldRate, newRate);
    }

    /// @notice Updates the maximum coverable loss in basis points.
    ///         Only callable before the policy is bound — coverage terms are locked at binding.
    function setMaxCoverableLossBps(uint16 newBps) external override onlyOwner {
        require(!policyBoundExecuted, IA.InvalidMaxCoverableLoss());
        require(newBps > 0 && newBps <= BPS_DENOMINATOR, IA.InvalidMaxCoverableLoss());
        require(newBps > deductibleBps, IA.InvalidMaxCoverableLoss());
        uint16 oldBps = maxCoverableLossBps;
        maxCoverableLossBps = newBps;
        emit IE.MaxCoverableLossBpsUpdated(oldBps, newBps);
    }

    /// @notice Proposes a new depositCap (standard timelock). Must not exceed the formula ceiling
    ///         derived from coverageLimit and maxCoverableLossBps. Allows the owner to tighten the
    ///         cap independently of payout terms — e.g. to stop new deposits when the underlying
    ///         vault is at elevated risk without changing maxCoverableLossBps for existing users.
    function setDepositCap(uint256 newCap) external override onlyOwner {
        require(policyBoundExecuted, IA.InvalidParameters());
        uint256 ceiling = (coverageLimit * BPS_DENOMINATOR) / uint256(maxCoverableLossBps);
        require(newCap <= ceiling, IA.InvalidParameters());
        pendingDepositCapTimestamp = _propose(pendingDepositCapTimestamp, "depositCap", STANDARD_DELAY);
        pendingDepositCap = newCap;
        emit IE.DepositCapProposed(newCap, pendingDepositCapTimestamp);
    }

    /// @notice Applies a pending depositCap change after the standard timelock elapses.
    function executeDepositCap() external override onlyOwner {
        _requireTimelockReady(pendingDepositCapTimestamp);
        uint256 oldCap = depositCap;
        uint256 newCap = pendingDepositCap;
        // Re-validate ceiling at execution time in case maxCoverableLossBps changed since proposal.
        uint256 ceiling = (coverageLimit * BPS_DENOMINATOR) / uint256(maxCoverableLossBps);
        require(newCap <= ceiling, IA.InvalidParameters());
        depositCap = newCap;
        pendingDepositCap = 0;
        pendingDepositCapTimestamp = 0;
        emit IE.DepositCapExecuted(oldCap, newCap);
    }

    /// @dev Call executeDeductibleBps() after the delay to apply the pending value.
    function setDeductibleBps(uint16 newBps) external override onlyOwner {
        require(newBps < BPS_DENOMINATOR, IA.InvalidParameters());
        require(newBps < maxCoverableLossBps, IA.InvalidParameters());
        pendingDeductibleTimestamp = _propose(pendingDeductibleTimestamp, "deductibleBps", STANDARD_DELAY);
        pendingDeductibleBps = newBps;
        emit IE.DeductibleBpsProposed(newBps, pendingDeductibleTimestamp);
    }

    /// @notice Applies a pending deductibleBps change after the standard timelock elapses.
    function executeDeductibleBps() external override onlyOwner {
        _requireTimelockReady(pendingDeductibleTimestamp);
        uint16 oldBps = deductibleBps;
        uint16 newBps = pendingDeductibleBps;
        // Re-validate at execution time in case maxCoverableLossBps changed since proposal.
        require(newBps < maxCoverableLossBps, IA.InvalidParameters());
        deductibleBps = newBps;
        pendingDeductibleBps = 0;
        pendingDeductibleTimestamp = 0;
        emit IE.DeductibleBpsExecuted(oldBps, newBps);
    }

    /// @dev Now uses propose/execute pattern consistent with all other parameter changes.
    ///      newRecipient must implement IPremiumManager (verified by calling platformTreasury()).
    ///      This guards against accidentally setting an EOA or unrelated contract as recipient,
    ///      which would cause collectPremium() to permanently revert when a policy is bound.
    function setPremiumRecipient(address newRecipient) external override onlyOwner {
        require(newRecipient != address(0), IA.ZeroAddress());
        if (newRecipient.code.length == 0) revert IA.InvalidPremiumRecipient();
        try IPremiumManager(newRecipient).platformTreasury() returns (address treasury) {
            require(treasury != address(0), IA.InvalidPremiumRecipient());
        } catch {
            revert IA.InvalidPremiumRecipient();
        }
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
    ///         Both the pending values AND their timestamps are zeroed so the incoming owner
    ///         cannot inadvertently execute proposals queued by the outgoing owner.
    function acceptOwnership() public override {
        super.acceptOwnership();
        pendingPremiumRate = 0;
        pendingPremiumRateTimestamp = 0;
        pendingDeductibleBps = 0;
        pendingDeductibleTimestamp = 0;
        pendingImplementation = address(0);
        pendingUpgradeTimestamp = 0;
        pendingPremiumRecipient = address(0);
        pendingPremiumRecipientTimestamp = 0;
        pendingDepositCap = 0;
        pendingDepositCapTimestamp = 0;
    }

    /// @notice Prevents ownership renunciation which would permanently brick all onlyOwner functions
    ///         and the UUPS upgrade path.
    function renounceOwnership() public pure override {
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
        // _authorizeUpgrade clears the pending state before the implementation is swapped.
        upgradeToAndCall(impl, "");
    }

    /// @dev UUPS authorization gate. Since upgradeToAndCall is public on UUPSUpgradeable, this function
    ///      is the ONLY enforcement point — it must independently verify owner, timelock, and implementation match.
    ///      Pending state is cleared here so it is consumed atomically regardless of whether the caller
    ///      used executeUpgrade() or called upgradeToAndCall() directly.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(
            newImplementation == pendingImplementation && pendingUpgradeTimestamp != 0
                && block.timestamp >= pendingUpgradeTimestamp,
            IA.NotAuthorizedUpgrader(msg.sender)
        );
        pendingUpgradeTimestamp = 0;
        pendingImplementation = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                    POLICY LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Resets the policy binding flag so a new policy can be bound after the current one expires.
    /// @dev Only callable after the current policy's raw maturity has passed (no grace period extension).
    ///      Clears policyId, policyBoundExecuted, depositCap, and policyStartTime so that onPolicyBound
    ///      can be called again by PolicyManager for a successive coverage period.
    ///      Existing depositors retain their shares and principal during the transition; the new policy
    ///      binding will set a fresh accrual start anchor.
    //slither-disable-start reentrancy-no-eth,reentrancy-benign
    // ReentrancyGuardTransient (nonReentrant modifier) prevents reentry; slither does not recognise
    // EIP-1153 transient storage guards and therefore cannot verify the protection statically.
    function resetPolicyBinding() external override onlyOwner nonReentrant {
        if (policyId != 0) {
            IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);
            require(block.timestamp >= uint256(meta.maturityTime), IA.InvalidParameters());
        }
        uint96 prevPolicyId = policyId;
        // Accrue any remaining premium and flush pendingPremium through distributePremium()
        // before clearing policyId. Without the flush, withdrawal-accumulated pendingPremium
        // would later be sent via the fallback safeTransfer path (policyId == 0), bypassing
        // pool curator fees and restaker reward splitting.
        _accruePremium();
        _flushPendingPremium();
        policyId = 0;
        policyBoundExecuted = false;
        depositCap = 0;
        policyStartTime = 0;
        pendingDepositCap = 0;
        pendingDepositCapTimestamp = 0;
        pendingDeductibleBps = 0;
        pendingDeductibleTimestamp = 0;
        pendingPremiumRate = 0;
        pendingPremiumRateTimestamp = 0;
        pendingPremiumRecipient = address(0);
        pendingPremiumRecipientTimestamp = 0;
        // Clear any sub-unit WAD remainder so it does not leak into the next policy's accrual epoch.
        premiumAccrualRemainder = 0;
        emit IE.PolicyBindingReset(prevPolicyId);
    }

    //slither-disable-end reentrancy-no-eth,reentrancy-benign

    /*//////////////////////////////////////////////////////////////
                    MORPHO GATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Toggles Morpho gate status to pause/resume premium accrual.
    /// @dev On activation: caches Morpho value as a convertToAssets() fallback.
    function setMorphoGateActive(bool active) external override onlyOwner {
        _accruePremium();
        if (active && !morphoGateActive) {
            try IMorphoVault(morphoVault).convertToAssets(IMorphoVault(morphoVault).balanceOf(address(this))) returns (
                uint256 val
            ) {
                lastKnownMorphoValue = val;
            } catch {}
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
            // For Morpho shares: only allow sweeping surplus above the shares corresponding to user principal.
            // convertToShares(totalPrincipal) is a conservative lower bound — actual user entitlements
            // include accrued yield, but we protect principal. In a loss scenario (shares worth less per asset)
            // convertToShares(totalPrincipal) > balance, so sweepable floors to 0. _safeSub guards underflow.
            uint256 balance = IMorphoVault(morphoVault).balanceOf(address(this));
            uint256 minTracked = IMorphoVault(morphoVault).convertToShares(totalPrincipal);
            uint256 sweepable = balance > minTracked ? balance - minTracked : 0;
            require(amount <= sweepable, IA.InvalidParameters());
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
        // forge-lint: disable-next-line(unsafe-typecast)
        executeAfter = uint64(block.timestamp + delay);
    }
}

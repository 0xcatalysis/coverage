// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {CompleteCoverageFlow} from "./CompleteCoverageFlow.s.sol";

/**
 * @title ForkCompleteCoverageFlow
 * @notice Fork-specific extension of CompleteCoverageFlow that funds EigenLayer vaults
 *         with stake before policy binding.
 * @dev On a fresh mainnet fork, DurationVaultStrategy vaults hold zero stake.
 *      setCommitteeVaults (called inside bindPolicyForRequest) verifies that the vault's
 *      USD-valued stake >= coverageLimit, which fails with InsufficientStake on an empty fork.
 *
 *      This script inserts Phase 3b between vault discovery and Phase 4:
 *        - Wraps COVERAGE_LIMIT ETH to WETH (curator has 10 000 ETH on Anvil)
 *        - Delegates the curator to the vault (required by DurationVaultStrategy.beforeAddShares,
 *          which enforces delegatedTo(staker) == vault; delegationApprover is address(0))
 *        - Deposits WETH into the vault via EigenLayer StrategyManager
 *
 *      EigenLayer constraint: a staker can only be delegated to ONE operator at a time.
 *      This supports single-vault committees only (one ACCEPTABLE_TOKEN = one vault).
 *      Multi-vault scenarios would require a separate depositor address per vault.
 *
 *      The EigenLayer contract addresses are hardcoded for Ethereum mainnet (chain ID 1).
 *
 * Usage:
 *   forge script script/testing/ForkCompleteCoverageFlow.s.sol:ForkCompleteCoverageFlow \
 *     --rpc-url $ANVIL_RPC_URL --broadcast --slow -vvvv
 *
 *   Or via the Makefile:
 *   make test-fork
 */
contract ForkCompleteCoverageFlow is CompleteCoverageFlow {
    /// @dev EigenLayer StrategyManager on Ethereum mainnet.
    address private constant EIGENLAYER_STRATEGY_MANAGER = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
    /// @dev EigenLayer DelegationManager on Ethereum mainnet.
    address private constant EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    /**
     * @notice Wraps ETH -> WETH, delegates curator to the vault, and deposits via StrategyManager.
     */
    function _beforePhase4() internal override {
        if (vaults.length == 0) {
            return;
        }

        console.log("\n=== PHASE 3b: FUND VAULTS (EigenLayer stake) ===");
        require(vaults.length == 1, "Phase 3b: multi-vault not supported (one delegator per operator)");

        uint256 depositAmount = coverageLimit;

        vm.startBroadcast(curatorPrivateKey);

        (bool ok,) = payoutToken.call{value: depositAmount}(abi.encodeWithSignature("deposit()"));
        require(ok, "Phase 3b: ETH->WETH wrap failed");

        (ok,) = payoutToken.call(
            abi.encodeWithSignature("approve(address,uint256)", EIGENLAYER_STRATEGY_MANAGER, depositAmount)
        );
        require(ok, "Phase 3b: WETH approve to StrategyManager failed");

        (bool delegatedOk, bytes memory delegatedData) =
            EIGENLAYER_DELEGATION_MANAGER.staticcall(abi.encodeWithSignature("delegatedTo(address)", curator));
        address currentOperator =
            (delegatedOk && delegatedData.length >= 32) ? abi.decode(delegatedData, (address)) : address(0);

        if (currentOperator != vaults[0]) {
            (ok,) = EIGENLAYER_DELEGATION_MANAGER.call(
                abi.encodePacked(
                    bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)")),
                    bytes32(uint256(uint160(vaults[0]))), // operator (address, zero-padded)
                    bytes32(uint256(0x60)), // offset to struct (3 * 32 = 96)
                    bytes32(0), // approverSalt
                    bytes32(uint256(0x40)), // struct: offset to sig bytes (2 * 32 = 64)
                    bytes32(uint256(0)), // struct: expiry = 0
                    bytes32(uint256(0)) // struct: sig length = 0 (empty)
                )
            );
            require(ok, "Phase 3b: EigenLayer delegateTo vault failed");
            console.log("[OK] Curator delegated to vault");
        } else {
            console.log("[SKIP] Curator already delegated to vault");
        }

        (ok,) = EIGENLAYER_STRATEGY_MANAGER.call(
            abi.encodeWithSignature(
                "depositIntoStrategy(address,address,uint256)", vaults[0], payoutToken, depositAmount
            )
        );
        require(ok, "Phase 3b: EigenLayer depositIntoStrategy failed");
        console.log("[OK] Deposited", depositAmount, "WETH into vault");

        vm.stopBroadcast();

        emit FlowCompleted("Vault Funding", 35);
    }
}

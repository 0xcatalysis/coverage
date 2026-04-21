// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CompleteCoverageFlow} from "./CompleteCoverageFlow.s.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";

/// @notice Minimal interface for Morpho VaultV2Factory
interface IVaultV2FactoryFork {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address);
}

/// @notice Minimal interface for Morpho VaultV2 (curator / setCurator)
interface IVaultV2Fork {
    function setCurator(address curator) external;
}

/// @notice Minimal SSPRouter interface for vault discovery
interface ISSPRouterForkScript {
    /// @notice Returns all vaults registered for a given module type (global list, always readable).
    function getVaultsByModule(uint8 moduleType) external view returns (address[] memory);
    /// @notice Returns vaults for a specific committee. Only valid AFTER bindPolicyForRequest
    ///         (setCommitteeVaults inside bindPolicyForRequest populates committeeModuleVaults).
    function getCommitteeVaultsByModule(uint96 committeeId, uint8 moduleType) external view returns (address[] memory);
}

/// @notice Returns the ERC-20 token held by a DurationVaultStrategy (e.g. wstETH on live mainnet).
interface IDurationVaultStrategyScript {
    function underlyingToken() external view returns (address);
}

/// @notice Queries USD values from the live Catalysis ChainlinkPriceFeed.
interface IChainlinkPriceFeedForkScript {
    function getUSDValue(address token, uint256 amount) external view returns (uint256);
}

/**
 * @title ForkCompleteCoverageFlow
 * @notice Extends CompleteCoverageFlow for use against a live Ethereum mainnet fork.
 *
 * @dev Two modes controlled by the `DEPLOY_COVERED_VAULT` environment variable:
 *
 *      DEPLOY_COVERED_VAULT=false (default / legacy mode):
 *        Runs the standard EigenLayer-only end-to-end flow (Phase 3b funds vaults).
 *        BENEFICIARY and BIND_POLICY_HOOK are taken from environment variables as before.
 *
 *      DEPLOY_COVERED_VAULT=true (new covered-vault mode):
 *        Phase 1c: Deploys a fresh Morpho V2 vault + CoveredVaultWrapper UUPS proxy.
 *                  Overrides BENEFICIARY and BIND_POLICY_HOOK to the wrapper address.
 *        Phase 3d: Seeds a test user with WETH (on-chain ETH wrap), deposits into the
 *                  wrapper, simulates a vault loss via an anvil_impersonateAccount drain
 *                  broadcast, and verifies the vault balance reflects the loss.
 *                  Redeem is skipped: DurationVaultStrategy locks collateral for the full
 *                  policy duration; ClaimManager reverts ZeroPayoutAmount on immediate slash,
 *                  which is tested in CoveredVaultWrapper.fork.t.sol via vm.skip.
 *                  Phase 5, 6, 7 still run but Phase 7 becomes a log-only check.
 *
 *      Vault discovery uses a snapshot-delta on the global getVaultsByModule list taken just
 *      before requestCoverage (see _snapshotEigenLayerVaultCount / _discoverVaultsIfNeeded).
 *      getCommitteeVaultsByModule cannot be used pre-bind because committeeModuleVaults is only
 *      populated by setCommitteeVaults inside bindPolicyForRequest.
 *
 *      Required additional env vars when DEPLOY_COVERED_VAULT=true:
 *        - COVERED_VAULT_MAX_LOSS_BPS     (default: 1000 = 10%)
 *        - COVERED_VAULT_DEDUCTIBLE_BPS   (default: 100  =  1%)
 *        - COVERED_VAULT_USER_PRIVATE_KEY (seed-deposit EOA; defaults to BUYER_PRIVATE_KEY)
 *        - COVERED_VAULT_DEPOSIT_AMOUNT   (USDC amount to seed-deposit; default: 1000e6)
 *        - COVERED_VAULT_LOSS_PCT         (% of vault balance to remove; default: 5)
 *
 * Usage:
 *   forge script script/testing/ForkCompleteCoverageFlow.s.sol:ForkCompleteCoverageFlow \
 *     --rpc-url $ANVIL_RPC_URL --broadcast --slow -vvvv
 *
 *   Or via the Makefile:
 *   make test-fork
 */
contract ForkCompleteCoverageFlow is CompleteCoverageFlow {
    address private constant EIGENLAYER_STRATEGY_MANAGER = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
    address private constant EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
    address private constant VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;
    /// @dev Lido stETH on Ethereum mainnet — used to acquire wstETH by wrapping ETH in Phase 3b.
    address private constant LIDO_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    bool private _deployCoveredVault;

    /// @dev Global EigenLayer vault count snapshotted just before _phase2_requestCoverage.
    ///      requestCoverage triggers SSPRouter to deploy new DurationVaultStrategy vaults; the
    ///      delta between the post-request global list and this snapshot identifies them.
    ///      getCommitteeVaultsByModule cannot be used here because committeeModuleVaults is only
    ///      populated by setCommitteeVaults inside bindPolicyForRequest (Phase 4).
    uint256 private _eigenLayerVaultCountSnapshot;

    uint16 private _coveredVaultMaxLossBps;
    uint16 private _coveredVaultDeductibleBps;
    uint256 private _coveredVaultUserPrivateKey;
    address private _coveredVaultUser;
    uint256 private _coveredVaultDepositAmount;
    uint256 private _coveredVaultLossPct;

    constructor() {
        _deployCoveredVault = vm.envOr("DEPLOY_COVERED_VAULT", false);
        if (_deployCoveredVault) {
            _coveredVaultMaxLossBps = uint16(vm.envOr("COVERED_VAULT_MAX_LOSS_BPS", uint256(1000)));
            _coveredVaultDeductibleBps = uint16(vm.envOr("COVERED_VAULT_DEDUCTIBLE_BPS", uint256(100)));
            _coveredVaultUserPrivateKey = vm.envOr("COVERED_VAULT_USER_PRIVATE_KEY", buyerPrivateKey);
            _coveredVaultUser = vm.addr(_coveredVaultUserPrivateKey);
            _coveredVaultDepositAmount = vm.envOr("COVERED_VAULT_DEPOSIT_AMOUNT", uint256(1000e6));
            _coveredVaultLossPct = vm.envOr("COVERED_VAULT_LOSS_PCT", uint256(5));
        }
    }

    // ════════════════════════════════════════════
    //  Phase 1c: Deploy Morpho V2 vault + wrapper (DEPLOY_COVERED_VAULT=true only)
    // ════════════════════════════════════════════

    /// @dev Deploys Morpho V2 vault + wrapper and overrides beneficiary/claimer/bindPolicyHook
    ///      to the wrapper address so Phases 2 and 4 use it.
    function _phase1c_deployCoveredVault() internal {
        if (!_deployCoveredVault) {
            console.log("[SKIP] DEPLOY_COVERED_VAULT=false, skipping Phase 1c");
            return;
        }

        console.log("\n=== PHASE 1c: DEPLOY MORPHO V2 VAULT + COVERED VAULT WRAPPER ===");

        vm.startBroadcast(curatorPrivateKey);
        address morphoVault = IVaultV2FactoryFork(VAULT_V2_FACTORY)
            .createVaultV2(curator, payoutToken, bytes32(uint256(block.timestamp)));
        IVaultV2Fork(morphoVault).setCurator(curator);
        vm.stopBroadcast();
        console.log("[OK] Morpho V2 vault deployed:", morphoVault);

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;

        vm.startBroadcast(curatorPrivateKey);
        address proxy = Upgrades.deployUUPSProxy(
            "CoveredVaultWrapper.sol",
            abi.encodeCall(
                CoveredVaultWrapper.initialize,
                (
                    morphoVault,
                    claimManager,
                    coverPool,
                    _coveredVaultMaxLossBps,
                    _coveredVaultDeductibleBps,
                    premiumManager,
                    curator,
                    "Covered Vault",
                    "cvVAULT"
                )
            ),
            deployOpts
        );
        vm.stopBroadcast();
        console.log("[OK] CoveredVaultWrapper deployed:", proxy);

        coveredVault = proxy;
        beneficiary = proxy;
        bindPolicyHook = proxy;
        claimer = proxy;

        buyer = curator;
        buyerPrivateKey = curatorPrivateKey;

        emit FlowCompleted("Deploy Covered Vault", 15);
    }

    // ════════════════════════════════════════════
    //  Phase 3b: Fund EigenLayer vaults
    // ════════════════════════════════════════════

    /// @dev Overrides parent Phase 3b to support multiple vaults (one per acceptableToken).
    ///      Each vault's underlying collateral token is discovered at runtime via underlyingToken()
    ///      rather than assumed to be payoutToken — on live mainnet the vault holds wstETH, not WETH.
    function _beforePhase4() internal override {
        if (vaults.length == 0) {
            return;
        }

        console.log("\n=== PHASE 3b: FUND VAULTS (EigenLayer stake) ===");

        address chainlinkPriceFeed = vm.envAddress("CHAINLINK_PRICE_FEED");
        uint256 coverageLimitUSD =
            IChainlinkPriceFeedForkScript(chainlinkPriceFeed).getUSDValue(payoutToken, coverageLimit);
        uint256 targetUSD = coverageLimitUSD * 2;

        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("Funding vault", i, ":", vaults[i]);

            address collateralToken = IDurationVaultStrategyScript(vaults[i]).underlyingToken();
            console.log("     collateral token:", collateralToken);

            uint256 tokenUnit = 10 ** uint256(IERC20Metadata(collateralToken).decimals());
            uint256 tokenPriceUSD =
                IChainlinkPriceFeedForkScript(chainlinkPriceFeed).getUSDValue(collateralToken, tokenUnit);
            uint256 collateralAmount = (targetUSD * tokenUnit + tokenPriceUSD - 1) / tokenPriceUSD;

            uint256 depositorKey = _anvilDepositorKey(i);
            address depositor = vm.addr(depositorKey);

            vm.startBroadcast(depositorKey);

            {
                (bool lidoOk,) =
                    LIDO_STETH.call{value: collateralAmount * 2}(abi.encodeWithSignature("submit(address)", address(0)));
                require(lidoOk, "Phase 3b: Lido ETH submit failed");

                (bool balOk, bytes memory stETHBalData) =
                    LIDO_STETH.staticcall(abi.encodeWithSignature("balanceOf(address)", depositor));
                require(balOk && stETHBalData.length >= 32, "Phase 3b: stETH balanceOf failed");
                uint256 stETHBalance = abi.decode(stETHBalData, (uint256));

                (lidoOk,) =
                    LIDO_STETH.call(abi.encodeWithSignature("approve(address,uint256)", collateralToken, stETHBalance));
                require(lidoOk, "Phase 3b: stETH approve for wrap failed");

                (lidoOk,) = collateralToken.call(abi.encodeWithSignature("wrap(uint256)", stETHBalance));
                require(lidoOk, "Phase 3b: wstETH wrap failed");
            }

            (bool delegatedOk, bytes memory delegatedData) =
                EIGENLAYER_DELEGATION_MANAGER.staticcall(abi.encodeWithSignature("delegatedTo(address)", depositor));
            address currentOperator =
                (delegatedOk && delegatedData.length >= 32) ? abi.decode(delegatedData, (address)) : address(0);

            bool ok;
            if (currentOperator != vaults[i]) {
                (ok,) = EIGENLAYER_DELEGATION_MANAGER.call(
                    abi.encodePacked(
                        bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)")),
                        bytes32(uint256(uint160(vaults[i]))),
                        bytes32(uint256(0x60)),
                        bytes32(0),
                        bytes32(uint256(0x40)),
                        bytes32(uint256(0)),
                        bytes32(uint256(0))
                    )
                );
                require(ok, "Phase 3b: EigenLayer delegateTo vault failed");
                console.log("[OK] Depositor", i, "delegated to vault", i);
            } else {
                console.log("[SKIP] Depositor", i, "already delegated to vault", i);
            }

            (ok,) = collateralToken.call(
                abi.encodeWithSignature("approve(address,uint256)", EIGENLAYER_STRATEGY_MANAGER, collateralAmount)
            );
            require(ok, "Phase 3b: collateral token approve to StrategyManager failed");

            (ok,) = EIGENLAYER_STRATEGY_MANAGER.call(
                abi.encodeWithSignature(
                    "depositIntoStrategy(address,address,uint256)", vaults[i], collateralToken, collateralAmount
                )
            );
            require(ok, "Phase 3b: EigenLayer depositIntoStrategy failed");
            console.log("[OK] Deposited", collateralAmount, "collateral tokens into vault", i);
            console.log("     via depositor:", depositor);

            vm.stopBroadcast();
        }

        emit FlowCompleted("Vault Funding", 35);
    }

    // ════════════════════════════════════════════
    //  Phase 3d: Seed deposit + simulate loss + redeem (DEPLOY_COVERED_VAULT=true only)
    // ════════════════════════════════════════════

    /// @dev Deposits WETH, simulates a vault loss, and redeems to trigger CoveredVaultWrapper.fileClaim.
    ///      (claimer = wrapper, so a direct EOA fileClaim is not possible)
    function _phase3d_seedAndTriggerClaim() internal {
        if (!_deployCoveredVault) {
            return;
        }

        console.log("\n=== PHASE 3d: SEED DEPOSIT + SIMULATE LOSS + VERIFY fileClaim ===");

        address morphoVaultAddr = CoveredVaultWrapper(coveredVault).morphoVault();

        vm.startBroadcast(curatorPrivateKey);
        (bool sendOk,) = payable(_coveredVaultUser).call{value: _coveredVaultDepositAmount + 0.1 ether}("");
        require(sendOk, "Phase 3d: failed to send ETH to user");
        vm.stopBroadcast();

        vm.startBroadcast(_coveredVaultUserPrivateKey);
        (bool wrapOk,) = payoutToken.call{value: _coveredVaultDepositAmount}(abi.encodeWithSignature("deposit()"));
        require(wrapOk, "Phase 3d: ETH->WETH wrap failed (payoutToken must be WETH)");
        IERC20(payoutToken).approve(coveredVault, _coveredVaultDepositAmount);
        CoveredVaultWrapper(coveredVault).deposit(_coveredVaultDepositAmount, _coveredVaultUser);
        vm.stopBroadcast();
        console.log("[OK] User deposited", _coveredVaultDepositAmount, "WETH into wrapper");

        uint256 morphoBalance = IERC20(payoutToken).balanceOf(morphoVaultAddr);
        uint256 lossAmount = morphoBalance * _coveredVaultLossPct / 100;

        vm.deal(morphoVaultAddr, 1 ether); // local simulation
        vm.rpc(
            "anvil_setBalance",
            string.concat("[\"", vm.toString(morphoVaultAddr), "\",\"0xde0b6b3a7640000\"]") // 1 ETH
        );

        vm.rpc("anvil_impersonateAccount", string.concat("[\"", vm.toString(morphoVaultAddr), "\"]"));
        vm.startBroadcast(morphoVaultAddr);
        IERC20(payoutToken).transfer(address(1), lossAmount);
        vm.stopBroadcast();
        console.log("[OK] Simulated", _coveredVaultLossPct, "% loss on Morpho vault");
        console.log("     Drained", lossAmount, "WETH from vault (impersonation broadcast)");
        console.log("     Morpho vault balance:", morphoBalance - lossAmount);

        uint256 postDrainBalance = IERC20(payoutToken).balanceOf(morphoVaultAddr);
        require(
            postDrainBalance < _coveredVaultDepositAmount,
            "Phase 3d: vault balance should be less than deposit after drain"
        );
        console.log("[OK] Vault balance after drain:", postDrainBalance);
        console.log("     Loss correctly reflected vs. deposit:", _coveredVaultDepositAmount);
        console.log("     (redeem step skipped: EigenLayer vault locked for policy duration)");

        emit FlowCompleted("Seed + Trigger Claim", 38);
    }

    // ════════════════════════════════════════════
    //  Anvil depositor key lookup
    // ════════════════════════════════════════════

    /// @dev Returns the private key of Anvil's well-known funded account at the given index
    ///      (starting at 4, leaving 0-3 for CURATOR/BUYER/CLAIMER/QUOTE_SIGNER).
    ///      to the node.
    function _anvilDepositorKey(uint256 index) private pure returns (uint256) {
        if (index == 0) return 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
        if (index == 1) return 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
        if (index == 2) return 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
        if (index == 3) return 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;
        if (index == 4) return 0xdbda1821b80551c9d65939329250132c444b89e5a5b7eb6d6f3d3d89c6fbac3e;
        if (index == 5) return 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
        revert("Phase 3b: vault index > 5; only Anvil accounts 4-9 are reserved as depositors");
    }

    // ════════════════════════════════════════════
    //  Vault snapshot helper
    // ════════════════════════════════════════════

    /// @dev Records the current global EigenLayer vault count so _discoverVaultsIfNeeded can
    ///      identify the vaults created for this committee as the delta.  Must be called BEFORE
    ///      _phase2_requestCoverage because requestCoverage triggers SSPRouter to deploy new
    ///      DurationVaultStrategy vaults into the global list.
    function _snapshotEigenLayerVaultCount() internal {
        (bool ok1, bytes memory d1) = stakeManager.staticcall(abi.encodeWithSignature("router()"));
        require(ok1 && d1.length >= 32, "Snapshot: StakeManager.router() call failed");
        address router = abi.decode(d1, (address));

        (bool ok2, bytes memory d2) = router.staticcall(abi.encodeWithSignature("getVaultsByModule(uint8)", uint8(2)));
        require(ok2 && d2.length >= 32, "Snapshot: getVaultsByModule call failed");

        address[] memory currentVaults = abi.decode(d2, (address[]));
        _eigenLayerVaultCountSnapshot = currentVaults.length;
        console.log("[OK] EigenLayer vault count snapshot:", _eigenLayerVaultCountSnapshot);
    }

    function run() external override {
        console.log("============================================");
        console.log("  COMPLETE COVERAGE PROTOCOL E2E FLOW");
        console.log("============================================");
        console.log("Curator:", curator);
        console.log("Buyer:", buyer);
        console.log("Claimer:", claimer);
        console.log("Beneficiary:", beneficiary);
        console.log("DEPLOY_COVERED_VAULT:", _deployCoveredVault);
        console.log("");

        _phase0_whitelistPayoutToken();
        _phase1_createCoverPool();
        _phase1b_releaseOperator();
        _phase1c_deployCoveredVault();
        _snapshotEigenLayerVaultCount();
        _phase2_requestCoverage();
        _phase3_verifyCommittee();
        _discoverVaultsIfNeeded();
        _beforePhase4();
        _phase4_bindPolicy();
        _phase3d_seedAndTriggerClaim();
        _phase5_verifyPremiumAccrual();
        _phase6_distributePremiums();
        _phase7_fileClaim();
        _phase8_summary();

        console.log("\n============================================");
        console.log("  E2E FLOW COMPLETED SUCCESSFULLY");
        console.log("============================================");
        emit EndToEndCompleted(policyId, coverPool, beneficiary);
    }

    /// @dev Overrides parent to use the snapshot-delta approach: compares the current global
    ///      getVaultsByModule(EIGENLAYER) list against the pre-requestCoverage snapshot to find
    ///      the vaults that were just deployed for this committee.
    ///
    ///      getCommitteeVaultsByModule CANNOT be used here because committeeModuleVaults is only
    ///      populated by setCommitteeVaults inside bindPolicyForRequest (Phase 4), which has not
    ///      run yet.  This matches the pattern used by ForkCoverageSetup._discoverNewEigenLayerVaults
    ///      and CoveredVaultWrapper.fork.t.sol.
    function _discoverVaultsIfNeeded() internal override {
        if (vaults.length > 0) {
            return;
        }

        console.log("\n=== VAULT AUTO-DISCOVERY (global delta, pre-bind) ===");

        (bool ok1, bytes memory d1) = stakeManager.staticcall(abi.encodeWithSignature("router()"));
        require(ok1 && d1.length >= 32, "Vault discovery: StakeManager.router() call failed");
        address router = abi.decode(d1, (address));
        console.log("SSPRouter:", router);

        (bool ok2, bytes memory d2) = router.staticcall(abi.encodeWithSignature("getVaultsByModule(uint8)", uint8(2)));
        require(ok2 && d2.length >= 32, "Vault discovery: getVaultsByModule call failed");
        address[] memory allVaults = abi.decode(d2, (address[]));

        require(
            allVaults.length > _eigenLayerVaultCountSnapshot,
            "Vault auto-discovery: no new EigenLayer vaults deployed since snapshot"
        );

        uint256 newCount = allVaults.length - _eigenLayerVaultCountSnapshot;
        vaults = new address[](newCount);
        for (uint256 i = 0; i < newCount; i++) {
            vaults[i] = allVaults[_eigenLayerVaultCountSnapshot + i];
        }

        console.log("Discovered vault(s) for committee (snapshot delta):");
        console.log("  snapshot count:", _eigenLayerVaultCountSnapshot);
        console.log("  total count:", allVaults.length);
        console.log("  new vaults:", vaults.length);
        console.log("  policyId:", policyId);
        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("  Vault", i, ":", vaults[i]);
        }
    }
}

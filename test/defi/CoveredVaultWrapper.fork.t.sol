// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {ICoverPoolFactory} from "coverage/interfaces/ICoverPoolFactory.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {ForkCoverageSetup} from "./helpers/ForkCoverageSetup.sol";

/// @title CoveredVaultWrapperForkTest
/// @notice Fork tests for CoveredVaultWrapper backed by a real Morpho V2 vault, fresh Coverage
///         contracts wired to the live Catalysis Core deployment on Ethereum mainnet.
///
/// Run: FOUNDRY_PROFILE=fork forge test --match-contract CoveredVaultWrapperForkTest -vvv
contract CoveredVaultWrapperForkTest is ForkCoverageSetup {
    bytes32 internal constant SPEC_ID = keccak256("morpho-spec");
    bytes32 internal constant TERMS_HASH = keccak256("morpho-terms");

    uint16 internal constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 internal constant DEDUCTIBLE_BPS = 100; // 1%
    uint256 internal constant COVERAGE_LIMIT = 100_000e6; // 100k USDC

    IVaultV2 morphoVault;
    CoveredVaultWrapper wrapper;

    address owner;
    address curator;
    address buyer;
    address user1;
    address user2;
    address underlyingFeeRecipient;

    address coverPool;
    uint96 policyId;

    function setUp() public {
        _forkMainnet();
        if (!forkActive) return;

        owner = makeAddr("owner");
        curator = makeAddr("curator");
        buyer = makeAddr("buyer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        underlyingFeeRecipient = makeAddr("feeRecipient");

        _deployCoverageStack();
        _advancePolicyId();
        _wireCoverageToLiveCore();

        // USDC feed is not registered on live OraclePriceFeed at fork block; WETH is.
        _registerPriceFeedIfMissing(WETH, ETH_USD_AGGREGATOR, 86_400);
        _registerPriceFeedIfMissing(USDC, USDC_USD_AGGREGATOR, 86_400);
        _whitelistPayoutToken(USDC);

        _deploySpec();
        // wstETH→USDC: the live SSPRouter acceptableTokens=[wstETH], so slashing yields wstETH.
        _registerSwapRoute(WETH, USDC, 500);
        _registerSwapRoute(WETH_STAKED, USDC, 500);

        morphoVault = _deployMorphoVaultV2(owner, curator, USDC);

        // Pool must be created before the wrapper so its address can be passed to initialize().
        ICoverPoolFactory.CreateCoverPoolParams memory poolParams =
            ICoverPoolFactory.CreateCoverPoolParams({curator: address(this), quoteSigner: quoteSigner, poolFeeBps: 0});
        coverPool = coverPoolFactory.computeCoverPoolAddress(poolParams);
        coverPoolFactory.createCoverPool(poolParams);

        // wrapper implements IBindPolicyHook + IERC165, so it serves as beneficiary, claimer, and hook.
        wrapper = _deployCoveredVaultWrapper(
            address(morphoVault), coverPool, MAX_COVERABLE_LOSS_BPS, DEDUCTIBLE_BPS, buyer, "Covered USDC", "cvUSDC"
        );

        // Snapshot vault count before requestCoverage; SSPRouter.setCommitteeVaults (called inside
        // bindPolicyForRequest) populates committeeModuleVaults only after binding, so pre-bind vault
        // discovery relies on the delta between global counts.
        uint256 vaultCountBefore = _eigenLayerVaultCount();

        // Duration: EigenLayer MAX_DURATION = 2*365 days, long enough for the 365-day fee skips.
        vm.prank(buyer);
        policyId = policyManager.requestCoverage(
            coverPool, address(wrapper), address(wrapper), USDC, 2 * 365 days, address(wrapper)
        );

        // Fund EigenLayer stake before binding (binding checks stake >= coverageLimit via OraclePriceFeed).
        address[] memory vaults = _discoverNewEigenLayerVaults(vaultCountBefore);
        require(vaults.length > 0, "no new EigenLayer vaults deployed for committee");
        for (uint256 i = 0; i < vaults.length; i++) {
            address collateralToken = _vaultUnderlyingToken(vaults[i]);
            _fundEigenLayerStake(
                vaults[i],
                makeAddr(string.concat("stakeDepositor", vm.toString(i))),
                _collateralAmountFor2xCoverage(collateralToken, COVERAGE_LIMIT)
            );
        }

        // bindPolicyForRequest → EigenAdapter.setCommitteeVaults → vault.lock() → modifyAllocations.
        // The allocation becomes slashable after allocationDelay (100801 blocks on mainnet).
        _bindPolicy(
            policyId, coverPool, address(mockSpec), COVERAGE_LIMIT, address(wrapper), SPEC_ID, TERMS_HASH, vaults
        );
        vm.roll(block.number + 100_802);

        vm.prank(user1);
        IERC20(USDC).approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        IERC20(USDC).approve(address(wrapper), type(uint256).max);
    }

    modifier onlyFork() {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _userDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        deal(USDC, user, IERC20(USDC).balanceOf(user) + amount);
        vm.startPrank(user);
        IERC20(USDC).approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, user);
        vm.stopPrank();
    }

    function _userRedeemAll(address user) internal returns (uint256 assets) {
        uint256 shares = wrapper.balanceOf(user);
        vm.prank(user);
        assets = wrapper.redeem(shares, user, user);
    }

    function _curatorSubmitExec(bytes memory data) internal {
        vm.prank(curator);
        (bool ok,) = address(morphoVault).call(abi.encodeWithSignature("submit(bytes)", data));
        require(ok, "submit failed");
        vm.prank(curator);
        (ok,) = address(morphoVault).call(data);
        require(ok, "execute failed");
    }

    /// @notice Morpho ~2% management fee counts as a real loss; insurance covers the shortfall above deductible.
    function test_fork_UnderlyingVaultFee_LossCount() public onlyFork {
        uint256 feePerSec = uint256(0.02e18) / uint256(365 days);
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFeeRecipient(address)", underlyingFeeRecipient));
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFee(uint256)", feePerSec));

        uint256 depositAmount = 1000e6;
        _userDeposit(user1, depositAmount);
        skip(365 days);
        _userRedeemAll(user1);

        // Morpho returns ~980 after 2% fee; shortfall ~20; claim = 20 - 10 deductible ≈ 10 USDC.
        // assertApproxEqAbs absorbs Uniswap V3 sub-unit rounding on the wstETH→USDC swap.
        assertApproxEqAbs(IERC20(USDC).balanceOf(user1), 990_000_000, 2, "User received Morpho proceeds + insurance");
        assertApproxEqAbs(
            claimManager.policyClaim(policyId).totalPaidOut, 9_999_999, 2, "Insurance covers loss above deductible"
        );
    }

    /// @notice When a 5% yield gain covers the 2% fee, no insurance fires.
    function test_fork_UnderlyingVaultFee_ProfitCoversFee() public onlyFork {
        uint256 feePerSec = uint256(0.02e18) / uint256(365 days);
        uint256 maxRatePerSec = uint256(0.2e18) / uint256(365 days);

        // setIsAllocator and setMaxRate are required by Morpho V2 for fee accrual to work.
        _curatorSubmitExec(abi.encodeWithSignature("setIsAllocator(address,bool)", curator, true));
        vm.prank(curator);
        (bool ok,) = address(morphoVault).call(abi.encodeWithSignature("setMaxRate(uint256)", maxRatePerSec));
        require(ok, "setMaxRate failed");
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFeeRecipient(address)", underlyingFeeRecipient));
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFee(uint256)", feePerSec));

        uint256 depositAmount = 1000e6;
        _userDeposit(user1, depositAmount);
        deal(USDC, address(morphoVault), IERC20(USDC).balanceOf(address(morphoVault)) + depositAmount * 5 / 100);
        skip(365 days);
        _userRedeemAll(user1);

        assertGt(IERC20(USDC).balanceOf(user1), depositAmount, "User received profit from underlying vault");
        assertEq(claimManager.policyClaim(policyId).totalPaidOut, 0, "Insurance payout not triggered");
    }

    /// @notice Fee + simulated hack loss triggers insurance; only the amount above the deductible is paid.
    function test_fork_UnderlyingVaultFee_OnlyLossCovered() public onlyFork {
        uint256 feePerSec = uint256(0.02e18) / uint256(365 days);
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFeeRecipient(address)", underlyingFeeRecipient));
        _curatorSubmitExec(abi.encodeWithSignature("setManagementFee(uint256)", feePerSec));

        uint256 depositAmount = 1000e6;
        _userDeposit(user1, depositAmount);
        skip(365 days);

        uint256 morphoBalance = IERC20(USDC).balanceOf(address(morphoVault));
        deal(USDC, address(morphoVault), morphoBalance - depositAmount * 1 / 100); // +1% hack on top of fee
        _userRedeemAll(user1);

        // Morpho ~970.2 after fee+hack; shortfall ~29.8; claim = 29.8 - 10 deductible ≈ 19.8 USDC.
        assertApproxEqAbs(IERC20(USDC).balanceOf(user1), 990_000_000, 2, "User received insurance for fee + hack loss");
        assertApproxEqAbs(
            claimManager.policyClaim(policyId).totalPaidOut, 19_799_999, 2, "Insurance covers loss above deductible"
        );
    }
}

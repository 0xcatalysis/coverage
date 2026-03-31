// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {PremiumManager} from "../../src/PremiumManager.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract FuzzPMToken is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FuzzRewardsManager {
    function distributeRewards(uint96, address, uint256, IERC20, bytes32) external {}
}

contract FuzzCoverPool {
    address public owner;
    address public feeRecipient;
    uint16 public poolFeeBps;

    constructor(address owner_, address feeRecipient_, uint16 poolFeeBps_) {
        owner = owner_;
        feeRecipient = feeRecipient_;
        poolFeeBps = poolFeeBps_;
    }

    function hasBoundPolicy(uint96 policyId) external pure returns (bool) {
        return policyId != 0;
    }
}

// ---------------------------------------------------------------------------
// Fuzz suite
// ---------------------------------------------------------------------------

contract PremiumManagerFuzzTest is Test {
    PremiumManager internal premiumManager;
    FuzzPMToken internal premiumToken;
    FuzzRewardsManager internal rewardsManager;
    FuzzCoverPool internal pool;

    address internal admin = makeAddr("admin");
    address internal premiumCollector = makeAddr("premiumCollector");
    address internal platformTreasury = makeAddr("platformTreasury");
    address internal poolFeeRecipient = makeAddr("poolFeeRecipient");
    address internal curator = makeAddr("curator");

    uint96 internal constant POLICY_ID = 1;

    function setUp() public {
        rewardsManager = new FuzzRewardsManager();
        premiumToken = new FuzzPMToken();

        PremiumManager impl = new PremiumManager();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(PremiumManager.initialize, (admin, address(rewardsManager), platformTreasury, 50))
            )
        );
        premiumManager = PremiumManager(proxy);
    }

    // ------------------------------------------------------------------
    // Fuzz: fee splits always sum to gross premium
    // ------------------------------------------------------------------
    function testFuzz_getFeeSplits_AlwaysSumsToGross(
        uint256 grossPremium,
        uint16 platformFeeBps,
        uint16 poolFeeBps
    )
        public
        view
    {
        grossPremium = bound(grossPremium, 0, 1_000_000 ether);
        platformFeeBps = uint16(bound(platformFeeBps, 0, 10_000));
        poolFeeBps = uint16(bound(poolFeeBps, 0, 10_000 - platformFeeBps));

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps);

        assertEq(platformSplit + poolSplit + restakerSplit, grossPremium, "Fee splits must sum to gross premium");
    }

    // ------------------------------------------------------------------
    // Fuzz: platformSplit never exceeds gross * platformFeeBps / 10_000
    // ------------------------------------------------------------------
    function testFuzz_getFeeSplits_PlatformSplitBounded(uint256 grossPremium, uint16 platformFeeBps) public view {
        grossPremium = bound(grossPremium, 0, 1_000_000 ether);
        platformFeeBps = uint16(bound(platformFeeBps, 0, 10_000));
        uint16 poolFeeBps = 0;

        (uint256 platformSplit,,) = premiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps);

        assertLe(platformSplit, grossPremium * platformFeeBps / 10_000 + 1, "Platform split must be bounded");
    }

    // ------------------------------------------------------------------
    // Fuzz: restakerSplit is never negative (no underflow)
    // ------------------------------------------------------------------
    function testFuzz_getFeeSplits_RestakerSplitNonNegative(
        uint256 grossPremium,
        uint16 platformFeeBps,
        uint16 poolFeeBps
    )
        public
        view
    {
        grossPremium = bound(grossPremium, 0, 1_000_000 ether);
        platformFeeBps = uint16(bound(platformFeeBps, 0, 10_000));
        poolFeeBps = uint16(bound(poolFeeBps, 0, 10_000 - platformFeeBps));

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps);

        assertLe(platformSplit + poolSplit, grossPremium, "Fees must not exceed gross premium");
        assertGe(restakerSplit, 0, "Restaker split must be non-negative");
    }

    // ------------------------------------------------------------------
    // Fuzz: distributePremium transfers tokens to correct recipients
    // ------------------------------------------------------------------
    function testFuzz_distributePremium_CorrectTransfers(uint256 grossPremium, uint16 poolFeeBps) public {
        grossPremium = bound(grossPremium, 1 ether, 100_000 ether);
        poolFeeBps = uint16(bound(poolFeeBps, 0, 9950));

        pool = new FuzzCoverPool(curator, poolFeeRecipient, poolFeeBps);
        premiumToken.mint(address(premiumManager), grossPremium);

        uint16 platformFeeBps = premiumManager.platformFeeBps();
        (uint256 expectedPlatform, uint256 expectedPool,) =
            premiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps);

        uint256 treasuryBefore = premiumToken.balanceOf(platformTreasury);
        uint256 poolBefore = premiumToken.balanceOf(poolFeeRecipient);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(pool), POLICY_ID, address(premiumToken), grossPremium);

        assertEq(
            premiumToken.balanceOf(platformTreasury) - treasuryBefore,
            expectedPlatform,
            "Platform treasury received wrong amount"
        );
        assertEq(
            premiumToken.balanceOf(poolFeeRecipient) - poolBefore,
            expectedPool,
            "Pool fee recipient received wrong amount"
        );
    }
}

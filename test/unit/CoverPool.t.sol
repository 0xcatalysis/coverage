// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";

contract CoverPoolTest is Test {
    CoverPool internal coverPool;

    function setUp() public {
        coverPool = new CoverPool();
    }

    function test_coverPoolDeployment() public view {
        assertTrue(address(coverPool) != address(0), "CoverPool deployment failed");
        assertGt(address(coverPool).code.length, 0, "CoverPool should have runtime code");
    }
}

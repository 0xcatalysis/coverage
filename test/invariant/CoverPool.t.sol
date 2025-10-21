// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";

contract CoverPoolInvariantTest is StdInvariant, Test {
    CoverPool internal coverPool;

    function setUp() public {
        coverPool = new CoverPool();
        targetContract(address(coverPool));
    }

    function invariant_coverPoolAlwaysHasCode() public view {
        assertGt(address(coverPool).code.length, 0, "CoverPool should always contain code");
    }
}

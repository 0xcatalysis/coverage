// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISlashingManager} from "coverage/interfaces/ISlashingManager.sol";
import {IChainlinkPriceFeed} from "coverage/interfaces/IChainlinkPriceFeed.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IBindPolicyHook} from "coverage/interfaces/IBindPolicyHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract MockStakeManager {
    mapping(uint96 => address[]) private _committeeVaults;
    mapping(uint96 => address[]) private _committeeTokens;
    mapping(uint96 => uint256[]) private _committeeTokenStakes;

    function createCommittee(uint96, address, uint32) external {}

    function addOperatorToCommittee(address, uint96) external {}

    function removeOperatorFromCommittee(address, uint96) external {}

    function setCommitteeVaults(uint96 committeeId, address[] calldata vaults, uint256) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            _committeeVaults[committeeId].push(vaults[i]);
        }
    }

    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory) {
        return _committeeVaults[committeeId];
    }

    function getCommitteeTokenStakes(uint96 committeeId)
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        vaults = _committeeVaults[committeeId];
        tokens = _committeeTokens[committeeId];
        tokenStakes = _committeeTokenStakes[committeeId];

        if (tokens.length == 0 && vaults.length > 0) {
            tokens = new address[](vaults.length);
            tokenStakes = new uint256[](vaults.length);
        }
    }

    /// @notice Test helper: set per-vault token stakes for a committee
    function setCommitteeTokenStakes(
        uint96 committeeId,
        address[] calldata tokens,
        uint256[] calldata stakes
    )
        external
    {
        _committeeTokens[committeeId] = tokens;
        _committeeTokenStakes[committeeId] = stakes;
    }
}

/// @title MockChainlinkPriceFeedDefi
/// @notice Returns input amount as USD value (1:1 identity) so stake checks always pass when stakes >= coverageLimit
contract MockChainlinkPriceFeedDefi is IChainlinkPriceFeed {
    function getUSDValue(address, uint256 amount) external pure override returns (uint256) {
        return amount;
    }

    function getTokenAmount(address, uint256 usdValue) external pure override returns (uint256) {
        return usdValue;
    }
}

contract MockCoverPoolFactory {
    mapping(address => bool) private _pools;

    function coverPoolExists(address pool) external view returns (bool) {
        return _pools[pool];
    }

    function register(address pool) external {
        _pools[pool] = true;
    }
}

contract MockSpecRegistry {
    mapping(bytes32 => mapping(address => address)) private _specs;

    function registerSpec(bytes32 specId, ISpec spec) external {
        _specs[specId][msg.sender] = address(spec);
    }

    function resolveSpec(address coverPool, bytes32 specId) external view returns (ISpec) {
        return ISpec(_specs[specId][coverPool]);
    }
}

contract MockBindPolicyHook is IBindPolicyHook {
    function onPolicyBound(uint96, uint256) external override {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

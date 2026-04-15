// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ICreateX} from "./ICreateX.sol";

/**
 * @title CreateXDeployer
 * @notice Base contract providing CREATE3 deployment helpers via the CreateX factory.
 * @dev CreateX is deployed at the same address on all EVM chains (including testnets).
 *      CREATE3 produces addresses that depend only on the deployer + salt, NOT the
 *      bytecode or constructor args. This gives identical proxy addresses across chains
 *      even when initialization parameters (admin, core contract addresses, etc.) differ.
 *
 *      Salt structure (32 bytes):
 *        - Bytes 0-19:  deployer address (permissioned — only this msg.sender can use the salt)
 *        - Byte 20:     0x00 (cross-chain redeploy protection OFF — same address on all chains)
 *        - Bytes 21-31: first 11 bytes of keccak256(contractName)
 */
abstract contract CreateXDeployer is Script {
    /// @notice CreateX universal deployer address (same on all EVM chains).
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /**
     * @notice Ensures CreateX bytecode exists at the canonical address.
     * @dev On public chains (testnets, mainnet) CreateX is already deployed — this is a no-op.
     *      On local Anvil chains, this etches the CreateX runtime bytecode at the canonical address.
     *      Must be called BEFORE vm.startBroadcast() so the cheatcode applies to the local state.
     *      When using --broadcast against Anvil, also call _ensureCreateXOnChain() after startBroadcast.
     */
    function _ensureCreateX() internal {
        if (address(CREATEX).code.length > 0) return;
        // forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory code = vm.parseBytes(vm.readFile("script/createx-bytecode.txt"));
        vm.etch(address(CREATEX), code);
    }

    /**
     * @notice Builds a deterministic, deployer-permissioned salt for CREATE3.
     * @param deployer Address that will call CreateX (embedded in bytes 0-19 for frontrun protection).
     * @param contractName Human-readable name (e.g. "SwapperProxy") — hashed for entropy bytes.
     * @return salt The 32-byte salt for CreateX.
     */
    function _computeSalt(address deployer, string memory contractName) internal pure returns (bytes32) {
        bytes11 entropy = bytes11(keccak256(abi.encodePacked(contractName)));
        return bytes32(abi.encodePacked(deployer, uint8(0x00), entropy));
    }

    /**
     * @notice Deploys arbitrary creation bytecode via CreateX CREATE3 for a deterministic address.
     * @dev Unlike _deployProxy3, this does NOT wrap the bytecode in an ERC1967Proxy.
     *      Use for non-proxy contracts (e.g. TimelockController) that still need deterministic addresses.
     * @param deployer Address calling CreateX (must match the broadcast sender).
     * @param contractName Salt name (e.g. "TimelockController").
     * @param initCode Full creation bytecode including constructor args.
     * @return deployed Address of the deployed contract.
     */
    function _deploy3(
        address deployer,
        string memory contractName,
        bytes memory initCode
    )
        internal
        returns (address deployed)
    {
        bytes32 salt = _computeSalt(deployer, contractName);
        deployed = CREATEX.deployCreate3(salt, initCode);
    }

    /**
     * @notice Deploys an ERC1967Proxy via CreateX CREATE3 for a deterministic address.
     * @dev The proxy is created with `new ERC1967Proxy(impl, initData)` bytecode, but
     *      deployed through CreateX so the resulting address depends only on deployer + salt.
     * @param deployer Address calling CreateX (must match the broadcast sender).
     * @param contractName Salt name (e.g. "SwapperProxy").
     * @param impl Implementation address the proxy will delegate to.
     * @param initData ABI-encoded initializer call (e.g. abi.encodeCall(Contract.initialize, (...))).
     * @return proxy Address of the deployed proxy.
     */
    function _deployProxy3(
        address deployer,
        string memory contractName,
        address impl,
        bytes memory initData
    )
        internal
        returns (address proxy)
    {
        bytes32 salt = _computeSalt(deployer, contractName);
        bytes memory initCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));
        proxy = CREATEX.deployCreate3(salt, initCode);
    }

    /**
     * @notice Precomputes the deterministic CREATE3 address for any contract name without deploying.
     * @dev Works for both proxy and non-proxy deployments — the address depends only on deployer + salt.
     *
     *      CreateX's deployCreate3 guards the raw salt before using it in CREATE2:
     *        guardedSalt = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), rawSalt))
     *      This guard applies when bytes 0-19 of the salt equal msg.sender (deployer) and byte 20 = 0x00.
     *      computeCreate3Address expects the already-guarded salt, so we must apply the same
     *      transformation here to get an address that matches what deployCreate3 actually produces.
     *
     * @param deployer Address that will call CreateX.
     * @param contractName Salt name (must match what _deploy3 or _deployProxy3 will use).
     * @return The deterministic address.
     */
    function _computeCreate3Address(address deployer, string memory contractName) internal pure returns (address) {
        bytes32 rawSalt = _computeSalt(deployer, contractName);
        // Apply CreateX's _guard transformation for permissioned salts (bytes 0-19 = deployer, byte 20 = 0x00):
        //   guardedSalt = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), rawSalt))
        bytes32 guardedSalt = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), rawSalt));
        return CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));
    }

    /**
     * @notice Alias for _computeCreate3Address — kept for backwards compatibility.
     */
    function _computeProxyAddress(address deployer, string memory contractName) internal pure returns (address) {
        return _computeCreate3Address(deployer, contractName);
    }
}

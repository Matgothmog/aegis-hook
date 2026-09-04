// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AegisHook} from "../src/AegisHook.sol";
import {AegisDeploy} from "./AegisDeploy.sol";

/// @notice Deploy AegisHook to a chain that already has a v4 PoolManager.
///
/// Verified PoolManager addresses (checked to have code, not copied from a search result):
///   Unichain Sepolia  1301       0x00b036b58a818b1bc34d502d3fe730db729e62ac
///   Base Sepolia      84532      0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408
///   Ethereum Sepolia  11155111   0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
///
/// Dry run (no broadcast, no funds needed):
///   forge script script/DeployAegis.s.sol --rpc-url unichain_sepolia
///
/// Live:
///   forge script script/DeployAegis.s.sol --rpc-url unichain_sepolia \
///     --broadcast --private-key $PRIVATE_KEY
contract DeployAegis is Script {
    /// @dev Defaults to Unichain Sepolia, because the MEV tax assumes priority-fee ordering and
    ///      Unichain is the chain whose sequencer actually provides it.
    address constant DEFAULT_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external returns (AegisHook hook, bytes32 salt) {
        IPoolManager poolManager = IPoolManager(vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER));
        address guardian = vm.envOr("GUARDIAN", msg.sender);

        console2.log("chain id      ", block.chainid);
        console2.log("pool manager  ", address(poolManager));
        console2.log("guardian      ", guardian);

        vm.startBroadcast();
        (hook, salt) = AegisDeploy.deploy(poolManager, guardian);
        vm.stopBroadcast();

        console2.log("hook deployed ", address(hook));
        console2.log("permission bits", uint160(address(hook)) & 0x3FFF);
        console2.logBytes32(salt);
    }
}

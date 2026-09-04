// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {AegisHook} from "../src/AegisHook.sol";

/// @title AegisDeploy
/// @notice The one place that knows how an Aegis hook comes into existence.
///
/// @dev v4 encodes a hook's permissions in the low 14 bits of its own address, so a hook cannot
///      simply be deployed — an address has to be *found* whose bits already spell the
///      permissions the contract claims, then reached deterministically via CREATE2.
///
///      This lives in a library rather than in the script because the deploy script and the
///      tests must exercise the *same* code. A test that constructs the hook some other way —
///      `deployCodeTo`, a plain `new` — proves nothing about whether the real deployment works,
///      since address derivation is the part that actually fails. Everything here is what runs
///      onchain; the tests call it directly.
library AegisDeploy {
    /// @notice Deterministic CREATE2 proxy, present at the same address on every EVM chain.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The permission bits Aegis claims. `AegisHook`'s constructor asserts the address it
    ///         lands on encodes exactly these, so a bad mine reverts at deployment rather than
    ///         silently producing a hook whose callbacks v4 never invokes.
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    error PoolManagerHasNoCode(address poolManager);
    error Create2FactoryMissing(address factory);
    error DeploymentFailed();
    error AddressMismatch(address expected, address actual);

    function initCode(IPoolManager poolManager, address guardian) internal pure returns (bytes memory) {
        return abi.encodePacked(type(AegisHook).creationCode, abi.encode(poolManager, guardian));
    }

    /// @notice Search for a salt whose CREATE2 address carries the Aegis permission bits.
    /// @dev ~2^14 expected iterations, since 14 specific bits must match.
    function mine(IPoolManager poolManager, address guardian)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        (hookAddress, salt) =
            HookMiner.find(CREATE2_FACTORY, FLAGS, type(AegisHook).creationCode, abi.encode(poolManager, guardian));
    }

    /// @notice Mine and deploy. Reverts rather than half-succeeding at every step that can fail.
    function deploy(IPoolManager poolManager, address guardian) internal returns (AegisHook hook, bytes32 salt) {
        // Guard the two "wrong network" mistakes that otherwise surface as an opaque revert:
        // a PoolManager address copied from the wrong chain, and a chain without the proxy.
        if (address(poolManager).code.length == 0) revert PoolManagerHasNoCode(address(poolManager));
        if (CREATE2_FACTORY.code.length == 0) revert Create2FactoryMissing(CREATE2_FACTORY);

        address predicted;
        (predicted, salt) = mine(poolManager, guardian);

        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode(poolManager, guardian)));
        if (!ok) revert DeploymentFailed();

        address deployed = address(uint160(bytes20(ret)));
        if (deployed != predicted) revert AddressMismatch(predicted, deployed);
        if (deployed.code.length == 0) revert DeploymentFailed();

        hook = AegisHook(deployed);
    }
}

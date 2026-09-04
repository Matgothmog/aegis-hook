// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title BaseHook
/// @notice Minimal, self-contained base for a Uniswap v4 hook.
/// @dev v4-periphery removed its own `BaseHook` (see the `src/base` layout as of Aug 2026),
///      so Aegis carries its own rather than depending on an external re-implementation.
///      For a security project this is the right trade: the entire trusted surface of the
///      hook is in-repo and auditable, and there is no upstream API drift to track.
///
///      Every entrypoint is gated on `onlyPoolManager`. Unimplemented callbacks revert with
///      `HookNotImplemented` — they are unreachable in practice, because v4 only invokes the
///      callbacks encoded in the hook's own address bits, and the constructor asserts that
///      those bits match `getHookPermissions()` exactly.
abstract contract BaseHook is IHooks {
    /// @notice Thrown when a callback is invoked by anything other than the PoolManager.
    error NotPoolManager();
    /// @notice Thrown when a callback the hook does not implement is somehow reached.
    error HookNotImplemented();

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        validateHookAddress(this);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice The permissions this hook claims. Must match the deployed address's low bits.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    /// @dev Asserts the address the hook was mined to actually encodes `getHookPermissions()`.
    ///      Reverts deployment otherwise, so a mis-mined hook can never go live.
    function validateHookAddress(BaseHook _this) internal pure virtual {
        Hooks.validateHookPermissions(_this, getHookPermissions());
    }

    // -------------------------------------------------------------------------
    // IHooks — default implementations revert; children override what they claim.
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {AegisHook} from "../../src/AegisHook.sol";

/// @notice Shared fixture: one Aegis-protected pool and one vanilla pool on the same
///         PoolManager, with identical liquidity, so every attack can be run against both.
///         The vanilla pool is the control group — without it, no result means anything.
abstract contract AegisFixture is Test, Deployers {
    using LPFeeLibrary for uint24;

    AegisHook internal hook;

    PoolKey internal aegisKey;
    PoolId internal aegisId;

    PoolKey internal vanillaKey;
    PoolId internal vanillaId;

    address internal guardian;

    int24 internal constant TICK_SPACING = 60;

    /// @dev The permission bits Aegis claims. Must equal `getHookPermissions()`,
    ///      or the hook's own constructor rejects the deployment.
    uint160 internal constant AEGIS_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function _deployAegis() internal {
        guardian = address(this);

        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // v4 encodes hook permissions in the low bits of the hook's address, so the hook has to
        // live at an address matching AEGIS_FLAGS. In tests we place it directly; the deploy
        // script mines a CREATE2 salt for the same result onchain.
        address target = address(AEGIS_FLAGS ^ (0x4444 << 144));
        deployCodeTo("AegisHook.sol:AegisHook", abi.encode(manager, guardian), target);
        hook = AegisHook(target);

        // Protected pool — must opt into dynamic fees or beforeInitialize rejects it.
        (aegisKey, aegisId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1);

        hook.configurePool(aegisKey, _defaultConfig());

        // Control pool — same currencies, same liquidity, no hook.
        (vanillaKey, vanillaId) =
            initPool(currency0, currency1, IHooks(address(0)), 3000, TICK_SPACING, SQRT_PRICE_1_1);

        _addLiquidity(aegisKey, 1000e18);
        _addLiquidity(vanillaKey, 1000e18);
    }

    function _defaultConfig() internal pure returns (AegisHook.PoolConfig memory) {
        return AegisHook.PoolConfig({
            baseFee: 3000, // 0.30% floor
            maxFee: 50_000, // 5% ceiling
            mevTaxPerGwei: 10_000, // +1% of fee per gwei of priority fee
            maxTickDeviation: 500, // ~5% per block
            cooldownBlocks: 100,
            minPositionAgeBlocks: 0, // JIT defense off by default; enabled per-test
            maxVolumePerBlock: type(uint128).max, // volume limit off by default
            configured: true
        });
    }

    function _addLiquidity(PoolKey memory k, int256 amount) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: amount, salt: 0}),
            ZERO_BYTES
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @notice Simulate a searcher bidding `gwei` of priority fee on top of base fee.
    function _setPriorityFee(uint256 gweiBid) internal {
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + gweiBid * 1 gwei);
    }
}

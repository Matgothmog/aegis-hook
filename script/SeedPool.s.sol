// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AegisHook} from "../src/AegisHook.sol";

/// @notice Stand up a live Aegis-protected pool: two demo tokens, routers, an initialized
///         dynamic-fee pool, and liquidity. Run once; then drive it with DemoSwap.s.sol.
///
/// Uses v4's own test routers rather than PositionManager. On a testnet demo that is the right
/// trade — they are small, their behaviour is already exercised by this repo's suite, and they
/// keep the script legible. A production deployment would route through PositionManager.
///
///   forge script script/SeedPool.s.sol --rpc-url unichain_sepolia --broadcast \
///     --account aegis-deployer --password aegis-testnet-only
contract SeedPool is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;

    function run() external {
        AegisHook hook = AegisHook(vm.envAddress("HOOK"));

        vm.startBroadcast();

        MockERC20 a = new MockERC20("Aegis Demo A", "AEGA", 18);
        MockERC20 b = new MockERC20("Aegis Demo B", "AEGB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);

        PoolSwapTest swapRouter = new PoolSwapTest(POOL_MANAGER);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        t0.mint(msg.sender, 1_000_000e18);
        t1.mint(msg.sender, 1_000_000e18);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // beforeInitialize rejects anything else
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);

        hook.configurePool(
            key,
            AegisHook.PoolConfig({
                baseFee: 3000, // 0.30% floor
                maxFee: 50_000, // 5% ceiling
                mevTaxPerGwei: 10_000, // +1% of fee per gwei bid
                maxTickDeviation: 500, // ~5% per block
                cooldownBlocks: 100,
                minPositionAgeBlocks: 0,
                maxVolumePerBlock: type(uint128).max,
                configured: true
            })
        );

        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1000e18, salt: 0}),
            ""
        );

        vm.stopBroadcast();

        console2.log("token0        ", address(t0));
        console2.log("token1        ", address(t1));
        console2.log("swapRouter    ", address(swapRouter));
        console2.log("liqRouter     ", address(liquidityRouter));
        console2.log("hook          ", address(hook));
        console2.log("poolId        ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}

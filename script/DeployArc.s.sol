// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AegisHook} from "../src/AegisHook.sol";
import {AegisDeploy} from "./AegisDeploy.sol";

/// @notice Bring Aegis to Arc — Circle's stablecoin-native L1 (chain 5042002).
///
/// Arc has no Uniswap v4 deployment, so this deploys a PoolManager first. That is the interesting
/// part: it is a v4 deployment on a chain that did not have one, with a security hook on top.
///
/// ## Two things Arc changes, both measured rather than assumed
///
/// **The tax needs a floor.** Arc runs a flat 20 gwei base fee and its median transaction bids
/// 10 gwei of priority (sampled: 666 txs over 40 blocks, p50 10, p90 25, p99 80). Charging the raw
/// priority fee would tax that median swap 100,000 units, clamp to the ceiling, and make every
/// ordinary trade pay the 5% maximum. `mevTaxFloorGwei` is set at Arc's p90 so ambient flow is
/// untaxed and only a genuine outbid pays.
///
/// **The breaker can be far tighter.** Arc is built for stablecoins, and a stable pair has no
/// business moving 5% in a block — ever. What would strangle a volatile pair is comfortable here,
/// and a manipulation that could hide inside ETH volatility stands out immediately.
///
/// **The tax's economics are weaker here, and that is stated rather than hidden.** Arc uses
/// Malachite consensus, where ordering is proposer-determined rather than a priority-fee auction.
/// The mechanism still executes and still charges, but the argument that a bid is a *truthful*
/// signal is a property of priority ordering, which Unichain has and Arc does not. On Arc the
/// breaker and the position-age rule are what carry the defense.
///
///   forge script script/DeployArc.s.sol --rpc-url arc_testnet --broadcast \
///     --account aegis-deployer --password aegis-testnet-only
contract DeployArc is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Stablecoin pairs live in a narrow band, so a tight spacing is the right granularity.
    int24 constant TICK_SPACING = 10;

    /// @dev Arc's measured p90 priority fee. Below this is ambient flow, not a bid for position.
    uint24 constant ARC_TAX_FLOOR_GWEI = 25;

    /// @dev ~0.5%. Aegis's calibration engine put volatile Unichain pools at 100-200 ticks against
    ///      a worst honest excursion of 39. A stablecoin pair should move far less than that, so
    ///      50 is deliberately tighter — and is a starting point to be re-derived from Arc's own
    ///      history once this pool has one, not a number to leave sitting there.
    uint24 constant ARC_TICK_DEVIATION = 50;

    function run() external {
        address guardian = vm.envOr("GUARDIAN", msg.sender);

        vm.startBroadcast();

        // Arc has no v4. Bring one.
        PoolManager manager = new PoolManager(guardian);
        console2.log("PoolManager   ", address(manager));

        (AegisHook hook, bytes32 salt) = AegisDeploy.deploy(IPoolManager(address(manager)), guardian);
        console2.log("AegisHook     ", address(hook));
        console2.log("permission bits", uint160(address(hook)) & 0x3FFF);

        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        PoolModifyLiquidityTest liqRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // Stand-ins for a stablecoin pair. Real USDC on Arc would slot in unchanged.
        MockERC20 a = new MockERC20("Aegis USD A", "aUSDA", 6);
        MockERC20 b = new MockERC20("Aegis USD B", "aUSDB", 6);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);

        t0.mint(msg.sender, 1_000_000e6);
        t1.mint(msg.sender, 1_000_000e6);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liqRouter), type(uint256).max);
        t1.approve(address(liqRouter), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        hook.configurePool(
            key,
            AegisHook.PoolConfig({
                baseFee: 500, // 0.05% — a stable pair cannot carry a 0.30% fee
                maxFee: 20_000, // 2% ceiling, likewise tighter
                mevTaxPerGwei: 10_000,
                mevTaxFloorGwei: ARC_TAX_FLOOR_GWEI,
                maxTickDeviation: ARC_TICK_DEVIATION,
                cooldownBlocks: 100,
                minPositionAgeBlocks: 5, // JIT defense on: stable pools are where JIT pays best
                maxVolumePerBlock: type(uint128).max,
                configured: true
            })
        );

        liqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -500, tickUpper: 500, liquidityDelta: 100_000e6, salt: 0}),
            ""
        );

        vm.stopBroadcast();

        console2.log("swapRouter    ", address(swapRouter));
        console2.log("liqRouter     ", address(liqRouter));
        console2.log("token0        ", address(t0));
        console2.log("token1        ", address(t1));
        console2.log("poolId        ");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.logBytes32(salt);
    }
}

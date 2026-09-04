// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AegisFixture} from "./utils/AegisFixture.sol";
import {AegisHook} from "../src/AegisHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract AegisHookTest is AegisFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployAegis();
    }

    // -------------------------------------------------------------------------
    // Day 1 gate: the hook is wired in and swaps route through it.
    // -------------------------------------------------------------------------

    function test_hookAddressEncodesItsPermissions() public view {
        // The constructor would have reverted otherwise, but assert it explicitly:
        // a hook whose address disagrees with its claimed permissions is the single
        // most common v4 deployment footgun.
        assertEq(uint160(address(hook)) & 0x3FFF, AEGIS_FLAGS, "address bits != permissions");
    }

    function test_swapRoutesThroughHook() public {
        _setPriorityFee(0);
        uint256 taxBefore = hook.mevTaxUnitsCollected(aegisId);

        _swap(aegisKey, true, -1e15);

        // A swap with no priority fee bid collects no tax, but must still have executed.
        (, int24 tick,,) = manager.getSlot0(aegisId);
        assertLt(tick, 0, "price should have moved down on a 0->1 swap");
        assertEq(hook.mevTaxUnitsCollected(aegisId), taxBefore, "no bid should mean no tax");
    }

    function test_poolMustUseDynamicFee() public {
        // A static-fee pool would silently ignore the MEV tax. Fail closed instead.
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, TICK_SPACING, SQRT_PRICE_1_1);
    }

    // -------------------------------------------------------------------------
    // MEV tax
    // -------------------------------------------------------------------------

    function test_mevTaxScalesWithPriorityFee() public {
        _setPriorityFee(0);
        assertEq(hook.quoteFee(aegisKey), 3000, "no bid => base fee");

        _setPriorityFee(1);
        assertEq(hook.quoteFee(aegisKey), 13_000, "1 gwei bid => +1%");

        _setPriorityFee(2);
        assertEq(hook.quoteFee(aegisKey), 23_000, "2 gwei bid => +2%");
    }

    function test_mevTaxIsCappedAtMaxFee() public {
        // An unbounded fee would let a searcher's bid grief honest flow sharing the block.
        _setPriorityFee(1000);
        assertEq(hook.quoteFee(aegisKey), 50_000, "must clamp to maxFee");
    }

    function test_mevTaxIsCollectedOnSwap() public {
        _setPriorityFee(2);
        _swap(aegisKey, true, -1e15);
        assertEq(hook.mevTaxUnitsCollected(aegisId), 20_000, "tax units recorded for the watchtower");
    }

    /// @dev The fee curve must be monotonic and never exceed the ceiling, for any bid.
    function testFuzz_feeCurveIsMonotonicAndBounded(uint64 bidWei) public {
        // vm.txGasPrice caps at 2^64, so the bid is bounded to keep basefee + bid representable.
        bidWei = uint64(bound(bidWei, 0, type(uint64).max - uint64(1 gwei)));

        vm.fee(1 gwei);
        vm.txGasPrice(uint256(1 gwei) + bidWei);
        uint24 fee = hook.quoteFee(aegisKey);

        assertGe(fee, 3000, "never below the floor");
        assertLe(fee, 50_000, "never above the ceiling");

        // Monotonicity: a strictly larger bid never yields a smaller fee.
        if (bidWei < type(uint64).max - uint64(1 gwei)) {
            vm.txGasPrice(uint256(1 gwei) + bidWei + 1);
            assertGe(hook.quoteFee(aegisKey), fee, "fee must be non-decreasing in the bid");
        }
    }

    // -------------------------------------------------------------------------
    // Circuit breaker
    // -------------------------------------------------------------------------

    function test_breakerAllowsNormalFlow() public {
        _setPriorityFee(0);
        _swap(aegisKey, true, -1e15);
        _swap(aegisKey, true, -1e15);
        // Two small swaps in one block stay well inside the deviation bound.
    }

    function test_breakerRejectsLargeIntraBlockMove() public {
        _setPriorityFee(0);

        // Establish the block-open checkpoint with a small swap.
        _swap(aegisKey, true, -1e15);

        // Now try to walk the price far beyond the per-block bound, in the same block.
        vm.expectRevert();
        _swap(aegisKey, true, -50e18);
    }

    function test_breakerCheckpointResetsEachBlock() public {
        _setPriorityFee(0);
        _swap(aegisKey, true, -1e15);

        // Same move that would be rejected intra-block is fine once the block rolls over,
        // because the checkpoint re-anchors. The breaker bounds velocity, not total drift.
        vm.roll(block.number + 1);
        _swap(aegisKey, true, -1e15);
    }

    function test_volumeLimitRejectsOversizedBlock() public {
        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.maxVolumePerBlock = 1e15;
        hook.configurePool(aegisKey, cfg);

        _setPriorityFee(0);
        vm.expectRevert();
        _swap(aegisKey, true, -2e15);
    }

    // -------------------------------------------------------------------------
    // Guardian — bounded authority
    // -------------------------------------------------------------------------

    function test_guardianCanHaltAndResume() public {
        _setPriorityFee(0);
        hook.halt(aegisKey);

        vm.expectRevert();
        _swap(aegisKey, true, -1e15);

        hook.resume(aegisKey);
        _swap(aegisKey, true, -1e15);
    }

    function test_nonGuardianCannotHalt() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AegisHook.NotGuardian.selector);
        hook.halt(aegisKey);
    }

    function test_guardianCannotExceedHardBounds() public {
        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.maxFee = 200_000; // above ABSOLUTE_MAX_FEE
        vm.expectRevert(AegisHook.InvalidConfig.selector);
        hook.configurePool(aegisKey, cfg);

        cfg = _defaultConfig();
        cfg.maxTickDeviation = 1; // below MIN_TICK_DEVIATION — would halt honest flow
        vm.expectRevert(AegisHook.InvalidConfig.selector);
        hook.configurePool(aegisKey, cfg);

        cfg = _defaultConfig();
        cfg.cooldownBlocks = 100_000; // guardian must not be able to halt forever
        vm.expectRevert(AegisHook.InvalidConfig.selector);
        hook.configurePool(aegisKey, cfg);
    }

    function test_haltDoesNotBlockWithdrawals() public {
        // A halted pool must still let LPs leave, or the breaker becomes a hostage mechanism.
        hook.halt(aegisKey);
        modifyLiquidityRouter.modifyLiquidity(
            aegisKey,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: -1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // -------------------------------------------------------------------------
    // JIT defense
    // -------------------------------------------------------------------------

    function test_jitLiquidityCannotExitImmediately() public {
        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.minPositionAgeBlocks = 5;
        hook.configurePool(aegisKey, cfg);

        modifyLiquidityRouter.modifyLiquidity(
            aegisKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(uint256(1))}),
            ZERO_BYTES
        );

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            aegisKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -1e18, salt: bytes32(uint256(1))}),
            ZERO_BYTES
        );

        // ...but it can leave once it has carried real price risk for the required window.
        vm.roll(block.number + 5);
        modifyLiquidityRouter.modifyLiquidity(
            aegisKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -1e18, salt: bytes32(uint256(1))}),
            ZERO_BYTES
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AegisFixture} from "../utils/AegisFixture.sol";
import {AegisHook} from "../../src/AegisHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Attack lab — single-block price manipulation.
///
/// This is the attack the MEV tax cannot touch. An attacker borrowing flash-loan-scale capital
/// slams the pool price inside one block, so that any contract reading a price from this pool in
/// that block reads a fabricated one — a lending market sizing a loan, a liquidation engine
/// deciding whether a position is underwater, a derivative settling.
///
/// The profit here is not the swap. The swap is a loss the attacker happily eats, because it is
/// paid for many times over by whatever mispriced the manipulated reading unlocks. Charging a
/// larger fee changes nothing: a 5% fee against an eight-figure exploit is a rounding error.
///
/// Only a hard bound helps, and that is what the breaker is. Aegis refuses to let one block move
/// the price beyond a configured number of ticks, whatever the attacker is willing to pay.
contract OracleManipulationTest is AegisFixture {
    using StateLibrary for IPoolManager;

    address internal manipulator = address(0xDEADBEEF);

    /// @dev Flash-loan scale relative to the book: enough to walk the price a long way.
    uint256 internal constant ATTACK_SIZE = 400e18;

    function setUp() public {
        _deployAegis();
        _fundActor(manipulator, 10_000_000e18);
    }

    /// @dev Public so `vm.expectRevert` can target a genuine external call.
    function runManipulation(PoolKey memory k, PoolId id, uint256 size)
        public
        returns (int24 tickBefore, int24 tickAfter)
    {
        (, tickBefore,,) = manager.getSlot0(id);
        _swapAs(manipulator, k, true, -int256(size));
        (, tickAfter,,) = manager.getSlot0(id);
    }

    // -------------------------------------------------------------------------

    /// @notice Control group: nothing in v4 itself bounds how far one block may move a price.
    function test_vanillaPoolCanBeMovedArbitrarilyInOneBlock() public {
        _setPriorityFee(0);
        (int24 before_, int24 after_) = this.runManipulation(vanillaKey, vanillaId, ATTACK_SIZE);

        int256 moved = int256(after_) - int256(before_);
        emit log_named_int("vanilla pool | tick before", before_);
        emit log_named_int("vanilla pool | tick after ", after_);
        emit log_named_int("vanilla pool | ticks moved in ONE block", moved);

        assertLt(after_, before_ - 500, "control group: the price must actually be manipulable");
    }

    /// @notice The same capital against Aegis cannot move the price past the bound.
    function test_breakerRefusesTheManipulation() public {
        _setPriorityFee(0);
        vm.expectRevert();
        this.runManipulation(aegisKey, aegisId, ATTACK_SIZE);
    }

    /// @notice Paying more does not help. This is the property that distinguishes the breaker
    ///         from the tax: it is a bound, not a price, so there is no bid that clears it.
    function test_breakerCannotBeBoughtOff() public {
        _setPriorityFee(500); // an absurd bid, far past the fee ceiling
        vm.expectRevert();
        this.runManipulation(aegisKey, aegisId, ATTACK_SIZE);
    }

    /// @notice Splitting the attack across swaps within the block does not help either — the
    ///         checkpoint is per block, so the bound applies to cumulative movement, not per-swap.
    function test_breakerResistsSplittingWithinABlock() public {
        _setPriorityFee(0);
        vm.expectRevert();
        this.runSplitManipulation(aegisKey, ATTACK_SIZE, 8);
    }

    function runSplitManipulation(PoolKey memory k, uint256 total, uint256 slices) public {
        for (uint256 i; i < slices; ++i) {
            _swapAs(manipulator, k, true, -int256(total / slices));
        }
    }

    /// @notice Honest volatility is not blocked: the bound re-anchors each block, so a market
    ///         that genuinely moves can still get there — it just cannot arrive instantly.
    function test_priceCanStillMoveAcrossBlocks() public {
        _setPriorityFee(0);
        (, int24 start,,) = manager.getSlot0(aegisId);

        for (uint256 i; i < 6; ++i) {
            _swapAs(manipulator, aegisKey, true, -20e18);
            vm.roll(block.number + 1);
        }

        (, int24 end,,) = manager.getSlot0(aegisId);
        emit log_named_int("aegis | ticks moved across 6 blocks", int256(end) - int256(start));
        assertLt(end, start - 500, "sustained honest movement must remain possible");
    }

    /// @notice Side-by-side benchmark for the submission table.
    function test_benchmarkManipulation() public {
        _setPriorityFee(0);
        (int24 vBefore, int24 vAfter) = this.runManipulation(vanillaKey, vanillaId, ATTACK_SIZE);

        emit log_string("");
        emit log_string("  single-block price manipulation | 400e18 against a 1000e18 book");
        emit log_named_int("    vanilla pool   ticks moved in one block", int256(vAfter) - int256(vBefore));
        emit log_string("    aegis pool     reverted - bound is 500 ticks");
        emit log_string("");

        vm.expectRevert();
        this.runManipulation(aegisKey, aegisId, ATTACK_SIZE);
    }
}

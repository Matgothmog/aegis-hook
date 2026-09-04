// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AegisFixture} from "./utils/AegisFixture.sol";
import {AegisHook} from "../src/AegisHook.sol";
import {OracleReference} from "../src/libraries/OracleReference.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice The multi-block gap, and the reference that closes it.
///
/// Aegis's circuit breaker bounds movement *within* a block, which forecloses everything needing
/// atomicity. An attacker willing to spend several blocks can walk the price anywhere, one legal
/// step at a time — and a lending market reading this pool would follow them the whole way.
///
/// The per-block breaker cannot see it, by construction: it re-anchors its checkpoint every
/// block, so a slow walk never violates it. Catching it needs a reference the attacker does not
/// control.
contract OracleGuardTest is AegisFixture {
    using StateLibrary for IPoolManager;

    MockAggregator internal feed;
    address internal walker = address(0xA11CE);

    function setUp() public {
        _deployAegis();
        _fundActor(walker, 10_000_000e18);
        // Both fixture tokens are 18dp and the pool opens at 1:1, so 1.00000000 is tick 0.
        feed = new MockAggregator(8, 1e8);
    }

    function _attachOracle(uint24 bound, uint32 staleness) internal {
        hook.configureOracle(
            aegisKey,
            OracleReference.Config({
                feed: address(feed),
                feedDecimals: 8,
                token0Decimals: 18,
                token1Decimals: 18,
                invert: false,
                maxTickDeviation: bound,
                maxStaleness: staleness
            })
        );
    }

    /// @dev Walk the price down over `blocks` blocks, each step small enough that the per-block
    ///      breaker allows it. Public so `vm.expectRevert` sees a real call boundary.
    function walk(uint256 blocks, uint256 sizePerBlock) public {
        for (uint256 i; i < blocks; ++i) {
            _swapAs(walker, aegisKey, true, -int256(sizePerBlock));
            vm.roll(block.number + 1);
        }
    }

    // -------------------------------------------------------------------------

    /// @notice Control: with no oracle attached, the slow walk succeeds. This is the gap.
    function test_multiBlockWalkSucceedsWithoutAnOracle() public {
        _setPriorityFee(0);
        (, int24 start,,) = manager.getSlot0(aegisId);

        this.walk(6, 20e18);

        (, int24 end,,) = manager.getSlot0(aegisId);
        emit log_named_int("ticks moved across 6 blocks, no oracle", int256(end) - int256(start));
        assertLt(end, start - 1000, "the walk must actually move the price");
    }

    /// @notice The same walk, with a reference attached, is stopped once it drifts too far from
    ///         a price the attacker does not control.
    function test_oracleStopsTheMultiBlockWalk() public {
        _setPriorityFee(0);
        _attachOracle(1000, 3600); // ~10% from the reference

        vm.expectRevert();
        this.walk(6, 20e18);
    }

    /// @notice And it does not interfere while the pool tracks the reference.
    function test_oracleAllowsMovementTheReferenceAgreesWith() public {
        _setPriorityFee(0);
        _attachOracle(1000, 3600);

        // A genuine repricing: the market moves and the feed moves with it. Each leg is kept
        // inside the 1000-tick bound — two blocks of this size drift ~750 — because the point is
        // that tracked movement is allowed, not that the bound can be exceeded.
        this.walk(2, 20e18);
        (, int24 tick,,) = manager.getSlot0(aegisId);
        assertLt(tick, 0, "pool should have moved");

        // The feed catches up to where the pool now is, so drift returns to ~0 and the pool is
        // free to keep moving. This is the difference between a repricing and a manipulation:
        // the rest of the world agrees.
        feed.set(_answerForTick(tick));
        this.walk(2, 20e18);

        (, int24 endTick,,) = manager.getSlot0(aegisId);
        assertLt(endTick, tick, "tracked movement must be allowed to continue");
    }

    /// @dev The answer a feed would report if the pool sat exactly at `tick`. Derived from
    ///      TickMath rather than approximated — an earlier version used a coarse power-of-1.0001
    ///      estimate that returned an unchanged price for small moves, which made this test look
    ///      like an oracle failure when it was a test-helper failure.
    function _answerForTick(int24 tick) internal pure returns (int256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
        // both fixture tokens are 18dp, feed is 8dp: answer = price · 1e8
        return int256(FullMath.mulDiv(priceX96, 1e8, 1 << 96));
    }

    // -------------------------------------------------------------------------
    // Fail-open behaviour
    // -------------------------------------------------------------------------

    /// @notice A stale feed must not halt the pool. Failing closed would turn a Chainlink outage
    ///         into a denial of service on the venue people need most when markets move.
    function test_staleFeedFailsOpenRatherThanHaltingThePool() public {
        _setPriorityFee(0);
        _attachOracle(1000, 3600);

        // Push the pool far from the reference, then let the feed go stale.
        vm.warp(block.timestamp + 10_000);
        feed.setStale(1e8, 7200);

        // The swap succeeds despite the divergence, because the reference is not usable.
        this.walk(6, 20e18);

        (, int24 tick,,) = manager.getSlot0(aegisId);
        assertLt(tick, -1000, "pool drifted well past the oracle bound, and still traded");
    }

    function test_brokenFeedFailsOpen() public {
        _setPriorityFee(0);
        _attachOracle(1000, 3600);
        feed.set(0); // a broken feed, not a zero price

        this.walk(6, 20e18);
    }

    /// @notice Detaching the oracle restores the pre-oracle behaviour exactly.
    function test_oracleCanBeDetached() public {
        _setPriorityFee(0);
        _attachOracle(1000, 3600);

        hook.configureOracle(
            aegisKey,
            OracleReference.Config({
                feed: address(0),
                feedDecimals: 0,
                token0Decimals: 0,
                token1Decimals: 0,
                invert: false,
                maxTickDeviation: 0,
                maxStaleness: 0
            })
        );
        this.walk(6, 20e18);
    }

    function test_onlyGuardianCanConfigureTheOracle() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AegisHook.NotGuardian.selector);
        _attachOracle(1000, 3600);
    }
}

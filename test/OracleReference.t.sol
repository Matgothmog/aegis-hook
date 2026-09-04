// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {OracleReference} from "../src/libraries/OracleReference.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @notice Tests for the feed→tick conversion, exercised directly rather than through a swap.
///
/// This is the most error-prone code in Aegis: a mistake in the fixed-point rescaling yields a
/// plausible wrong tick instead of a revert, and would silently either halt an honest pool or
/// wave through the manipulation the check exists to catch. So it is tested against a round
/// trip — derive the feed answer a given pool price implies, convert it back, and require the
/// tick to come home.
contract OracleReferenceTest is Test {
    using OracleReference for OracleReference.Config;

    function _cfg(address feed, uint8 fd, uint8 d0, uint8 d1, bool invert)
        internal
        pure
        returns (OracleReference.Config memory)
    {
        return OracleReference.Config({
            feed: feed,
            feedDecimals: fd,
            token0Decimals: d0,
            token1Decimals: d1,
            invert: invert,
            maxTickDeviation: 500,
            maxStaleness: 3600
        });
    }

    /// @dev The answer a feed would report if the pool sat exactly at `tick`.
    function _answerForTick(int24 tick, uint8 fd, uint8 d0, uint8 d1) internal pure returns (int256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        // poolPrice = (sqrtP / 2^96)^2, in raw units; answer = poolPrice · 10^fd · 10^d0 / 10^d1
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96); // price · 2^96
        uint256 scaled = FullMath.mulDiv(priceX96, 10 ** uint256(fd) * 10 ** uint256(d0), 1 << 96);
        return int256(scaled / 10 ** uint256(d1));
    }

    // -------------------------------------------------------------------------

    function test_parityPriceMapsToTickZero() public {
        // Both tokens 18dp, feed 8dp, answer 1.00000000 → the pool sits at 1:1, i.e. tick 0.
        MockAggregator feed = new MockAggregator(8, 1e8);
        (OracleReference.Status s, int24 tick) = _cfg(address(feed), 8, 18, 18, false).referenceTick();

        assertEq(uint8(s), uint8(OracleReference.Status.Ok));
        assertApproxEqAbs(int256(tick), int256(0), 1, "parity must land on tick 0");
    }

    /// @notice The realistic shape: 18-decimal token0 against a 6-decimal token1, as WETH/USDC.
    ///         Getting the decimal rescaling wrong here is the classic oracle-integration bug.
    function test_mixedDecimalsRoundTrip() public {
        int24 target = 199_000; // roughly where a WETH/USDC pool sits
        int256 answer = _answerForTick(target, 8, 18, 6);
        MockAggregator feed = new MockAggregator(8, answer);

        (OracleReference.Status s, int24 tick) = _cfg(address(feed), 8, 18, 6, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.Ok));
        assertApproxEqAbs(int256(tick), int256(target), 2, "mixed decimals must round-trip");
    }

    function test_invertedFeedRoundTrip() public {
        // A feed quoting token0 per token1 must produce the same tick as its reciprocal.
        MockAggregator direct = new MockAggregator(8, 2000e8);
        MockAggregator inverse = new MockAggregator(8, int256(1e8 * 1e8) / 2000e8);

        (, int24 a) = _cfg(address(direct), 8, 18, 18, false).referenceTick();
        (, int24 b) = _cfg(address(inverse), 8, 18, 18, true).referenceTick();

        assertApproxEqAbs(int256(a), int256(b), 3, "inverted feed must agree with the direct one");
    }

    /// @notice The property that matters: whatever the pool price, the derived answer converts
    ///         back to the tick it came from.
    function testFuzz_roundTripAcrossTheTickRange(int24 target, uint8 d0, uint8 d1) public {
        target = int24(bound(int256(target), -300_000, 300_000));
        d0 = uint8(bound(d0, 6, 18));
        d1 = uint8(bound(d1, 6, 18));

        int256 answer = _answerForTick(target, 8, d0, d1);
        // The feed must be able to *represent* the price. An 8-decimal feed reporting a value of
        // 3 carries one significant figure, and no conversion recovers a tick from that. This is
        // a property of feed precision, not of the conversion, so it is excluded rather than
        // absorbed into a wider tolerance that would hide a real regression.
        vm.assume(answer >= 1e8);

        MockAggregator feed = new MockAggregator(8, answer);
        (OracleReference.Status s, int24 tick) = _cfg(address(feed), 8, d0, d1, false).referenceTick();
        vm.assume(s == OracleReference.Status.Ok);

        // Tolerance is a few ticks: the answer is integer-truncated at the feed's precision, and
        // one tick is a 0.01% price step, so low-precision feeds cannot resolve it exactly.
        assertApproxEqAbs(int256(tick), int256(target), 5, "round trip must return the tick");
    }

    // -------------------------------------------------------------------------
    // Failure modes — each reported distinctly, never silently as a price
    // -------------------------------------------------------------------------

    function test_unconfiguredFeedIsReportedNotAssumed() public view {
        (OracleReference.Status s,) = _cfg(address(0), 8, 18, 18, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.NotConfigured));
    }

    function test_staleAnswerIsRejected() public {
        MockAggregator feed = new MockAggregator(8, 1e8);
        vm.warp(block.timestamp + 10_000);
        feed.setStale(1e8, 7200); // older than the 3600s bound

        (OracleReference.Status s,) = _cfg(address(feed), 8, 18, 18, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.StaleAnswer));
    }

    function test_nonPositiveAnswerIsRejected() public {
        // A zero or negative answer is a broken feed, not a very low price. Treating it as a
        // price would place the reference tick at an extreme and reject every honest swap.
        MockAggregator feed = new MockAggregator(8, 0);
        (OracleReference.Status s,) = _cfg(address(feed), 8, 18, 18, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.InvalidAnswer));

        feed.set(-1e8);
        (OracleReference.Status s2,) = _cfg(address(feed), 8, 18, 18, false).referenceTick();
        assertEq(uint8(s2), uint8(OracleReference.Status.InvalidAnswer));
    }

    function test_absurdPriceIsReportedOutOfRange() public {
        // Note the calibration: int128.max is NOT absurd here — it converts to a sqrt price of
        // ~1.0e44 against a 1.46e48 ceiling, comfortably representable. It takes ~1e50 to leave
        // v4's range, which is why the bound is where it is rather than at some round number.
        MockAggregator feed = new MockAggregator(8, 1e50);
        (OracleReference.Status s,) = _cfg(address(feed), 8, 18, 18, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.OutOfRange));
    }

    /// @notice A garbage answer must be reported, never revert. This library runs on a fail-open
    ///         path inside `afterSwap`, so an arithmetic revert here would halt the pool.
    function test_hugeAnswerIsReportedRatherThanReverting() public {
        MockAggregator feed = new MockAggregator(8, type(int256).max);
        (OracleReference.Status s,) = _cfg(address(feed), 8, 18, 18, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.OutOfRange), "must report, not revert");
    }

    function test_nonsensicalDecimalsAreReportedAsBadConfig() public {
        MockAggregator feed = new MockAggregator(8, 1e8);
        (OracleReference.Status s,) = _cfg(address(feed), 8, 200, 18, false).referenceTick();
        assertEq(uint8(s), uint8(OracleReference.Status.BadConfig), "10**200 must not be attempted");
    }
}

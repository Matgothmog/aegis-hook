// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title OracleReference
/// @notice Turns a Chainlink price feed into a Uniswap tick, so an external reference can be
///         compared against a pool using the same units the rest of Aegis already works in.
///
/// @dev ## Why this exists
///
/// Aegis's circuit breaker bounds how far a pool's price moves *within one block*, which
/// forecloses every attack that needs atomicity. It says nothing about manipulation walked
/// slowly across many blocks, each move individually legal. Closing that gap needs a reference
/// the attacker does not control, and a price feed is exactly that.
///
/// ## Why it is a separate library
///
/// This is the most error-prone code in the project: fixed-point conversion between a feed's
/// decimal representation and Q64.96 sqrt-price space, where a mistake produces a plausible
/// wrong number rather than a revert. Isolating it means it can be fuzzed directly against a
/// round trip, instead of only being exercised through a swap.
library OracleReference {
    using FixedPointMathLib for uint256;

    /// @notice Why a reference could not be used. Reported rather than swallowed.
    enum Status {
        Ok,
        NotConfigured,
        StaleAnswer,
        InvalidAnswer,
        OutOfRange,
        BadConfig
    }

    /// @dev No real token or feed uses more than this, and it keeps 10**d inside uint256.
    uint8 internal constant MAX_DECIMALS = 36;

    /// @dev Comfortably past anything v4 can represent, and well below where `answer * 10**d`
    ///      would overflow. The bound exists so a garbage feed reading is *reported* rather than
    ///      reverting: this library runs on a fail-open path, and an arithmetic revert inside
    ///      `afterSwap` would turn a broken oracle into a halted pool — the exact denial of
    ///      service the design is trying to avoid.
    uint256 internal constant MAX_ANSWER = 1e50;

    struct Config {
        /// @dev address(0) disables the check entirely.
        address feed;
        uint8 feedDecimals;
        uint8 token0Decimals;
        uint8 token1Decimals;
        /// @dev True when the feed quotes token0 per token1 rather than token1 per token0.
        bool invert;
        /// @dev How far the pool may sit from the reference before a swap is refused.
        uint24 maxTickDeviation;
        /// @dev An answer older than this is treated as unusable.
        uint32 maxStaleness;
    }

    /// @notice Convert a feed answer to the sqrt price the pool would have at that price.
    ///
    /// @dev The pool's price is token1 per token0 in *raw* units, so the feed's answer has to be
    ///      rescaled by both tokens' decimals as well as the feed's own.
    ///
    ///        poolPrice = answer · 10^d1 / (10^feedDecimals · 10^d0)
    ///
    ///      and then, since sqrtPriceX96 = sqrt(poolPrice) · 2^96,
    ///
    ///        sqrtPriceX96 = sqrt(poolPrice · 2^192) = sqrt(poolPrice · 2^96) · 2^48
    ///
    ///      The split into two factors of 2^48 is what keeps the intermediate inside 256 bits:
    ///      multiplying by 2^192 up front would overflow for any realistic price.
    function sqrtPriceFromAnswer(uint256 answer, Config memory cfg) internal pure returns (uint256) {
        uint256 num;
        uint256 den;

        if (!cfg.invert) {
            num = answer * (10 ** uint256(cfg.token1Decimals));
            den = 10 ** (uint256(cfg.feedDecimals) + uint256(cfg.token0Decimals));
        } else {
            num = 10 ** (uint256(cfg.feedDecimals) + uint256(cfg.token1Decimals));
            den = answer * (10 ** uint256(cfg.token0Decimals));
        }
        if (den == 0) return 0;

        uint256 ratioX96 = FullMath.mulDiv(num, 1 << 96, den);
        return ratioX96.sqrt() << 48;
    }

    /// @notice Read the feed and express it as a tick.
    /// @return status Ok only when `tick` is meaningful; the caller decides what a failure means.
    function referenceTick(Config memory cfg) internal view returns (Status status, int24 tick) {
        if (cfg.feed == address(0)) return (Status.NotConfigured, int24(0));

        if (
            cfg.feedDecimals > MAX_DECIMALS || cfg.token0Decimals > MAX_DECIMALS
                || cfg.token1Decimals > MAX_DECIMALS
        ) return (Status.BadConfig, int24(0));

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(cfg.feed).latestRoundData();

        // A non-positive answer is not a low price, it is a broken feed.
        if (answer <= 0) return (Status.InvalidAnswer, int24(0));
        if (uint256(answer) > MAX_ANSWER) return (Status.OutOfRange, int24(0));
        if (cfg.maxStaleness != 0 && block.timestamp > updatedAt + cfg.maxStaleness) {
            return (Status.StaleAnswer, int24(0));
        }

        uint256 sqrtPriceX96 = sqrtPriceFromAnswer(uint256(answer), cfg);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            return (Status.OutOfRange, int24(0));
        }

        return (Status.Ok, TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96)));
    }
}

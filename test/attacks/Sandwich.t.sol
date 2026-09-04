// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AegisFixture} from "../utils/AegisFixture.sol";
import {AegisHook} from "../../src/AegisHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Attack lab — sandwich.
///
/// The attacker runs three swaps inside one block: a frontrun that pushes the price against
/// the victim, the victim's own swap at the degraded price, and a backrun that unwinds the
/// position for a profit. The searcher must bid priority fee to win that ordering, and on a
/// priority-ordered chain that bid is what Aegis taxes.
///
/// Every scenario runs twice: once against a vanilla v4 pool, once against Aegis. The vanilla
/// run is the control — it establishes that the attack is real and profitable to begin with,
/// which is the only thing that makes the protected run meaningful.
contract SandwichTest is AegisFixture {
    address internal attacker = address(0xA77AC4);
    address internal victim = address(0xB0B);

    /// @dev Priority fee the searcher bids to win the ordering race, in gwei.
    uint256 internal constant SEARCHER_BID_GWEI = 3;

    function setUp() public {
        _deployAegis();
        _fund(attacker, 1_000e18);
        _fund(victim, 1_000e18);
    }

    function _fund(address who, uint256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, amt);
        MockERC20(Currency.unwrap(currency1)).mint(who, amt);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swapAs(address who, PoolKey memory k, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta)
    {
        vm.prank(who);
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

    function _bal(address who) internal view returns (uint256 t0, uint256 t1) {
        t0 = MockERC20(Currency.unwrap(currency0)).balanceOf(who);
        t1 = MockERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    /// @notice Run the full three-swap sandwich. Returns attacker PnL denominated in token0.
    /// @dev Reverts propagate — a blocked frontrun means the attack could not be mounted at all.
    /// @dev Public so `vm.expectRevert` can target it as a real external call — cheatcodes
    ///      that expect a revert do not apply to internal calls.
    function runSandwich(PoolKey memory k, uint256 frontrunAmt, uint256 victimAmt)
        public
        returns (int256 pnl0)
    {
        (uint256 startT0, uint256 startT1) = _bal(attacker);

        // 1. Frontrun. The searcher bids priority fee to land first.
        _setPriorityFee(SEARCHER_BID_GWEI);
        _swapAs(attacker, k, true, -int256(frontrunAmt));

        // Only the token1 *acquired by the frontrun* gets unwound. Using the attacker's whole
        // balance here would model a large directional trade, not a sandwich.
        (, uint256 afterFrontrunT1) = _bal(attacker);
        uint256 gainedT1 = afterFrontrunT1 - startT1;

        // 2. Victim trades at the degraded price, bidding nothing.
        _setPriorityFee(0);
        _swapAs(victim, k, true, -int256(victimAmt));

        // 3. Backrun: unwind the whole token1 position back into token0.
        _setPriorityFee(SEARCHER_BID_GWEI);
        _swapAs(attacker, k, false, -int256(gainedT1));

        (uint256 endT0,) = _bal(attacker);
        pnl0 = int256(endT0) - int256(startT0);
    }

    // -------------------------------------------------------------------------

    /// @notice Control group: the sandwich must actually work on an unprotected pool.
    function test_sandwichIsProfitableOnVanillaPool() public {
        int256 pnl = this.runSandwich(vanillaKey, 5e18, 10e18);
        emit log_named_decimal_int("vanilla pool  | attacker PnL (token0)", pnl, 18);
        assertGt(pnl, 0, "control group: sandwich must be profitable, or the test proves nothing");
    }

    /// @notice The same attack against Aegis, with the breaker wide enough that the frontrun
    ///         still executes. The MEV tax alone should erase the edge.
    function test_mevTaxAloneErasesSandwichProfit() public {
        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.maxTickDeviation = 20_000; // breaker effectively disabled: isolate the tax
        hook.configurePool(aegisKey, cfg);

        int256 pnl = this.runSandwich(aegisKey, 5e18, 10e18);
        emit log_named_decimal_int("aegis (tax only) | attacker PnL (token0)", pnl, 18);
        assertLt(pnl, 0, "the searcher's own priority-fee bid should price the attack out");
    }

    /// @notice The two defenses cover different regimes, and this is where the breaker earns
    ///         its place. At ordinary sandwich sizes the frontrun stays inside the tick bound and
    ///         the breaker correctly lets it through — the MEV tax is what makes it unprofitable.
    ///         The breaker exists for the move the tax cannot price: a frontrun large enough to
    ///         be an attack on the pool itself rather than on one victim.
    function test_breakerBlocksLargeFrontrun() public {
        // ~20x the ordinary sandwich size: this pushes the tick past the per-block bound.
        vm.expectRevert();
        this.runSandwich(aegisKey, 100e18, 10e18);
    }

    /// @notice The same oversized frontrun is accepted by an unprotected pool. Nothing in v4
    ///         itself bounds how far one block may move a price.
    function test_vanillaPoolAcceptsLargeFrontrun() public {
        this.runSandwich(vanillaKey, 100e18, 10e18);
    }

    /// @notice Side-by-side benchmark, printed for the submission table.
    function test_benchmarkSandwich() public {
        int256 vanillaPnl = this.runSandwich(vanillaKey, 5e18, 10e18);

        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.maxTickDeviation = 20_000;
        hook.configurePool(aegisKey, cfg);
        int256 aegisPnl = this.runSandwich(aegisKey, 5e18, 10e18);

        emit log_string("");
        emit log_string("  sandwich | frontrun 5e18, victim 10e18, searcher bids 3 gwei");
        emit log_named_decimal_int("    vanilla pool   attacker PnL", vanillaPnl, 18);
        emit log_named_decimal_int("    aegis pool     attacker PnL", aegisPnl, 18);
        emit log_string("");

        assertGt(vanillaPnl, 0);
        assertLt(aegisPnl, 0);
    }
}

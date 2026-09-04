// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AegisFixture} from "../utils/AegisFixture.sol";
import {AegisHook} from "../../src/AegisHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Attack lab — just-in-time liquidity.
///
/// A JIT bot watches for a large pending swap and supplies an enormous concentrated position
/// immediately before it, purely to collect that swap's fee, then withdraws in the same block.
/// Because its position dwarfs the passive book, it takes almost the entire fee while carrying
/// essentially none of the risk that fee is supposed to compensate — it is exposed for one block,
/// at a price it already knows.
///
/// The loss lands on the passive LPs who were there before the swap and will still be there
/// after it. Nothing is stolen in the ordinary sense; the fee is simply redirected.
///
/// Aegis answers this with a minimum position age. Liquidity that will not stay cannot leave,
/// which forces a would-be JIT bot to hold real price risk — exactly what a passive LP holds.
contract JitLiquidityTest is AegisFixture {
    address internal jitBot = address(0xB07);
    address internal whale = address(0xF00D);

    /// @dev Tight band around the starting tick: the whole point of JIT is concentration.
    int24 internal constant JIT_LOWER = -600;
    int24 internal constant JIT_UPPER = 600;
    int256 internal constant JIT_SIZE = 50_000e18;
    uint256 internal constant WHALE_SWAP = 5e18;

    function setUp() public {
        _deployAegis();
        _fundActor(jitBot, 5_000_000e18);
        _fundActor(whale, 1_000_000e18);
    }

    function _jitParams(int256 delta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: JIT_LOWER,
            tickUpper: JIT_UPPER,
            liquidityDelta: delta,
            salt: bytes32(uint256(1))
        });
    }

    /// @dev Public so `vm.expectRevert` can target it as a genuine external call.
    function runJit(PoolKey memory k) public returns (int256 pnl) {
        uint256 before = _portfolio(jitBot);

        _modifyAs(jitBot, k, _jitParams(JIT_SIZE));   // 1. supply, moments before the swap
        _swapAs(whale, k, true, -int256(WHALE_SWAP)); // 2. the swap the bot came for
        _modifyAs(jitBot, k, _jitParams(-JIT_SIZE));  // 3. withdraw, same block

        pnl = int256(_portfolio(jitBot)) - int256(before);
    }

    // -------------------------------------------------------------------------

    /// @notice Control group: JIT must actually pay on an unprotected pool.
    function test_jitIsProfitableOnVanillaPool() public {
        _setPriorityFee(0);
        int256 pnl = this.runJit(vanillaKey);
        emit log_named_decimal_int("vanilla pool | JIT bot PnL", pnl, 18);
        assertGt(pnl, 0, "control group: JIT must be profitable, or the test proves nothing");
    }

    /// @notice With a minimum position age, the withdrawal leg cannot execute at all.
    function test_minimumPositionAgeBlocksTheExit() public {
        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.minPositionAgeBlocks = 5;
        hook.configurePool(aegisKey, cfg);

        _setPriorityFee(0);
        vm.expectRevert();
        this.runJit(aegisKey);
    }

    /// @notice The lockup is a delay, not a trap: once the position has carried real price risk
    ///         for the required window it exits normally. An LP is inconvenienced; a JIT bot
    ///         loses the entire premise of the strategy.
    function test_honestLiquidityStillExitsAfterTheWindow() public {
        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.minPositionAgeBlocks = 5;
        hook.configurePool(aegisKey, cfg);
        _setPriorityFee(0);

        _modifyAs(jitBot, aegisKey, _jitParams(JIT_SIZE));
        _swapAs(whale, aegisKey, true, -int256(WHALE_SWAP));

        vm.roll(block.number + 5);
        _modifyAs(jitBot, aegisKey, _jitParams(-JIT_SIZE));
    }

    /// @notice Side-by-side benchmark for the submission table.
    function test_benchmarkJit() public {
        _setPriorityFee(0);
        int256 vanillaPnl = this.runJit(vanillaKey);

        AegisHook.PoolConfig memory cfg = _defaultConfig();
        cfg.minPositionAgeBlocks = 5;
        hook.configurePool(aegisKey, cfg);

        emit log_string("");
        emit log_string("  JIT liquidity | 50000e18 supplied for one block around a 5e18 swap");
        emit log_named_decimal_int("    vanilla pool   JIT bot PnL", vanillaPnl, 18);
        emit log_string("    aegis pool     JIT bot PnL   n/a - withdrawal reverts");
        emit log_string("");

        vm.expectRevert();
        this.runJit(aegisKey);
    }
}

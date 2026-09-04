// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AegisHook} from "../../src/AegisHook.sol";
import {AegisDeploy} from "../../script/AegisDeploy.sol";

/// @notice Fork test against the *real* Uniswap v4 deployment on Unichain Sepolia.
///
/// The local suite runs against a PoolManager compiled from this repo's pinned v4-core submodule.
/// The chain runs whatever Uniswap actually deployed, which may not be the same revision. Every
/// assumption the hook makes about v4 — that a dynamic-fee pool accepts an `OVERRIDE_FEE_FLAG`
/// from `beforeSwap`, that a revert in `afterSwap` unwinds the swap, that permission bits are
/// read from the address the way `HookMiner` computes it — is only really verified here.
///
/// This is the test that fails cheaply now instead of expensively on deploy day.
///
/// Run: forge test --match-path 'test/fork/*' -vv
/// Skips itself when the RPC is unreachable, so CI without network access stays green.
contract UnichainSepoliaForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Verified to have code on chain 1301 before being written down here.
    IPoolManager constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant TICK_SPACING = 60;

    bool internal forked;
    AegisHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("unichain_sepolia")) {
            forked = true;
        } catch {
            forked = false;
            return;
        }

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        MockERC20 a = new MockERC20("Aegis Test A", "AEGA", 18);
        MockERC20 b = new MockERC20("Aegis Test B", "AEGB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);

        t0.mint(address(this), 1_000_000e18);
        t1.mint(address(this), 1_000_000e18);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);

        (hook,) = AegisDeploy.deploy(POOL_MANAGER, address(this));

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        hook.configurePool(key, _config());

        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1000e18, salt: 0}),
            ""
        );
    }

    function _config() internal pure returns (AegisHook.PoolConfig memory) {
        return AegisHook.PoolConfig({
            baseFee: 3000,
            maxFee: 50_000,
            mevTaxPerGwei: 10_000,
            maxTickDeviation: 500,
            cooldownBlocks: 100,
            minPositionAgeBlocks: 0,
            maxVolumePerBlock: type(uint128).max,
            configured: true
        });
    }

    modifier onlyForked() {
        if (!forked) {
            console2.log("SKIP: unichain_sepolia RPC unreachable");
            vm.skip(true);
        }
        _;
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // -------------------------------------------------------------------------

    function test_realPoolManagerHasCode() public onlyForked {
        assertEq(block.chainid, 1301, "must be forked onto Unichain Sepolia");
        assertGt(address(POOL_MANAGER).code.length, 0, "PoolManager address must not be empty");
    }

    /// @notice The live PoolManager accepted a hook mined by our own deploy library — meaning its
    ///         permission-bit validation agrees with `HookMiner`'s address derivation.
    function test_liveManagerAcceptsOurMinedHook() public onlyForked {
        assertEq(uint160(address(hook)) & 0x3FFF, AegisDeploy.FLAGS, "flags must survive onchain");
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "pool must be initialized on the live manager");
    }

    /// @notice The core mechanism, against the real deployed v4: a dynamic-fee pool honours a
    ///         per-swap fee override returned from `beforeSwap`.
    function test_mevTaxAppliesOnLiveV4() public onlyForked {
        vm.fee(1 gwei);
        vm.txGasPrice(3 gwei); // 2 gwei priority bid

        _swap(true, -1e15);

        assertEq(hook.mevTaxUnitsCollected(id), 20_000, "live v4 must honour the fee override");
    }

    /// @notice The other half: a revert from `afterSwap` really does unwind the swap on live v4.
    function test_breakerRevertsOnLiveV4() public onlyForked {
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);

        _swap(true, -1e15); // establishes the block checkpoint

        (uint160 priceBefore,,,) = POOL_MANAGER.getSlot0(id);
        vm.expectRevert();
        _swap(true, -400e18);

        (uint160 priceAfter,,,) = POOL_MANAGER.getSlot0(id);
        assertEq(priceAfter, priceBefore, "a reverted swap must leave no trace");
    }
}

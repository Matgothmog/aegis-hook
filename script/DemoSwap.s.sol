// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AegisHook} from "../src/AegisHook.sol";

/// @notice Swap against the live Aegis pool. The fee charged depends on the priority fee this
///         transaction bids, so running it twice at different bids demonstrates the MEV tax
///         onchain rather than in a test harness.
///
///   forge script script/DemoSwap.s.sol --rpc-url unichain_sepolia --broadcast \
///     --account aegis-deployer --password aegis-testnet-only \
///     --priority-gas-price 2gwei --with-gas-price 3gwei
///
/// `tx.gasprice` settles to `min(maxFee, baseFee + maxPriorityFee)`, so the hook sees a priority
/// fee of very nearly the `--priority-gas-price` value and taxes accordingly.
contract DemoSwap is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev Chain-dependent: Unichain's demo pool uses 60, Arc's stablecoin pool uses 10.
    int24 constant DEFAULT_TICK_SPACING = 60;

    function run() external {
        AegisHook hook = AegisHook(vm.envAddress("HOOK"));
        PoolSwapTest swapRouter = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
        int256 amount = vm.envOr("AMOUNT", int256(1e15));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("TOKEN0")),
            currency1: Currency.wrap(vm.envAddress("TOKEN1")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(uint24(DEFAULT_TICK_SPACING))))),
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        console2.log("priority fee (wei)", hook.priorityFee());
        console2.log("fee that would be charged", hook.quoteFee(key));
        console2.log("tax units before", hook.mevTaxUnitsCollected(id));

        vm.startBroadcast();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
    }
}

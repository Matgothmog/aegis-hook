// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {AegisHook} from "../src/AegisHook.sol";

/// @notice Apply a calibrated `maxTickDeviation` to a live pool.
///
/// The value is not invented here. `watchtower/calibrate.mjs` replays the hook's own checkpoint
/// logic over a real pool's swap history and reports the distribution of honest intra-block
/// excursions; this writes the resulting bound onchain.
///
/// Note the pool being retuned is on a testnet with almost no flow, so it cannot be calibrated
/// from its own history — the engine correctly refuses to recommend anything for it. The value
/// applied here comes from the busiest live v4 pools on Unichain *mainnet*, whose worst observed
/// honest excursion was 39 ticks. Saying so matters: a number derived from one pool and applied
/// to another is a judgement call, not a measurement, and should be labelled as one.
///
///   TICK_DEVIATION=200 forge script script/Retune.s.sol --rpc-url unichain_sepolia \
///     --broadcast --account aegis-deployer --password aegis-testnet-only
contract Retune is Script {
    using PoolIdLibrary for PoolKey;

    int24 constant TICK_SPACING = 60;

    function run() external {
        AegisHook hook = AegisHook(vm.envAddress("HOOK"));
        uint24 newDeviation = uint24(vm.envUint("TICK_DEVIATION"));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("TOKEN0")),
            currency1: Currency.wrap(vm.envAddress("TOKEN1")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        // Read the live config and change exactly one field, so a retune cannot silently reset
        // the fee schedule, the tax floor or the JIT lockup as a side effect.
        AegisHook.PoolConfig memory cfg = hook.getPoolConfig(id);
        require(cfg.configured, "pool not configured");

        console2.log("pool");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("maxTickDeviation  from", uint256(cfg.maxTickDeviation));
        console2.log("                    to", uint256(newDeviation));

        cfg.maxTickDeviation = newDeviation;

        vm.startBroadcast();
        hook.configurePool(key, cfg);
        vm.stopBroadcast();
    }
}

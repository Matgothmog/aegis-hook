// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {AegisHook} from "../src/AegisHook.sol";
import {AegisDeploy} from "../script/AegisDeploy.sol";

/// @notice Deployment tests.
///
/// Every other test in this repo builds the hook with `deployCodeTo`, which *etches* bytecode at
/// an address chosen by the test. Real deployment cannot do that: v4 reads a hook's permissions
/// out of its own address, so a salt must be mined until CREATE2 lands on an address whose low
/// 14 bits already spell those permissions.
///
/// That makes address derivation the part most likely to fail, and the part every other test
/// skips entirely. These tests drive `AegisDeploy` — the same library `DeployAegis.s.sol` calls —
/// so what is verified here is what runs onchain.
contract DeployTest is Test, Deployers {
    address internal guardian = address(0x6A6D);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
    }

    function test_create2FactoryIsAvailable() public view {
        // The deterministic proxy sits at the same address on every EVM chain. If it were missing
        // the library would revert with a clear error rather than an opaque CREATE2 failure.
        assertGt(AegisDeploy.CREATE2_FACTORY.code.length, 0, "CREATE2 proxy must exist");
    }

    function test_minedAddressCarriesThePermissionBits() public view {
        (address predicted,) = AegisDeploy.mine(manager, guardian);
        assertEq(uint160(predicted) & 0x3FFF, AegisDeploy.FLAGS, "mined address must encode the flags");
    }

    function test_deployLandsOnThePredictedAddress() public {
        (address predicted, bytes32 predictedSalt) = AegisDeploy.mine(manager, guardian);
        (AegisHook hook, bytes32 salt) = AegisDeploy.deploy(manager, guardian);

        assertEq(address(hook), predicted, "deployed address must match the prediction");
        assertEq(salt, predictedSalt, "salt must be reproducible");
        assertGt(address(hook).code.length, 0, "hook must have code");
    }

    /// @notice The flags the deploy library mines for must equal what the contract itself claims.
    ///         If these ever drift, v4 silently stops calling half the hook.
    function test_minedFlagsMatchTheContractsOwnPermissions() public {
        (AegisHook hook,) = AegisDeploy.deploy(manager, guardian);

        uint160 declared;

        // Rebuild the bitmap from getHookPermissions() and compare against the address.
        if (hook.getHookPermissions().beforeInitialize) declared |= uint160(1 << 13);
        if (hook.getHookPermissions().afterInitialize) declared |= uint160(1 << 12);
        if (hook.getHookPermissions().beforeAddLiquidity) declared |= uint160(1 << 11);
        if (hook.getHookPermissions().afterAddLiquidity) declared |= uint160(1 << 10);
        if (hook.getHookPermissions().beforeRemoveLiquidity) declared |= uint160(1 << 9);
        if (hook.getHookPermissions().afterRemoveLiquidity) declared |= uint160(1 << 8);
        if (hook.getHookPermissions().beforeSwap) declared |= uint160(1 << 7);
        if (hook.getHookPermissions().afterSwap) declared |= uint160(1 << 6);

        assertEq(declared, AegisDeploy.FLAGS, "AegisDeploy.FLAGS drifted from getHookPermissions()");
        assertEq(uint160(address(hook)) & 0x3FFF, declared, "address bits must match the claim");
    }

    /// @dev External so `vm.expectRevert` sees a depth change — `AegisDeploy` is an internal
    ///      library, so its calls inline into the caller and never cross a call boundary.
    function deployWith(address poolManager_) public returns (AegisHook hook) {
        (hook,) = AegisDeploy.deploy(IPoolManager(poolManager_), guardian);
    }

    function test_wrongPoolManagerAddressFailsLoudly() public {
        // The single most common deploy mistake is a PoolManager address copied from another
        // chain. It must not surface as an opaque CREATE2 revert.
        address empty = address(0xBADC0DE);
        vm.expectRevert(abi.encodeWithSelector(AegisDeploy.PoolManagerHasNoCode.selector, empty));
        this.deployWith(empty);
    }

    /// @notice The real gate: a hook deployed the production way is actually usable by v4.
    ///         Mining a pretty address means nothing if the PoolManager then rejects it.
    function test_deployedHookRunsAFullPoolLifecycle() public {
        (AegisHook hook,) = AegisDeploy.deploy(manager, guardian);

        (PoolKey memory key_, PoolId id) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1
        );

        vm.prank(guardian);
        hook.configurePool(
            key_,
            AegisHook.PoolConfig({
                baseFee: 3000,
                maxFee: 50_000,
                mevTaxPerGwei: 10_000,
                maxTickDeviation: 500,
                cooldownBlocks: 100,
                minPositionAgeBlocks: 0,
                maxVolumePerBlock: type(uint128).max,
                configured: true
            })
        );

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1000e18, salt: 0}),
            ZERO_BYTES
        );

        // A searcher bidding 2 gwei must be taxed by the deployed hook, not just by a test double.
        vm.fee(1 gwei);
        vm.txGasPrice(3 gwei);

        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(hook.mevTaxUnitsCollected(id), 20_000, "deployed hook must charge the MEV tax");
    }
}

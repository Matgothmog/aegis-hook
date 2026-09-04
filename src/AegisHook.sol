// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title AegisHook
/// @notice A self-defending Uniswap v4 pool: an MEV tax that prices extraction out of the
///         block, and a circuit breaker that bounds what any single block can do to the price.
///
/// @dev ## Two defenses
///
/// **1. MEV tax.** On a chain with priority-fee ordering (Unichain via Rollup-Boost), a searcher
/// who wants to win an ordering race must bid the highest priority fee. That bid is a public,
/// self-reported lower bound on the MEV they expect to capture. The hook reads it and charges
/// proportionally, so the searcher's own bid sets their fee and the surplus accrues to LPs
/// instead of the builder.
///
/// This defense is only as good as the ordering rule. On a chain with private orderflow or
/// builder-side ordering, priority fee stops being a truthful signal and the tax degrades to a
/// no-op — it never becomes *unsafe*, it just stops collecting. That assumption is stated
/// rather than hidden.
///
/// **2. Circuit breaker.** The hook checkpoints the pool tick at the first swap of each block
/// and rejects any swap that would carry the tick further than `maxTickDeviation` from that
/// checkpoint, plus a per-block volume ceiling. Ticks are used rather than sqrt-prices because
/// tick space is already logarithmic: the bound is exact, cheap, and free of overflow concerns.
///
/// ## Why reverting *is* the latch
///
/// A subtlety worth stating, because it drove the design. The natural instinct is to "trip" a
/// breaker by writing a cooldown flag to storage and blocking subsequent swaps. But the
/// deviation is only observable in `afterSwap`, and a revert there unwinds the entire
/// transaction — including the flag write. A latch set on the offending path can never persist.
///
/// So the automatic defenses do not latch. They revert, and reverting is the whole defense: the
/// offending swap simply does not happen, and there is no damage left to contain. State that
/// *does* persist is only ever written by swaps that succeed — the block checkpoint and the
/// running volume total — which is exactly the state the next swap needs to judge itself
/// against. The explicit cooldown latch is reserved for the guardian path, whose own
/// transaction succeeds and therefore can persist it.
///
/// ## Guardian authority is bounded
///
/// The guardian can halt trading and retune parameters within hard-coded bounds. It cannot move
/// funds, and the hook never takes custody of any: it returns a fee override and a zero delta,
/// never a balance delta in its own favour. The worst a fully compromised guardian achieves is
/// denial of service on the pool — griefing, not theft. Withdrawals are unaffected by a halt.
contract AegisHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // -------------------------------------------------------------------------
    // Hard bounds — the guardian cannot escape these, they are enforced on write.
    // -------------------------------------------------------------------------

    /// @notice No pool may ever charge more than 10% on a swap, whatever the priority fee.
    uint24 public constant ABSOLUTE_MAX_FEE = 100_000; // 10% in hundredths of a bip
    /// @notice A breaker may never be tighter than this, or honest flow cannot trade.
    uint24 public constant MIN_TICK_DEVIATION = 10; // ~0.1%
    /// @notice A cooldown may never exceed this, so a guardian cannot halt a pool forever.
    uint32 public constant MAX_COOLDOWN_BLOCKS = 7200;
    /// @notice Liquidity lockup may never exceed this.
    uint32 public constant MAX_POSITION_AGE_BLOCKS = 300;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Why a swap was rejected. Indexed off-chain by the watchtower subgraph.
    enum Reason {
        None,
        PriceDeviation,
        VolumeLimit,
        GuardianHalt,
        PositionTooYoung
    }

    struct PoolConfig {
        uint24 baseFee; // fee floor, in hundredths of a bip (3000 = 0.30%)
        uint24 maxFee; // ceiling after the MEV tax is added
        uint24 mevTaxPerGwei; // fee units added per 1 gwei of priority fee
        uint24 maxTickDeviation; // per-block tick bound, from the block-open checkpoint
        uint32 cooldownBlocks; // guardian halt duration
        uint32 minPositionAgeBlocks; // JIT defense: minimum liquidity lifetime
        uint128 maxVolumePerBlock; // per-block volume ceiling, in token0 units
        bool configured;
    }

    struct BlockState {
        uint64 blockNumber; // block the checkpoint belongs to
        int24 checkpointTick; // tick at the open of that block
        uint128 volumeInBlock; // cumulative token0 volume within that block
        uint64 haltedUntilBlock; // guardian latch
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public guardian;

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => BlockState) public blockState;
    /// @dev poolId => position key => block the position was last added to.
    mapping(PoolId => mapping(bytes32 => uint64)) public positionBlock;

    /// @notice Total fee units collected above the base fee, per pool. Watchtower metric.
    mapping(PoolId => uint256) public mevTaxUnitsCollected;

    // -------------------------------------------------------------------------
    // Events — the watchtower indexes exclusively from these.
    // -------------------------------------------------------------------------

    event PoolConfigured(PoolId indexed poolId, PoolConfig config);
    event BlockCheckpointed(PoolId indexed poolId, uint64 blockNumber, int24 tick);
    event MevTaxApplied(
        PoolId indexed poolId, address indexed sender, uint256 priorityFeeWei, uint24 feeCharged, uint24 taxUnits
    );
    event SwapRejected(PoolId indexed poolId, address indexed sender, Reason reason, int256 observed, int256 bound);
    event GuardianHalt(PoolId indexed poolId, uint64 untilBlock);
    event GuardianTransferred(address indexed from, address indexed to);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotGuardian();
    error PoolNotConfigured();
    error MustUseDynamicFee();
    error PriceDeviationExceeded(int24 checkpointTick, int24 observedTick, uint24 bound);
    error VolumeLimitExceeded(uint128 attempted, uint128 bound);
    error PoolHalted(uint64 untilBlock);
    error PositionTooYoung(uint64 addedAt, uint64 unlocksAt);
    error InvalidConfig();
    error ZeroAddress();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(IPoolManager _poolManager, address _guardian) BaseHook(_poolManager) {
        if (_guardian == address(0)) revert ZeroAddress();
        guardian = _guardian;
        emit GuardianTransferred(address(0), _guardian);
    }

    // -------------------------------------------------------------------------
    // Permissions
    // -------------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // enforce the pool opts into dynamic fees
            afterInitialize: false,
            beforeAddLiquidity: true, // stamp position age for the JIT defense
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // enforce minimum position age
            afterRemoveLiquidity: false,
            beforeSwap: true, // MEV tax + halt/volume checks
            afterSwap: true, // deviation check on the resulting tick
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // the hook never takes a delta — it cannot self-deal
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Set or retune a pool's defenses. Bounded by the constants above.
    function configurePool(PoolKey calldata key, PoolConfig calldata cfg) external onlyGuardian {
        if (
            cfg.baseFee > cfg.maxFee || cfg.maxFee > ABSOLUTE_MAX_FEE || cfg.maxTickDeviation < MIN_TICK_DEVIATION
                || cfg.cooldownBlocks > MAX_COOLDOWN_BLOCKS || cfg.minPositionAgeBlocks > MAX_POSITION_AGE_BLOCKS
                || cfg.maxVolumePerBlock == 0
        ) revert InvalidConfig();

        PoolId poolId = key.toId();
        PoolConfig memory stored = cfg;
        stored.configured = true;
        poolConfig[poolId] = stored;
        emit PoolConfigured(poolId, stored);
    }

    /// @notice Halt a pool for `cooldownBlocks`. Swaps revert; liquidity withdrawal is unaffected.
    function halt(PoolKey calldata key) external onlyGuardian {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        if (!cfg.configured) revert PoolNotConfigured();

        uint64 until = uint64(block.number) + cfg.cooldownBlocks;
        blockState[poolId].haltedUntilBlock = until;
        emit GuardianHalt(poolId, until);
    }

    /// @notice Clear a halt early.
    function resume(PoolKey calldata key) external onlyGuardian {
        PoolId poolId = key.toId();
        blockState[poolId].haltedUntilBlock = 0;
        emit GuardianHalt(poolId, 0);
    }

    function transferGuardian(address to) external onlyGuardian {
        if (to == address(0)) revert ZeroAddress();
        emit GuardianTransferred(guardian, to);
        guardian = to;
    }

    // -------------------------------------------------------------------------
    // Hook callbacks
    // -------------------------------------------------------------------------

    /// @dev The pool must opt into dynamic fees, otherwise the MEV tax is silently inert.
    ///      Failing closed at initialization is better than a pool that thinks it is protected.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view override onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        if (!cfg.configured) revert PoolNotConfigured();

        BlockState storage bs = blockState[poolId];

        // Guardian latch.
        if (block.number < bs.haltedUntilBlock) {
            emit SwapRejected(poolId, sender, Reason.GuardianHalt, int256(block.number), int256(uint256(bs.haltedUntilBlock)));
            revert PoolHalted(bs.haltedUntilBlock);
        }

        // First swap of a new block: checkpoint the opening tick and reset the volume window.
        // This write only lands if the swap succeeds, which is the property the breaker relies on.
        if (bs.blockNumber != uint64(block.number)) {
            (, int24 tick,,) = poolManager.getSlot0(poolId);
            bs.blockNumber = uint64(block.number);
            bs.checkpointTick = tick;
            bs.volumeInBlock = 0;
            emit BlockCheckpointed(poolId, uint64(block.number), tick);
        }

        // Per-block volume ceiling, charged on the specified amount as a cheap pre-filter.
        // The authoritative accounting happens in afterSwap against the settled delta.
        uint128 attempted = bs.volumeInBlock + _abs128(params.amountSpecified);
        if (attempted > cfg.maxVolumePerBlock) {
            emit SwapRejected(poolId, sender, Reason.VolumeLimit, int256(uint256(attempted)), int256(uint256(cfg.maxVolumePerBlock)));
            revert VolumeLimitExceeded(attempted, cfg.maxVolumePerBlock);
        }

        // MEV tax: the searcher's own priority-fee bid sets the fee they pay.
        uint24 fee = _mevTaxedFee(poolId, sender, cfg);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev The deviation bound is enforced here, on the tick the swap actually produced.
    ///      Reverting unwinds the swap entirely — see the note on latching in the contract docs.
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        BlockState storage bs = blockState[poolId];

        (, int24 tick,,) = poolManager.getSlot0(poolId);

        int24 checkpoint = bs.checkpointTick;
        uint24 moved = uint24(_absTick(tick - checkpoint));
        if (moved > cfg.maxTickDeviation) {
            emit SwapRejected(poolId, sender, Reason.PriceDeviation, int256(tick), int256(checkpoint));
            revert PriceDeviationExceeded(checkpoint, tick, cfg.maxTickDeviation);
        }

        // Settle the authoritative volume for this block from the realised delta.
        bs.volumeInBlock += _abs128(int256(delta.amount0()));

        return (BaseHook.afterSwap.selector, int128(0));
    }

    /// @dev Stamp the position's birth block so JIT liquidity can be rejected on the way out.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        positionBlock[poolId][_positionKey(sender, params)] = uint64(block.number);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev JIT defense: liquidity that has not lived `minPositionAgeBlocks` cannot leave.
    ///      A JIT attacker's whole edge is supplying liquidity for exactly one block around a
    ///      large swap; forcing it to stay exposes them to the price risk real LPs carry.
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];

        if (cfg.minPositionAgeBlocks != 0) {
            uint64 addedAt = positionBlock[poolId][_positionKey(sender, params)];
            uint64 unlocksAt = addedAt + cfg.minPositionAgeBlocks;
            if (addedAt != 0 && block.number < unlocksAt) {
                emit SwapRejected(poolId, sender, Reason.PositionTooYoung, int256(block.number), int256(uint256(unlocksAt)));
                revert PositionTooYoung(addedAt, unlocksAt);
            }
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The fee this pool would charge right now, at the caller's priority fee.
    /// @dev Lets a router quote honestly before committing to a swap.
    function quoteFee(PoolKey calldata key) external view returns (uint24) {
        PoolConfig memory cfg = poolConfig[key.toId()];
        if (!cfg.configured) revert PoolNotConfigured();
        (uint24 fee,) = _feeFor(cfg);
        return fee;
    }

    /// @notice Current priority fee bid, in wei per gas. Zero if the chain reports none.
    function priorityFee() public view returns (uint256) {
        return tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _mevTaxedFee(PoolId poolId, address sender, PoolConfig memory cfg) internal returns (uint24 fee) {
        uint256 pf;
        uint24 taxUnits;
        (fee, taxUnits) = _feeFor(cfg);
        pf = priorityFee();

        if (taxUnits != 0) {
            mevTaxUnitsCollected[poolId] += taxUnits;
            emit MevTaxApplied(poolId, sender, pf, fee, taxUnits);
        }
    }

    /// @dev fee = baseFee + min(priorityFee_in_gwei * mevTaxPerGwei, maxFee - baseFee)
    function _feeFor(PoolConfig memory cfg) internal view returns (uint24 fee, uint24 taxUnits) {
        uint256 pf = priorityFee();
        uint256 headroom = cfg.maxFee - cfg.baseFee;
        // Integer division by 1 gwei: sub-gwei bids contribute nothing, which is the intent —
        // ordinary users on a fast L2 do not need to bid, and should not be taxed.
        uint256 tax = (pf * cfg.mevTaxPerGwei) / 1 gwei;
        if (tax > headroom) tax = headroom;
        taxUnits = uint24(tax);
        fee = cfg.baseFee + taxUnits;
    }

    /// @dev Deliberately the same tuple and encoding as v4-core's own
    ///      `Position.calculatePositionKey(owner, tickLower, tickUpper, salt)`, so the hook's
    ///      notion of position identity is exactly the protocol's rather than a parallel one.
    ///
    ///      `owner` here is whoever called `modifyLiquidity` — under v4 that is the router, not
    ///      the end user. That is not a flaw in this key, it is how v4 itself identifies
    ///      positions: uniqueness between users of one router comes from `salt`, which
    ///      PositionManager derives from the position's NFT id. A router that reuses salts
    ///      across users would collide here exactly as it would collide in v4-core.
    function _positionKey(address owner, ModifyLiquidityParams calldata params) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, params.tickLower, params.tickUpper, params.salt));
    }

    function _abs128(int256 x) internal pure returns (uint128) {
        uint256 v = x < 0 ? uint256(-x) : uint256(x);
        return v > type(uint128).max ? type(uint128).max : uint128(v);
    }

    function _absTick(int24 x) internal pure returns (int24) {
        return x < 0 ? -x : x;
    }
}

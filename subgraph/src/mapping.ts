import { BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  PoolConfigured,
  BlockCheckpointed,
  MevTaxApplied,
  OracleUnavailable,
  OracleConfigured,
  GuardianHalt,
} from "../generated/AegisHook/AegisHook";
import { Pool, MevTax, OracleSkipped, BlockCheckpoint, PoolDayData } from "../generated/schema";

const SECONDS_PER_DAY = 86400;

// Mirrors OracleReference.Status. Kept as strings so a consumer never has to carry the enum
// ordering; the agent layer and any dashboard read these directly.
function statusName(code: i32): string {
  if (code == 1) return "NotConfigured";
  if (code == 2) return "StaleAnswer";
  if (code == 3) return "InvalidAnswer";
  if (code == 4) return "OutOfRange";
  if (code == 5) return "BadConfig";
  return "Ok";
}

function abs32(x: i32): i32 {
  return x < 0 ? -x : x;
}

function loadOrCreatePool(poolId: Bytes, hook: Bytes): Pool {
  let pool = Pool.load(poolId);
  if (pool != null) return pool;

  pool = new Pool(poolId);
  pool.hook = hook;
  pool.baseFee = 0;
  pool.maxFee = 0;
  pool.mevTaxPerGwei = 0;
  pool.mevTaxFloorGwei = 0;
  pool.maxTickDeviation = 0;
  pool.cooldownBlocks = 0;
  pool.minPositionAgeBlocks = 0;
  pool.maxVolumePerBlock = BigInt.zero();
  pool.configuredAtBlock = BigInt.zero();
  pool.reconfigurations = 0;
  pool.totalTaxUnits = BigInt.zero();
  pool.totalTaxedSwaps = 0;
  pool.totalPriorityFeeWei = BigInt.zero();
  pool.oracleSkips = 0;
  pool.oracleFeed = Bytes.empty();
  pool.oracleMaxTickDeviation = 0;
  pool.haltedUntilBlock = BigInt.zero();
  pool.lastTick = 0;
  pool.lastCheckpointBlock = BigInt.zero();
  pool.maxObservedTickDelta = 0;
  pool.save();
  return pool;
}

function loadOrCreateDay(pool: Pool, timestamp: BigInt): PoolDayData {
  let date = timestamp.toI32() / SECONDS_PER_DAY;
  let id = pool.id.concatI32(date);
  let day = PoolDayData.load(id);
  if (day != null) return day;

  day = new PoolDayData(id);
  day.pool = pool.id;
  day.date = date * SECONDS_PER_DAY;
  day.taxUnits = BigInt.zero();
  day.taxedSwaps = 0;
  day.oracleSkips = 0;
  day.maxAbsTickDelta = 0;
  day.checkpoints = 0;
  return day;
}

function eventId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32());
}

export function handlePoolConfigured(event: PoolConfigured): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);

  let cfg = event.params.config;
  pool.baseFee = cfg.baseFee;
  pool.maxFee = cfg.maxFee;
  pool.mevTaxPerGwei = cfg.mevTaxPerGwei;
  pool.mevTaxFloorGwei = cfg.mevTaxFloorGwei;
  pool.maxTickDeviation = cfg.maxTickDeviation;
  // uint32 codegens to BigInt. Narrowing to i32 is safe here and not merely convenient: the
  // hook caps these at MAX_COOLDOWN_BLOCKS (7200) and MAX_POSITION_AGE_BLOCKS (300) on every
  // config write, so neither can approach i32 range.
  pool.cooldownBlocks = cfg.cooldownBlocks.toI32();
  pool.minPositionAgeBlocks = cfg.minPositionAgeBlocks.toI32();
  pool.maxVolumePerBlock = cfg.maxVolumePerBlock;

  if (pool.configuredAtBlock.equals(BigInt.zero())) {
    pool.configuredAtBlock = event.block.number;
  } else {
    // Retunings are worth counting: a pool whose bound keeps being widened is telling you the
    // original calibration was wrong.
    pool.reconfigurations = pool.reconfigurations + 1;
  }
  pool.save();
}

export function handleBlockCheckpointed(event: BlockCheckpointed): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);

  let tick = event.params.tick;
  let isFirst = pool.lastCheckpointBlock.equals(BigInt.zero());

  // The first checkpoint has no predecessor, so it has no movement to report. Recording a delta
  // against a zero default would inject a spurious outlier straight into the calibration data.
  let delta = isFirst ? 0 : tick - pool.lastTick;
  let absDelta = abs32(delta);

  let checkpoint = new BlockCheckpoint(eventId(event));
  checkpoint.pool = pool.id;
  checkpoint.blockNumber = event.block.number;
  checkpoint.tick = tick;
  checkpoint.tickDelta = delta;
  checkpoint.absTickDelta = absDelta;
  checkpoint.blocksSincePrevious = isFirst
    ? BigInt.zero()
    : event.block.number.minus(pool.lastCheckpointBlock);
  checkpoint.timestamp = event.block.timestamp;
  checkpoint.save();

  if (absDelta > pool.maxObservedTickDelta) pool.maxObservedTickDelta = absDelta;
  pool.lastTick = tick;
  pool.lastCheckpointBlock = event.block.number;
  pool.save();

  let day = loadOrCreateDay(pool, event.block.timestamp);
  day.checkpoints = day.checkpoints + 1;
  if (absDelta > day.maxAbsTickDelta) day.maxAbsTickDelta = absDelta;
  day.save();
}

export function handleMevTaxApplied(event: MevTaxApplied): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);

  let tax = new MevTax(eventId(event));
  tax.pool = pool.id;
  tax.sender = event.params.sender;
  tax.priorityFeeWei = event.params.priorityFeeWei;
  tax.feeCharged = event.params.feeCharged;
  tax.taxUnits = event.params.taxUnits;
  tax.blockNumber = event.block.number;
  tax.timestamp = event.block.timestamp;
  tax.txHash = event.transaction.hash;
  tax.save();

  pool.totalTaxUnits = pool.totalTaxUnits.plus(BigInt.fromI32(event.params.taxUnits));
  pool.totalTaxedSwaps = pool.totalTaxedSwaps + 1;
  pool.totalPriorityFeeWei = pool.totalPriorityFeeWei.plus(event.params.priorityFeeWei);
  pool.save();

  let day = loadOrCreateDay(pool, event.block.timestamp);
  day.taxUnits = day.taxUnits.plus(BigInt.fromI32(event.params.taxUnits));
  day.taxedSwaps = day.taxedSwaps + 1;
  day.save();
}

export function handleOracleUnavailable(event: OracleUnavailable): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);

  let skip = new OracleSkipped(eventId(event));
  skip.pool = pool.id;
  skip.reason = statusName(event.params.status);
  skip.blockNumber = event.block.number;
  skip.timestamp = event.block.timestamp;
  skip.txHash = event.transaction.hash;
  skip.save();

  pool.oracleSkips = pool.oracleSkips + 1;
  pool.save();

  let day = loadOrCreateDay(pool, event.block.timestamp);
  day.oracleSkips = day.oracleSkips + 1;
  day.save();
}

export function handleOracleConfigured(event: OracleConfigured): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);
  pool.oracleFeed = event.params.feed;
  pool.oracleMaxTickDeviation = event.params.maxTickDeviation;
  pool.save();
}

export function handleGuardianHalt(event: GuardianHalt): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);
  pool.haltedUntilBlock = event.params.untilBlock; // uint64 already codegens to BigInt
  pool.save();
}

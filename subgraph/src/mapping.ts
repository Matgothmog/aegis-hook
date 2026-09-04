import { BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  PoolConfigured,
  BlockCheckpointed,
  MevTaxApplied,
  SwapRejected,
  GuardianHalt,
} from "../generated/AegisHook/AegisHook";
import { Pool, MevTax, Rejection, BlockCheckpoint, PoolDayData } from "../generated/schema";

const SECONDS_PER_DAY = 86400;

// Mirrors AegisHook.Reason. Kept as strings in the schema so a consumer never has to carry the
// enum ordering; the agent layer and any dashboard read these directly.
function reasonName(code: i32): string {
  if (code == 1) return "PriceDeviation";
  if (code == 2) return "VolumeLimit";
  if (code == 3) return "GuardianHalt";
  if (code == 4) return "PositionTooYoung";
  return "None";
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
  pool.totalRejections = 0;
  pool.rejectionsByDeviation = 0;
  pool.rejectionsByVolume = 0;
  pool.rejectionsByHalt = 0;
  pool.rejectionsByPositionAge = 0;
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
  day.rejections = 0;
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

export function handleSwapRejected(event: SwapRejected): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);

  let rejection = new Rejection(eventId(event));
  rejection.pool = pool.id;
  rejection.sender = event.params.sender;
  rejection.reason = reasonName(event.params.reason);
  rejection.observed = event.params.observed;
  rejection.bound = event.params.bound;
  rejection.blockNumber = event.block.number;
  rejection.timestamp = event.block.timestamp;
  rejection.txHash = event.transaction.hash;
  rejection.save();

  pool.totalRejections = pool.totalRejections + 1;
  let code = event.params.reason;
  if (code == 1) pool.rejectionsByDeviation = pool.rejectionsByDeviation + 1;
  else if (code == 2) pool.rejectionsByVolume = pool.rejectionsByVolume + 1;
  else if (code == 3) pool.rejectionsByHalt = pool.rejectionsByHalt + 1;
  else if (code == 4) pool.rejectionsByPositionAge = pool.rejectionsByPositionAge + 1;
  pool.save();

  let day = loadOrCreateDay(pool, event.block.timestamp);
  day.rejections = day.rejections + 1;
  day.save();
}

export function handleGuardianHalt(event: GuardianHalt): void {
  let pool = loadOrCreatePool(event.params.poolId, event.address);
  pool.haltedUntilBlock = event.params.untilBlock; // uint64 already codegens to BigInt
  pool.save();
}

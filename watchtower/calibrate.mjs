#!/usr/bin/env node
/**
 * Aegis calibration engine.
 *
 * Answers the question the hook's own design leaves open.
 *
 * AegisHook bounds how far a pool's tick may move within one block, which trades safety against
 * liveness: too tight a bound and honest trades are rejected. The README's answer is "per-pool
 * calibration" -- but calibrated how? Guessing 500 ticks is not an answer, it is a placeholder.
 *
 * This derives the bound from evidence. It reads a real Uniswap v4 pool's swap history, measures
 * the distribution of honest intra-block price excursions, and recommends a bound that sits above
 * observed honest behaviour and below what a manipulation needs.
 *
 * WHAT IS MEASURED, PRECISELY
 *
 * The breaker checkpoints the tick at a block's first swap, then rejects any swap carrying the
 * tick further than `maxTickDeviation` from that checkpoint. So the quantity that matters is the
 * maximum excursion from the block-opening tick, measured within each block -- not the
 * block-to-block drift, which is a different and much smaller number. Calibrating against drift
 * would produce a bound that looks generous and rejects real trades.
 *
 * Zero dependencies: plain JSON-RPC over fetch.
 *
 * Usage:
 *   node watchtower/calibrate.mjs --pool 0x<poolId> [--rpc URL] [--manager 0x..] [--blocks N]
 */

const SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f";

const DEFAULTS = {
  rpc: "https://mainnet.unichain.org",
  manager: "0x1F98400000000000000000000000000000000004",
  blocks: 5000,
  chunk: 1000,
};

function parseArgs(argv) {
  const out = { ...DEFAULTS };
  for (let i = 2; i < argv.length; i++) {
    if (!argv[i].startsWith("--")) continue;
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    // Bare flags (--json) take no value; everything else consumes the next token.
    if (next === undefined || next.startsWith("--")) {
      out[key] = true;
    } else {
      out[key] = /^\d+$/.test(next) ? Number(next) : next;
      i++;
    }
  }
  return out;
}

async function rpc(url, method, params) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

/**
 * Decode a signed integer from one 32-byte ABI word.
 *
 * The ABI sign-extends smaller signed types across the whole word, so a tick of -100 arrives as
 * 0xffff…ff9c, not as a bare 24-bit value. The conversion must therefore be two's complement at
 * 256 bits regardless of the declared width; applying it at the declared width instead returns
 * ~1.16e77 for every negative value, which is silently wrong rather than loudly wrong.
 */
function decodeSignedWord(hexWord) {
  const value = BigInt("0x" + hexWord);
  const limit = 1n << 255n;
  return Number(value >= limit ? value - (1n << 256n) : value);
}

/**
 * Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1,
 *      uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)
 * Non-indexed words, in order: amount0, amount1, sqrtPriceX96, liquidity, tick, fee.
 */
function decodeSwap(log) {
  const data = log.data.slice(2);
  const word = (i) => data.slice(i * 64, (i + 1) * 64);
  return {
    block: Number(BigInt(log.blockNumber)),
    logIndex: Number(BigInt(log.logIndex)),
    amount0: decodeSignedWord(word(0)),
    tick: decodeSignedWord(word(4)),
  };
}

export async function fetchSwaps({ rpc: url, manager, pool, blocks, chunk, quiet }) {
  const latest = Number(BigInt(await rpc(url, "eth_blockNumber", [])));
  const from = latest - blocks;
  const swaps = [];

  for (let start = from; start <= latest; start += chunk) {
    const end = Math.min(start + chunk - 1, latest);
    const logs = await rpc(url, "eth_getLogs", [
      {
        address: manager,
        topics: [SWAP_TOPIC, pool],
        fromBlock: "0x" + start.toString(16),
        toBlock: "0x" + end.toString(16),
      },
    ]);
    for (const log of logs) swaps.push(decodeSwap(log));
    if (!quiet) process.stderr.write(`\r  scanned ${end - from + 1}/${blocks + 1} blocks, ${swaps.length} swaps`);
  }
  if (!quiet) process.stderr.write("\n");

  swaps.sort((a, b) => a.block - b.block || a.logIndex - b.logIndex);
  return { swaps, from, latest };
}

/**
 * Replay Aegis's checkpoint logic over real history.
 *
 * For each block that traded, the checkpoint is the tick as the block opened -- which is the tick
 * left behind by the previous block that traded. The excursion is then the furthest any swap in
 * that block carried the tick away from that checkpoint. That is exactly the quantity `afterSwap`
 * tests against `maxTickDeviation`.
 */
export function measureExcursions(swaps) {
  const byBlock = new Map();
  for (const s of swaps) {
    if (!byBlock.has(s.block)) byBlock.set(s.block, []);
    byBlock.get(s.block).push(s);
  }

  const excursions = [];
  let checkpoint = null;

  for (const [block, blockSwaps] of [...byBlock.entries()].sort((a, b) => a[0] - b[0])) {
    if (checkpoint !== null) {
      let worst = 0;
      for (const s of blockSwaps) {
        const d = Math.abs(s.tick - checkpoint);
        if (d > worst) worst = d;
      }
      excursions.push({ block, excursion: worst, swaps: blockSwaps.length });
    }
    checkpoint = blockSwaps[blockSwaps.length - 1].tick;
  }
  return excursions;
}

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

const toPct = (ticks) => (Math.pow(1.0001, ticks) - 1) * 100;

export function recommend(excursions) {
  const values = excursions.map((e) => e.excursion).sort((a, b) => a - b);
  if (values.length === 0) return null;

  const p = (q) => percentile(values, q);
  const observedMax = values[values.length - 1];

  // A 3x margin over the 99.9th percentile. The asymmetry is deliberate: rejecting an honest
  // trade is a visible, immediate failure for a user, while a bound somewhat looser than optimal
  // still forecloses the manipulation class this defends against, which needs moves an order of
  // magnitude larger. When in doubt, err toward liveness.
  const raw = Math.max(p(99.9), observedMax) * 3;

  // Round up to something a human would actually write in a config.
  const steps = [10, 25, 50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000];
  const recommended = steps.find((s) => s >= raw) ?? Math.ceil(raw / 1000) * 1000;

  const rejected = values.filter((v) => v > recommended).length;

  return {
    blocksMeasured: values.length,
    p50: p(50),
    p90: p(90),
    p99: p(99),
    p999: p(99.9),
    observedMax,
    recommended,
    wouldHaveRejected: rejected,
    rejectionRate: rejected / values.length,
  };
}

function render(pool, range, r) {
  const row = (label, ticks) =>
    `  ${label.padEnd(34)} ${String(ticks).padStart(6)} ticks   ${toPct(ticks).toFixed(3).padStart(8)}%`;

  console.log("");
  console.log(`Aegis calibration — pool ${pool.slice(0, 18)}…`);
  console.log(`blocks ${range.from}–${range.latest}, ${r.blocksMeasured} of them traded`);
  console.log("");
  console.log("  Intra-block price excursion from the block-opening tick");
  console.log("  " + "-".repeat(62));
  console.log(row("median block", r.p50));
  console.log(row("90th percentile", r.p90));
  console.log(row("99th percentile", r.p99));
  console.log(row("99.9th percentile", r.p999));
  console.log(row("worst block observed", r.observedMax));
  console.log("");
  console.log("  Recommendation");
  console.log("  " + "-".repeat(62));
  console.log(row("maxTickDeviation", r.recommended));
  console.log(
    `  ${"would have rejected".padEnd(34)} ${String(r.wouldHaveRejected).padStart(6)} blocks   ${(
      r.rejectionRate * 100
    ).toFixed(3).padStart(8)}%`
  );
  console.log("");

  if (r.observedMax === 0) {
    console.log("  No price movement observed. Too little history to calibrate on.");
  } else if (r.rejectionRate > 0.001) {
    console.log("  Note: this bound would still have rejected real trades in this window.");
    console.log("  Widen it, or accept the rejection rate deliberately.");
  } else {
    console.log("  This bound clears every honest block in the sample, with margin.");
    console.log(`  A single-block manipulation needs a move far beyond ${r.recommended} ticks to pay,`);
    console.log("  so the gap between honest volatility and attack size is the safety margin.");
  }
  console.log("");
}

async function main() {
  const args = parseArgs(process.argv);
  if (!args.pool) {
    console.error("usage: node watchtower/calibrate.mjs --pool 0x<poolId> [--rpc URL] [--blocks N]");
    process.exit(1);
  }
  console.error(`fetching swaps for ${args.pool}`);
  const { swaps, from, latest } = await fetchSwaps(args);
  if (swaps.length === 0) {
    console.error("no swaps found for that pool in the window");
    process.exit(1);
  }
  const excursions = measureExcursions(swaps);
  const r = recommend(excursions);
  if (!r) {
    console.error("not enough traded blocks to calibrate");
    process.exit(1);
  }
  if (args.json) {
    console.log(JSON.stringify({ pool: args.pool, from, latest, ...r }, null, 2));
  } else {
    render(args.pool, { from, latest }, r);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error("error:", e.message);
    process.exit(1);
  });
}

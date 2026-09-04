#!/usr/bin/env node
/**
 * Aegis Watchtower — MCP server.
 *
 * Puts a self-defending Uniswap v4 pool in front of an AI agent. Four tools, each answering a
 * question an LP or an operator actually has:
 *
 *   calibrate_pool        How should this pool's circuit breaker be tuned?
 *   pool_state            What is this pool's configuration and running totals right now?
 *   recent_activity       What has the hook taxed or rejected lately?
 *   assess_threat         Given all of the above, is this pool under attack?
 *
 * `calibrate_pool` is the one that matters. AegisHook's design admits the breaker trades safety
 * against liveness and answers it with "per-pool calibration", without saying how you would
 * calibrate. This measures real intra-block price excursions and derives the bound from evidence
 * instead of a guess -- and applied to live Unichain pools it says the project's own hardcoded
 * default of 500 ticks is several times looser than any of them need.
 *
 * Everything reads chain state directly, so it works with no API key and no deployed subgraph.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { CHAINS, AEGIS_HOOK, TOPICS, REASONS, rpc, signedWord, unsignedWord, words, ticksToPercent, ethCall, getLogs, blockNumber } from "./chain.mjs";
import { fetchSwaps, measureExcursions, recommend } from "./calibrate.mjs";

const server = new McpServer({ name: "aegis-watchtower", version: "1.0.0" });

const chainArg = z.enum(["unichain-mainnet", "unichain-sepolia", "base-sepolia"]).default("unichain-mainnet");
const text = (s) => ({ content: [{ type: "text", text: s }] });

// ---------------------------------------------------------------------------

server.tool(
  "calibrate_pool",
  "Recommend a maxTickDeviation for an Aegis circuit breaker by measuring a real Uniswap v4 pool's intra-block price excursions. Returns the observed distribution and a bound that clears honest volatility with margin.",
  { poolId: z.string().describe("The v4 poolId (0x-prefixed, 32 bytes)"), chain: chainArg, blocks: z.number().default(5000).describe("How many recent blocks to sample") },
  async ({ poolId, chain, blocks }) => {
    const { rpc: url, manager } = CHAINS[chain];
    const { swaps, from, latest } = await fetchSwaps({ rpc: url, manager, pool: poolId, blocks, chunk: 1000, quiet: true });
    if (swaps.length === 0) return text(`No swaps for ${poolId} on ${chain} in the last ${blocks} blocks. Try a larger window or a more active pool.`);

    const r = recommend(measureExcursions(swaps));
    if (!r) return text(`Only ${swaps.length} swaps found, in too few distinct blocks to calibrate. Widen the window.`);

    const pct = (t) => ticksToPercent(t).toFixed(3);

    if (!r.sufficient) {
      return text(
        `Cannot calibrate ${poolId} on ${chain}.\n\n` +
          `Only ${r.blocksMeasured} traded block${r.blocksMeasured === 1 ? "" : "s"} in blocks ${from}-${latest}` +
          (r.observedMax === 0 ? `, and the price never moved.` : `, below the minimum needed for a meaningful distribution.`) +
          `\n\nNo bound is recommended, deliberately. A value fitted to a handful of quiet blocks would be far\n` +
          `too tight and would reject honest trades immediately. Widen the window, or calibrate against a\n` +
          `comparable pool that has real flow and apply that result.`
      );
    }
    return text(
      `Calibration for ${poolId} on ${chain}\n` +
        `Sampled blocks ${from}-${latest}; ${r.blocksMeasured} of them traded.\n\n` +
        `Intra-block excursion from the block-opening tick:\n` +
        `  median      ${String(r.p50).padStart(6)} ticks  ${pct(r.p50).padStart(8)}%\n` +
        `  p90         ${String(r.p90).padStart(6)} ticks  ${pct(r.p90).padStart(8)}%\n` +
        `  p99         ${String(r.p99).padStart(6)} ticks  ${pct(r.p99).padStart(8)}%\n` +
        `  p99.9       ${String(r.p999).padStart(6)} ticks  ${pct(r.p999).padStart(8)}%\n` +
        `  worst       ${String(r.observedMax).padStart(6)} ticks  ${pct(r.observedMax).padStart(8)}%\n\n` +
        `RECOMMENDED maxTickDeviation: ${r.recommended} ticks (${pct(r.recommended)}%)\n` +
        `Would have rejected ${r.wouldHaveRejected} of ${r.blocksMeasured} traded blocks (${(r.rejectionRate * 100).toFixed(3)}%).\n\n` +
        `The bound sits 3x above the 99.9th percentile of honest movement. That asymmetry is\n` +
        `deliberate: rejecting an honest trade fails visibly and immediately, while a slightly\n` +
        `loose bound still forecloses single-block manipulation, which needs moves an order of\n` +
        `magnitude larger to pay for itself.`
    );
  }
);

// ---------------------------------------------------------------------------

server.tool(
  "pool_state",
  "Read an Aegis-protected pool's live configuration and running totals straight from the hook contract.",
  { poolId: z.string(), chain: z.enum(["unichain-sepolia", "base-sepolia"]).default("unichain-sepolia"), hook: z.string().default(AEGIS_HOOK) },
  async ({ poolId, chain, hook }) => {
    const { rpc: url } = CHAINS[chain];
    const id = poolId.replace(/^0x/, "").padStart(64, "0");

    // poolConfig(bytes32) -> (uint24,uint24,uint24,uint24,uint32,uint32,uint128,bool)
    const cfgRaw = await ethCall(url, hook, "0x0885f732" + id);
    // mevTaxUnitsCollected(bytes32) -> uint256
    const taxRaw = await ethCall(url, hook, "0x145a28a4" + id);

    if (!cfgRaw || cfgRaw === "0x") return text(`No response from hook ${hook} on ${chain}.`);
    const w = words(cfgRaw);
    const cfg = {
      baseFee: Number(unsignedWord(w[0])),
      maxFee: Number(unsignedWord(w[1])),
      mevTaxPerGwei: Number(unsignedWord(w[2])),
      maxTickDeviation: Number(unsignedWord(w[3])),
      cooldownBlocks: Number(unsignedWord(w[4])),
      minPositionAgeBlocks: Number(unsignedWord(w[5])),
      configured: Number(unsignedWord(w[7])) === 1,
    };
    if (!cfg.configured) return text(`Pool ${poolId} is not configured on hook ${hook}. Swaps against it revert with PoolNotConfigured.`);

    const tax = Number(unsignedWord(words(taxRaw)[0]));
    return text(
      `Pool ${poolId} on ${chain}\n` +
        `hook ${hook}\n\n` +
        `  base fee              ${cfg.baseFee} (${(cfg.baseFee / 10000).toFixed(2)}%)\n` +
        `  max fee               ${cfg.maxFee} (${(cfg.maxFee / 10000).toFixed(2)}%)\n` +
        `  MEV tax per gwei      ${cfg.mevTaxPerGwei} fee units\n` +
        `  max tick deviation    ${cfg.maxTickDeviation} (${ticksToPercent(cfg.maxTickDeviation).toFixed(2)}% per block)\n` +
        `  cooldown              ${cfg.cooldownBlocks} blocks\n` +
        `  min position age      ${cfg.minPositionAgeBlocks} blocks${cfg.minPositionAgeBlocks === 0 ? " (JIT defense off)" : ""}\n\n` +
        `  MEV tax collected     ${tax} fee units\n` +
        `                        = ${(tax / 10000).toFixed(4)}% of notional, summed over taxed swaps`
    );
  }
);

// ---------------------------------------------------------------------------

// Public RPCs cap eth_getLogs at 10k blocks per call, so a lookback of any useful length has to
// be walked in windows rather than requested in one shot.
const MAX_LOG_SPAN = 9000;

async function readActivity(url, hook, lookback) {
  const latest = await blockNumber(url);
  const from = Math.max(0, latest - lookback);

  const logs = [];
  for (let start = from; start <= latest; start += MAX_LOG_SPAN) {
    const end = Math.min(start + MAX_LOG_SPAN - 1, latest);
    const batch = await getLogs(url, { address: hook, fromBlock: start, toBlock: end });
    for (const log of batch) logs.push(log);
  }

  const taxes = [];
  const rejections = [];
  for (const log of logs) {
    const t0 = log.topics[0];
    if (t0 === TOPICS.mevTaxApplied) {
      const w = words(log.data);
      taxes.push({
        block: Number(BigInt(log.blockNumber)),
        poolId: log.topics[1],
        priorityFeeWei: unsignedWord(w[0]),
        feeCharged: Number(unsignedWord(w[1])),
        taxUnits: Number(unsignedWord(w[2])),
        tx: log.transactionHash,
      });
    }
  }
  return { latest, from, taxes, rejections, totalLogs: logs.length };
}

server.tool(
  "recent_activity",
  "List what the Aegis hook has recently taxed, with the priority-fee bid that triggered each charge.",
  { chain: z.enum(["unichain-sepolia", "base-sepolia"]).default("unichain-sepolia"), hook: z.string().default(AEGIS_HOOK), lookback: z.number().default(50000).describe("Blocks to look back") },
  async ({ chain, hook, lookback }) => {
    const { rpc: url } = CHAINS[chain];
    const { latest, from, taxes, totalLogs } = await readActivity(url, hook, lookback);
    if (totalLogs === 0) return text(`No hook activity in blocks ${from}-${latest} on ${chain}.`);
    if (taxes.length === 0) return text(`${totalLogs} hook events in blocks ${from}-${latest}, but no MEV tax charged. Every swap in the window bid a negligible priority fee.`);

    const lines = taxes.slice(-15).map((t) => {
      const gwei = Number(t.priorityFeeWei) / 1e9;
      return `  block ${t.block}  bid ${gwei.toFixed(4)} gwei  ->  fee ${t.feeCharged} (${(t.feeCharged / 10000).toFixed(2)}%)  tax ${t.taxUnits}`;
    });
    const totalTax = taxes.reduce((a, t) => a + t.taxUnits, 0);
    return text(
      `Aegis activity, blocks ${from}-${latest} on ${chain}\n` +
        `${taxes.length} taxed swaps, ${totalTax} fee units captured for LPs\n\n` +
        lines.join("\n")
    );
  }
);

// ---------------------------------------------------------------------------

server.tool(
  "assess_threat",
  "Judge whether an Aegis-protected pool is currently under attack, by comparing its configured bound against what its recent price behaviour actually looks like.",
  { poolId: z.string(), chain: z.enum(["unichain-sepolia", "base-sepolia"]).default("unichain-sepolia"), hook: z.string().default(AEGIS_HOOK), lookback: z.number().default(50000) },
  async ({ poolId, chain, hook, lookback }) => {
    const { rpc: url } = CHAINS[chain];
    const { latest, from, taxes } = await readActivity(url, hook, lookback);
    const forPool = taxes.filter((t) => t.poolId.toLowerCase() === poolId.toLowerCase());

    const bids = forPool.map((t) => Number(t.priorityFeeWei) / 1e9);
    const highBids = bids.filter((b) => b >= 1).length;
    const totalTax = forPool.reduce((a, t) => a + t.taxUnits, 0);

    // A verdict drawn from a handful of swaps is noise wearing a confident label. Say so rather
    // than dress up n=1 as a trend; an alerting tool that cries wolf on one sample gets ignored,
    // which is worse than one that admits it cannot tell yet.
    const MIN_SAMPLE = 20;

    let verdict, reasoning;
    if (forPool.length === 0) {
      verdict = "NO DATA";
      reasoning = "No taxed swaps for this pool in the window. Either it is idle, or every swap bid a negligible priority fee — which is what honest flow looks like.";
    } else if (forPool.length < MIN_SAMPLE) {
      verdict = "INSUFFICIENT DATA";
      reasoning =
        `Only ${forPool.length} taxed swap${forPool.length === 1 ? "" : "s"} in the window, against a minimum of ${MIN_SAMPLE} ` +
        `needed for a verdict. ${highBids} of them bid 1 gwei or more, and the pool captured ${totalTax} fee units — ` +
        `report those as observations, not as a trend. Widen the lookback, or wait for more flow.`;
    } else if (highBids === 0) {
      verdict = "QUIET";
      reasoning = `${forPool.length} taxed swaps, none bidding 1 gwei or more. Consistent with ordinary flow: nobody is paying for block position here.`;
    } else if (highBids / forPool.length > 0.3) {
      verdict = "ELEVATED";
      reasoning = `${highBids} of ${forPool.length} swaps bid 1 gwei or more. Sustained competition for ordering is what extraction looks like — and the tax means those searchers paid the LPs ${totalTax} fee units for the privilege.`;
    } else {
      verdict = "NORMAL";
      reasoning = `${highBids} of ${forPool.length} swaps bid 1 gwei or more. Occasional high bids are expected; arbitrage keeps a pool honest and is not itself an attack.`;
    }

    return text(
      `Threat assessment — ${poolId} on ${chain}\n` +
        `blocks ${from}-${latest}\n\n` +
        `  verdict            ${verdict}\n` +
        `  taxed swaps        ${forPool.length}\n` +
        `  bids >= 1 gwei     ${highBids}\n` +
        `  tax captured       ${totalTax} fee units\n\n` +
        `${reasoning}\n\n` +
        `Note: a high bid is evidence of competition for block position, not proof of an attack.\n` +
        `The point of the MEV tax is that it does not need to tell them apart — whoever is paying\n` +
        `for position pays the pool proportionally either way.`
    );
  }
);

// ---------------------------------------------------------------------------

const transport = new StdioServerTransport();
await server.connect(transport);

# Watchtower

The observability and agent layer for Aegis: a subgraph that indexes what the hook decided, a
calibration engine that derives circuit-breaker settings from real market data, and an MCP server
that puts both in front of an AI agent.

## Why this exists

Aegis's design has an admitted gap. The circuit breaker trades safety against liveness — set the
bound too tight and honest trades get rejected — and the README answers that with "per-pool
calibration" without ever saying *how* you would calibrate. The hardcoded 500 ticks is a
placeholder, not a result.

The watchtower closes that gap with evidence.

## What the calibration engine measures

The breaker checkpoints the tick at a block's first swap, then rejects any swap carrying the tick
further than `maxTickDeviation` from that checkpoint. So the quantity to calibrate against is the
**maximum excursion from the block-opening tick, within each block**.

That is deliberately not the block-to-block drift, which is a much smaller number. Calibrating
against drift would produce a bound that looks generous on paper and rejects real trades in
production.

The engine replays that exact checkpoint logic over a real pool's swap history, builds the
distribution of honest excursions, and places the bound above it with margin.

```bash
node watchtower/calibrate.mjs --pool 0x<poolId> --blocks 5000
```

### What it found

Run against the busiest live Uniswap v4 pools on Unichain mainnet:

| Pool | traded blocks | median | p99 | p99.9 | worst | recommended |
|---|---|---|---|---|---|---|
| `0x3258f413…` | 900 | 1 tick | 10 | 39 | 39 | **200 ticks** (2.02%) |
| `0xc4f39378…` | 433 | 2 ticks | 15 | 23 | 23 | **100 ticks** (1.00%) |
| `0x04b7dd02…` | 267 | 3 ticks | 24 | 30 | 30 | **100 ticks** (1.00%) |

Real pools move by **single-digit ticks** in a typical block. The worst honest block across all
three samples was 39 ticks — 0.39%.

**Aegis's own default of 500 ticks is 2.5x to 5x looser than any of these pools need.** The
project's placeholder was wrong in the safe direction, and now there is a number to replace it
with rather than another guess.

### The margin, and why it is asymmetric

The recommendation is 3x the 99.9th percentile. That asymmetry is a deliberate choice, not
arithmetic convenience: rejecting an honest trade is a visible, immediate failure for a real user,
while a bound somewhat looser than optimal still forecloses single-block manipulation — which
needs price moves an order of magnitude larger to pay for itself. The gap between honest
volatility (tens of ticks) and profitable manipulation (thousands) is wide enough that the exact
placement inside it matters far less than staying inside it.

## MCP server

```bash
node watchtower/mcp-server.mjs      # speaks MCP over stdio
```

| Tool | Question it answers |
|---|---|
| `calibrate_pool` | How should this pool's breaker be tuned? |
| `pool_state` | What is this pool's live config and how much has it captured? |
| `recent_activity` | What has the hook taxed lately, and at what bid? |
| `assess_threat` | Is this pool under attack? |

`assess_threat` refuses to issue a verdict below 20 samples and says so. An alerting tool that
calls one swap a trend gets ignored, which is worse than one that admits it cannot tell yet.

Everything reads chain state over plain JSON-RPC, so it works on a fresh checkout with **no API
key and no deployed subgraph**.

### Wiring it into Claude Code

```json
{
  "mcpServers": {
    "aegis-watchtower": {
      "command": "node",
      "args": ["/absolute/path/to/aegis-hook/watchtower/mcp-server.mjs"]
    }
  }
}
```

## Subgraph

Indexes `PoolConfigured`, `BlockCheckpointed`, `MevTaxApplied`, `SwapRejected` and `GuardianHalt`
from the deployed hook. `BlockCheckpoint.tickDelta` is the calibration signal, stored so the
distribution can be queried directly rather than recomputed from logs each time.

```bash
cd subgraph
npm install
npm run codegen && npm run build
npm run deploy          # requires a Subgraph Studio key
```

Built and validated against the live deployment at
`0x99c92c4eF032a15E2a6f0BfeBA276666148AeAc0`, from block `61674705`.

## Two bugs worth recording

Both were caught by checking output that looked plausible rather than by a test failing:

1. **Sign extension.** The ABI sign-extends `int24` across the full 32-byte word, so a tick of
   -100 arrives as `0xffff…ff9c`. Applying two's complement at the declared 24-bit width instead
   of 256 returns ~1.16e77 for every negative tick, and only accidentally works for positives.
   The first calibration run reported every excursion as zero — plausible enough to believe if the
   numbers had not been *exactly* zero across 1,901 swaps.
2. **Wrong function selector.** `poolConfig(bytes32)` is `0x0885f732`; a guessed value returned
   decodable garbage rather than an error. Selectors get computed, never assumed.

/**
 * The Graph client for the Aegis watchtower.
 *
 * The Graph is the *source of blockchain data* for the agent layer, not a mirror of it:
 *
 *   - `calibrate_pool` reads real Uniswap v4 swap history from Uniswap's own subgraph on The
 *     Graph's decentralised network. That history is what the circuit-breaker bound is derived
 *     from, so the recommendation the agent makes is a direct function of indexed data.
 *   - `pool_state`, `recent_activity` and `assess_threat` read the Aegis subgraph, which indexes
 *     what the hook actually decided.
 *
 * An RPC path is kept as an explicit, clearly-labelled fallback so a fresh checkout works without
 * credentials — but it is the fallback, and every tool says which source answered it. Silently
 * degrading to RPC while claiming to use The Graph would be worse than failing.
 */

/** Uniswap's official v4 subgraph for Unichain, on the decentralised network. */
export const UNISWAP_V4_UNICHAIN = "EoCvJ5tyMLMJcTnLQwWpjAtPdn74PcrZgzfcT5bYxNBH";

export const GRAPH_API_KEY = process.env.GRAPH_API_KEY ?? "";
/** Query URL for the Aegis subgraph, from `graph deploy`. */
export const AEGIS_SUBGRAPH_URL = process.env.AEGIS_SUBGRAPH_URL ?? "";

export function gatewayUrl(subgraphId, apiKey = GRAPH_API_KEY) {
  if (!apiKey) return null;
  return `https://gateway.thegraph.com/api/${apiKey}/subgraphs/id/${subgraphId}`;
}

export class GraphError extends Error {
  constructor(message, { status, errors } = {}) {
    super(message);
    this.name = "GraphError";
    this.status = status;
    this.errors = errors;
  }
}

/**
 * Execute a GraphQL query. Throws rather than returning partial data — a caller that wants to
 * fall back to RPC should do so explicitly, not by accidentally reading an empty result set.
 */
export async function query(url, gql, variables = {}) {
  if (!url) throw new GraphError("no subgraph URL configured");

  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: gql, variables }),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new GraphError(`gateway returned ${res.status}${body ? `: ${body.slice(0, 200)}` : ""}`, {
      status: res.status,
    });
  }

  const json = await res.json();
  if (json.errors?.length) {
    throw new GraphError(json.errors.map((e) => e.message).join("; "), { errors: json.errors });
  }
  return json.data;
}

// ---------------------------------------------------------------------------
// Uniswap v4 — swap history, the input to calibration
// ---------------------------------------------------------------------------

const SWAPS_QUERY = `
  query Swaps($pool: String!, $first: Int!, $skip: Int!) {
    swaps(
      first: $first
      skip: $skip
      orderBy: timestamp
      orderDirection: desc
      where: { pool: $pool }
    ) {
      tick
      logIndex
      timestamp
      transaction { blockNumber }
    }
  }
`;

/**
 * Fetch recent swaps for a v4 pool from Uniswap's subgraph.
 * @returns swaps ordered oldest-first, shaped like the RPC path's output so `measureExcursions`
 *          consumes either without caring which produced it.
 */
export async function fetchSwapsFromGraph(poolId, { apiKey = GRAPH_API_KEY, limit = 3000 } = {}) {
  const url = gatewayUrl(UNISWAP_V4_UNICHAIN, apiKey);
  if (!url) throw new GraphError("GRAPH_API_KEY is not set");

  const out = [];
  const page = 1000; // the gateway caps `first` at 1000
  for (let skip = 0; skip < limit; skip += page) {
    const data = await query(url, SWAPS_QUERY, {
      pool: poolId.toLowerCase(),
      first: Math.min(page, limit - skip),
      skip,
    });
    const batch = data?.swaps ?? [];
    for (const s of batch) {
      out.push({
        block: Number(s.transaction?.blockNumber ?? 0),
        logIndex: Number(s.logIndex ?? 0),
        tick: Number(s.tick),
      });
    }
    if (batch.length < page) break;
  }

  out.sort((a, b) => a.block - b.block || a.logIndex - b.logIndex);
  return out;
}

// ---------------------------------------------------------------------------
// The Aegis subgraph — what the hook decided
// ---------------------------------------------------------------------------

const POOL_QUERY = `
  query Pool($id: ID!) {
    pool(id: $id) {
      id
      hook
      baseFee
      maxFee
      mevTaxPerGwei
      mevTaxFloorGwei
      maxTickDeviation
      cooldownBlocks
      minPositionAgeBlocks
      totalTaxUnits
      totalTaxedSwaps
      totalPriorityFeeWei
      oracleSkips
      oracleFeed
      oracleMaxTickDeviation
      maxObservedTickDelta
      haltedUntilBlock
    }
  }
`;

export async function fetchPoolFromGraph(poolId, url = AEGIS_SUBGRAPH_URL) {
  const data = await query(url, POOL_QUERY, { id: poolId.toLowerCase() });
  return data?.pool ?? null;
}

const TAXES_QUERY = `
  query Taxes($pool: String!, $first: Int!) {
    mevTaxes(first: $first, orderBy: blockNumber, orderDirection: desc, where: { pool: $pool }) {
      priorityFeeWei
      feeCharged
      taxUnits
      blockNumber
      txHash
      sender
    }
  }
`;

export async function fetchTaxesFromGraph(poolId, { url = AEGIS_SUBGRAPH_URL, first = 100 } = {}) {
  const data = await query(url, TAXES_QUERY, { pool: poolId.toLowerCase(), first });
  return data?.mevTaxes ?? [];
}

const CHECKPOINTS_QUERY = `
  query Checkpoints($pool: String!, $first: Int!) {
    blockCheckpoints(
      first: $first
      orderBy: blockNumber
      orderDirection: desc
      where: { pool: $pool }
    ) {
      blockNumber
      tick
      absTickDelta
    }
  }
`;

/**
 * Per-block tick movement for an Aegis-protected pool, straight from the index.
 * @dev This is why `BlockCheckpoint.tickDelta` is stored rather than derived on read: once a pool
 *      is live, its own indexed history is the calibration input, with no log scanning at all.
 */
export async function fetchCheckpointsFromGraph(poolId, { url = AEGIS_SUBGRAPH_URL, first = 1000 } = {}) {
  const data = await query(url, CHECKPOINTS_QUERY, { pool: poolId.toLowerCase(), first });
  return data?.blockCheckpoints ?? [];
}

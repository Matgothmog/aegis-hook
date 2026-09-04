/**
 * Thin JSON-RPC helpers shared by the calibration engine and the MCP server.
 *
 * Reads live chain state directly rather than depending on the subgraph being deployed, so every
 * tool here works against a fresh checkout with no API key. When the subgraph is live it is a
 * faster path to the same history, not a prerequisite.
 */

export const CHAINS = {
  "unichain-mainnet": { rpc: "https://mainnet.unichain.org", manager: "0x1F98400000000000000000000000000000000004", id: 130 },
  "unichain-sepolia": { rpc: "https://sepolia.unichain.org", manager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC", id: 1301 },
  "base-sepolia": { rpc: "https://sepolia.base.org", manager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408", id: 84532 },
  // Arc has no canonical v4 deployment; Aegis brings its own PoolManager, so the address here is
  // filled in by script/DeployArc.s.sol rather than being a chain constant.
  "arc-testnet": { rpc: "https://rpc.testnet.arc.io", manager: null, id: 5042002 },
};

export const AEGIS_HOOK = "0x295DB25bC9aE00ddC51C875F0FeC16a406a9eAc0";

export const TOPICS = {
  swap: "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f",
  mevTaxApplied: "0xffea188a65b6b4aa83a3637c2a6ce58e82e3ed4ffbc37913bd5e48d2e7b77385",
  blockCheckpointed: "0x8cbfc39bd48fb367bb972089aa224bef27b2fd37bca607cd2b94756b66240634",
};

export const REASONS = ["None", "PriceDeviation", "VolumeLimit", "GuardianHalt", "PositionTooYoung"];

export async function rpc(url, method, params) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!res.ok) throw new Error(`RPC ${res.status}`);
  const json = await res.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}

/** Two's complement at 256 bits — the ABI sign-extends smaller signed types across the word. */
export function signedWord(hexWord) {
  const v = BigInt("0x" + hexWord);
  return v >= 1n << 255n ? v - (1n << 256n) : v;
}

export const unsignedWord = (hexWord) => BigInt("0x" + hexWord);
export const words = (data) => data.slice(2).match(/.{64}/g) ?? [];
export const ticksToPercent = (t) => (Math.pow(1.0001, t) - 1) * 100;

export async function ethCall(url, to, data) {
  return rpc(url, "eth_call", [{ to, data }, "latest"]);
}

export async function getLogs(url, { address, topics, fromBlock, toBlock }) {
  const filter = { address, fromBlock: "0x" + fromBlock.toString(16), toBlock: "0x" + toBlock.toString(16) };
  // Some nodes reject an explicit empty topics array; omit it rather than send one.
  if (topics && topics.length) filter.topics = topics;
  return rpc(url, "eth_getLogs", [filter]);
}

export async function blockNumber(url) {
  return Number(BigInt(await rpc(url, "eth_blockNumber", [])));
}

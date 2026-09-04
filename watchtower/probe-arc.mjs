const url = "https://rpc.testnet.arc.io";
async function rpc(m, p) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: m, params: p }) });
  const j = await r.json(); if (j.error) throw new Error(j.error.message); return j.result;
}
const latest = Number(BigInt(await rpc("eth_blockNumber", [])));
const tips = [];
let bases = [];
for (let i = 0; i < 40; i++) {
  const b = await rpc("eth_getBlockByNumber", ["0x" + (latest - i).toString(16), true]);
  if (!b) continue;
  const base = BigInt(b.baseFeePerGas ?? "0x0");
  bases.push(Number(base) / 1e9);
  for (const t of b.transactions ?? []) {
    // effective tip = min(maxPriorityFee, maxFee - base) for 1559, else gasPrice - base
    let tip;
    if (t.maxPriorityFeePerGas != null && t.maxFeePerGas != null) {
      const mpf = BigInt(t.maxPriorityFeePerGas), mf = BigInt(t.maxFeePerGas);
      const room = mf > base ? mf - base : 0n;
      tip = mpf < room ? mpf : room;
    } else {
      const gp = BigInt(t.gasPrice ?? "0x0");
      tip = gp > base ? gp - base : 0n;
    }
    tips.push(Number(tip) / 1e9);
  }
}
tips.sort((a, b) => a - b);
const pct = (q) => tips.length ? tips[Math.min(tips.length - 1, Math.ceil(q / 100 * tips.length) - 1)] : 0;
console.log(`sampled ${tips.length} txs across 40 blocks`);
console.log(`base fee   min ${Math.min(...bases).toFixed(3)}  max ${Math.max(...bases).toFixed(3)} gwei-equiv`);
if (tips.length) {
  console.log(`priority fee (gwei-equiv):`);
  for (const q of [50, 75, 90, 99]) console.log(`  p${q}  ${pct(q).toFixed(4)}`);
  console.log(`  max  ${tips[tips.length-1].toFixed(4)}`);
} else console.log("no transactions sampled");

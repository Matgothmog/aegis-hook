import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({ command: "node", args: ["./mcp-server.mjs"] });
const client = new Client({ name: "test", version: "1.0.0" });
await client.connect(transport);

const calls = [
  ["pool_state", { poolId: "0x578a0a4f0ac22902b8d8881558e5a246f960933f7c4d994dcd563765de5f252f", chain: "unichain-sepolia" }],
  ["calibrate_pool", { poolId: "0x578a0a4f0ac22902b8d8881558e5a246f960933f7c4d994dcd563765de5f252f", chain: "unichain-sepolia", blocks: 8000 }],
];
for (const [name, args] of calls) {
  console.log("=".repeat(70));
  console.log("CALL:", name);
  console.log("=".repeat(70));
  try {
    const r = await client.callTool({ name, arguments: args });
    console.log(r.content[0].text);
  } catch (e) { console.log("ERROR:", e.message); }
  console.log("");
}
await client.close();

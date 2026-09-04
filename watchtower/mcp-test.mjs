import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
const transport = new StdioClientTransport({ command: "node", args: ["./mcp-server.mjs"] });
const client = new Client({ name: "test", version: "1.0.0" });
await client.connect(transport);
const r = await client.callTool({ name: "pool_state", arguments: {
  poolId: "0xb350a55f4185c565df844fd1ec1c3a453523e01854e79ea63c141dce3ef2a9da", chain: "unichain-sepolia" } });
console.log(r.content[0].text);
await client.close();

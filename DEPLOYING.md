# Deploying Aegis

## Why deployment is not just `forge create`

v4 reads a hook's permissions out of **the low 14 bits of the hook's own address**. A hook cannot
be deployed to wherever CREATE happens to put it: a salt has to be searched until CREATE2 lands
on an address whose bits already spell the permissions the contract claims. `AegisHook`'s
constructor then asserts the match, so a bad mine reverts at deployment rather than producing a
hook whose callbacks v4 silently never invokes.

All of that lives in [`script/AegisDeploy.sol`](./script/AegisDeploy.sol), and
[`test/Deploy.t.sol`](./test/Deploy.t.sol) drives that same library — so the tested path is the
deployed path.

## Verified addresses

Each of these was checked to actually have code before being written down.

| Chain | ID | PoolManager |
|---|---|---|
| Unichain Sepolia | 1301 | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Base Sepolia | 84532 | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Ethereum Sepolia | 11155111 | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |

Unichain Sepolia is the default target, because the MEV tax assumes priority-fee ordering and
Unichain is the chain whose sequencer actually provides it.

> Note the address `0x1F98400000000000000000000000000000000004`, which several sources give for
> Unichain — that is the **mainnet** PoolManager. It has no code on Sepolia. Verify before trusting.

## 1. Get a funded key

### Generate one, without ever printing the private key

```bash
cast wallet new ~/.foundry/keystores aegis-deployer
```

This prompts for a password, prints only the **address**, and writes the encrypted key to
`~/.foundry/keystores/aegis-deployer`. The private key never reaches your terminal, your shell
history, or an environment variable.

Use a **fresh** key. Never a wallet holding real funds — a deployer key ends up in scripts, CI
logs and screenshots, so treat it as disposable from the start.

### Fund it

Unichain Sepolia is a testnet; the ETH is free and worth nothing.

| Faucet | Notes |
|---|---|
| <https://ethglobal.com/faucet/unichain-sepolia-1301> | Start here — for hackathon participants, no mainnet balance required |
| <https://www.l2faucet.com/unichain> | Device attestation instead of a mainnet balance |
| <https://console.optimism.io/faucet> | Superchain faucet, 0.05 ETH / 24h |
| <https://faucet.quicknode.com/unichain/sepolia> | One drip / 12h |
| <https://faucets.chain.link/unichain-testnet> | Chainlink; also useful for the Chainlink track |

Several faucets require a small **mainnet** ETH balance as anti-sybil. The first two do not.

0.05 ETH is ample: the deploy itself costs ~0.0000217 ETH, and the rest covers pool setup,
liquidity and demo swaps.

Alternatively bridge Ethereum Sepolia ETH via <https://bridge.unichain.org>.

### Check it landed

```bash
cast balance <your-address> --rpc-url https://sepolia.unichain.org --ether
```

## 2. Dry run — costs nothing, needs no key

```bash
forge script script/DeployAegis.s.sol --rpc-url unichain_sepolia
```

This mines the salt and simulates the deployment. Expect roughly 16k iterations (14 bits must
match) and a log line ending in `permission bits 10944` — that is `0x2AC0`, the Aegis flag set.
A `lack of funds` error at the end is normal here: simulation succeeded, there is just no funded
sender yet.

## 3. Deploy

```bash
forge script script/DeployAegis.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --account aegis-deployer
```

`--account` reads the encrypted keystore and prompts for the password, so the private key never
becomes an environment variable or a shell-history entry. `--private-key $PRIVATE_KEY` also works
but leaves the key in both.

The guardian defaults to the broadcasting address. Override with `GUARDIAN=0x...`, and the target
chain with `POOL_MANAGER=0x...`.

**The mined address depends on the constructor arguments**, guardian included — so deploying with
a different guardian yields a different salt and a different hook address. That is expected.

## 4. Verify against the live chain

Before deploying anything, the fork suite already exercises the real deployed v4:

```bash
forge test --match-path 'test/fork/*' -vv
```

It confirms the live PoolManager accepts a hook mined by our library, that a dynamic-fee pool
honours the per-swap fee override returned from `beforeSwap`, and that a revert in `afterSwap`
genuinely unwinds the swap. It skips itself if the RPC is unreachable.

## Live deployments

| | |
|---|---|
| Chain | Unichain Sepolia (1301) |
| AegisHook | [`0x99c92c4eF032a15E2a6f0BfeBA276666148AeAc0`](https://sepolia.uniscan.xyz/address/0x99c92c4eF032a15E2a6f0BfeBA276666148AeAc0) |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Guardian | `0x504D0A8ff1775bA0CF71785AD24E38A4EC7f9388` |
| CREATE2 salt | `0x0b23` |
| Permission bits | `0x2AC0` (10944) |

Verified onchain rather than taken from the deploy log: the contract has code, `poolManager()`
and `guardian()` read back correctly, and the address's low 14 bits equal what
`getHookPermissions()` declares — which is what makes v4 invoke the callbacks at all.

Deployment cost 0.0000015 ETH.

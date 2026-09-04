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
| AegisHook | [`0x295DB25bC9aE00ddC51C875F0FeC16a406a9eAc0`](https://sepolia.uniscan.xyz/address/0x295DB25bC9aE00ddC51C875F0FeC16a406a9eAc0) |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Guardian | `0x504D0A8ff1775bA0CF71785AD24E38A4EC7f9388` |
| CREATE2 salt | see `broadcast/` |
| Permission bits | `0x2AC0` (10944) |

Verified onchain rather than taken from the deploy log: the contract has code, `poolManager()`
and `guardian()` read back correctly, and the address's low 14 bits equal what
`getHookPermissions()` declares — which is what makes v4 invoke the callbacks at all.

Deployment cost 0.0000015 ETH.

## Live demo pool

Seeded by `script/SeedPool.s.sol`, driven by `script/DemoSwap.s.sol`.

| | |
|---|---|
| poolId | `0xb350a55f4185c565df844fd1ec1c3a453523e01854e79ea63c141dce3ef2a9da` |
| token0 (AEGA) | `0x0dCDA2128dE6BF15246B8531CECB7Ab2331D1e01` |
| token1 (AEGB) | `0xbCB29a19524C68ad33721B6ED60045fC0a3F2ca6` |
| PoolSwapTest | `0x0c656f8f1Cc477b12E197d0df0b2e511E70d8A65` |
| PoolModifyLiquidityTest | `0xfE70D8b253343dCb7b7a13bC5704C87E4EAC7aF4` |

```bash
export HOOK=0x295DB25bC9aE00ddC51C875F0FeC16a406a9eAc0
export SWAP_ROUTER=0x0c656f8f1Cc477b12E197d0df0b2e511E70d8A65
export TOKEN0=0x0dCDA2128dE6BF15246B8531CECB7Ab2331D1e01
export TOKEN1=0xbCB29a19524C68ad33721B6ED60045fC0a3F2ca6

# honest user: charged the 3000 base fee
forge script script/DemoSwap.s.sol --rpc-url unichain_sepolia --broadcast \
  --account aegis-deployer --password aegis-testnet-only

# searcher bidding 2 gwei: charged 23000
forge script script/DemoSwap.s.sol --rpc-url unichain_sepolia --broadcast \
  --account aegis-deployer --password aegis-testnet-only \
  --priority-gas-price 2gwei --with-gas-price 3gwei

# read the accumulated tax
cast call $HOOK "mevTaxUnitsCollected(bytes32)(uint256)" \
  0xb350a55f4185c565df844fd1ec1c3a453523e01854e79ea63c141dce3ef2a9da \
  --rpc-url https://sepolia.unichain.org
```

Give the RPC a few seconds after a broadcast before reading state back — querying immediately
can hit a node that has not caught up and return a stale zero.

## Arc (Circle) — chain 5042002

Arc has **no Uniswap v4 deployment**, so `script/DeployArc.s.sol` deploys a PoolManager first and
then the hook on top of it. That makes this a v4 deployment on a chain that did not have one.

### Get test USDC

Arc pays gas in **USDC**, not ETH. The faucet is Circle's:

1. <https://faucet.circle.com>
2. Select **Arc testnet**
3. Paste the deployer address and claim

The dry run puts the whole deployment — PoolManager, hook, routers, tokens, pool, liquidity — at
**~0.70 USDC**. Claim a few dollars' worth and there is ample margin.

```bash
# costs nothing, needs no funds
forge script script/DeployArc.s.sol --rpc-url arc_testnet

# live
forge script script/DeployArc.s.sol --rpc-url arc_testnet --broadcast \
  --account aegis-deployer --password aegis-testnet-only
```

### What Arc changes, and why

**The tax needs a floor, or the pool is broken.** Sampling 666 transactions over 40 blocks, Arc
runs a flat 20 gwei base fee and its *median* transaction bids 10 gwei of priority (p90 25, p99 80).
Charging the raw priority fee the way the Unichain deployment does would tax that median swap
100,000 units, clamp it to the ceiling, and make **every ordinary trade pay the 5% maximum**.

This is a design flaw the port exposed, not merely a mis-set constant: the tax is meant to price
the *excess* a searcher pays to win an ordering race, and on a chain with an ambient tip the excess
is not the whole priority fee. `mevTaxFloorGwei` fixes it, set to Arc's measured p90. A floor of 0
reproduces the original behaviour exactly, which is correct on Unichain where ordinary flow bids
nothing — so the Unichain deployment is unchanged in behaviour.

**The breaker can be much tighter.** Arc is stablecoin-native, and a stable pair has no business
moving 5% in a block. The Arc pool ships at 50 ticks (~0.5%) against Unichain's calibrated 200. A
bound that would strangle a volatile pair is comfortable here, and a manipulation that could hide
inside ETH volatility stands out immediately. That 50 is a starting point to be re-derived from
Arc's own history once the pool has one — not a number to leave sitting there.

**The tax's economics are weaker on Arc, and the code says so.** Arc uses Malachite consensus,
where ordering is proposer-determined rather than a priority-fee auction. The mechanism still
executes and still charges, but the argument that a bid is a *truthful* signal is a property of
priority ordering, which Unichain has and Arc does not. On Arc the circuit breaker and the
position-age rule carry the defense.

### Live on Arc testnet

| | |
|---|---|
| Chain | Arc testnet (5042002) |
| PoolManager | `0x94f5CB26384D025Ba617460233f4c8100A993Fc7` — **deployed by this project; Arc had no v4** |
| AegisHook | `0x84e19075E873fc1458b484332D7D1487DC542AC0` |
| poolId | `0x108f480a40c490e9a3348979b1b86763ac4bbb3f833af329e35d647c85864bbe` |
| token0 / token1 | `0x7F97F4ce…bd90` / `0xD8cC7Cfb…669C` (6-decimal stablecoin stand-ins) |
| swapRouter | `0xe4d271184BbFa35806d1A478e110cF112E35D0C3` |
| Permission bits | `0x2AC0` (10944) |

Config: 0.05% base fee, 2% ceiling, **tax floor 25 gwei**, 50-tick breaker (~0.5%), 5-block
position age. Total cost of the whole deployment plus demo swaps: **0.32 USDC**.

### The floor, verified onchain

Two swaps against the live Arc pool, differing only in what they bid for block position:

| Bid | Above the 25 gwei floor? | Tax charged |
|---|---|---|
| 10 gwei — Arc's *median* transaction | no | **0** |
| 26 gwei — 1 gwei of genuine excess | +1 gwei | **10,000** (= 1 × `mevTaxPerGwei`) |

The first swap is the one that matters. Before `mevTaxFloorGwei` existed, that ordinary trade
would have been taxed 100,000 units, clamped to the ceiling, and charged the full 2%. It now pays
the 0.05% base fee, while a searcher bidding a single gwei above ambient pays precisely for the
excess. The fix is not theoretical; both numbers came off the chain.

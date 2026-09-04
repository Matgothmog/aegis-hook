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

## 1. Get testnet ETH

Unichain Sepolia is a testnet; the ETH is free and worth nothing.

- <https://faucet.quicknode.com/unichain/sepolia>
- Or bridge Ethereum Sepolia ETH via <https://bridge.unichain.org>

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
export PRIVATE_KEY=0x...
forge script script/DeployAegis.s.sol \
  --rpc-url unichain_sepolia \
  --broadcast \
  --private-key $PRIVATE_KEY
```

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

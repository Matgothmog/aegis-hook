# Aegis

**Self-defending Uniswap v4 pools.**

A v4 hook that prices MEV out of the block and trips a circuit breaker when a pool
is under attack — shipped with an attack lab that measures real attacker profit
against a protected pool versus a vanilla one.

> Built for ETHOnline 2026.

---

## The problem

A Uniswap pool is a passive object. It has no idea whether the swap it is executing
is honest flow or the middle slice of a sandwich, and it cannot tell the difference
between price discovery and a flash-loan-funded oracle manipulation. Every defense
today lives *outside* the pool — private mempools, RPC-level protection, off-chain
monitoring. The pool itself never fights back.

v4 hooks change what is possible: the pool can now run code at the exact moment it
matters, with the swap parameters and its own state in hand.

## The mechanism

Aegis is two defenses in one hook, plus the harness that proves they work.

### 1. MEV tax — make the attack unprofitable

On a chain with **priority-fee transaction ordering**, a searcher who wants to land
an arbitrage or a sandwich *must* outbid every rival on priority fee. That bid is a
public signal of exactly how much MEV the searcher expects to extract.

Aegis reads that signal and charges for it:

```
priorityFee = tx.gasprice - block.basefee
swapFee     = baseFee + clamp(priorityFee * taxRate, 0, maxFee)
```

The searcher's own bid sets the fee they pay. Bid harder to win the ordering race,
pay more to the LPs. The extractable profit is compressed toward zero, and whatever
the searcher does capture is paid to the pool rather than the block builder.

This is not speculative — it is the precondition Unichain already satisfies.
[Rollup-Boost](https://blog.uniswap.org/rollup-boost-is-live-on-unichain) enforces
priority ordering inside a TEE, with attestations third parties can verify. Aegis
targets Unichain first for exactly this reason.

### 2. Circuit breaker — bound the damage

The MEV tax makes attacks expensive. The breaker makes them *bounded*.

Aegis checkpoints the pool price at the first swap of each block, then rejects any
swap that would move the price beyond a configured deviation within that same block,
and rate-limits cumulative volume per window. Trip the breaker and the pool enters a
cooldown where swaps revert until it clears.

A single intra-block price checkpoint turns out to defeat a whole family of attacks
at once, because they all share one requirement — a large price move inside one block:

| Attack | Why the breaker stops it |
|---|---|
| Sandwich | Frontrun leg cannot move price far enough to be worth the backrun |
| Single-block oracle manipulation | Price cannot reach the extreme the reading depends on |
| Flash-loan drain | The whole loan must repay inside one transaction, one block |
| JIT liquidity | Position-age check taxes liquidity that lives for one block |

A Chainlink feed provides an external reference so the breaker also catches
manipulation walked across *multiple* blocks, which an internal-price-only check
would miss.

### 3. Attack lab — prove it

The part that makes this a security project and not a fee experiment.

The lab implements working attacker contracts and runs each one twice: against a vanilla
v4 pool and against an Aegis pool, reporting what the attacker actually walks away with.

```
sandwich | frontrun 5e18, victim 10e18, searcher bids 3 gwei priority
  vanilla pool      attacker PnL   +0.068972 token0
  aegis  pool       attacker PnL   -0.230778 token0

JIT liquidity | 50000e18 supplied for one block around a 5e18 swap
  vanilla pool      JIT bot PnL    +0.015184 token0   (~the entire 0.3% fee)
  aegis  pool       withdrawal reverts - position too young

single-block price manipulation | 400e18 against a 1000e18 book
  vanilla pool      -6713 ticks in one block   ->  price x0.51  (-48.9%)
  aegis  pool       reverted - bound is 500 ticks (-4.9%)
```

Three different attacks, three different defenses doing the work. The sandwich is priced out
by the tax. The JIT bot is stopped by the position-age requirement. The manipulator is stopped
by the breaker — and *only* by the breaker, since no fee is large enough to deter someone whose
real profit is in a lending market elsewhere.

**The manipulation result is worth reading twice.** 400e18 against this book moves an
unprotected pool 48.9% inside a single block. Any contract reading a price from that pool in
that block — a lending market sizing a loan, a liquidation engine, a settling derivative —
reads a fabricated number. Aegis caps that at 4.9% per block, and paying more does not help:
`test_breakerCannotBeBoughtOff` bids 500 gwei and is still refused, because a bound is not a
price. Splitting the attack into eight smaller swaps inside the block does not help either —
the checkpoint is per block, so the bound applies to cumulative movement.

Critically, this does **not** pin the price. Across six blocks the same pool still moved
-20.2%, because the checkpoint re-anchors each block. The breaker rate-limits *velocity*, not
direction — a market that genuinely repriced can still get there, it just cannot arrive
instantly. That distinction is the whole design, and `test_priceCanStillMoveAcrossBlocks` is
what holds it honest.

A defense that is not measured is a claim. This measures it.

**The control group is the point.** Every scenario runs against a vanilla pool first. An
early version of this harness reported a +506 token0 "profit" — implausible on its face,
and it turned out the backrun was unwinding the attacker's entire token1 balance rather
than the amount the frontrun acquired. Without a control run to sanity-check against, that
number would have gone straight into a slide.

### 4. Watchtower — the pool tells you it is under attack

Every decision the hook makes is emitted on-chain: fee charged, tax collected,
breaker armed or tripped, swap rejected and why. A subgraph indexes those events and
an MCP server puts them in front of an AI agent, so an LP can ask in plain language:

> *"Is pool 0xabc… under attack right now, and what has it collected today?"*

---

## Architecture

```
                         swap
                          │
                          ▼
                 ┌──────────────────┐
                 │   PoolManager    │
                 └────────┬─────────┘
                          │ beforeSwap
                          ▼
        ┌─────────────────────────────────────┐
        │            AegisHook                │
        │                                     │
        │  1. checkpoint price (first swap    │
        │     of the block)                   │
        │  2. breaker: |Δprice| , volume,     │
        │     Chainlink cross-check           │
        │     └─ trip ⇒ revert + cooldown     │
        │  3. MEV tax: fee = f(priorityFee)   │
        │     └─ return OVERRIDE_FEE_FLAG     │
        └─────────────────┬───────────────────┘
                          │ afterSwap
                          ▼
                  FirewallEvent(...)
                          │
                          ▼
              subgraph ──▶ MCP server ──▶ agent
```

## Also live on Arc (Circle)

Arc has no Uniswap v4 deployment, so Aegis
[brought one](https://docs.arc.io): PoolManager `0x94f5CB26…3Fc7` and hook `0x84e19075…2AC0` on
chain 5042002, configured for a stablecoin pair — 0.05% base fee, a 50-tick breaker, JIT lockup on.

**The port found a bug.** Arc runs a flat 20 gwei base fee and its *median* transaction bids
10 gwei of priority (sampled: 666 txs over 40 blocks). Charging the raw priority fee — what the
Unichain deployment did — taxes that median swap to the ceiling, making every ordinary trade pay
the maximum. The tax is meant to price the *excess* a searcher pays to win ordering, and on a chain
with an ambient tip that excess is not the whole priority fee. `mevTaxFloorGwei` fixes it; a floor
of 0 reproduces the old behaviour, so Unichain is unchanged.

Verified on the live Arc pool: a swap at Arc's median 10 gwei pays **zero** tax, and one bidding
26 gwei — a single gwei above the floor — pays exactly **10,000** units. See
[DEPLOYING.md](./DEPLOYING.md).

## Console

An interactive page for the deployed pool:
[claude.ai/code/artifact/d54a8daf](https://claude.ai/code/artifact/d54a8daf-da30-4715-b22c-b87297336fb9).

The fee simulator is genuinely live — it runs the contract's real formula in the browser, so you
can drag a searcher's bid and watch the fee it buys them, with the two on-chain-verified points
marked. Contract state is a labelled snapshot rather than a fake ticker: a published page cannot
reach an RPC, and pretending otherwise would be the sort of theatre this project exists to avoid.

## Watchtower — the agent layer

[`WATCHTOWER.md`](./WATCHTOWER.md). A subgraph, a calibration engine and an MCP server.

The calibration engine closes a gap this project openly had. The breaker's bound trades safety
against liveness, and "per-pool calibration" was the answer without any account of *how*. The
engine replays the hook's checkpoint logic over a real pool's swap history and derives the bound
from the observed distribution of honest intra-block excursions.

Applied to the busiest live v4 pools on Unichain mainnet, honest blocks move by **single-digit
ticks**, with a worst observed excursion of 39 ticks (0.39%) — which means **this project's own
default of 500 ticks is 2.5x to 5x looser than any of those pools need**. The placeholder was
wrong in the safe direction, and there is now a measurement to replace it with.

## Where the Uniswap integration lives

Judges asked to verify the integration should start here. Line numbers are current as of the
latest commit.

| What | Where |
|---|---|
| Hook permissions declared, asserted against the address bits | [`src/AegisHook.sol:163`](./src/AegisHook.sol#L163) |
| `beforeInitialize` — rejects pools not using dynamic fees | [`src/AegisHook.sol:246`](./src/AegisHook.sol#L246) |
| `beforeSwap` — MEV tax, block checkpoint, volume ceiling | [`src/AegisHook.sol:251`](./src/AegisHook.sol#L251) |
| `afterSwap` — tick deviation bound, enforced by reverting | [`src/AegisHook.sol:293`](./src/AegisHook.sol#L293) |
| `beforeRemoveLiquidity` — JIT defense via minimum position age | [`src/AegisHook.sol:334`](./src/AegisHook.sol#L334) |
| The fee formula itself | [`src/AegisHook.sol:408`](./src/AegisHook.sol#L408) |
| Oracle cross-check, fail-open | [`src/AegisHook.sol:444`](./src/AegisHook.sol#L444) |
| Our own `BaseHook` (v4-periphery removed theirs) | [`src/base/BaseHook.sol:46`](./src/base/BaseHook.sol#L46) |
| CREATE2 salt mining, shared by script and tests | [`script/AegisDeploy.sol:44`](./script/AegisDeploy.sol#L44) |
| Chainlink answer → v4 tick conversion | [`src/libraries/OracleReference.sol:76`](./src/libraries/OracleReference.sol#L76) |

**Uniswap components used:** `IHooks`, `Hooks` (permission bits and validation), `LPFeeLibrary`
(`DYNAMIC_FEE_FLAG`, `OVERRIDE_FEE_FLAG`), `StateLibrary.getSlot0`, `TickMath`, `FullMath`,
`PoolKey`/`PoolId`, `BeforeSwapDelta`, and v4-core's `Deployers` test fixtures. `HookMiner` from
v4-periphery.

Developer feedback on building against the stack: [FEEDBACK.md](./FEEDBACK.md).

## Prize tracks targeted

| Sponsor | Track | How Aegis qualifies |
|---|---|---|
| Uniswap Foundation | Best Uniswap Stack Contribution | The hook, the reusable attack-lab harness, and [FEEDBACK.md](./FEEDBACK.md) |
| The Graph | Best AI Tooling (from scratch) | Aegis subgraph + Uniswap's v4 subgraph as the agent's source of blockchain data; the calibration recommendation is derived from indexed history |
| Arc (Circle) | Launch on Arc Testnet | First v4 deployment on Arc — PoolManager brought along, hook on top |

**Not claiming Chainlink.** The oracle guard uses Chainlink Data Feeds, but every Chainlink track
at this event requires a CRE Confidential Workflow with a TEE handler, which is a different
product entirely. The guard is in the repo because the threat model needed it, not because it wins
anything — and saying so beats a judge working it out.

## Three defenses, three regimes

Worth being precise about, because it would be easy to oversell. None of the three subsumes
another.

| Attack shape | What stops it | Why the others cannot |
|---|---|---|
| Ordinary sandwich | **MEV tax** | The move stays inside the tick bound, and the breaker correctly lets it through — blocking it would block honest trades of the same size |
| Single-block manipulation | **Circuit breaker** | No fee deters someone whose real profit is in a lending market elsewhere; a bound is not a price, and cannot be outbid |
| Manipulation walked across many blocks | **Oracle reference** | The breaker re-anchors its checkpoint every block, so a slow walk never violates it — by construction, not by oversight |

The third is the one most hook designs miss. `test_multiBlockWalkSucceedsWithoutAnOracle` shows
the gap: six blocks of legal moves carry the price -2261 ticks past a breaker that never fires.
`test_oracleStopsTheMultiBlockWalk` shows it closed.

## Live on Unichain Sepolia

`AegisHook` is deployed at
[`0x295DB25bC9aE00ddC51C875F0FeC16a406a9eAc0`](https://sepolia.uniscan.xyz/address/0x295DB25bC9aE00ddC51C875F0FeC16a406a9eAc0)
against the real v4 PoolManager, with the permission bits `0x2AC0` encoded in its own address.

**The tax works onchain, not just in tests.** Two swaps against the same live pool, differing
only in what the sender bid for block position:

| Trader | Priority bid | Fee charged |
|---|---|---|
| Honest user | ~0 | **3,000** (0.30%) — base fee only |
| Searcher | 2 gwei | **23,000** (2.30%) |

Transaction
[`0x0c3730a4…8aff`](https://sepolia.uniscan.xyz/tx/0x0c3730a435bcd0adc15f401777aa2ecd3d55086ae2d0fb83bea737daeaaa8aff)
emitted `MevTaxApplied(priorityFeeWei: 2000000000, feeCharged: 23000, taxUnits: 20000)`.
7.7x the fee, set by the searcher's own bid, paid to the LPs.

Reproduce it with [`script/DemoSwap.s.sol`](./script/DemoSwap.s.sol) at any `--priority-gas-price`.

> Note for anyone verifying: Unichain Sepolia runs with `baseFeePerGas = 0`, so `priorityFee()`
> there is the whole gas price rather than the usual difference. The mechanism is unaffected, but
> it is worth knowing before reading the numbers.

See [DEPLOYING.md](./DEPLOYING.md).

## Status

46 tests passing. Three attacks benchmarked against a control pool, the hook live on two chains,
and the deploy path verified against real Uniswap v4 deployments rather than only a local mock.
See [ROADMAP.md](./ROADMAP.md).

## Build

```bash
forge build
forge test --no-match-path 'test/fork/*'     # 37 tests
forge test --match-contract SandwichTest -vv # the benchmark
forge test --match-path 'test/fork/*' -vv    # against live v4 on Unichain Sepolia
```

## Deploy

See [DEPLOYING.md](./DEPLOYING.md). Short version: v4 reads a hook's permissions from its own
address, so deployment means mining a CREATE2 salt until the address bits match what the contract
claims. The mining lives in a library that the deploy script and the tests both call, so the
tested path is the deployed path.

```bash
forge script script/DeployAegis.s.sol --rpc-url unichain_sepolia   # dry run, no key needed
```

## License

MIT

## Prior art and attribution

Being explicit about what is borrowed and what is not.

**The MEV tax is not an original idea.** It comes from
[*Priority Is All You Need*](https://www.paradigm.xyz/2024/06/priority-is-all-you-need) by Dan
Robinson and Dave White (Paradigm). The insight that a searcher's priority-fee bid, under
priority ordering, is a truthful self-reported lower bound on the MEV they expect — and can
therefore be charged against — is theirs. Aegis implements it as a v4 hook and measures it.

**Circuit breakers and per-block rate limits** are a long-standing DeFi security pattern, not
something invented here. Likewise **minimum position age as a JIT-liquidity mitigation** has been
proposed before.

**What this project contributes:**

- The **attack lab** — a reusable control-pool harness that runs working attacker contracts
  against a protected and an unprotected pool and reports attacker PnL for both. The measurement
  methodology is the contribution; a defense that is not measured against a control is a claim.
- **Numbers** for these mechanisms that had not been published: a sandwich going from +0.068972
  to -0.230778 token0, and a single-block price manipulation from -48.9% to a bounded -4.9%.
- The observation that the breaker **cannot latch**: deviation is only visible in `afterSwap`, and
  reverting there unwinds the flag write too, so reverting must *be* the defense rather than the
  trigger for one. Implementations that write a "tripped" flag on that path do not work.
- The **composition** — MEV tax, circuit breaker and JIT age in one hook, with an explicit
  argument for which attack regime each one covers and where each is useless.

**Dependencies:** Uniswap `v4-core` and `v4-periphery`, `forge-std`, `solmate`, tracked as git
submodules. All 1,828 lines under `src/`, `test/` and `script/` were written for this hackathon.

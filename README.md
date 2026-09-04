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

## Prize tracks targeted

| Sponsor | Track | How Aegis qualifies |
|---|---|---|
| Uniswap Foundation | Best Uniswap Stack Contribution | The hook itself + the reusable attack-lab harness |
| The Graph | Best AI Tooling (from scratch) | Subgraph → MCP server → agent that reasons over live pool threat state |
| Chainlink | Best Confidential Workflow / Automated Protection | Feed as breaker reference; Automation for cooldown reset |
| Arc (Circle) | Best DeFi + Launch on Arc Testnet | Secondary deployment |

## Two defenses, two regimes

Worth being precise about, because it is easy to oversell:

- At **ordinary sandwich sizes** the frontrun stays well inside the tick bound, and the
  breaker correctly lets it through. The MEV tax is what makes the attack unprofitable.
- The **breaker** exists for the move the tax cannot price — a swap large enough to be an
  attack on the pool itself rather than on one victim. Nothing in v4 bounds how far a single
  block may move a price; this does.

Neither mechanism subsumes the other, and claiming either one alone is sufficient would be
wrong.

## Live on Unichain Sepolia

`AegisHook` is deployed at
[`0x99c92c4eF032a15E2a6f0BfeBA276666148AeAc0`](https://sepolia.uniscan.xyz/address/0x99c92c4eF032a15E2a6f0BfeBA276666148AeAc0)
against the real v4 PoolManager, with the permission bits `0x2AC0` encoded in its own address.
See [DEPLOYING.md](./DEPLOYING.md).

## Status

Day 2 of 10, roadmap through Day 7 largely complete. 37 tests passing, three attacks
benchmarked against a control pool, and the deploy path verified against the real Uniswap v4
deployment on Unichain Sepolia — not just against a local mock.
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

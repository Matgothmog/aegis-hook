# Inspirations, sources and prior art

Everything Aegis draws on, so the line between borrowed and built stays visible. Kept separate
from the README's short attribution section because this is the working record, not the pitch.

---

## 1. The core mechanism — not ours

### MEV tax (priority-fee-proportional swap fee)

**[Priority Is All You Need](https://www.paradigm.xyz/2024/06/priority-is-all-you-need)** —
Dan Robinson, Dave White (Paradigm), June 2024.

The load-bearing idea of this project and **not an original contribution**. Under priority-fee
ordering, a searcher who wants to win an ordering race must outbid rivals, and that bid is a
truthful, self-reported lower bound on the MEV they expect to extract. An application can read it
and charge proportionally, capturing the surplus for itself instead of the block builder.

Aegis implements this as a Uniswap v4 hook and measures whether it actually deters attacks.
Cite this paper before anyone asks.

### Priority ordering as a precondition

**[Rollup-Boost is live on Unichain](https://blog.uniswap.org/rollup-boost-is-live-on-unichain)** —
Uniswap, on priority ordering enforced inside a TEE with verifiable attestations, plus fast
blocks. This is what makes the MEV tax honest on Unichain specifically, and why it is the primary
deploy target. Verified: the mechanism executes anywhere, but the *economic* argument depends on
this ordering rule.

### Related dynamic-fee work

- **[Arrakis Pro Hook](https://arrakis.finance/blog/the-arrakis-pro-hook-dynamic-fees-for-token-issuers-on-uniswap-v4)** —
  dynamic fees on v4 to protect LPs from arbitrage MEV. Different trigger (volatility rather than
  priority fee), same family.
- **[The AMM Renaissance: Dynamic Fees and MEV Auctions](https://arrakis.finance/blog/the-amm-renaissance-how-mev-auctions-and-dynamic-fees-prevent-lvr)** —
  survey of how dynamic fees and MEV auctions address LVR.

---

## 2. The attacks — existing literature

### Sandwich attacks / MEV as a field

**Flash Boys 2.0** — Daian, Goldfeder, Kell, Li, Zhao, Bentov, Breidenbach, Juels (2019). The
paper that formalised frontrunning, priority gas auctions and MEV on Ethereum.

### LVR — Loss Versus Rebalancing

**Milionis, Moallemi, Roughgarden, Zhang.** The formal account of why passive LPs systematically
lose to arbitrageurs. Background for *why* a pool would want to capture this value rather than
leak it; Aegis does not attempt to solve LVR directly.

### JIT (just-in-time) liquidity

A known extractive strategy: supply concentrated liquidity immediately before a large swap, take
the fee, withdraw in the same block, carrying essentially no price risk. **Minimum position age as
a mitigation has been proposed before** and is not original here.

### Oracle manipulation via flash loans

The attack class the circuit breaker exists for, established by real incidents — bZx (2020),
Harvest Finance (2020), Mango Markets (2022). All share the same shape: borrow, move a pool price
inside one block, exploit a contract that reads that price, repay.

---

## 3. Defensive patterns — existing

### Circuit breakers / rate limits

A long-standing DeFi pattern, not invented here. Related: **ERC-7265** (circuit breaker standard
proposal), and guardian-pause roles as used by Aave and Compound. Aegis's contribution is only
the specific form — a per-block tick-deviation bound enforced inside a v4 hook — and the
observation about why it cannot latch.

### Bounded admin authority

Standard security practice: hard-coded limits an admin cannot exceed, no custody of user funds,
and withdrawals that stay open while trading is halted so a pause cannot become a hostage
mechanism.

---

## 4. Uniswap v4 — the platform

- **[v4 hooks documentation](https://docs.uniswap.org/contracts/v4/concepts/dynamic-fees)** —
  dynamic fees, the `OVERRIDE_FEE_FLAG` mechanism.
- **v4-core source**, read directly rather than via tutorials, because the API has moved:
  - `libraries/Hooks.sol` — permission flags encoded in the hook address, `validateHookPermissions`
  - `libraries/LPFeeLibrary.sol` — `DYNAMIC_FEE_FLAG` (0x800000), `OVERRIDE_FEE_FLAG` (0x400000)
  - `libraries/StateLibrary.sol` — `getSlot0`
  - `libraries/Position.sol` — `calculatePositionKey`, which Aegis's position key deliberately mirrors
  - `test/utils/Deployers.sol` — the fixture the test suite builds on
- **v4-periphery source**:
  - `test/shared/HookMiner.sol` — CREATE2 salt search. Used as-is.
  - **Note:** `BaseHook` was *removed* from v4-periphery (absent as of the Aug 2026 revision
    pinned here). Aegis carries its own re-implementation in `src/base/BaseHook.sol`. The
    `IHooks` signatures it implements are dictated by v4, not designed by us.
- **Uniswap v3 whitepaper** — tick math (`tick = log₁.₀₀₀₁(price)`), concentrated liquidity. The
  reason a tick delta is a clean percentage bound.

---

## 5. Tooling and infrastructure

- **Foundry** (`forge`, `cast`, `anvil`) — build, test, fuzz, script, fork.
- **Deterministic deployment proxy** at `0x4e59b44847b379578588920cA78FbF26c0B4956C` (Arachnid's
  `deterministic-deployment-proxy`), present at the same address on every EVM chain. Required
  because a v4 hook's address must be mined.
- **solmate** — `MockERC20` for tests and the demo pool.

---

## 6. What is actually ours

Stated plainly so it can be defended under questioning:

1. **The attack lab.** A control-pool harness that runs working attacker contracts against a
   protected and an unprotected pool on the same PoolManager and reports attacker PnL for both.
   The methodology is the contribution — a defense not measured against a control is a claim, not
   a result. It caught a genuine bug in its own first version (a backrun unwinding the attacker's
   entire balance rather than the frontrun's gain, reporting an implausible +506 token0).
2. **The measurements.** Sandwich +0.068972 → -0.230778 token0. JIT +0.015184 → withdrawal
   reverts. Single-block manipulation -6713 ticks (-48.9%) → bounded at -4.9%. And the honesty
   check: -20.2% still reachable across six blocks, proving the breaker bounds velocity rather
   than pinning price.
3. **The non-latching analysis.** Deviation is only observable in `afterSwap`; a revert there
   unwinds the storage write too, so a "tripped" flag set on the offending path can never
   persist. Reverting must *be* the defense rather than the trigger for one. Implementations that
   write a latch on that path are broken.
4. **Tick-space bounds** rather than sqrt-price comparison — exact, cheap, and free of the
   overflow risk that squaring `sqrtPriceX96` carries at extremes.
5. **The composition argument** — which of the three defenses covers which attack regime, and
   explicitly where each is useless on its own.

---

## 7. Hackathon context

**ETHOnline 2026**, $80,000 across 11 sponsors. Uniswap Foundation's "Best Uniswap Stack
Contribution" is $5,000 total ($3,000 across up to 3 teams), which is why the project is built to
also qualify for The Graph, Chainlink and Arc rather than for the Uniswap track alone.

---

## 8. Things verified rather than assumed

Recorded because each was wrong or surprising on first look:

- `0x1F98400000000000000000000000000000000004` is widely cited as the Unichain PoolManager. It is
  the **mainnet** address and has **no code** on Unichain Sepolia. The Sepolia address is
  `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`, confirmed to have 48,021 bytes of code.
- `BaseHook` no longer exists in v4-periphery. Most tutorials are stale on this.
- Aegis's position key matches v4-core's own `calculatePositionKey` tuple — an earlier note
  calling this a defect was wrong and was retracted.
- **Unichain Sepolia runs `baseFeePerGas = 0`**, so `priorityFee()` there is the entire gas price
  rather than the usual difference. Does not affect the mechanism; does affect reading the numbers.
- Reading contract state immediately after a broadcast can hit a node that has not caught up and
  return a stale zero — which briefly looked like the MEV tax had failed when it had not.

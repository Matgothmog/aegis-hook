# Developer feedback on the Uniswap stack

Written while building [Aegis](./README.md), a v4 security hook, from an empty directory. Every
item below is friction that actually cost time, with the file and line that caused it — not
general impressions.

Context: solo developer, prior Solidity experience, no prior v4 experience.

---

## 1. `BaseHook` was removed from v4-periphery, and every tutorial still uses it

**The single biggest time sink.**

Essentially all v4 hook material — official docs, the v4-template, blog posts, conference talks —
starts with `contract MyHook is BaseHook`. As of the current v4-periphery `main`
(`dce236d`, Aug 2026), `src/` contains no `BaseHook.sol`:

```
lib/v4-periphery/src/
├── base/          BaseActionsRouter, DeltaResolver, SafeCallback, ImmutableState, …
├── hooks/         permissionedPools/ only
├── interfaces/  lens/  libraries/
└── PositionManager.sol  PositionDescriptor.sol  V4Router.sol
```

The first twenty minutes went into believing the import path was wrong. There is no deprecation
note, no stub that reverts with a pointer, and no mention in the README.

**Suggestion:** either keep a `BaseHook.sol` that is a thin re-export, or add a line to the
v4-periphery README saying where it went and what to use instead. A one-line grave marker would
have saved the time entirely.

We ended up writing our own ([`src/base/BaseHook.sol`](./src/base/BaseHook.sol), 131 lines). For a
security project that turned out to be the better outcome — the whole trusted surface is in-repo —
but it should have been a deliberate choice rather than a forced one.

## 2. `HookMiner` lives in `test/`, but it is production deployment code

[`lib/v4-periphery/test/shared/HookMiner.sol`](https://github.com/Uniswap/v4-periphery/blob/main/test/shared/HookMiner.sol)
is required by *every* real hook deployment — v4 reads permissions from the hook's address, so a
CREATE2 salt must be mined. Importing from a dependency's `test/` directory into a production
deploy script feels wrong, and some build setups exclude `test/` from dependency resolution.

**Suggestion:** move it to `src/utils/HookMiner.sol`. It is not test scaffolding; it is the only
supported way to deploy a hook.

## 3. Address-encoded permissions make the deploy path the least-tested part of a hook

This is a consequence of the design rather than a defect, but it deserves a documented warning.

The idiomatic test setup uses `deployCodeTo(...)` to *etch* a hook at a chosen address. That
bypasses CREATE2 entirely — so a project can have a comprehensive test suite in which **address
derivation, the part most likely to fail, is never exercised**. We had 21 passing tests before
noticing that nothing covered deployment.

**Suggestion:** the hook-deployment docs would benefit from an explicit "your tests do not cover
this" callout, and the v4-template could ship a deployment test alongside its behavioural ones.

## 4. `Position.calculatePositionKey` uses the router as `owner`, which surprises hook authors

[`Position.calculatePositionKey(owner, tickLower, tickUpper, salt)`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Position.sol#L48)
takes `owner` as whoever called `modifyLiquidity` — under v4 that is the router, not the end user.
A hook wanting per-position state (ours enforces a minimum position age against JIT liquidity)
naturally reaches for `sender`, and gets the router.

It is correct — uniqueness comes from `salt`, which PositionManager derives from the NFT id — but
the naming invites the wrong mental model, and a hook paired with a router that reuses salts would
have a real collision.

**Suggestion:** a note in the hook docs that `sender` in liquidity callbacks is the router, and
that per-user state must key on `salt`.

## 5. Events emitted before a revert are silently lost, which affects hook observability more than most contracts

Not a Uniswap defect — it is EVM semantics — but hooks hit it harder than ordinary contracts,
because **a hook's primary action is to refuse**. We shipped a `SwapRejected` event and only later
realised every emit sat immediately before a `revert` and could never appear on-chain. Our own
subgraph was configured to index an event that would never fire.

The consequence is architectural: a hook that defends by reverting **cannot** expose its
rejections as events. They are observable only as failed transactions, which subgraphs do not
index.

**Suggestion:** worth a paragraph in the hooks documentation. Anyone building monitoring around a
defensive hook will hit this, and the natural design is the wrong one.

## 6. `poolConfig`-style struct getters hit stack-too-deep quickly

A `public mapping(PoolId => Struct)` with nine fields generates a nine-element tuple getter. A
script that reads it and writes most fields back overflows the stack without `via_ir`:

```
Error: Compiler error (LValue.cpp:51): Stack too deep.
```

Solved by adding an explicit `getPoolConfig(PoolId) returns (PoolConfig memory)`. Obvious in
hindsight; not obvious at the time, and the error names no useful location.

**Suggestion:** if hook examples used a struct-returning view rather than relying on the
autogenerated getter, downstream tooling would inherit the better pattern.

## 7. Documentation addresses conflate mainnet and testnet

Searching for the Unichain PoolManager address returns
`0x1F98400000000000000000000000000000000004` from many sources. That is the **mainnet**
deployment; it has no code on Unichain Sepolia, where the address is
`0x00B036B58a818B1BC34d502D3fE730Db729e62AC`.

Deploying against the wrong one produces an opaque CREATE2 failure, not a useful error. Our
deploy library now checks for code and reverts with `PoolManagerHasNoCode` — a guard that only
exists because we got this wrong first.

**Suggestion:** the deployments page is correct; the problem is that search results are not. Not
much Uniswap can do directly, but per-chain address pages with the chain in the page title would
help.

---

## What was genuinely good

- **`Hooks.validateHookPermissions`** asserting the address matches the declared permissions, in
  the constructor, is excellent. It converts the single most dangerous class of hook
  misconfiguration into a failed deployment. More protocols should do this.
- **`LPFeeLibrary.OVERRIDE_FEE_FLAG`** makes per-swap dynamic fees genuinely simple once found —
  the entire MEV tax is one returned `uint24`.
- **`Deployers`** in v4-core's test utils removed most of the fixture work. Standing up two pools,
  one hooked and one vanilla, on a shared PoolManager took a handful of lines and made a
  control-group methodology practical.
- **Reverting from `afterSwap` to unwind a swap** is a powerful primitive, and the reason a
  circuit breaker is expressible at all.

---

*Filed alongside the Uniswap Developer Feedback Form for ETHOnline 2026.*
*Project: [github.com/Matgothmog/aegis-hook](https://github.com/Matgothmog/aegis-hook)*

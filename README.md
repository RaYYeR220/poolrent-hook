# PoolRent

[![CI](https://github.com/RaYYeR220/poolrent-hook/actions/workflows/ci.yml/badge.svg)](https://github.com/RaYYeR220/poolrent-hook/actions/workflows/ci.yml)

**The right to set a pool's fee is auctioned. The rent goes to the people who supply the liquidity.**

A Uniswap v4 hook. Arbitrageurs already compete for the first trade against a stale pool price — they
just settle that competition in the block builder's fee market, and liquidity providers never see the
money. PoolRent moves that auction on-chain and points the proceeds at the LPs instead.

Anyone can post a WETH deposit and bid a per-block rent for the right to manage the canonical pool.
The winner sets the pool's LP fee inside immutable bounds and earns half of a fixed 20 bps volume
charge. Rent accrues every block, is deducted from the deposit, and is donated straight to in-range
liquidity providers. A challenger must beat the standing rent by at least 10%, and only after the
incumbent's minimum tenure. When a deposit runs dry the manager is evicted in constant time and the
pool falls back to its default fee.

Taking the seat costs one block of rent up front, and a manager earns no share of the volume charge
in the block it took the seat — otherwise a searcher could grab a vacant seat, collect the manager
half of a swap it front-ran, and withdraw its whole deposit before a single block had elapsed.

The manager therefore has a reason to price the pool well — its own revenue tracks volume — and a
reason to bid what the pool's flow is actually worth, because that bid is what it pays the LPs.

## Why this needs v4

The mechanism is three things that only a hook can do atomically, on the pool itself:

1. **Return a per-swap LP fee** chosen by the current auction winner, via `beforeSwap` with the
   dynamic-fee override flag. A router cannot do this — traders would simply route around it.
2. **Charge a volume fee on executed gross quote-side volume** across all four swap quadrants using
   before/after return deltas, so the charge is measured on what the pool actually executed rather
   than on what the trader requested.
3. **Pay the rent to liquidity providers with `PoolManager.donate`**, in the same transaction as the
   swap, proportionally to in-range liquidity, with no registry of LPs and no custody of positions.

None of it is expressible as an LP fee, a transfer tax, or a router charge.

## Architecture

| Contract | Role |
| --- | --- |
| `src/PoolRentHook.sol` | Pool admission, the rent auction, the LP-fee override, volume-fee accounting and claims, rent donation |
| `src/PoolRentLauncher.sol` | One-shot atomic launch: deploy token → deploy the permission-mined hook → initialise the pool → seed full-range liquidity → settle |
| `src/PoolRentToken.sol` | Immutable fixed-supply ERC-20 |
| `src/libraries/PoolRentMath.sol` | Rounding-explicit fee arithmetic |

Hook permissions: `beforeInitialize`, `afterInitialize`, `beforeSwap`, `beforeSwapReturnDelta`,
`afterSwap`, `afterSwapReturnDelta` — mask `0x30CC`. The other eight bits are off.

### Pool binding

Every launch-defining field — both currencies, the tick spacing, the dynamic-fee flag and the
initial `sqrtPriceX96` — is a constructor immutable, so it sits inside the hook's CREATE2 preimage.
`beforeInitialize` recomputes the expected `PoolId` and rejects anything else, and rejects a second
initialization outright. A third party cannot bind this hook to a pool of their choosing, and the
custodied balances can never be stranded behind a re-bound key.

### Fee layers

Two charges that are deliberately kept separate:

- **LP fee** — variable, chosen by the manager inside `[1 bp, 200 bps]`, applied as a per-swap
  override, paid entirely to liquidity providers. The hook never takes a share of it.
- **Volume fee** — fixed at 20 bps of executed gross quote-side volume. Exactly 10 bps accrues to an
  immutable owner set at construction; the other 10 bps accrues to the current manager. With no
  manager — or in the block a manager took the seat — the manager half is donated to liquidity
  providers rather than left unowned.

Exact-input legs round the charge down; exact-output legs gross it up. A charge can never consume the
whole executed amount. Partial fills on the two quadrants charged in `beforeSwap` are rejected rather
than charged against volume the pool never executed.

### Solvency

```
WETH.balanceOf(hook) >= totalDeposits + pendingRent + totalFeeOwed
```

Three disjoint liability namespaces — auction deposits, rent owed to liquidity providers, and
claimable fee liabilities — never netted against each other. `isSolvent()` exposes the check and the
invariant suite asserts it after every generated sequence.

### Authority

There is no admin, owner, guardian, oracle, keeper, upgrade path, pause, rescue, mint, blacklist or
sweep anywhere in the system. The manager is a rotating, permissionless role: it can set the LP fee
within immutable bounds and claim its own accrued liability, and that is all. It cannot pause the
pool, block an exit, touch another account's deposit, or reach the immutable owner's liability.
Deposits are always withdrawable by their owner, including by a manager, who is simply evicted in the
same call if the withdrawal drops it below its floor.

## Running it

```bash
git clone https://github.com/RaYYeR220/poolrent-hook
cd poolrent-hook
forge test
```

The pinned dependencies are checked in, so there is nothing to install and nothing to resolve — the
tree you clone is byte-for-byte the tree the tests and the evidence were produced from.

The mainnet-fork suites need an archive RPC and default to a public one, so they run with no key:

```bash
forge test --match-path test/Fork.t.sol            # pinned block + current head
MAINNET_RPC_URL=<your-rpc> forge test --match-path test/Fork.t.sol
```

`test/Fork.t.sol` runs the entire lifecycle — launch, all four swap quadrants, winning the auction,
setting a fee, rent accrual, donation, and the owner claim — against the real Ethereum mainnet
PoolManager at `0x000000000004444c5dc75cB358380D2e3dE08A90` and the real WETH9, both pinned to an
exact block and against the current head.

181 tests across nine suites: the launch and pool-admission checks, the lifecycle smoke tests, the
volume-fee policy, the rent auction and its authority boundaries, an adversarial suite (misbehaving
and reentrant quote tokens, foreign-PoolManager callbacks, nested-action settlement, and a full
reconstruction of hook state from emitted events alone), 22 fuzz properties at 1000 runs each,
9 stateful invariants at 256 runs and depth 64 (16,384 calls each, zero wei left unattributed), and
the two fork suites. Boundaries are asserted on both sides — the block a tenure becomes contestable,
the wei at which a deposit is too small, the percentage at which an outbid is accepted.

Build lock: solc `0.8.26`, EVM Cancun, optimizer on at 1000 runs, no viaIR, no bytecode metadata.
Dependencies are checked in at exact pinned revisions.

The deployed mainnet `PoolManager` this hook binds to was not taken on trust: it was recompiled from
the pinned `lib/v4-core` revision with the official `solc 0.8.26+commit.8a97fa7a` binary under
Uniswap's own build settings, and the runtime matches byte for byte once the single
`NoDelegateCall.original` immutable is substituted — 24,009 bytes, zero differences, identical
`keccak256`.

## Honest limits

- `donate` only reaches **in-range** liquidity. A provider whose position is out of range earns no
  rent while it is inactive. This is a deliberate consequence of paying rent the same way the pool
  pays fees, and it is tested.
- With zero in-range liquidity the donation is skipped and the rent stays in `pendingRent` until a
  swap can distribute it. Rent is never lost, and a swap never reverts because of it.
- The auction only means anything once the pool carries real arbitrage flow. On a cold pool there is
  simply no manager and it behaves as an ordinary dynamic-fee pool at the default fee.
- Per-swap directional rounding leaves bounded dust in the hook. It is covered by the solvency
  invariant and disclosed rather than swept.
- The rent auction assumes managers bid rationally against the flow they expect. It is a market, not
  a guarantee: a manager that overpays simply subsidises the liquidity providers.
- Nothing here is deployed, reviewed, or audited. This repository is a prototype submitted for review.

## License

MIT. See [LICENSE](LICENSE).

# On-chain prices, LP shares, ERG price history and arbitrage

Date: 2026-10-06
Branch: `roadmap/pricing`
Status: implemented on the branch (F1, F1 history, F2 with execution)

## What was asked

- **F1.** Token and LP-token prices from chain data. Tokens from their
  deepest trustworthy Spectrum pool above the existing depth floor; tokens
  without an ERG pool through one intermediate hop (token → SigUSD → ERG)
  when both pools pass the floor. LP tokens at their share of both
  reserves, the token side at the pool's own price, priced inside the
  pricer so every consumer gets them with no UI change. Unverified or
  shallow values stay out of totals. ERG → fiat stays with the source the
  user picked. Read only the user's node.
- **F1, history** (added mid-task). ERG's price over a window plus its
  24-hour change, following the Display-settings source: oracle-pool boxes
  or ERG/SigUSD pool boxes from the node, CoinGecko's market chart under
  the CoinGecko source. One service API, kept in memory, no extra polling,
  an explicit "unavailable" with a reason. Not wired into the home screen.
- **F2.** Arbitrage, opt-in from Discover, scanning only while open. For
  each opportunity: route, amount in, expected net ERG profit after pool
  fees, miner fees and minimum box values, above a user-set minimum. The
  user decided to **execute with safeguards**: rebuild every leg against
  fresh pool state immediately before signing; refuse below the minimum;
  show the whole chain and a plain risk note before signing; broadcast the
  legs together; if a later leg fails, say exactly what the wallet now
  holds and offer a one-tap sale of the stranded token back to ERG at a
  fresh quote, shown before signing.
- Build the core in Argus's own Rust, taking the better approach from
  Pantheon (`arkadianet/pantheon`, with `ergo-pricing` from
  `arkadianet/ergo-sdk`) or the vendored Citadel `amm` crate piece by
  piece, porting rather than depending. Move the pricing path to it. Leave
  swap and LP transaction building on the vendored crate for now.

## What the contracts actually enforce

Both implementations were checked against the deployed pool ErgoTrees
rather than against each other. Decoding them (`wallet-amm/src/contract.rs`,
pinned by a test on the encoded bytes) gives:

| Fact | Where in the tree |
|---|---|
| `FeeDenom = 1000`; numerator is the pool's own `R4: Int`, which the successor must repeat | N2T constant 8, T2T constant 10; `SELF.R4[Int].get` |
| Swap valid iff `reservesOut0·Δin·feeNum ≥ Δout·(reservesIn0·FeeDenom + Δin·feeNum)` | body |
| An N2T pool's ERG reserve is the whole box value | `reservesX0 = SELF.value` |
| An N2T successor must keep **`value > 10_000_000`** (strict) | constant 14 = Long 10 000 000 under `GT` |
| A T2T successor must keep `value ≥ SELF.value` (swaps never move its ERG) | `GE(OUTPUTS(0).value, SELF.value)` |
| LP supply = `0x7fffffffffffffff` − LP held by the pool | `InitiallyLockedLP` |

So the largest valid output for an input is the floor of the CFMM formula,
and the least input for a wanted output its ceiling. One transaction can
spend one pool box (`successor = OUTPUTS(0)`), so a k-leg cycle is k
transactions.

## Pantheon / ergo-pricing vs the vendored router

| | Vendored `amm` (router, arb, arb_chain, calculator) | Pantheon `amm-arb-bot` + `ergo-pricing` | Argus `wallet-amm` |
|---|---|---|---|
| Output formula | floor, BigInt | floor, BigInt (u128 checked in `amm_swap_output_checked`) | floor; u128 with BigUint fallback |
| Input for an output | `floor + 1`: overpays by one unit when the division is exact | true ceiling | true ceiling (tested at the contract boundary both ways) |
| N2T ERG floor | `pool − out ≥ 1_000_000`: **accepts swaps the contract rejects** (the contract needs > 10 000 000) | builder `new_pool ≥ 1_000_000`, scanner no check: same bug | `pool − out > 10_000_000`, in quotes and reverse quotes |
| N2T reserve | full box value (correct) | quotes use full value; `ergo-pricing` pricing/LP use `value − min_box` ("tradable") | full value for swaps; LP value uses full reserves (what redemption pays) |
| Box without R4 | assumes fee 997 (would price an unspendable box) | assumes 997 | refused: the contract reads R4 with `.get` |
| Junk boxes / odd fees | parse anything with 3/4 tokens | same; `PoolIndex::build` **fails the whole index** on a duplicated LP id, which anyone holding one LP unit can cause | fee must be 1..=1000, sides distinct, N2T above the floor; duplicate LP ids resolved to the box that locks the most |
| Miner fee | per hop, constant | per hop from config, but the builder hardcodes `TX_FEE_NANO` | miner fee **and the Argus app fee** per leg; box minimums counted as capital, not cost |
| Cycle search | DFS from ERG, no pool or token twice, ≤ 3 pools per pair | identical | same rules, recursive with backtracking |
| Sizing | ternary search over `[0.01 ERG, min(reserve, 1000 ERG)]`, then reverse-tighten | identical | closed form: a chain of swaps is one fractional-linear curve `a·x/(c·x+1)`, so the optimum is `(√a−1)/c` and the best possible profit `(√a−1)²/c` (a free filter); then the exact integer stairs around it, each trimmed to its least input. A ternary search on a two-decimal token is misled by stairs tens of millions of nanoERG wide. |
| One pool per tx | builds sequential legs; ids known before signing (`derive_output_boxes`) | sequential legs; patches ids after signing each leg; "piggyback ERG" for later legs' fees | sequential legs with ids known before signing (whole chain reviewed and signed up front); later legs may only take the token from the previous leg's output |
| Mid-chain failure | none | rebuilds the remaining hops at whatever the pools now pay (no profit check), checkpoints, retries | stop, say what is held, offer the sale back at a fresh quote |
| Mempool | none | skips pools whose box is in flight; chained-input race retry | skips busy pools in the scan, re-checks them before signing; chained-input race retry |
| Pricing | none in the router | spot from deepest N2T pool; up to 3-hop BFS path to ERG; LP = 2·tradable ERG (N2T) or both sides at outside prices (T2T) | deepest N2T above the floor; exactly one hop, both pools above the floor; LP = 2·ERG side (N2T) or 2·the smaller priced side (T2T), trust flags |
| Tests | 38 router + 10 arb_chain + 18 calculator | 45 bot + 86 ergo-pricing | 50 `wallet-amm` + 12 FFI + Dart |

### What was taken from where

- **From the vendored crate**: full-box-value reserves; the cycle rules and
  per-pair cap; ids derived before signing so the whole chain is reviewed
  and signed at once; the direct-swap transaction builder itself (used,
  not ported, per the brief).
- **From Pantheon / ergo-pricing**: true-ceiling inverse; u128 fast path;
  busy-pool skipping and the chained-input race retry; the "deepest pool
  above a floor" pricing selection; LP supply from locked LP.
- **New**: the contract's real ERG floor; refusing boxes without R4; the
  closed-form sizing and stair walk; app fee per leg; LP-id disambiguation;
  the one-hop rule with both pools held to the floor; T2T depth in ERG
  terms; stranded-token recovery.

Not taken: Pantheon's automatic mid-chain rebuild (it finishes a broken
chain at any price, which is a bot's choice, not a wallet's), ergo-pricing's
three-hop pricing paths (the brief asks for one hop), and its LP valuation
of T2T pools at outside prices (it counts the pool's own mispricing as value
a holder cannot redeem at that rate).

## Where the code lives

- `rust/crates/wallet-amm` — new crate. Pure: arithmetic over reserves,
  no network, no keys, no vendored crate, no ergo-lib (deps: `serde`,
  `num-bigint`). A separate crate rather than a module of `wallet-core`
  because `wallet-core` holds seeds and signing and depends on vendored
  crates; keeping market maths out of it keeps that crate's audit surface
  small, and a dependency-free crate is the base the later de-vendoring
  pass builds the transaction side on. Modules: `contract`, `pool`,
  `math`, `graph`, `pricing`, `arb`, `chain`.
- `wallet-ffi/src/api/pricing.rs`, `wallet-ffi/src/api/arbitrage.rs` — the
  FFI, as submodules of `crate::api`.
- `wallet-ffi/src/arbitrage_chain.rs` — building and checking a chain and
  the stranded-token sale. Outside the `api` tree on purpose: the bridge
  generator exposes `pub` structs it finds under `crate::api` even with
  restricted visibility.
- Dart: `services/token_pricing.dart`, `services/token_pricer.dart`,
  `services/erg_price_history.dart`, `services/arbitrage_service.dart`,
  `ui/arbitrage_screen.dart`, and the Discover entry.

## F1: prices

The pricer keeps its sources and its pool set (the disk-cached `amm_pools`
answer when under 15 minutes old, else a node refresh) and hands the pool
set to `pricingPoolPrices`. It adds no node request. Rust returns nanoERG per
base unit; Dart applies decimals and the ERG/USD rate.

1. Pegs, protocol rates and the oracle/CoinGecko majors win, as before.
2. LP shares next, then pool prices.
3. **Direct**: deepest N2T pool whose ERG side is ≥ 50 ERG.
4. **One hop**: a token with no direct pool above the floor (a shallow ERG
   pool counts as none) is priced through a T2T pool against a directly
   priced token, when that T2T pool's ERG-equivalent side is also ≥ 50 ERG.
   Deepest weaker pool wins. Labelled "Spectrum pools via SigUSD".
5. **LP**: `2 × ERG side / supply` for N2T; for T2T each side at its own
   token's price, the smaller side doubled. Depth floor on that side.
6. **Trust**: a price counts in totals only when every token it rests on is
   verified (`verified_tokens.dart`, cautioned tokens excluded): the token,
   the hop token, both LP sides.
7. Under the Spectrum source ERG/USD now comes from the SigUSD price in the
   same book, so it is held to the depth floor too.

Known limit: the pool set comes from the vendored discovery, which assumes
fee 997 for a box without R4; the arbitrage path reads boxes itself and
refuses those. None exist on mainnet today (all 549 parseable pool boxes
carry R4); the depth floor bounds the effect.

## F1: ERG price history

`TokenPricer.ergPriceHistory(PriceWindow window)` → `ErgPriceHistory`:

- `points` (oldest first, display currency per ERG), `change24hPct`,
  `sourceLabel`, `currency`, `approximateTimes`, `stale`,
  `unavailableReason` / `available`.
- `PriceWindow.day | week | month` (24h, 7d, 30d).

| Source | Data | Notes |
|---|---|---|
| Oracle pool | operator data-point boxes (`/blockchain/box/byTokenId/<oracle token>`), per-epoch median of ERG_USD, the aggregation the live price uses | `stale` when the newest epoch is older than the oracle's stale limit (the AVL oracle stopped posting ~22 days ago at the time of writing) |
| Spectrum pools | the deepest ERG/SigUSD pool's past boxes (the pool the price book used) | |
| CoinGecko | `coins/ergo/market_chart` in the display currency | the host that source already uses; nothing new for the others |

Node history is newest-first by offset. The first page (100 boxes) covers a
quiet pool's whole window; a busy feed is sampled: the box rate on the first
page places 12 small pages across the rest of the window plus one past its
start, so any window costs at most 14 requests. Heights become times at two
minutes a block. Answers are kept in memory for the pricer's refresh period
(5 min; 30 s for an unavailable answer), and nothing polls. A node without
the extra index, no node, or no history gives a reason instead of an error.
Node sources are converted at today's cross rate for non-USD currencies.

## F2: arbitrage

**Scan** (`arbitrage_scan`), only while the screen is open and in front,
paused while a review is open. The screen asks the node for its height
every 20 s (a few hundred bytes) and reads every pool again only when a
new block has arrived or the user pulls to refresh: a full read is about a
megabyte, and pools only move when a block lands. Every pool box is read
fresh from the user's node and parsed strictly; Dexy pools excluded; pools at least
50 ERG deep (T2T by their ERG-equivalent side); cycles of 2–3 legs; one
mempool read per pool contract to skip pools a pending transaction is
already spending. Routes through unverified tokens are left out unless the
user turns on "Include unverified tokens" (a failed leg there can strand a
token nobody buys). Each opportunity carries its legs, input, output, gross
and net profit, miner and Argus fees per leg, the box minimum in transit
(returned by the next leg, so capital not cost), the ERG needed, and the
estimated loss of selling the token straight back if the second leg fails.
Sizes are fitted to the wallet's balance when it is smaller.

**Prepare** (`arbitrage_prepare`): re-reads every pool on the route,
refuses if one is busy in the mempool, re-sizes, refuses below the minimum,
then builds each leg with the Swap screen's direct-swap builder. Leg 1 is
funded from ERG-only boxes covering the whole chain's capital; later legs
take the token only from the previous leg's payout box, so if a leg never
lands the next one is invalid instead of selling tokens the wallet already
held. Every chain is checked before it is shown: each leg pays exactly the
quoted amount, conserves ERG and every token, never pays the Citadel fee,
and the wallet's ERG across all legs moves by exactly the quoted net profit.

**Execute** (`arbitrage_execute`): immediately before signing, every pool
box is read again; if one changed or is busy, nothing is signed and the
screen prepares and shows a fresh review. Reviews older than 5 minutes are
refused. Otherwise every leg is signed through the normal signing path,
then the legs are broadcast back to back (a chained-input race is retried
briefly; a missing or double-spent pool box is final). Answers `submitted`,
`rejected` (nothing changed) or `stranded` with what the wallet holds.

**Follow and recover**: while open, `arbitrage_status` checks each leg
(mempool, then block); a leg that is in neither after the node accepted it
marks the chain stranded after the last good leg. `arbitrage_prepare_unwind`
quotes the stranded token against every pool as it is now and prepares its
sale from exactly the box the chain left it in, as an ordinary preparation
on the standard confirm sheet.

Chains live in memory only; after an app restart a stranded token is sold
from the Swap screen like any other holding.

## Privacy and safety decisions

- Pricing and arbitrage read only the user's node. CoinGecko is contacted
  for history only when it is already the price source.
- Nothing scans in the background; leaving the screen or the app stops it.
- The verified list decides what counts in totals and which arbitrage
  routes are shown by default.
- Arbitrage never signs what the user did not see; a moved pool means a new
  review, not a silent rebuild.

This supersedes the "out of scope: multi-hop routing, arb_chain" line of
`2026-08-23-amm-direct-swaps-design.md` for arbitrage only.

## What still depends on the vendored `amm` crate

For the later de-vendoring pass (`wallet-amm` replaces `router/*`,
`arb_chain`, and the pricing maths, none of which Argus calls any more):

1. Pool discovery and parsing: `api_amm_impl::load_pools`
   (`fetch::discover_n2t_pools` / `discover_t2t_pools`), behind
   `amm_pools` (the pricer's pool set, the Swap and Liquidity pickers),
   `amm_quote`, `amm_quote_exact_output`.
2. `api_amm_impl::fetch_pool` / `parse_pool_box` (`fetch::parse_n2t_pool`,
   `parse_t2t_pool`): swaps, LP, arbitrage freshness checks.
3. Quote helpers: `calculator::quote_swap`, `calculate_input`
   (`best_pool_for`, `best_pool_for_output`).
4. Swap building: `direct_swap::build_direct_swap_eip12(_with_held)`
   (Swap screen, buy-and-send, every arbitrage leg, the stranded-token
   sale).
5. LP and pool creation: `build_lp_deposit_eip12`, `build_lp_redeem_eip12`,
   `build_pool_bootstrap_eip12`, `build_pool_create_eip12`,
   `pool_setup::PoolSetupParams`.
6. Types at the FFI edge: `state::AmmPool`, `PoolType`, `SwapInput`,
   `TokenAmount`, `SwapQuote`.

Also still vendored around it: `ergo-node-client` (pool, mempool and
transaction-status reads), `ergo-tx` (EIP-12 types, output derivation,
the app-fee output), `citadel-core` (fee and box constants).

## Tests

- `wallet-amm`: contract facts pinned to the tree bytes; floor/ceiling on
  the contract boundary both ways, overflow paths; pool validation; graph
  and cycles; pricing rules (floor, hop, trust, LP, junk LP ids, order
  independence); sizing against brute force on fine and coarse tokens;
  fee and minimum accounting, wallet fitting, busy/untrusted skips,
  re-quote refusal; chain classification and exits.
- FFI: the pool JSON the app holds priced end to end; a built chain
  conserves ERG and tokens per leg and moves the wallet by exactly the
  quoted profit (Argus fee on every leg); refusal at minimum + 1; a wallet
  too small refused up front; a held token never sold by a later leg; a
  moved pool refused at re-quote; the stranded-leg sale spends exactly the
  stranded box at a fresh quote and conserves everything; a box without
  R4 is not a pool.
- Dart: pricing policy and LP shares, the pricer's Rust book and its
  failure, price history per source (real pool and oracle fixtures,
  sampling bounds, caching, degradation), the arbitrage service and
  scanner lifecycle, and the screen (warnings, review, watch-only,
  stranded recovery to the confirm sheet, background pause, 2× text).

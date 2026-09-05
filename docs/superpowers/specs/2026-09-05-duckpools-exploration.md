# Duckpools in Argus: exploration

Date: 2026-09-05
Status: exploration, nothing built. Sources: `duckpools/lend-protocol-contracts`,
`duckpools/off-chain-bot` (CC0), `duckpools/interest-contracts`,
`duckpools/logic-contracts`, `duckpools/duckpools-sdk`, and live boxes read
from the explorer on the date above.

## What Duckpools is

Pool lending on Ergo. Lenders deposit an asset into a pool and receive
*lend tokens* whose value in that asset rises as borrowers pay interest.
Borrowers lock collateral (ERG, priced through a Spectrum pool named in the
order) and draw the pool's asset against it; interest accrues through an
*interest box* that the pool and collateral contracts read as a data
input; off-chain bots liquidate when collateral falls to 125% of the debt
(140% for QUACKS).

## How a user transaction actually works

Nothing a user does spends the pool box directly. Every action is an
**order**: the wallet creates a *proxy box* under a per-pool, per-action
contract, and an **off-chain bot** (anyone can run one) spends it against
the pool, paying itself a small fee and the protocol its service fee.
This is the same shape as Spectrum's swap orders.

| Order | Proxy box the wallet builds | What the bot does |
|---|---|---|
| Lend | value = amount + 2 × 0.001 ERG + 0.001 fee; R4 = user's ErgoTree, R5 = minimum lend tokens, R6 = refund height | spends pool + proxy; outputs pool, service fee box, user box with lend tokens (R7 = proxy box id), bot fee |
| Withdraw | lend tokens + R4 user tree, R5 minimum asset out, R6 refund height | inverse |
| Borrow | collateral ERG; R4 user tree, R5 loan amount, R6 refund height, R7 (liquidation threshold, penalty), R8 Spectrum pool NFT used for pricing, R9 user public key | outputs pool, a *collateral box* holding the ERG and borrow tokens, and the loan to the user |
| Repay / partial repay | asset + collateral reference | releases collateral |

The proxy contracts pin the output layout by index (`OUTPUTS(0)` pool,
`OUTPUTS(1)` service fee, `OUTPUTS(2)` user), so an Argus app fee output
cannot ride on the bot's transaction; it can ride on the order-creating
transaction, which is an ordinary send.

**Refunds.** If no bot takes an order, the proxy contract allows a refund
to the user's own script after `R6` (the refund height, which the wallet
chooses; the bot fills orders it can and refunds ones it cannot). The
borrow proxy additionally allows `proveDlog(userPk)` at any time. A wallet
that creates orders must therefore also be able to build the refund
transaction, or a user whose order is never picked up has money stuck
until they find another tool.

## Live map, 2026-09-05

Eight pools are configured in the bot: ERG, SigUSD, QUACKS, SigRSV, RSN,
rsADA, SPF, rsBTC. Each has a pool NFT, a lend token, borrow tokens, a
parent and child interest box, and a parameter box; the identities are in
`off-chain-bot/consts.py`. Two the wallet would start with:

| Pool | Pool NFT | Lend token |
|---|---|---|
| ERG | `90290924d95d699f5852d54dd5c20d01a3c729b11e7ccb5444671f62bec3b4bc` | `fc888e0eed50a4042324793a7894134d83c7aaf5c99f4bf643e7e2b4e71e0095` |
| SigUSD | `6a5506ff2e12fe121686dfb5089b3576d0d921caba2eb68de99f7aa54c18d658` | `99fd3c29dd4485bcb9cabd3574a66435a8c699bef8783ce71bc3edbb7b39e4cd` |

The ERG pool box today holds 15,055 ERG with **nothing borrowed** (its
borrow tokens are all still in the box), so the lend rate is zero. Its
last transaction was 2026-08-12 (1,329 in its history). The pool is
solvent and used, but quiet: a lender entering now earns nothing until a
borrower appears.

## Pool arithmetic the wallet needs

From `lendPool.md`, all integer:

- lend tokens circulating = 9,000,000,001,000,000 − lend tokens in the pool box
- borrowed = 9,000,000,000,000,000 − borrow tokens in the pool box (v1; v2 values borrow tokens through the interest box's R5)
- lend token value = 10^15 × (pooled + borrowed) / circulating
- a deposit of `d` mints `floor(circulating × (pooled + d + borrowed) / (pooled + borrowed)) − circulating` tokens, and the contract requires the value per token not to fall
- **service fee** on the change in pooled assets: 1/160 up to 20 ERG, then 1/200 up to 200 ERG, then 1/250, minimum 0.001 ERG; token pools use their own two thresholds. Paid to the script in the parameter box's R8.
- bot fee 0.001 ERG plus the miner fee, taken from the order's value.

A lender's position is simply their lend-token balance times the current
value, which Argus can show without any order.

## What "native support" would be

1. **Positions, read-only.** Value the lend tokens a wallet already holds
   (they are ordinary tokens, already visible) with the pool formula, and
   show any open collateral boxes whose R4 is the wallet's script. No
   transactions, no bot dependency. Small.
2. **Lend and withdraw.** Build the two proxy orders, confirm them on the
   usual sheet, then watch for the bot's fill (the user box carries the
   proxy id in R7) or the refund, and build the refund ourselves after the
   height passes. Medium: two builders, a fixture-based test against the
   pool box, a live ignored test, an order tracker like the mix records.
3. **Borrow, repay, collateral top-up.** The borrow proxy needs the
   Spectrum pool NFT for pricing, the interest boxes for the quote, and a
   liquidation-risk display; repay needs the collateral box and the
   interest index. Larger, and the part where a wrong number costs money.

## Risks

- **Bot dependency.** Orders fill only while someone runs a bot; the
  quiet pool suggests few do. Argus must build refunds, and say so.
- **Version churn.** `interest-contracts` and `logic-contracts` (both
  Dec 2025) specify a v2 with a different interest oracle and pluggable
  collateral pricing; QUACKS already uses a "dex-weighted" logic contract.
  Pin per-pool contract versions by ErgoTree, the way Dexy and ZeroJoin
  are pinned, and treat the SDK as types only (it is).
- **No reference client.** The TypeScript SDK holds interfaces, not
  builders; the Python bot is the only working reference for the fill
  side, and the UI is not public. Every builder is written from the
  contract text and proven against live boxes, as with Dexy.
- **Fees.** The wallet cannot add its fee to the bot's transaction;
  only to the order transaction.

## Recommendation

Do step 1 now: it is safe, cheap, and makes lend tokens a user already
holds mean something in the wallet. Do step 2 as its own batch with the
same discipline as Dexy (fixtures from mainnet, live ignored tests that
reduce every input, refund path built and tested). Hold step 3 until the
v2 contracts settle and a pool shows real borrowing; today there is none
to quote against.

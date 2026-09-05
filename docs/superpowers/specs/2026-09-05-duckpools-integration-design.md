# Duckpools in Argus: integration plan

Date: 2026-09-05
Status: batch 1 in review (#74), batch 2 in review stacked on it. Follows `2026-09-05-duckpools-exploration.md`,
which found the protocol shape (proxy orders filled by off-chain bots), the
live pool map, the pool arithmetic and the fee tiers.

## Decisions

**Read what the wallet already holds first.** Lend tokens are ordinary
tokens already in the balance; valuing them with the pool formula needs
no transaction and no bot. Every later step builds on the same pool
reader.

**One protocol crate, pinned by identity, verified by fixtures.** As with
Dexy and ZeroJoin: `rust/crates/vendor/protocols/duckpools` holds the
eight pools' identities (pool NFT, lend token, borrow token, pool
currency, pool script), parses a pool box into typed state, and computes
the lend-token value. Every pool box is a fixture captured from mainnet
on the date above, and a live ignored test re-reads them.

**Pool state comes from the box under the pool script that carries the
pool NFT.** The NFTs were minted with more than one unit (the deployer's
token bag holds the rest), so "unspent box by token id" alone is not
enough; the script is the discriminator.

**Rates are shown as they are, not as promised.** Lend rate is derived
from utilisation the way the FAQ describes it (borrow rate × utilisation)
only once the interest model is read from the interest boxes, which is
batch 2. Batch 1 shows pooled, borrowed and utilisation, and marks the
rate as unknown rather than inventing one.

**Orders are the user's, refunds included.** When Argus creates a proxy
order (batch 2), it records it like a mix and can build the refund after
the refund height itself. A user whose order no bot fills must never need
another tool.

**Fees.** The protocol's service fee and the bot fee are read from the
contracts and shown before confirming. The Argus fee rides on the order
transaction, never on the fill, whose outputs the contract pins.

## Batches

| Batch | Contents | Done when |
|---|---|---|
| 1 (#74) | `duckpools` crate: identities, `PoolBox::parse`, `lend_token_value`, `position_value`, fixtures, live test. FFI `duckpools_pools` (identities) and `duckpools_state(pool_boxes_json, holdings_json)` (per pool: pooled, borrowed, utilisation, lend-token value, the wallet's lend tokens and their value). Dart `DuckpoolsService` (fetch the eight pool boxes by script through node then explorer, compute state), a Duckpools screen listing pools and the wallet's positions, a Discover card with a position line, lend tokens named in the verified list. | Positions and pool state render from live boxes; unit tests on the arithmetic against the fixtures. |
| 2 (this PR) | Lend and withdraw orders: proxy-box builders in Rust proven against the pool box (fixtures, live reduction), an order record with refund height, an order tracker on the poll tick (filled, refunded, refundable), the refund transaction, confirm sheets with the fee tiers, interest boxes read for the rate. | A lend order fills against the live ERG pool and a withdraw returns the asset; a deliberately unfilled order is refunded by Argus. |
| 3 | Borrow, repay, partial repay, collateral top-up, liquidation risk display. Only once a pool shows real borrowing to quote against and the v2 interest and logic contracts have settled. | Device-tested against SigUSD, the pool with borrowing today. |

## Found while building batch 2

**Two `MaxLendTokens`.** The ERG pool contract sets it one million above
the true maximum; every token pool's contract sets it ten above. Batch 1
used the ERG value for all eight and halved the token pools' lend-token
price; fixed on the batch 1 branch, with the SigUSD fixture pinning
1.7047 SigUSD per lend token.

**The fee tiers, literally.** Above the second step the contract charges
`(delta − step2 − step1)/250 + step2/200 + step1/160`: the whole second
step at 1/200, not only its excess. The crate follows the contract, not
the FAQ's description.

**Refunds need exactly one fee.** The proxy contracts allow at most
`minTxFee` (0.001 ERG) to leave the box on a refund, so the refund
transaction uses that fee, not the wallet's default.

**The rate is readable.** The interest parameter box holds six
coefficients; the rate per 120-block period is a polynomial in
utilisation. Today's curve gives 1.07% a year at zero utilisation, and
lenders earn that times utilisation.

## Live map used by batch 1

Pooled and borrowed on 2026-09-05 (borrowed = 9,000,000,000,000,000 minus
borrow tokens in the box):

| Pool | Pooled | Borrowed |
|---|---|---|
| ERG | 15,055 ERG | 0 |
| SigUSD | 14,670.24 SigUSD | 5,557.99 SigUSD |
| QUACKS, SigRSV, RSN, rsADA, SPF, rsBTC | small | small or none |

## Not in this plan

Argus's own lending protocol. That is a separate decision, recorded in
the exploration's recommendation, to be made once these batches show
whether people lend and borrow from a phone.

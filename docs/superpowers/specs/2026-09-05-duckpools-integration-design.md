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
| 2 (#77) | Lend and withdraw orders: proxy-box builders in Rust proven against the pool box (fixtures, live reduction), an order record with refund height, an order tracker on the poll tick (filled, refunded, refundable), the refund transaction, confirm sheets with the fee tiers, interest boxes read for the rate. | A lend order fills against the live ERG pool and a withdraw returns the asset; a deliberately unfilled order is refunded by Argus. |
| 3 (#78) | Borrow against ERG from the token pools, full and partial repayment, the wallet's loans read from the collateral boxes with what they owe (interest compounded as the contract does), what the collateral counts for (priced through the Spectrum pool as the contract does), health against the pool's liquidation line and the forced-liquidation height. Refunds for every order kind. | Device-tested against SigUSD, the pool with borrowing today. |
| 4 (this PR) | Borrow ERG from the ERG pool against SigUSD, SigRSV, RSN or rsADA, priced the other way round through the same Spectrum pools; ERG-pool loans read, repaid and partly repaid in ERG. | Device-tested: a small SigUSD-backed ERG loan opened and repaid. |
| 5 | Collateral top-up and withdrawal: the collateral contract's own recreation path, a direct spend the borrower signs with the interest and price boxes as data inputs. No bot. | — |
| 6 | Health alerts: the poll tick and the background job value every loan and notify when health crosses a warning line or the forced-liquidation height nears. | — |
| never | Liquidating other people's loans: a bot's business. | — |

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

## Found while building batch 3

**Where a loan lives.** A collateral box carries the ERG, the pool's
borrow tokens (the principal), the borrower's script in R4, where in the
interest history the loan began in R5 as `(parent index, child index)`,
the pool's `(threshold, penalty)` in R6, the price source NFT in R7, the
borrower's key in R8 and `(forced liquidation height, buffer)` in R9.
The wallet finds its loans by reading every box under a pool's
collateral script and keeping those whose R4 is one of its own trees.

**Interest is a history, not a rate.** Every 120 blocks a bot appends
the period's rate to the head *child* interest box; when a child fills
up its product goes into the *parent* box and a new child starts, so
there are as many live child boxes as parent entries plus one (the
SigUSD pool has fourteen, all unspent). What a loan owes is `1 + loan ×
compounded / 1e8` where `compounded` folds the base child's rates from
the loan's child index, then the head child, then the parent entries
after the loan's parent index, in that order and with the contract's
integer rounding. The crate reproduces it and pins a live loan: 238.99
SigUSD borrowed, 239.39 owed at height 1 866 418.

**Collateral is priced pessimistically.** The contract values ERG
collateral as what it would buy from the Spectrum ERG/asset pool after
taking off 0.005 ERG, adding two percent slippage to the ERG reserve
and paying the DEX fee. On 2026-09-05 that made 2,500 ERG count for
623.16 SigUSD. Liquidation opens when that value falls to `owed ×
threshold / 1000` (SigUSD and QUACKS: 140%), or after the forced
height, about 65,520 blocks (91 days) from the borrow.

**The parameter box is the source of the terms.** Threshold, penalty
and price source per collateral come from the pool's parameter box (R4,
R7, R6), and a borrow order must repeat the pair the box holds or the
pool contract rejects the fill. The live SigUSD box lists two
thresholds but one price source; the contract indexes by price source.

**Borrow orders can be taken back at once.** The borrow proxy is
`operation || proveDlog(userPk)`, so the borrower's signature alone
spends it; the wallet's ordinary refund builder works before the refund
height, where lend, withdraw and repay proxies wait for it.

**Repay overpayment is not returned.** The fill puts everything the
repay proxy carries into the repayment box, so the order carries what is
owed plus two more periods of interest at the latest rate plus one unit,
and no more. A partial repayment names the borrow tokens that must
remain: `loan − repayment × 1e8 / compounded`.

**Fill markers differ by kind.** Lend and withdraw fills mark the user's
box in R7; borrow and repay fills mark it in R4, as refunds do, so the
outcome reader tells them apart by whether the marked box carries tokens
(borrow: a fill does, a refund does not; repay: the reverse). A partial
repay marks nothing and is read from the shape of the transaction.

## Found while building batch 4

**The ERG pool prices the other way.** Its collateral is a token in
`tokens(0)` of the collateral box, the borrow tokens in `tokens(1)`, and
the box's ERG is a fixed 0.004 carry from the proxy. Collateral value is
what the token sells for on its Spectrum pool after two percent slippage
on the *token* reserve and the DEX fee, minus a 0.004 ERG network fee
(the token pools take 0.005 off the ERG first). The pool contract
accepts a loan exactly on the line (`>=`) where the token pools want
strictly above it, and lends no less than 0.05 ERG.

**Four collaterals, one parameter box.** R5 of the ERG pool's parameter
box lists SigUSD, SigRSV, RSN and rsADA against the R6 price sources,
with thresholds `[1250, 1250, 1250, 1500]` and penalties of 30%. The
identities are pinned in the crate for the app to know which price
boxes to fetch; the parameter box read at run time decides the terms.

**ERG repayments are ERG.** The repay proxy's box value is the
repayment; the fill's repayment box is that less the borrower's box and
the fee, plus the collateral box's 0.004, and must reach owed plus one
fee. A partial repayment's proxy carries the repayment plus 0.002 for
the fee and the repayment box, and must leave at least 0.05 ERG owed.

**No live ERG-pool loans to pin.** The ERG pool had no collateral boxes
on 2026-09-05, so the tests build one the way the bot does (registers
through the crate's own encoders) and price it through the live SigUSD
market: 1,000 SigUSD counts for 3,716.17 ERG.

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

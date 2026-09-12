# Stake recovery: contract foundations

Native Argus code for Batch 1 of the [agreed design](../../../../../docs/superpowers/specs/2026-09-11-stake-recovery-design.md).
The registry contains published addresses and token ids, not serialized trees.
Ergopad and Paideia are active entries; EGIO is an inactive entry. Full trees
are derived through `ergo_tx::address_to_ergo_tree` and parsed before use.

The parsers take `Eip12InputBox`, reconstruct its canonical id using sigma-rust,
check the full contract tree and positional assets, and expose immutable decoded
views. They reject extra registers/assets and noncanonical register encodings.
The layouts confirmed by the historical boxes are:

| Box | Assets in order | Registers |
| --- | --- | --- |
| Stake | One pool stake token, positive reward balance | R4: `Coll[Long]` of length 2, checkpoint and stake time in milliseconds; R5: `Coll[Byte]` of length 32, key id |
| State | One state NFT, positive stake-token reserve | R4: `Coll[Long]` of length 5, total staked, checkpoint, staker count, last checkpoint milliseconds, cycle milliseconds |
| Paideia proxy | One key token | R4: `Coll[Long]` of length 1, positive unstake amount; R5: `Coll[Byte]`, a complete parsed recipient ErgoTree |

Counters and timestamps must be nonnegative; the cycle duration must be positive.
A key cannot be one of the registered pool assets. The state/stake relationship
check requires the same pool/checkpoint, sufficient totals and count, and a
checked increment of the reserve. Proxy execution also requires the same key and
exact full reward amount. These are eligibility primitives, not transaction
builders or proof that a box remains unspent. A valid proxy recipient can belong
to someone else; `validate_recipient` compares it with the destination established
by wallet integration or persisted tracking. It cannot prove ownership.

The 113,000,000 nanoERG proxy value is historical funding, not an exact-value
script constraint. The incentive, executor and execution-fee values are pinned
by proxy constants. The registry verifies the incentive's hash against constant
15 of the address-derived proxy. Minimum output values, fee destinations and
layout enforcement belong to the later builders.

Tests replay all three historical transactions through the pinned `reduce_tx`.
They inspect each reduced proposition, including the Ergopad wallet's exact
DLog public key. Mutations test contract rejection separately from recipient
policy: a changed refund recipient and corresponding output remain contract
valid but fail the expected-recipient check.

There is no discovery, FFI, wallet integration, transaction builder or submission
path here. Later batches must add transaction-wide conservation and ordering,
current-input revalidation, wallet control, preflight funding, and reduction of
native builder output. `FullUnstake` is only input accounting eligibility; it
does not establish that an assembled transaction satisfies every script branch.

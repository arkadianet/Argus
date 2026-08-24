# Mempool Awareness — Design

Date: 2026-08-23
Status: approved, pending implementation plan

## Goal

Make the wallet aware of unconfirmed transactions: show them in activity, reflect
them in balances, stop offering already-spent boxes, and allow spending
unconfirmed change (0-conf chaining).

## Why

Three gaps today, all stemming from the app reading only confirmed state:

1. **Activity** — `get_transaction_history` (`api.rs:348`) queries the indexed
   confirmed history. A sent transaction disappears until it is mined. The
   dashboard already renders a `'Pending'` badge (`dashboard_screen.dart:1581`)
   that nothing can currently reach.
2. **Balance** — `get_balance` (`api.rs:325`) uses `get_address_balances`,
   confirmed only. Sending does not move the displayed balance.
3. **Spendable UTXOs** — `gather_unspent` uses `wallet_net`'s `get_unspent`,
   confirmed only. After sending, the spent boxes are still offered as inputs,
   so a second send builds a transaction that double-spends them and the node
   rejects it. This one is a correctness bug, not a display gap.

`ergo-node-client` already contains `get_effective_utxos` (`lib.rs:609`) —
documented as *"Mempool-aware UTXOs: confirmed minus mempool-spent, plus
unconfirmed outputs. Enables 0-conf chained transactions."* It has **zero
callers**. It solves gap 3 in principle, but returns only `Eip12InputBox`, and
the signing path needs `ErgoBox` (see below), so it cannot simply be wired in.

## Scope

In scope:

- Unconfirmed transactions in the activity list
- Mempool-aware balance
- Excluding mempool-spent boxes from spending
- Spending unconfirmed outputs (0-conf chaining)
- Polling while the dashboard is open

Out of scope:

- Replace-by-fee or transaction cancellation
- Mempool eviction notifications beyond the entry disappearing
- Pending-state persistence across app restarts (mempool is re-read on launch)

## Foundation

One mempool read per wallet address via `get_unconfirmed_by_ergo_tree`
(`ergo-node-client/src/lib.rs:465`), which hits
`/transactions/unconfirmed/byErgoTree`. This is a plain node endpoint — mempool
is in-memory, so unlike Spectrum pool discovery it needs **no `extraIndex`** and
works against any node.

The wallet holds multiple addresses, so this is N concurrent requests. Use
`tokio::task::JoinSet`, the pattern already established in `discover_addresses`
(`api.rs:395`), rather than sequential awaits.

`get_unconfirmed_by_ergo_tree` hardcodes `offset=0&limit=100`, so a tree with
more than 100 mempool transactions is silently truncated. Acceptable for a
personal wallet, but it is a silent cap rather than an error.

**Every mempool query degrades to confirmed-only on failure.** A slow or flaky
mempool must never break the confirmed view. `get_effective_utxos` already
models this — it logs a warning and returns confirmed UTXOs — and that behaviour
is the rule for all four consumers.

## 1. Activity list

A new FFI call returns unconfirmed transactions for the wallet's addresses,
merged ahead of confirmed history in the dashboard. Entries carry no height, so
`formatActivityTime` and the existing `confirmed` flag drive the `'Pending'`
badge that is already implemented.

**Deduplicate by transaction id.** The mempool is queried once per address, and
a single transaction touching several wallet addresses — spending from A with
change to B — is returned once per matching tree. Without dedup the pending card
renders twice.

Note the asymmetry: the **balance** is naturally safe from this, because deltas
are computed per box and every box belongs to exactly one ergo tree, so summing
across addresses cannot double count. Only the merged activity list needs the
dedup.

Mempool transactions carry no timestamp, and `formatActivityTime` returns an
empty string for a null value (`format.dart:132-133`), so pending entries show
no time. All pending entries sort above confirmed ones; order among themselves
is unspecified and not worth defining.

An entry disappears when it either confirms (and reappears from confirmed
history) or is evicted from the mempool.

## 2. Balance

`get_balance` adjusts the confirmed figure by mempool deltas: subtract the value
of inputs the wallet owns, add the value of outputs it owns. Same for per-token
amounts.

**"Inputs the wallet owns" needs defining**, because mempool JSON inputs carry
only a `boxId` and no ergo tree. Ownership resolves as: the `boxId` appears in
that address's confirmed UTXO set. Outputs are the easy direction — they carry
`ergoTree` directly.

That definition covers a parent transaction, but not a chained one: with 0-conf
chaining a grandchild's input references an *unconfirmed* output, which is in no
confirmed UTXO set. The arithmetic still nets out provided **all of an address's
mempool transactions are collected and resolved in one pass before any deltas
are applied**, so intermediate outputs are known by the time inputs referencing
them are examined. Iterating transaction-by-transaction and applying deltas as
it goes will get this wrong.

A single mempool-aware number is shown rather than a confirmed/pending split.

## 3. Spendable UTXOs

Two halves, both in scope.

**3a — exclude mempool-spent boxes.** Filter the confirmed set by box ids
appearing as inputs of mempool transactions. This is the bug fix: it only ever
removes candidates, so it cannot create an invalid transaction.

**3b — include unconfirmed outputs.** The signing path needs `ErgoBox`, not
`Eip12InputBox`: `CachedPreparation.ergo_boxes` is `Vec<ErgoBox>` (`api.rs:40`),
and `wallet-net`'s `get_unspent` derives EIP-12 *from* `ErgoBox` via
`Eip12InputBox::from_ergo_box`, not the reverse. An unconfirmed output has no
`ErgoBox` in the node's UTXO set, so one must be built from the mempool JSON.

This is smaller than it first appears: `serde_json::from_value::<ErgoBox>` is
already used to parse node box JSON in three places
(`wallet-net/src/client.rs:277`, `ergo-node-client/src/lib.rs:173` and `:221`),
and mempool transaction outputs arrive in a similar shape. But they are not
identical: `json_output_to_eip12` (`ergo-node-client/src/lib.rs:996`) reads
`boxId` from the output while taking `tx_id` and `index` as **parameters**,
supplied by the caller from the enclosing transaction — which means a mempool
output object carries `boxId` but not `transactionId` or `index`.

The first implementation step is therefore to establish empirically whether
`from_value::<ErgoBox>` accepts a mempool output as-is, and if not, to inject
`transactionId` and `index` from the enclosing transaction before deserialising.
Everything downstream depends on the answer, so it is step one, not an
assumption.

**Where this logic lives.** `get_effective_utxos` already implements most of it
— a spent-set filter plus owned-output inclusion — but returns `Eip12InputBox`
and sits in the vendored `ergo-node-client`.

It goes in **`wallet-net`** (`rust/crates/wallet-net/src/client.rs`), as a
sibling of `get_unspent`. `wallet-net` is first-party, not vendored, and talks to
the node directly over reqwest, so this needs no vendored change. Returning the
same `(Vec<ErgoBox>, Vec<Eip12InputBox>)` tuple as `get_unspent` makes it a drop-
in at the one call site in `gather_unspent`.

This is better than the two obvious alternatives: extending the vendored crate
would break the house rule from the AMM work, and reimplementing inside
`wallet-ffi` would duplicate the logic into an already-large `api.rs` while
splitting UTXO fetching across two crates. The Dexy top-up remains the one
deliberate vendored exception, because the recipient output could only be built
inside the vendored builder; no such constraint applies here.

**Accepted risk:** a transaction chained onto an unconfirmed parent becomes
invalid if that parent is dropped from the mempool, and any descendants fail
with it. This was raised and accepted.

## 4. Polling

`Timer.periodic` while the dashboard is mounted, cancelled on dispose. Polling
runs whenever the dashboard is open rather than only while something is pending.

Polling pauses while the app is backgrounded, via a `WidgetsBindingObserver`
observing the `paused` and `hidden` lifecycle states — the same states
`SessionLock.onLifecycle` already reacts to.

An earlier draft said this would hook "the existing `session_lock` signal".
That was wrong: `SessionLock` (`services/session_lock.dart`) exposes `onLock` —
a callback it *invokes* — plus `suppress`/`release`, `run`, `onLifecycle` and
`grace`. Its `_backgrounded` flag is private and there is no locked-state
notifier to subscribe to. Observing the lifecycle directly needs no change to
`SessionLock`.

Still open: whether pausing is wanted at all. It was offered and not explicitly
accepted, and can be dropped for unconditional polling.

## Error handling

| Case | Behaviour |
|---|---|
| Mempool query fails | Warn, fall back to confirmed-only. Never surfaced as a send failure. |
| Mempool output will not deserialise | Skip that box, keep the rest. Never abort the whole UTXO set. |
| Parent dropped, child invalid | Node rejects on broadcast; surface the node error rather than pre-empting it. |
| Node lacks the endpoint | Same as a failed query — confirmed-only. |

## Testing

Pure functions, tested against synthetic mempool JSON, following the pattern of
the Dexy and AMM work:

- Balance delta arithmetic — owned inputs subtracted, owned outputs added
- Spent-box filter — a box spent in mempool is not offered
- Unconfirmed-output inclusion — an owned mempool output becomes spendable
- Degradation — a failed mempool query yields exactly the confirmed set
- Dedup — a transaction returned by two addresses appears once in activity, and
  its balance delta is counted once

Node behaviour itself stays unverified without a device; that gap is real and
should be closed by manual testing, as with the AMM and shortfall work.

## Manual verification

1. Send ERG; the entry appears immediately marked Pending and the balance drops
2. Send again before confirmation; the second transaction builds and broadcasts
3. Spend unconfirmed change; the chained transaction is accepted
4. Wait for a block; entries flip to Confirmed without a manual refresh
5. Point at a node with an empty mempool; nothing regresses

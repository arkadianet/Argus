# Token metadata: resolve during sync, cache per wallet

## The problem

A box carries only `(tokenId, amount)`. Name, decimals and description live
in the issuance box's registers, so showing them needs a reverse lookup.

Argus never made that lookup. `prefetchTokenMeta` was an empty method:

```dart
Future<void> prefetchTokenMeta(Iterable<String> ids) async {
  // Deliberately cache-only. Receiving or displaying an ID is not consent
  // to disclose it to a metadata provider.
}
```

`no_automatic_token_requests_test.dart` held that line, and `rememberTokenMeta`
— the only writer of the persisted cache — had no production caller, so
`persistTokenMeta()` always early-returned. A wallet of 194 tokens showed 194
rows of truncated ids, each needing a two-tap confirmation, and the result was
dropped on every backgrounding.

This reverses that posture deliberately. It was not an accident and is not a
repair.

## Why the old posture does not hold

The rationale drew a line at disclosure to the provider. The balance request
has already crossed it: the same node receives the wallet's addresses and
answers with the boxes those ids come from. Asking it to read one of those
tokens' registers adds no id it did not just send us.

The "unencrypted store" objection fails the same way. `argus_local_wallet_db_v3_*`
already persists this wallet's token ids, **names**, decimals, emission
amounts, icon URLs, addresses, balances and recent history, under `_obfuscate`
— an XOR keystream whose key is the wallet id, stored inside the payload. Its
own header says anyone with file access "can read everything here". Refusing
to store names for ids already in that file is a difference in legibility, not
confidentiality.

Two earlier attempts argued the opposite and were rejected on review:

- "The pinned node already knows your tokens" cited `PublicWalletSync`, which
  skips the active wallet. It also conflated possession with interest.
- A provider-scoped consent store answered that objection but was unwarranted
  for the ordinary node case, and its scheduler accumulated races across two
  review rounds without converging.

**Resolving during sync rather than on tap is what dissolves the interest
problem.** A request made when a token is tapped reveals which token the user
inspected. A request made as part of sync does not: it covers everything the
node just returned, in the same exchange.

## What is resolved, and what is not

| | Resolved automatically | Why |
|---|---|---|
| Ordinary public holdings | yes, via the sync node | ids came from that node's own boxes |
| Stealth-only holdings | **never** | not derivable from public addresses; the node has never seen them |
| The explorer | **never** | a token-specific lookup exceeds the generic stealth-template listing sync already makes |

`hydrateTokens` is cache-only. The sync controller submits only ids from
successful ordinary balance responses to `prefetchTokenMeta`, with the serving
node returned by that same batch read. Retained holdings, transaction history,
and stealth-only holdings never supply candidates.

## Storage

`TokenDescriptorStore` keys tables per wallet (`argus_token_descriptors_v1_<walletId>`).
App-wide would record that two wallets hold the same token — an association
neither wallet's own data carries.

Descriptors keep their evidence fields rather than flattening to a name, so a
cached descriptor cannot read as stronger proof than it was when fetched. A
cached name is never identity: `verifiedToken` and `impersonatedToken` still
key on the token id, and `TokenBalance`'s constructor runs `issuerText()` over
the name on the way in and out, so a hostile label is sanitised on cache load
as well as on fetch. `CachedDescriptor` deliberately carries no amount — a
holding cannot be reconstructed from the cache alone.

The legacy app-wide table is read once as a base layer and never written
again. The active wallet's descriptors overlay it.

## Bounds

- 40 lookups per sync, so a first sync does not become hundreds of sequential
  requests before the balance settles. The rest resolve on later syncs.
- An id attempted and unresolved is remembered, so an unresolvable token is
  not re-asked every sync.
- One capability failure (no `extraIndex`; `load_from` is HTTPS-only, so a
  user-configured `http://ip:port` node can never answer) stops the whole
  wallet from retrying that node. A new provider gets a fresh chance.
- Wallet ownership and the originating sync generation are checked across
  asynchronous work. The serving endpoint stays tied to the balance response.

## Serving node

The batch response includes `served_by`, obtained from the connected node
client. Resolution uses that endpoint without explorer fallback. If the read
cannot identify its serving node, it makes no automatic metadata requests.

## Clearing the cache

“Clear collectible cache” deletes the legacy metadata table, every wallet's
descriptor table, pending descriptor writes, and in-memory descriptor caches.
Descriptor epochs still discard lookup results that cross the clear.

It leaves published holdings, retained views and persisted balance snapshots
alone. Names and classifications already copied into those holdings can remain
visible or reappear on activation until a later sync replaces them. This is a
cache reset, not an erasure of token metadata from wallet history. The control's
tooltip states that saved holdings keep their metadata.

Snapshot writes are authoritative replacements, with no metadata merge and no
clear-triggered public-refresh invalidation. Background public refreshes update
amounts while retaining metadata from that same wallet's existing snapshot.
This preserves known decimal scales after a cache clear and avoids cross-wallet
metadata substitution without consulting a second storage layer.

## Still open

`rememberTokenMeta` now has a caller, but the legacy `argus_token_meta_v2`
table is still write-only-never. Left as a read-only base layer; it can be
dropped once enough releases have passed for wallets to have rebuilt their
per-wallet tables.

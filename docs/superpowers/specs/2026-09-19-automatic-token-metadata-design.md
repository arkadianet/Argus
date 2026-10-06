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
neither wallet's own data carries. Tokens of the public pool list are the
one exception, kept in a separate app-wide catalog that no holding ever
enters; see "One lookup, and a public catalog for pool tokens" below.

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
descriptor table, the public pool-token catalog, pending descriptor writes,
and in-memory descriptor caches.
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

## One lookup, and a public catalog for pool tokens (2026-10-06)

### Why names still went missing

On 1.0.0-beta.1 the per-wallet table worked, but the screens did not all
read it, and the one that did read it late:

| Screen | What it read | Why it missed |
|---|---|---|
| Asset list | holdings built by `hydrateTokens` | The table loaded lazily, inside the name pass, which runs after history, the UTXO count and the stealth scan. The first balance after every unlock republished each holding without its name; the pass restored it seconds later. Names came from the snapshot, vanished, and came back. |
| Activity rows, transaction screen | `cachedTokenMeta` | The same lazy load, and rows with two or more tokens only ever said "N tokens". |
| Swap picker, swap fields | `AmmPoolSet.tokens` only | A separate, app-wide cache (`argus_amm_tokens_v1`) seeded into Rust. Since pool enrichment became cache-only, Rust padded every token it was not told about with the first eight characters of its id and zero decimals, and `AmmPoolCache.rememberTokens` saved those placeholders as names. Seeding uses `or_insert`, so a placeholder was never replaced. COMET showed as "0cd8c9f4…" with raw amounts even though the wallet's table and the curated registry both named it. |
| Liquidity | `AmmPoolSet.tokens` only | The same placeholders: "ERG / 6de6f46e…", reserves in base units. Creating a pool preferred the placeholder's zero decimals over the holding's real scale, so "150" of a two-decimal token was confirmed and sent as 1.50. |

Nothing was cleared on lock beyond the session descriptors the NFT design
intends; the "every time" delay was the per-unlock reset of the in-memory
view plus the lazy reload.

### The lookup

`WalletService.cachedTokenMeta(id)` is the one lookup. Every holding is
built from it and every screen that names a token by id reads it, through
the helpers in `token_metadata.dart`. Best layer first:

1. this wallet's own descriptors (`TokenDescriptorStore`);
2. the public pool-token catalog (`PublicTokenCatalog`, below);
3. the curated registry built into the app (`verified_tokens.dart`), by its
   ticker, with evidence left unknown;
4. the legacy `argus_token_meta_v2` table, which has no provenance.

Explicitly loaded descriptors stay memory-only and are not a layer of this
lookup: holdings are built from it and persisted. `displayTokenMeta` and
`displayMetadata` put them on top for display only, as before.

The wallet's table is now read before `restoreWallet`/`createWallet`
returns — local storage, after the outgoing wallet's pending write — and
`hydrateTokens` waits for it, so the first balance carries every name the
wallet already learned. Holdings that carry no record of their own (built
before a token was known, or restored from a snapshot, which keeps names
but not evidence) take what the lookup knows now when displayed.

### The public catalog

Pool lists are not wallet data. Argus downloads the whole Spectrum list,
the same list for every wallet, and the node that serves it already holds
every token id in it. So:

- **What enters.** Only token ids from a pool list, resolved by
  `inspect_token_metadata` from the node that served that list
  (`networkController.activeUrl` as passed to `amm_pools`; Rust uses that
  exact URL, with no fallback). With no node configured Rust picks its own
  default, Argus cannot tell which node answered, and nothing is resolved.
  The old AMM table's real names migrate in once, marked incomplete so a
  pass upgrades them; its placeholders are dropped and the key removed.
- **What never enters.** A wallet's holdings or its resolved descriptors,
  explicitly loaded descriptors, ids from transaction history, stealth-only
  ids. Copying a holding's descriptor in would record, app-wide and past the
  wallet's deletion, that some wallet on this phone held that token — the
  association the per-wallet table exists to avoid. `publicPoolTokenMeta`,
  which fills the cached and shared `AmmPoolSet.tokens`, reads only the
  catalog and the curated registry for the same reason.
- **Order.** Candidates come in the pool list's own order, deepest ERG side
  first. Nothing a wallet holds may reorder them: the sequence of lookups
  would then say what it holds.
- **Bounds.** 40 lookups per pass, one pass at a time, started by a fresh
  pool list (Swap, Liquidity, pricing). Up to 2,000 entries. Not-found runs,
  three consecutive failures-to-answer, and one capability failure end a
  pass, classified by the same `DescriptorLookupFailure` rules as the
  wallet's pass. Misses and capability verdicts are per provider.
- **Sharing the job.** Lookups go through `WalletService.inspectForCatalog`,
  in the single native metadata job. The catalog yields: it starts nothing
  while a wallet pass or an explicit request waits, and those wait out its
  one request in flight instead of failing as busy. It runs only unlocked
  and in the foreground.
- **Clearing.** "Clear collectible cache" clears it with everything else.

Resolution from the serving node and only that node, sanitised issuer text,
and verified/impersonation checks keyed on the token id are unchanged. A
catalog name, like any cached name, is never identity.

### Amounts with unknown decimals

A holding nothing has described is built with zero decimals, a default and
not knowledge. Wherever an amount is shown, a known scale is applied; an
unknown one is said out loud — "5,000 raw units", "349,670,571,986 raw units
of 6de6f46e…" — and amount fields say they take raw units. A known zero
(COMET) is a scale: any name, evidence or descriptor counts as knowing it.

### Activity

Rows name up to two tokens, then sum up the rest: "69 COMET + 1.5 SigUSD +
1 more token + 1.8162 ERG". Named tokens are listed first; an unnamed one is
its short id. A swap shows both legs, "0.75 ERG for 69 COMET". ERG keeps four
decimals: two would turn a fee-only row into "0 ERG". The line may take two
lines, and above 1.4x text the time and status move under it (the asset row's
amount likewise), so the names stay legible at large text sizes.

## Still open

`rememberTokenMeta` now has a caller, but the legacy `argus_token_meta_v2`
table is still write-only-never. Left as a read-only base layer; it can be
dropped once enough releases have passed for wallets to have rebuilt their
per-wallet tables.

The Rust `amm_pools` call still builds a token map of its own — an echo of
what it is seeded with, padded with placeholders. Dart no longer seeds it
and discards the map; removing it needs a native rebuild and can ride along
with the next FFI change.

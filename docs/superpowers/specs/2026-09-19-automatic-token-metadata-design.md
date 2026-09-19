# Automatic token metadata resolution

## The problem

A box carries only `(tokenId, amount)`. A token's name, decimals and
description live in the registers of its issuance box, so showing them means
a reverse lookup: `tokenId -> issuance box -> parse R4..R9`.

Argus never made that lookup automatically. `WalletService.tokenMeta`, the
hook `PublicWalletSync` calls, is a pure local-cache read; the only path to
the network is `loadMetadata`, reached from a per-token confirmation dialog
in the token detail sheet. A wallet holding 194 unnamed tokens therefore
showed 194 rows of truncated ids, each needing two taps to resolve, and the
result was dropped again the next time the app went to the background.

Requiring 194 confirmations does not produce 194 informed decisions. It
produces reflexive approval, which is the failure mode the prompt exists to
prevent.

## The justification that did not survive review

The first version of this work argued that automatic resolution against the
pinned node disclosed nothing new, because sync already sends that node the
wallet's addresses and the boxes it returns enumerate the same tokens.

That argument was wrong, in two separate ways.

It was wrong on the facts. It cited `PublicWalletSync`, which
(`public_wallet_sync.dart:103`) explicitly *skips* the active wallet. The
active wallet syncs through `_LiveSyncRead`, which does pass
`networkController.activeUrl` — so the conclusion happened to hold on the
normal path — but the cited evidence did not support it, and the fallback
`getBalance` path passes no node at all.

It was wrong in principle, which matters more. Knowing that a provider
returned certain tokens does not authorise telling that provider *when* the
user opens Assets, how often they come back, or which wallet they unlocked.
Possession and interest are different facts, and a request burst is its own
signal. No amount of provenance tracking answers "may we disclose this
additional activity?" — only permission does.

The gate was also not enforcing even the weaker claim: `setPreferredNode`
assigns `preferredUrl` and then probes, so pinning a new node opened the gate
immediately, against holdings that a *different* node had served.

## What this does instead

Permission, not justification. `MetadataConsent` records the exact provider
endpoints allowed to resolve automatically, and the settings copy states what
the provider learns rather than denying that it learns anything:

> `<host>` sees your connection's IP address, the token ids requested and
> when they were requested. From those it can infer your holdings and link
> your activity across visits and wallets. Turning this off stops later
> requests. It cannot take back what has already been sent.

Consequences of keying on the endpoint:

- Grants are stored as `scheme://host:port`, so the same host over http, or
  on another port, is a different provider needing its own grant.
- A grant never transfers. Pinning a different node does not carry permission
  to it; the switch turns itself off because that endpoint is not granted.
- The pre-consent boolean (`argus_auto_metadata_v1`) is deliberately **not**
  migrated and is deleted on load. It was agreed to under terms that said the
  node learned nothing new, which is not what is being asked now.

## The boundaries

- **Failover** is a recipient restriction. Automatic resolution runs only
  when the active node *is* the pinned, granted endpoint. Metadata requests
  never fail over: another node serving balances neither earns permission nor
  removes the pinned node's.
- **The explorer** keeps its per-token prompt. Node permission does not
  authorise explorer requests.
- **Stealth holdings** are outside the grant's scope and are always asked
  about individually.
- **Foreground only.** Backgrounding wipes resolved metadata, and
  `dashboard_screen.dart` deliberately keeps polling for a window afterwards.
  Without a foreground condition a poll tick in that window would quietly
  fetch everything again, contradicting the promise the UI just made.

## Mechanics

Authorisation is re-read before every individual request, not once per
sweep: holding the metadata job pauses automatic resolution, it does not
freeze network settings or the grant list underneath it.

The sweep runs sequentially because both `_metadataBusy` and Rust's
`METADATA_JOB` allow one request at a time. It is capped at 250 per batch,
below the 1,000-entry `_descriptors` cap. Each token is attempted at most
once per session (`_attempted`): without that, a batch of timeouts is retried
in full on every sync tick, which no per-batch cap can bound.

`beginManualMetadata`/`endManualMetadata` hand the job to an explicit tap and
resume whatever the hold displaced, so one manual request does not strand the
rest of the wallet until the next sync tick.

## What deliberately did not change

Resolved descriptors stay memory-only, dropped on background, lock and wallet
switch. Persisting them would reduce repeated disclosure bursts — a real
argument in favour — but it needs a wallet-scoped encrypted store with
explicit retention and clearing semantics, not the unencrypted
`SharedPreferences` the legacy cache uses. That is a separate decision.

Deferred: plumbing the serving node back out of the Rust client (which does
silent failover and reports nothing), automatic resolution for the explorer,
any automation for stealth holdings, and persistent metadata caching.

## Still open

`rememberTokenMeta` has no production caller, so `_tokenMetaDirty` is never
set and `persistTokenMeta` always early-returns. The legacy
`argus_token_meta_v2` store can only shrink, so `cachedTokenMeta` consumers
(UTXO management, activity tiles, transaction details) degrade permanently to
shortened ids once a user clears collectible data. Untouched here.

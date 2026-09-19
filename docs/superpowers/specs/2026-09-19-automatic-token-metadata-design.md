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

That default is defensible for an unknown provider. It is not defensible for
the node the wallet is already talking to.

## The disclosure argument

`PublicWalletSync` sends the wallet's addresses to `networkController.activeUrl`
on every sync, for `getBalance` and `getTransactionHistory`. The boxes that
come back enumerate the wallet's tokens. Asking that same node to read one of
those tokens' issuance registers tells it nothing it was not already told.
The consent dialog was asking the user to approve a disclosure that had
already happened.

Three cases break that argument, and all three keep asking:

- **A node chosen by failover.** `chooseActive` falls back to any reachable
  node when the pinned one is down, and the default pool holds five. A
  non-null `preferredUrl` does not mean the pinned node is the one answering,
  so the gate is `preferredUrl != null && activeUrl == preferredUrl`
  (`NetworkController.pinnedNodeActive`), not merely "a node is pinned".
  Without that distinction, auto-resolution would spread the wallet's token
  set across up to five operators, none of which had necessarily served its
  balance.
- **The explorer.** Sync never contacts `networkController.explorer`. It holds
  nothing about this wallet, so a metadata lookup there is a fresh disclosure
  to a party that currently has none. It stays behind per-token consent
  regardless of the setting.
- **Stealth holdings.** Those boxes are not derivable from the wallet's public
  addresses, so the node has not seen them. `hasStealth` excludes a holding
  from automatic resolution even on the pinned node.

## What was built

`MetadataSettings.autoResolve`, persisted at `argus_auto_metadata_v1`,
**defaults to off** so an existing install keeps its current behaviour until
the user opts in. The switch lives in Network settings next to the node list,
because it is meaningless until a node is pinned and the copy says so.

`WalletService.autoResolveAllowedFor` holds the disclosure rule alone —
enabled, pinned-node-active, not stealth — with no session state, so it can
be checked directly in tests. `autoResolveEligible` adds unlocked and
not-hiding-balances on top.

`autoResolveMetadata` sweeps the holdings sequentially, because both
`_metadataBusy` in Dart and `METADATA_JOB` in Rust allow one metadata request
at a time. It skips what is already resolved, swallows per-token failures so
one unreadable token cannot stall the wallet, and stops at the next item when
the descriptor epoch changes or the active node moves. `stopAutoResolve`
lets an explicit tap take the job from a running sweep rather than be refused
with "another request is running".

The sweep is capped at 250 tokens, below the 1,000-entry `_descriptors` cap,
so a large wallet cannot evict its own freshly resolved entries mid-sweep.

## What deliberately did not change

Resolved descriptors stay memory-only and are still dropped on background,
lock and wallet switch. Automatic resolution changes *who has to be asked*,
not *what is kept on disk*. Persisting them would mean writing a map of the
wallet's holdings to unencrypted `SharedPreferences`, which is a separate
decision with a different threat model, and the existing persisted store
(`argus_token_meta_v2`) is already dead — its only writer, `rememberTokenMeta`,
has no production caller, so `persistTokenMeta` always early-returns.

That dead path is left alone here. It is worth settling separately: as
written, the legacy cache can only shrink, so `cachedTokenMeta` consumers
(UTXO management, activity tiles, transaction details) degrade permanently to
shortened ids once a user clears collectible data.

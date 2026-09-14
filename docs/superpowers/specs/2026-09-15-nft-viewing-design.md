# NFT viewing in Argus

Date: 2026-09-15. Status: proposed; no application changes.
Research baseline: `5ad8e4c`, branch `research/nft-viewing`.

## Decision

Extend Assets with a searchable **Collectibles** filter and text-first token details. Correct classification and stop automatic issuer-controlled media requests before adding previews. Then offer an explicit, per-item **Load preview** for bounded static images. Keep the dashboard compact. Do not build a marketplace, collection explorer, automatic gallery, or general media browser. A wallet should let its owner identify an asset and inspect its advertised artwork without making receiving a token equivalent to contacting its sender.

The smallest useful increment is **honest collectible identification and details without remote media**: supply evidence, declared artwork type, description, full token ID, and clear missing-data states within the existing Assets screen. This improves a feature that already partly exists. Optional images are a second increment with a separate security acceptance gate; shipping only the first increment is acceptable.

## 1. What an Ergo NFT actually is

### Protocol versus convention

Ergo has native tokens, not a separate NFT contract class. A box's R2 carries token IDs and integer quantities. Minting uses the transaction's first input box ID as the new token ID; tokens can subsequently be transferred or burned. Metadata is a convention on the minting output, not a protocol guarantee, and does not have to accompany later transfers. The convention is [EIP-4, Assets standard](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0004.md), currently marked Proposed. Box size and transaction limits constrain on-chain content. Holding one unit is not evidence that only one was issued.

The actual types in Argus's pinned [sigma-rust token module](https://github.com/ergoplatform/sigma-rust/blob/7f927613c5a72bf6ea93b95cf9987129a03dd4ba/ergotree-ir/src/chain/token.rs) are a 32-byte `TokenId`, convertible from `BoxId`, and a bounded integer `TokenAmount`. There is no artwork/authenticity flag in those types. Use sigma-rust's [typed Constant deserializer](https://github.com/ergoplatform/sigma-rust/blob/7f927613c5a72bf6ea93b95cf9987129a03dd4ba/ergotree-ir/src/serialization/constant.rs), already pinned by `rust/Cargo.lock`, for registers; it supplies serialization semantics, not an NFT trust decision.

### EIP-4 issuance output

These registers belong to the **issuance output**, identified by the token index's `boxId`. They are not generally the registers of the UTXO currently holding the token.

| Register | Meaning and encoding |
| --- | --- |
| R4 | Name, UTF-8 `Coll[Byte]` |
| R5 | Description, UTF-8 `Coll[Byte]`; may contain application-specific JSON text, but is not a mandatory JSON metadata URL |
| R6 | Decimals as UTF-8 digits in `Coll[Byte]`, e.g. `"0"` serializes as `0e0130`; not a Sigma Int |
| R7 | Asset category/subtype bytes. NFT category `01`; picture `01 01`, audio `01 02`, video `01 03`, artwork collection `01 04`, file attachments `01 0f`. Picture serializes as `0e020101`. Category-only declarations are permitted by the text. |
| R8 | For picture/audio/video: SHA-256 of the original media bytes, normally a 32-byte `Coll[Byte]`. Attachments instead use `Coll[Coll[Byte]]` of hashes. |
| R9 | Optional media URI as UTF-8 `Coll[Byte]`; audio also permits `(Coll[Byte], Coll[Byte])` for audio and cover links. Attachments have a structured encoding. |

These details come from [EIP-4's register tables and attachment extension](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0004.md). R8 hashes audio, not its cover. A collection marker does not imply supply one. The attachment section references [EIP-29](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0029.md); its example R7 also differs from the table. Do not guess how to render attachments from that inconsistency: retain the declaration, show unsupported content, and require interoperability fixtures before supporting it.

Media normally lives at an HTTPS host or on IPFS reached through a gateway. Neither availability nor safe content follows from being on chain. An immutable URI can return changing bytes. IPFS content addressing is not a persistence service; a gateway can fail or censor. R8 can check downloaded bytes against the issuance commitment, but a matching hash says nothing about authorship, copyright, monetary value, or whether an image is deceptive. Nor is an IPFS CID generally the SHA-256 of the returned file: DAG structure matters. Do not equate the two.

There is no universal ERC-721-style tokenURI JSON fetch step here. Do not recursively follow descriptions, JSON fields, playlists or HTML. Nonstandard inline/data-URI art should remain inspectable as metadata with an unsupported-preview state; it is not justification for an embedded browser.

### EIP-24 and EIP-34: a different box

[EIP-24, Artwork Standard](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0024.md), also Proposed, extends EIP-4. Its **issuer box is the first input**, already spent by minting, whose box ID equals the NFT token ID. Do not confuse this with `IndexedToken.boxId`.

- V1 issuer R4 is an Int royalty value in thousandths: 20 means 2%. The issuer script determines the royalty destination in the described auction design.
- V2 issuer R4 is the version Int, R5 is `Coll[(Coll[Byte], Int)]` of recipient ErgoTrees and royalty shares, and R6 is the nested properties/levels/stats tuple: `(Coll[(bytes, bytes)], (Coll[(bytes, (Int, Int))], Coll[(bytes, (Int, Int))]))`.
- V2 issuer R7 selects the collection token ID, or is empty. R8 is `Coll[(bytes, bytes)]` of additional information including the `explicit` flag. This R8 is not the media hash.
- The document's version-dispatch wording and its V1 royalty range deserve fixtures; implement explicit known layouts, not a heuristic that treats every small Int as valid V2. Royalties are auction-contract behavior, not a fee automatically imposed on every wallet transfer.
- Artist identity is traced to the first P2PK input in the transaction ancestry described by the standard; a display name, current holding address or arbitrary mint-output script cannot authenticate an artist. An address still does not establish a real-world identity.

[EIP-34, NFT Collection Standard](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0034.md), Proposed, allows multiple units of a collection token. Membership requires the collection token in the artwork's issuer input, together with EIP-24's selection rule; matching names or a claimed collection ID alone is insufficient. The collection's own issuer box carries R4 version Int (1), R5 `Coll[Coll[Byte]]` of logo/featured/banner/category strings, optional R6 social pairs, R7 expiry Long (`-1` means none), and R8 additional pairs. Name and description remain in the collection issuance output. Expiry is not automatically enforced by token consensus.

Recommendation: describe EIP-24/34 here, but defer artist tracing, traits, royalty presentation, collection grouping and collection images. They add historical lookups and ambiguous trust claims without helping the first useful view. Do not label self-reported `explicit=false` as a safety verdict.

### Classification proposed for Argus

Store separate facts: `supplyEvidence`, `decimalsEvidence`, `declaredAssetKind`, `metadataState`, and `mediaState`. Do not make `isNft` an authorization decision.

| Evidence | Display/filter behavior |
| --- | --- |
| Original emission = 1 and valid decimals = 0; R7 picture/audio/video | “Single-unit artwork · picture/audio/video”; include in Collectibles |
| Original emission = 1 and decimals = 0; no NFT declaration | “Single-unit token”; include in Collectibles, without implying artwork. Protocol identifier tokens can be singletons. |
| NFT R7, but supply > 1 | “Declared artwork · multiple units”; show actual supply/holding. Collection type gets “Collection token.” Include in Collectibles, never claim uniqueness. |
| NFT R7, but emission or decimals unavailable | “Declared artwork · supply unconfirmed”; include with uncertainty |
| No reliable emission/type, including metadata fetch failure | “Token · metadata unavailable”; stay in All, count as unclassified, never silently label NFT |
| Malformed registers or contradictory sources | “Metadata invalid” or “Metadata conflict”; preserve raw balance and ID; no preview until resolved |
| Unknown NFT subtype/category-only | “Declared NFT · unsupported type”; no guessed image decoder |

Original emission matters: burning a fungible supply down to one does not make it originally unique. Classification never changes coin selection, spendability, transaction review or token identity. Media absence/hash failure does not remove ownership. A valid EIP-4 declaration is still issuer-authored information, not a verified badge.

### Existing implementations: useful precedent, not a security specification

- [Ergo Wallet's TokenInfoManager](https://github.com/ergoplatform/ergo-wallet-app/blob/540e5edbe0e337e78474e6ce6759c482f3d66cd7/common-jvm/src/main/java/org/ergoplatform/tokens/TokenInfoManager.kt) obtains the issuance box via node/explorer, builds EIP-4 data, persists registers and separates picture/audio/video thumbnail kinds. Its [TokenUtils](https://github.com/ergoplatform/ergo-wallet-app/blob/540e5edbe0e337e78474e6ce6759c482f3d66cd7/common-jvm/src/main/java/org/ergoplatform/tokens/TokenUtils.kt) distinguishes a holding-based singleton helper from a full-supply helper. This is evidence of both the convention and the danger of borrowing the wrong predicate.
- Its [detail model](https://github.com/ergoplatform/ergo-wallet-app/blob/540e5edbe0e337e78474e6ce6759c482f3d66cd7/common-jvm/src/main/java/org/ergoplatform/uilogic/tokens/TokenInformationModelLogic.kt) has explicit download states and a download-content preference. Argus should similarly separate metadata from media, but avoid consent for one image silently authorizing future unsolicited content.
- Nautilus uses artwork subtypes in [walletStore](https://github.com/nautls/nautilus-wallet/blob/c2700a6770615119ba4e68b7b64852b2bc450305/src/stores/walletStore.ts), persistent [asset information](https://github.com/nautls/nautilus-wallet/blob/c2700a6770615119ba4e68b7b64852b2bc450305/src/database/assetInfoDbService.ts), and picture details in [AssetInfoDialog](https://github.com/nautls/nautilus-wallet/blob/c2700a6770615119ba4e68b7b64852b2bc450305/src/components/asset/AssetInfoDialog.vue). Its [AssetImageSandbox](https://github.com/nautls/nautilus-wallet/blob/c2700a6770615119ba4e68b7b64852b2bc450305/src/components/asset/AssetImageSandbox.vue) points an empty-sandbox iframe at `https://nautilus-nft-sandbox.azurewebsites.net/?url=…`, resolving IPFS through a setting. This isolates browser content but exposes the URL to another service; this source alone does not establish where the actual image fetch happens or prove privacy.
- The inspected [Ergo explorer frontend token page](https://github.com/ergoplatform/explorer-frontend/blob/285d2214f8ca5f7e821a86661d8b9ec2843228b0/src/pages/token/token.component.tsx) displays ID, emission, type, decimals and description; its [API service](https://github.com/ergoplatform/explorer-frontend/blob/285d2214f8ca5f7e821a86661d8b9ec2843228b0/src/services/token.api.service.ts) calls `/api/v1/tokens/{id}`. This inspected source does not implement an artwork preview or prove what every currently deployed explorer does. An explorer's `type` field is not enough to authenticate an NFT.

## 2. What Argus already provides

Paths below are relative to this document; findings describe the research baseline.

| Existing component | Reuse and actual gap |
| --- | --- |
| [TokenBalance and metadata cache](../../../app/lib/services/wallet_service.dart) | Already carries ID, holding, decimals, emission, icon URL and stealth quantity. `isNft` is exactly `amount == 1 && decimals == 0 && (emissionAmount == null || emissionAmount == 1)`. A failed metadata lookup returns default decimals zero and unknown emission, so one COMET can become an NFT. There is no R7 check. Add evidence/state fields rather than another holding model. |
| [Rust token lookup](../../../rust/crates/wallet-net/src/client.rs), [FFI enrichment](../../../rust/crates/wallet-ffi/src/api.rs) | Node extraIndex token lookup with explorer fallback already exists. FFI reads issuance R7/R9 and emits `mediaKind` and `iconUrl`. Dart discards `mediaKind`; description, R8 hash and source/completeness are also absent from its model. `iconUrl` is extracted independently of a recognized R7, so even arbitrary token R9 can become an avatar URL. |
| [Register helpers](../../../rust/crates/wallet-ffi/src/api_ergopay_impl.rs) | Hand-decoded byte collection and exact serialized R7 strings support three media kinds. No audio tuple, hash checking or collection marker. Decoder accepts a valid prefix with trailing bytes. Reuse the pinned Sigma library with strict type/length/full-consumption checks, not more bespoke hex cases. |
| [Assets](../../../app/lib/ui/assets_screen.dart), [dashboard](../../../app/lib/ui/dashboard_screen.dart), [detail sheet](../../../app/lib/ui/widgets/token_detail_sheet.dart) | Assets already has Tokens/NFTs sections and live holdings; dashboard orders fungibles before NFTs and caps displayed assets at four. Details already have ID, explorer and Send. Add a filter/search and better details; no new ownership scan or signing path. Assets builds all section children eagerly and needs lazy rows for large holdings. |
| [TokenAvatar](../../../app/lib/ui/token_avatar.dart), [media resolver](../../../app/lib/services/media_url.dart) | `Image.network` fetches automatically; IPFS is hardcoded to `https://ipfs.io/ipfs/…`; HTTP is accepted. Detail image has a loading block and “Artwork unavailable.” No explicit byte/pixel limits, hash, disk policy or consent. Tiny display dimensions do not bound source download/decode size. This behavior must be replaced wherever issuer-controlled icons reach shared widgets, including send/pickers. |
| [Per-wallet token count](../../../app/lib/ui/widgets/wallet_token_count.dart) | Counts distinct positive token IDs including NFTs; unknown/hidden snapshots produce no count and locked snapshots say “public.” Keep this definition. It is already a useful entry point to Assets, not an NFT count or number of collection items. |
| [Sync controller](../../../app/lib/services/wallet_sync_controller.dart), [public sync](../../../app/lib/services/public_wallet_sync.dart) | Reuse confirmed/pending holdings, snapshot age, wallet generation checks and merged stealth holdings. A cached descriptor is never proof of current ownership. Preserve public-only/partial states; do not turn an unavailable stealth scan into zero NFTs. |
| [Verified list](../../../app/lib/services/verified_tokens.dart), [pricing](../../../app/lib/services/token_pricing.dart) | ID-based curated verification/caution and impersonation warnings already exist. Unverified pool prices are excluded from totals. Reuse warnings, but do not infer artwork authenticity from a name, collection, R7 or image hash. No NFT floor prices or estimated collection wealth. |

The current `argus_token_meta_v2` preference map is app-wide, keyed only by token ID, containing name/decimals/emission/icon. It has no bound, source, schema-specific completeness or retry timestamp. Successful token lookup plus failed issuance lookup can permanently cache “no image.” `prefetchTokenMeta` and `hydrateTokens` use unbounded `Future.wait`. A gallery would multiply existing weaknesses. A bounded incremental cache migration and queue are necessary reuse work, not optional polish.

Privacy is an existing product choice. [PriceSource](../../../app/lib/services/token_pricing.dart) defaults to the on-chain oracle and explicitly describes external CoinGecko requests. [PrivacyService](../../../app/lib/services/privacy_service.dart) supports unused change addresses, hidden balances and default screenshot blocking. [StealthService](../../../app/lib/services/stealth_service.dart) fetches boxes by template and tests ownership locally in [Rust](../../../rust/crates/wallet-ffi/src/api_stealth_impl.rs); Argus also has mixer support. This makes a unique image request particularly consequential: a sender can correlate a stealth payment's unique URL with a viewer IP/time, bypassing the intended unlinkability without attacking cryptography.

Do not claim Argus currently avoids all such disclosure: stealth holdings already enter ordinary metadata hydration, and token metadata already falls back to an explorer. [WalletDatabaseService](../../../app/lib/services/wallet_database_service.dart) explicitly documents obfuscation rather than encryption and iOS backup exposure. Public chain data can still be sensitive when its local presence identifies which assets a device owns or views. The proposal must not expand that history casually. No Tor guarantee was found in the inspected network path.

## 3. Realistic choices

### Product shape

| Option | Cost, risk and failure modes | Decision |
| --- | --- | --- |
| Keep current rows; correct labels and text details | Smallest UI change, zero new media traffic. Less visually satisfying; incomplete metadata needs explicit state. | First release. |
| Assets Collectibles filter, optional per-item preview | Reuses ownership/sync/details. Requires lazy rows, metadata states and a controlled fetcher. A tap can still disclose interest; consent must be item-specific. | Recommended scope. |
| Separate gallery, using the same holdings/cache | Better visual browsing; another navigation surface, layout/accessibility work, spam controls and many concurrent decodes. Empty/error tiles dominate offline; temptation to prefetch creates bandwidth/privacy cost. | Defer. Only consider a cached-only alternate layout after actual demand. |
| Explorer-only viewing | Almost no renderer maintenance, broad format coverage. Exits wallet, exposes token ID/IP/browser context, adds phishing and availability dependence. | Explicit existing explorer link remains an escape hatch, not the primary experience. |
| Full collections/marketplace | Historical provenance, royalties, listings, valuations and third-party APIs; confusing ownership versus offers and large mobile maintenance burden. | Reject for this task. |

### Metadata and media sourcing

| Source | Tradeoff/failure | Policy |
| --- | --- | --- |
| Configured indexed node, raw issuance data | Closest to existing trust boundary; may be unindexed, unavailable or lagging. Operator still sees token IDs. | Default metadata source; record endpoint/network and completeness. |
| Configured explorer API | Useful fallback and alternate register JSON shape; centralized observation, outages, inaccurate/indexed summaries. | Explicit “Allow explorer fallback for collectible metadata,” off initially for new collectible enrichment. No silent broadening from a user's node choice. |
| Current holding UTXO registers | Cheap if already synced, but contracts may overwrite registers or use unrelated layouts. | Never use as mint metadata without proving it is the issuance output. |
| Marketplace/JSON aggregation service | Easy thumbnails/traits, but stale/unverifiable transformations, wallet-wide query disclosure, API churn and dependency. | Do not add. |
| Direct HTTPS media | No new Argus server; origin sees IP, timing and unique URL. Mutable/malicious host, SSRF and decode risks. | Explicit per-item load, strict endpoint and resource policy. |
| IPFS through a configured HTTPS gateway | Compatible with common art; gateway sees CID/path/IP, cold retrieval can be slow, no availability promise. | Explicit load; default proposal uses `https://ipfs.io/ipfs/{CID}/{path}` with displayed host and configurable gateway. No gateway racing/failover. |
| Argus thumbnail proxy | Can resize and hide client IP from origin, but Argus service sees every request, needs abuse controls, storage, bandwidth and operations; transformed bytes cannot be compared directly with R8. | Do not operate one for this feature. A future proxy requires its own threat model, not a claim of anonymity. |
| Embedded IPFS node/general web viewer | Network discovery traffic, storage/battery/attack surface disproportionate to wallet benefit. | Reject. |

A chain-only stop is legitimate if the safe fetch/decode boundary cannot be demonstrated on supported phones. The alternatives lose primarily on unsolicited disclosure and maintenance scope, not because a gallery is technically difficult to draw.

## 4. Concrete recommended design

### Ownership, metadata and endpoints

Use `walletSyncController.displayTokens` for the active wallet, with its generation and completeness. Never issue a second address discovery for the filter. All includes unknown tokens; Collectibles shows evidence-based matches and “N tokens unclassified” linking back to All. Search is local over token ID and normalized display name. Hidden is a reversible local filter, never a burn; hidden items remain visible in transaction review if spent. Keep actual quantities and stealth sweep restrictions.

Fetch metadata lazily for visible rows (page of 20) and selected detail; stop queuing when a page disappears. Do not classify the entire wallet before displaying balances. Deduplicate `(network, tokenId)` in-flight jobs. Maximum two metadata jobs, maximum two explicitly configured node attempts per job, 8 seconds per attempt, 20 seconds total per detail request. Explorer fallback, if permitted, must fit the same total budget. Bound token/box JSON responses to 256 KiB decoded, any transaction response to 1 MiB, streaming rather than trusting Content-Length. These are proposed application limits; too-large responses become an explicit state, not evidence of no token.

1. `GET {node}/blockchain/token/byId/{64-hex-tokenId}`; current default node is `https://ergo-node.eutxo.de`.
2. `GET {node}/blockchain/box/byId/{IndexedToken.boxId}` for the historical issuance output (not `/unspent/…`). Validate returned ID and that assets contain the requested token. Decode R4–R9 by type. Normalize node hex strings and explorer `{serializedValue, …}` register objects at the transport boundary; never trust a `renderedValue` as typed evidence.
3. Allowed fallback: `GET {explorer}/api/v1/tokens/{tokenId}` and `GET {explorer}/api/v1/boxes/{issuanceBoxId}`; configured default is `https://api.sigmaspace.io`. Preserve the provider relationship rather than silently using unrelated globals for the second call, as today's FFI does.
4. If index/box data conflicts, stop with conflict state. For disputed emission/provenance, an explicit advanced lookup can use `GET {node}/blockchain/transaction/byId/{issuanceTransactionId}` (or explorer `/api/v1/transactions/{id}`), check first input ID equals token ID and sum newly issued units across outputs. Do not mistake one issuance output's quantity for total emission. This still trusts provider chain inclusion; it is not a local full-node proof.
5. Future EIP-24 lookup would be `GET {node}/blockchain/box/byId/{tokenId}` (or explorer box equivalent), the spent issuer input. It is not needed for initial images and must not be automatically fetched for every row.

A bounded Rust descriptor returned across FRB should carry network, token ID, issuance box/transaction IDs, original emission evidence, nullable decimals, name/description, raw declaration bytes, typed media URI/optional audio cover URI/hash, source, fetch time and parse/completeness status. Keep URIs separate from curated icons. Dart controls presentation and consent; a dedicated Rust media client can reuse HTTP tooling but must not inherit node API credentials, headers, redirect policy or private-host exceptions. Use strict full-input Constant parsing, at most 4 KiB serialized register data per box, UTF-8 checks, bounded type nesting and no script evaluation. These limits need malformed-input tests before release.

This investigation made a read-only request for public COMET ID `0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b`. The [default node token endpoint](https://ergo-node.eutxo.de/blockchain/token/byId/0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b) returned HTTP 200, emission 21,000,000,000 and decimals 0. Its [issuance box](https://ergo-node.eutxo.de/blockchain/box/byId/d1957ee6d5de2d53c066ca49fe87f910409652d7308bfc63bf1f550695932657) returned R4–R6 as serialized strings. The corresponding configured explorer token request returned HTTP 403. This validates the node shape and a realistic failure case, not NFT coverage or an explorer SLA. No wallet addresses or arbitrary media URLs were sent in this research.

### Preview consent and hostile-content boundary

Default avatars use bundled icons or a locally generated token-ID mark. No issuer URI fetch on dashboard, list, notification, send review, widget build or background sync. Apply the rule to all tokens, because an NFT-only gate leaves the R9 avatar path open.

Details show “Remote preview not loaded” and, for supported static-picture candidates, **Load preview**. Before the first request for this item, show the actual destination host (punycode where relevant), protocol/gateway, maximum 5 MiB download and: “This host can see your IP address and which artwork you request. Artwork may contain unsolicited or misleading content.” This is a product action, not a global enable toggle. Do not resolve DNS or send HEAD before that action. A “Never load remote previews” setting disables the action. Offline/cold-device mode and locked wallets never initiate these requests. For stealth assets, explicitly mention that loading may link the private holding to this connection; do not auto-hydrate newly discovered stealth-only metadata either. Offer “Load metadata from [provider]” because token-ID queries themselves are revealing. Existing automatic stealth hydration needs this gate in the first increment.

For the optional fetcher:

- Accept strict `https` or parsed `ipfs` URIs only; reject HTTP, credentials, custom ports (allow only 443 initially), fragments, malformed/oversized URLs (>2 KiB), `file`, `data`, `javascript`, local schemes and executable links. Preserve a valid HTTPS query rather than silently changing the resource; it is part of the disclosure. Validate CID and canonical path, reject traversal, and do not convert arbitrary strings into gateway URLs.
- Resolve and reject loopback, private, link-local, multicast, reserved and unspecified IPv4/IPv6 destinations, including mapped IPv4 and IP literals; reject local hostnames. Bind the actual connection to the validated address while retaining TLS hostname verification to defeat DNS rebinding. Apply equivalent checks to custom gateways. A user's LAN node allowance does not authorize issuer-selected LAN media.
- Disable redirects initially, including cross-host and HTTPS-to-HTTP redirects. Show “Redirect blocked.” Never forward node auth, cookies, wallet IDs, addresses, Referer or unique app identifiers. No automatic gateway retry or external browser launch. If the selected HTTP stack cannot enforce this policy reliably, do not ship remote fetching.
- One media job at a time; 5-second connect and 15-second total deadline, cancel on close/lock/wallet switch/background. Stream with a hard 5 MiB body cap and identity content encoding; reject unexpected transport compression. Content-Length is only an early rejection hint. Delete partial files. No automatic retries.
- Initially allow static PNG/JPEG only, verified by bytes and MIME consistency, not extension. Reject animated PNG, GIF, SVG, WebP, HTML, PDF, audio/video, 3D and attachments for in-wallet rendering. Parse dimensions before allocation: at most 4096 per axis and 8 megapixels. Decode one image at a time off the UI thread, with an allocation limit of 48 MiB, into a maximum 1024-pixel-long-edge preview; thumbnail maximum 256. A Dart isolate alone is not a security sandbox for a native codec. Select and test a decoder with enforceable limits; keep a way to disable previews if a decoder vulnerability is found.
- Hash original bytes before transforming. Valid R8 mismatch: refuse rendering/cache, show “Content differs from issuance hash.” Missing/invalid R8: allow only a further explicit “View without integrity check” action after bounded format validation. A match is labelled “Matches issuance hash,” never “Verified NFT.” Audio cover has no implied R8 protection and remains unsupported initially.
- No HTML/Markdown rendering of descriptions, automatic linkification, QR scanning from artwork, scripts, embedded wallet connectors or media-origin signing/deep links. Render issuer text as bounded plain text, strip disruptive control characters/bidi overrides for display, isolate text direction and preserve inspectable original bytes. Limit list names to two lines, detail names to 256 characters and expanded description to 4 KiB. Show the full token ID in a separate app-owned field with copy action. Artwork cannot supply the app's badges or action buttons.

Explorer navigation stays explicit, names the selected explorer and warns once per navigation that it leaves Argus. Unsupported media can be copied as inert text; do not add a “claim,” “verify wallet,” or “unlock rewards” action based on its contents. Send continues through existing review by token ID and real amount, never by picture. Retain caution/impersonation warnings above artwork. Hidden balances also conceal collectible names, counts and cached images until locally revealed; screenshot policy applies to detail screens too.

### Cache and retention

Separate immutable descriptors from mutable holdings and media. Reuse the existing cache API but replace the unbounded preference JSON with an indexed app-private store as scale requires; do not cache large blobs in SharedPreferences.

| Data | Proposed policy |
| --- | --- |
| Complete confirmed descriptor | Key `(network/genesis identity, tokenId, issuanceBoxId, parserVersion)`. At most 10,000 entries or 16 MiB total, LRU; 16 KiB per descriptor. No routine refresh for validated immutable fields. Store provider and confirmation context; invalidate conflicting/reorged records and offer explicit refresh. Eviction removes metadata only, never holdings. |
| Partial/failed descriptor | Persist field completeness separately. Backoff 1 minute, 5 minutes, then 1 hour while visible; no background timer traffic. Retry button bypasses backoff once. Not-found for pending tokens is provisional. Old v2 records migrate as partial and cannot establish “no artwork.” Network changes and parser upgrades permit refetch. |
| Media | Default memory-only, item/session-specific consent; discard on detail close/lock/background/wallet switch. Optional **Keep this preview offline** only after successful load. Store sanitized preview/thumbnail, digest of original and source/integrity status, not original files. Global disk cap 50 MiB, per-item 2 MiB, 30-day expiry and LRU. Never re-fetch on cache miss without a tap. |
| Sensitive association | No persistent newly fetched stealth-only descriptor, media or hidden-item history in first release. Memory-only until lock. Regular preview associations are wallet-scoped; no cross-wallet “already viewed” hints. Keep disk files in platform cache storage, excluded from backup on both Android and iOS. Delete associations/files on wallet deletion; “Clear collectible data” clears descriptor/media caches and consent state without altering assets. |

Do not call disk obfuscation encryption. Cached public artwork becomes a local viewing history. If reliable backup exclusion or scoped deletion cannot be established, keep media memory-only. Negative media outcomes are remembered only for the current session; manual retry is always deliberate, never driven by rebuilding a widget. Cached previews do not contact origins for freshness or telemetry. A cached preview reflects previously obtained bytes; it cannot prove a mutable origin still serves them.

### Failure states and what the user sees

| State | UI and allowed action |
| --- | --- |
| Holdings not loaded / partial public snapshot | “Holdings not loaded” / “Public holdings only” with last-sync time. Never “No collectibles” until a complete snapshot supports it. |
| Complete holdings, no classified matches | “No identified collectibles”; report unclassified count separately; All still shows those assets. |
| Metadata loading | Stable token ID and actual amount; “Loading metadata…” with cancelable, bounded request. |
| Offline, cache hit | Cached details and kept preview with “Offline · holdings last synced …”; no request. |
| Offline, cache miss | “Metadata unavailable offline” / “Preview not saved”; retain ID/amount. |
| Node lacks index / timeout / 403 / rate limit | “Metadata unavailable from [provider]”; Retry and, when policy allows, explicit explorer fallback. Respect Retry-After within bounded scheduling. Do not cache this as non-NFT. |
| Absent R9 | “No media link in issuance metadata.” |
| Unsupported subtype, URI or format | “Preview not supported” with type/reason; metadata and inert URI copy remain. |
| User has not loaded / opted out | “Remote preview not loaded” / “Remote previews disabled.” |
| Downloading | Bytes received (percentage only with trustworthy length), Cancel. No blank endless spinner. |
| Timeout, missing gateway content or decode failure | “Preview unavailable” with specific reason and manual Retry. |
| Too large / dimensions exceed limit | “Preview exceeds wallet limits (5 MiB / 8 MP)”; no override in wallet. |
| Unsafe destination / redirect | “Preview address blocked” / “Redirect blocked”; no bypass button. |
| Hash mismatch | “Content differs from issuance hash”; no image, no trust badge. |
| Cache evicted / storage full | “Preview not saved”; memory display may continue, offline save reports failure. Never silently exceed quota. |
| Wallet switched/locked or asset transferred | Cancel job, ignore stale completion. Remove old-wallet visual content; cached descriptor does not create a holding. |

## 5. Phone cost and honest scope

These are planning bounds, not measured performance claims. At 100 KiB each, 1,000 thumbnails cost about 98 MiB; fetching 2 MiB originals for them costs about 1.95 GiB. One 8 MP RGBA decode is about 32 MiB before scratch buffers, so setting widget width to 40 pixels is insufficient. A 1024-square preview is about 4 MiB decoded. Allow one decoder and an NFT-specific decoded cache budget of 12 MiB; verify the chosen decoder's total peak separately against the 48 MiB limit. Existing Flutter global image caching must not defeat these limits.

For 1,000 unseen tokens, two historical metadata requests each means about 2,000 requests before retries. At two jobs and modest latency, that is many minutes, not a startup prerequisite. Lazy pages, deduplication and offline metadata are essential. An explicit “Load next 20 metadata records” can complete classification without automatically crawling a collection. No media prefetch, periodic polling, background thumbnail generation, animations or multi-gateway races: these cost radio wakeups, CPU, battery and disclose more interest.

Dashboard stays four compact rows. Collectibles is a filter inside Assets, not a permanent image strip taking space from balances and Send/Receive. Accessibility uses app-owned labels and ID, never requires recognizing artwork. First supported media scope is small static PNG/JPEG previews; video playback, animated art and large originals belong outside this wallet's renderer.

Indicative engineering scope for one developer familiar with Argus: roughly one week for classification/data migration/text UI and regression coverage; another two to three weeks for a secure media fetch/decode/cache path and device validation. These are uncertain planning estimates, not commitments. If decoder isolation/limits need new platform code, the second increment must be re-estimated or dropped. Drawing the view is the inexpensive part.

## 6. Build order and acceptance gates

1. **Honest collectible identification and details without remote media.** Add typed descriptor/evidence states across Rust/FRB/Dart, strict R4–R9 parsing, bounded metadata queue and partial-cache migration. Correct `isNft` consumers without altering transfer behavior. Gate stealth-only metadata queries. Remove automatic issuer-controlled avatar/preview requests everywhere. Add plain description/supply/type/ID details, lazy All/Collectibles filter and unknown count; preserve wallet count semantics, privacy masks and partial holdings. This is independently useful and releasable.
2. **Explicit static preview, memory-only.** Implement the separate fetcher and decoder only after the destination, resource and cancellation guarantees above are testable. Add per-item disclosure, hash status and full failure UI. No gallery and no global auto-load preference.
3. **Optional offline preview retention.** Add bounded sanitized disk cache, backup exclusions, scoped deletion, quota/error UX and clear-data control. Measure before enabling. If platform retention cannot be controlled, stop at step 2.
4. **Demand-led follow-up only.** Consider a cached-only grid and additional interoperable static formats after measuring user need. EIP-24/34 provenance/traits and artist verification require a separate proposal. Do not let optional follow-up delay the first increment.

Implementation verification must cover genuine failure boundaries, not just happy-path fixtures:

- Table tests for known fungible held as one, unknown emission, malformed decimals, singleton protocol token, multi-unit artwork and collection, unknown subtype, audio tuple, missing R9, R8 length/mismatch, malformed/truncated/trailing Constant bytes and nested-type limits. Compare real issuance fixtures with pinned sigma-rust and an existing wallet; retain source IDs in fixtures.
- Transport tests for node/explorer schema variants, issuance/issuer confusion, total emission split across outputs, unavailable index, 403, rate limits, partial cache upgrade, reorg/conflict, testnet/mainnet separation and persistent failures. Verify holdings render without awaiting metadata fan-out.
- Network tests that mounting every shared token widget makes zero media requests; initial stealth-only discovery makes zero token-specific enrichment requests. Exercise IPv6/mapped addresses, rebinding, redirects, credential leakage, compressed/chunked oversized bodies, false MIME, decompression bombs, decoder failures, cancellation and backgrounding.
- UI/state tests for All versus Collectibles, exact ID/copy, hidden balances, stale/public-only snapshots, wallet-switch races, send review preserving real quantities, hide/unhide without burning, offline cache miss/hit and failed save.
- Real low-memory Android and supported iOS measurements with 1,000 and 10,000 holdings, a slow gateway and airplane mode: request concurrency, transferred bytes, decoded-memory peak, responsiveness, cache cap, deletion and backup exclusion. A thousand metadata jobs must not become a thousand media requests. Fail the media release if limits cannot be enforced.

No helper or implementation code was needed to make this proposal credible; no builds were run. Research used source inspection and bounded public endpoint reads. Build output and temporary archives were not written to `/tmp`.

## 7. Risks not accepted, refusals and remaining uncertainty

I would refuse automatic arbitrary media fetching, blanket consent triggered by receiving a token, silent gateway/proxy fallback, media from private network destinations, embedded web content with wallet privileges, content-derived signing actions, unlimited downloads/decodes, and pricing or authenticity claims derived from artwork/name/hash. I would not build a gallery until the existing shared-avatar leak and unknown-supply classification are corrected. I would not add a public thumbnail service simply to avoid implementing a mobile trust boundary.

Residual risks must be stated honestly: a user-authorized request still reveals IP/time/interest; a unique URL can fingerprint a recipient; PNG/JPEG decoders still carry vulnerability risk; a cached image is a local privacy footprint; metadata sources can lie. A preview is not a certificate, and a private transaction route does not anonymize ordinary HTTP. No consent dialog cures unsafe networking or decoding.

The largest unresolved question is real-world compatibility: how much of the artwork users actually hold has valid R7/R8/R9, uses audio tuples, omits hashes, uses redirects, or consists of SVG/large originals. This research did not measure a representative collection corpus or fetch arbitrary artwork. Before broadening scope, obtain a public, reproducible sample of issuance IDs across known minting tools and EIP-24 versions, inspect registers without querying users' wallets, and measure formats/sizes with consent in an isolated research client. Compare with at least Ergo Wallet and Nautilus. Also resolve the attachment example discrepancy with maintainers before supporting it.

The second uncertainty is whether available mobile decoders and HTTP plumbing can enforce the proposed bounds without disproportionate new native code. Resolve through a small implementation spike with malicious fixtures and real-device memory/network traces, in its own reviewed change. Until both questions are answered, strict unsupported states and a text-only release are deliberate product boundaries, not incomplete gallery work.

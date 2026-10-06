# Storage rent in Argus

Date: 2026-10-06. Status: implemented on `roadmap/rent` (roadmap items E1, E2 and the UTXO-management half of G2).

## Decision

Show storage rent where the user can act on it, and nowhere else: a hint under the ERG amount of every recipient that receives tokens, a line per box in UTXO management, and a suggested cleanup at the top of UTXO management. The main screens stay rent-free. Every figure comes from the wallet core (`wallet_core::rent`) and the user's own node. The hint and the suggestion are advice: no amount the send form already accepts is refused, and nothing is signed without the usual confirmation sheet.

## The rules, as verified

Sources: arkadianet/ergo (Rust node with consensus parity to the Scala reference): `ergo-validation/src/tx/script/storage_rent_check.rs` (`is_storage_rent_eligible`, `check_storage_rent`), `ergo-validation/src/storage_rent.rs` (`compute_storage_fee`), the JVM oracle vectors in `test-vectors/ergo-sigma/verify/rent-cases.json`; arkadianet/storage-rent-bot `DESIGN.md` and `src/strategy.rs`, which cite Scala `ErgoInterpreter.checkExpiredBox` and `Constants.StoragePeriod`.

- **When.** A box may be spent without its script by a block at height `>= creationHeight + 1,051,200` (`4 × 365 × 24 × 30`, inclusive). Mempool validation uses the next block's height, so a box due at `D` can be collected once `D − 1` is the tip. The creation height is what the creating transaction declared, not the inclusion height.
- **How much.** `fee = storageFeeFactor × box.bytes.length`, an `Int × Int` product that wraps (ergoplatform/ergo#2251). At 1,250,000 nanoERG per byte the product goes negative above 1,717 bytes: a collector would have to add ERG to the box, so boxes of 1,718–3,435 bytes are never collected in practice. From 3,436 bytes it wraps positive again and is charged (a 4,032-byte box: 0.745 ERG).
- **What happens.** If `value − fee <= 0` the whole box may be taken, tokens included. Otherwise the box must be recreated with the same script, tokens and registers, at least `value − fee`, and the collecting block's height as creation height, which starts its next four years.
- **Size.** `box.bytes` is the whole serialized box the node hashes for its id: candidate with inline token ids, the 32-byte transaction id and the VLQ output index. The core measures existing boxes with ergo-lib, which rejects node JSON whose `boxId` differs from the hash of those bytes, so the size is exact. At today's heights a P2PK box without tokens is 77–79 bytes (about 0.1 ERG of rent); with one NFT, 110–112 bytes (0.1375–0.14 ERG). Any box worth less than that, ERG-only dust included, loses everything once due.

`wallet_core::rent` tests pin the JVM vectors (a 44-byte box, 55,000,000 fee, recreated value 945,000,000 accepted and one nanoERG less rejected), a real mainnet box (438 bytes, 0.5475 ERG), and the wrap boundaries.

## Where storageFeeFactor comes from

`/info` on the user's node: `parameters.storageFeeFactor` for the current voting epoch, with `fullHeight` as the tip (`wallet_net::rent_params`). A mainnet Scala 6.1.7 node at height 1,885,661 reports 1,250,000. The call goes through the same node list as every other request (`node_client`); no new hosts are contacted. `FALLBACK_STORAGE_FEE_FACTOR` (1,250,000, the launch value) stands in only when the node omits the factor, or, for the send hint, when `/info` cannot be read at all; the UI then says "default rate". Miners can vote the factor anywhere in 0–2,500,000, so every figure is "at today's rate".

## Rent per box (E2)

`box_rent_report` lists the confirmed unspent boxes at the wallet's addresses (the endpoint the screen already uses, read a second time) and returns each box's size, fee, charge (`fee`, `whole_box` or `none`), due height and blocks to go. Each card shows the fee, the due block and an approximate date at 2-minute blocks. **Due soon** means collectable now or within 30 days (21,600 blocks); **at risk** means the value does not exceed the fee, whenever it falls due. Boxes the protocol cannot charge say so. The summary card counts both, names the rate, and a "Rent" filter keeps the flagged boxes. A failed report leaves the list and the tools working.

## Send hint (E1)

For each recipient carrying tokens, `output_rent_estimate` raises the amount to the size floor and lays the tokens out exactly as the send builders do (`RecipientSpec::minimum_value`, `token_outputs`), then measures each box. The suggestion is the smallest whole 0.01 ERG that pays one charge and keeps the 0.001 ERG minimum box value, settled over the value's own VLQ width (0.14 ERG for an NFT to a P2PK address). Stealth recipients are measured through a throwaway one-time script of the same length. Until a recipient is typed, an ordinary address stands in. Not shown for buy-and-send, whose router sets that output's ERG.

## Suggested cleanup (G2, UTXO-management side)

A single consolidation transaction, proposed only when it helps:

- **One address.** Boxes at one address are already publicly linked; merging across addresses would link them, which coin control warns about and the cold-signing design calls a privacy regression. The new box goes back to the same address.
- **Never moved:** mixed boxes, funding reserved for a pending mix, and boxes this screen has already spent but the node still lists.
- **When.** An address with an at-risk or due-soon box qualifies; so does any address once the wallet is fragmented (more than 80 boxes, the home screen's threshold). The address with the most flagged boxes wins, then the largest.
- **Which boxes.** Fragmented: up to 100 (the existing per-transaction cap), flagged first, then dust, then oldest. Tidy: only the flagged boxes. Either way the address's largest ERG-only box joins, so rescued boxes land in one that can pay its rent.
- **Before signing** the review shows boxes merged, resulting boxes (the consolidation builder's own token layout), rent clocks restarted, miner and Argus fees, value after fees, and the new box's rent and due date.

Entry point for the home indicator: `UtxoManagementScreen(openCleanup: true)`, routed as `UtxoManagementScreen.cleanupRoute` (`/utxos/cleanup`). It opens the review as soon as boxes and rent have loaded, or says there is nothing to clean up.

## Limits

- The node lists confirmed boxes. A box spent by a pending transaction from another screen can still be proposed until mined; preparing then fails, and nothing is signed.
- The output index is assumed below 128 (a one-byte VLQ); a 128th output would be one byte larger.
- The overflow rule is reported as consensus applies it today. A protocol fix would make 1,718–3,435-byte boxes chargeable at the full per-byte rate.

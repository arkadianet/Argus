# ErgoPay (EIP-20) in Argus

Date: 2026-09-02
Status: design, implemented in the same change set (Phase B of the future-work plan)

## Goal

A dApp can hand Argus a reduced transaction by deep link or QR, the user
sees what it does in the same confirm sheet as a send, signs with PIN or
biometrics, and the dApp learns the transaction id.

## Request intake

Two link shapes, both handled by `parseErgoPayLink` (pure, tested):

| Shape | Meaning |
|---|---|
| `ergopay:<base64url>` | Static request: the payload is the reduced transaction itself. |
| `ergopay://host/path?...` | Remote request: replace `ergopay://` with `https://` (plain `http://` only for loopback/LAN hosts, same rule as node URLs) and GET a JSON `ErgoPaySigningRequest`. |

A remote URL may contain `#P2PK_ADDRESS#`. Argus asks the user to pick one
of the wallet's addresses (default: the current sender address) and
substitutes it before fetching.

Entry points: Android `VIEW` intents for the `ergopay` scheme (cold start
and warm), and the QR scanner from the home app bar. `ergo:` payment URIs
scanned from the same button go to the send screen as before.

If the wallet is locked when a link arrives, the link is parked in
`DeepLinkController` and opened as soon as the wallet unlocks.

## Signing request

```
{ "reducedTx": base64url, "address"?: string, "message"?: string,
  "messageSeverity"?: "INFORMATION"|"WARNING"|"ERROR", "replyTo"?: url }
```

- `reducedTx` missing → show the message only (a dApp "connect" or an
  error) and offer Close.
- `address` present and not owned by the wallet → refuse with a clear
  message. Ownership is checked in Rust (`wallet_owns_address`).
- `messageSeverity` ERROR → show the message and stop.

## Summary

`describe_reduced_transaction(handle, bytes, node_url)` (Rust, async):

1. Deserialise the reduced transaction.
2. Fetch each input box from the node (best effort) for values and tokens.
3. Classify every output: `fee` (miner fee tree), `change` (address owned
   by the wallet), else `recipient`.
4. Return inputs, outputs, `fee_nano_erg`, `sent_nano_erg`,
   `change_nano_erg`, `tokens_out`, and `spend_nano_erg` when input values
   are known (inputs − change).

The pure classifier `summarize_reduced` is unit-tested against a locally
built reduced transaction (recipient + change + fee, with tokens).

## Confirm and reply

Reuse `ConfirmTransactionSheet`: To (first recipient, full address
selectable), Amount, Tokens out, Miner fee, Change, and the dApp message as
the detail line. Inputs with unknown values show "Inputs: n (values
unavailable)". Confirm → `sign_reduced_transaction` → `submit_signed_transaction`
→ if `replyTo`, POST `{"txId": "..."}` (best effort; a failed reply is
shown but the transaction is already broadcast).

## Out of scope

ErgoAuth (needs a signing-message primitive not yet in wallet-core),
`#MULTIPLE_ADDRESSES#`, iOS universal links.

## Tests

- Dart: link parser (static, remote, placeholder, http-local rule), request
  JSON parser, reply body, `DeepLinkController` parking/unparking.
- Rust: `summarize_reduced` classification and totals.

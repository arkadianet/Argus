# Historical mainnet evidence

Captured 2026-09-11. `fetch.py` refreshes these files using only Python's standard
library; tests are offline and never invoke it.

| File | Transaction |
| --- | --- |
| ergopad.json | `0e1f269f2fe8e75d1c75d6550b4bff13ec43cdde7cb5afc94690e5cc1139e032` |
| paideia-unstake.json | `fccb0c4979d43295a27af7be0da3aa93db840776979621bee7c13a1b51c3cf97` |
| paideia-refund.json | `72e33dd7344b76cd3cd1a3721f126b3e6dc2f24620ed486af9eceabbbe690c7f` |

Each file retains the explorer response from
`https://api.ergoplatform.com/api/v1/transactions/{id}`. The indexed node
`https://ergo-node.eutxo.de/blockchain/transaction/byId/{id}` supplies complete
input boxes, including creation transaction ids, output indices, creation heights
and explicit spending proofs/extensions. The original signed transaction comes
from `/blocks/{blockId}/transactions`. The inclusion header and ten preceding
headers come from `/blocks/{blockId}/header`, following parent ids. All three
transactions have empty data-input lists and explicitly empty context extensions;
`dataInputBoxes` records the corresponding empty list rather than inventing
missing context.

The harness reconstructs canonical input ids, cross-checks creation metadata
against the explorer, matches each input to the signed transaction and verifies
the unsigned transaction id against the historical id. The inclusion header
supplies the preheader; previous headers supply the interpreter's header context.
`Parameters::default()` follows Argus's signing/reduction usage. These tests
prove propositions under the pinned interpreter, not historical consensus cost
validation or current unspentness.

Only factual addresses, asset ids and pinned contract constants were consulted
in the archived reference crate. No reference implementation code is used.

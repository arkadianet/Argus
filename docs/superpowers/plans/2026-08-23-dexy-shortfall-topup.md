# Dexy Shortfall Top-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When sending a Dexy token the wallet holds *some* but not enough of, acquire only the shortfall and deliver held-plus-acquired to the recipient in one transaction.

**Architecture:** The Dexy builders currently put exactly the minted/swapped amount in the recipient output and return every held token to change. Add one field to each request struct that moves N held tokens into the recipient output and excludes them from change. Token conservation is preserved: the held tokens move from the change box to the recipient box within the same transaction. Input selection already supports pulling a required token amount into the inputs, so no new selection logic is needed.

**Tech Stack:** Rust 2021, flutter_rust_bridge 2.11.1, Flutter/Dart, `cargo-ndk`.

## Global Constraints

- **This plan intentionally modifies `rust/crates/vendor/protocols/dexy/`.** That reverses the constraint in `docs/superpowers/specs/2026-08-23-amm-direct-swaps-design.md`. It is a deliberate, approved exception — the recipient output is built inside the vendored builders and cannot be corrected from `wallet-ffi` without rewriting a built transaction's outputs, which is fragile and untestable without a node.
- **The change must be upstreamed to `arkadianet/citadel`** (currently vendored at commit `f533f15`, per `docs/dependency-list.md:21`). If it is not, the next re-vendor silently reverts it *and* deletes the tests that would catch the regression. Task 7 covers this and is not optional.
- Argus levies **no dev fee**. Never remove the `std::env::set_var("CITADEL_DEV_FEE_ENABLED", "false")` call in `api.rs:25`. Vendored tests must wrap builds in the existing `no_citadel_fee(...)` helper (`tx_builder/tests/mod.rs:14`).
- New request fields default to `0`, meaning "no top-up". Every existing caller and test must keep its current behaviour.
- Dart package name is `argus_wallet`. Test imports use `package:argus_wallet/...`.
- Work continues on `feat/alpha-12` in `/home/rkadias/coding/arkadianet/Argus-wt-alpha-12`.

---

## File Structure

| File | Responsibility |
|---|---|
| `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/mod.rs` | Add the `DexyTxContext` fixture (none exists) |
| `rust/crates/vendor/protocols/dexy/src/tx_builder/mint.rs` | `recipient_held_tokens` on `MintDexyRequest` |
| `rust/crates/vendor/protocols/dexy/src/tx_builder/swap.rs` | Same on `SwapDexyRequest`, `ErgToDexy` branch only |
| `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/mint_tests.rs` | Build-level tests |
| `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/swap_tests.rs` | Build-level tests |
| `rust/crates/wallet-ffi/src/api.rs` | Thread the new argument through both entry points |
| `app/lib/services/dexy_service.dart` | Shortfall arithmetic, pass held amount |
| `app/lib/ui/send_screen.dart` | Offer the route when holding a partial balance |
| `app/test/dexy_service_test.dart` | Shortfall unit tests |

---

## Task 1: Build a mint transaction fixture

`mint_tests.rs` only covers validation and arithmetic — nothing builds a mint transaction, so there is no fixture to assert against. Build it first; every later task depends on it.

**Files:**
- Modify: `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/mod.rs`
- Modify: `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/mint_tests.rs`

**Interfaces:**
- Consumes: `create_test_input(value: i64, tokens: Vec<(&str, i64)>) -> Eip12InputBox` (`tests/mod.rs:44`), `create_test_state(dexy_in_bank: i64, can_mint: bool) -> DexyState` (`tests/mod.rs:18`), `no_citadel_fee` (`tests/mod.rs:14`)
- Produces: `fn create_mint_context(dexy_in_bank: i64, free_mint_available: i64) -> DexyTxContext`

- [ ] **Step 1: Write the failing test**

Append to `mint_tests.rs`:

```rust
#[test]
fn mint_sends_exactly_the_requested_amount_to_the_recipient() {
    let ctx = create_mint_context(1_000_000, 100_000);
    let state = create_test_state(1_000_000, true);

    let request = MintDexyRequest {
        variant: DexyVariant::Gold,
        amount: 1_000,
        user_address: "user_addr".to_string(),
        user_ergo_tree: "user_ergo_tree".to_string(),
        user_inputs: vec![create_test_input(100_000_000_000, vec![])],
        current_height: 100_000,
        recipient_ergo_tree: Some("recipient_ergo_tree".to_string()),
    };

    let build = no_citadel_fee(|| build_mint_dexy_tx(&request, &ctx, &state))
        .expect("mint should build");

    // outputs: [free_mint, bank, buyback, recipient, change?, fee]
    let recipient = &build.unsigned_tx.outputs[3];
    assert_eq!(recipient.ergo_tree, "recipient_ergo_tree");
    assert_eq!(recipient.assets[0].amount, "1000");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test -p dexy mint_sends_exactly`

Expected: FAIL to compile — `cannot find function 'create_mint_context'`.

- [ ] **Step 3: Write the fixture**

`DexyTxContext` is defined at `fetch.rs:180`. It carries both an `Eip12InputBox` and an `ergo_lib` `ErgoBox` for each protocol box; the builder reads only the `Eip12InputBox`, scalar and ergo-tree fields, so the `ErgoBox` members can be the same dummy `lp_tests.rs` already uses.

First move `create_dummy_ergo_box` (`lp_tests.rs:23`) into `tests/mod.rs` so both test modules can use it, leaving its body unchanged and updating `lp_tests.rs` to call the shared one. Then add:

```rust
fn dexy_protocol_input(
    box_id: &str,
    value: i64,
    tokens: Vec<(&str, i64)>,
    registers: HashMap<String, String>,
) -> Eip12InputBox {
    Eip12InputBox {
        box_id: box_id.to_string(),
        transaction_id: format!("{box_id}_tx"),
        index: 0,
        value: value.to_string(),
        ergo_tree: format!("{box_id}_ergo_tree"),
        assets: tokens
            .into_iter()
            .map(|(id, amt)| Eip12Asset::new(id, amt))
            .collect(),
        creation_height: 100_000,
        additional_registers: registers,
        extension: HashMap::new(),
    }
}

fn create_mint_context(dexy_in_bank: i64, free_mint_available: i64) -> DexyTxContext {
    let dummy = create_dummy_ergo_box();
    let dexy_token_id = create_test_state(dexy_in_bank, true).dexy_token_id;

    DexyTxContext {
        free_mint_input: dexy_protocol_input(
            "free_mint_box",
            1_000_000,
            vec![("free_mint_nft", 1)],
            HashMap::new(),
        ),
        free_mint_erg_nano: 1_000_000,
        free_mint_ergo_tree: "free_mint_box_ergo_tree".to_string(),
        free_mint_r4_height: 1,
        free_mint_r5_available: free_mint_available,
        free_mint_box: dummy.clone(),

        bank_input: dexy_protocol_input(
            "bank_box",
            1_000_000_000_000,
            vec![("bank_nft", 1), (dexy_token_id.as_str(), dexy_in_bank)],
            HashMap::new(),
        ),
        bank_erg_nano: 1_000_000_000_000,
        dexy_in_bank,
        bank_ergo_tree: "bank_box_ergo_tree".to_string(),
        bank_box: dummy.clone(),

        buyback_input: dexy_protocol_input(
            "buyback_box",
            1_000_000_000,
            vec![("buyback_nft", 1)],
            HashMap::new(),
        ),
        buyback_erg_nano: 1_000_000_000,
        buyback_ergo_tree: "buyback_box_ergo_tree".to_string(),
        buyback_box: dummy.clone(),

        oracle_data_input: Eip12DataInputBox {
            box_id: "oracle_box".to_string(),
        },
        oracle_rate_nano: 1_000_000_000,
        oracle_box: dummy.clone(),

        lp_data_input: Eip12DataInputBox {
            box_id: "lp_box".to_string(),
        },
        lp_erg_reserves: 500_000_000_000,
        lp_dexy_reserves: 500_000,
        lp_box: dummy,
    }
}
```

Two things to check against the real definitions rather than trusting the snippet: `Eip12DataInputBox`'s field list (`grep -n "pub struct Eip12DataInputBox" -A 6 rust/crates/vendor/ergo-tx/src/eip12.rs`) — if it carries more than `box_id`, fill the rest — and the exact field names in `fetch.rs:180-207`. `validate_free_mint_preflight` reads `free_mint_r4_height` and `free_mint_r5_available` against `current_height`, so keep `free_mint_r4_height` well below the request's height or the preflight rejects the build.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd rust && cargo test -p dexy mint_sends_exactly`

Expected: PASS. This test asserts *current* behaviour — it is the baseline that proves Task 2 does not break the no-top-up path.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/vendor/protocols/dexy/src/tx_builder/tests/
git commit -m "test: add a mint transaction fixture for the dexy builder"
```

---

## Task 2: Route held tokens into the mint recipient output

**Files:**
- Modify: `rust/crates/vendor/protocols/dexy/src/tx_builder/mint.rs`
- Modify: `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/mint_tests.rs`

**Interfaces:**
- Consumes: `create_mint_context` (Task 1); `select_inputs_for_spend(utxos, required_erg, token: Option<(&str, u64)>)` (`ergo-tx/src/tx_helpers.rs:67`); `append_change_output(outputs, selected, erg_used, spent_tokens: &[(&str, u64)], user_ergo_tree, height, min_change)` (`ergo-tx/src/tx_helpers.rs:26`)
- Produces: `MintDexyRequest.recipient_held_tokens: i64`

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn mint_tops_up_held_tokens_into_the_recipient_output() {
    let ctx = create_mint_context(1_000_000, 100_000);
    let state = create_test_state(1_000_000, true);
    let token_id = state.dexy_token_id.clone();

    // Wallet holds 266; deliver 1000 by minting only the 734 shortfall.
    let request = MintDexyRequest {
        variant: DexyVariant::Gold,
        amount: 734,
        user_address: "user_addr".to_string(),
        user_ergo_tree: "user_ergo_tree".to_string(),
        user_inputs: vec![create_test_input(
            100_000_000_000,
            vec![(token_id.as_str(), 266)],
        )],
        current_height: 100_000,
        recipient_ergo_tree: Some("recipient_ergo_tree".to_string()),
        recipient_held_tokens: 266,
    };

    let build = no_citadel_fee(|| build_mint_dexy_tx(&request, &ctx, &state))
        .expect("top-up mint should build");

    let recipient = &build.unsigned_tx.outputs[3];
    assert_eq!(recipient.ergo_tree, "recipient_ergo_tree");
    assert_eq!(
        recipient.assets[0].amount, "1000",
        "recipient must receive minted 734 plus held 266"
    );

    // The held tokens moved to the recipient, so none come back as change.
    let change_dexy: i64 = build
        .unsigned_tx
        .outputs
        .iter()
        .skip(4)
        .flat_map(|o| o.assets.iter())
        .filter(|a| a.token_id == token_id)
        .map(|a| a.amount.parse::<i64>().unwrap())
        .sum();
    assert_eq!(change_dexy, 0, "held tokens must not also return as change");
}
```

Add `recipient_held_tokens: 0` to the request in Task 1's test and to every other `MintDexyRequest` literal in the crate — `grep -rn "MintDexyRequest {" rust/crates/` to find them all.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test -p dexy mint_tops_up`

Expected: FAIL — `struct 'MintDexyRequest' has no field named 'recipient_held_tokens'`.

- [ ] **Step 3: Write the implementation**

In `mint.rs`, add the field:

```rust
pub struct MintDexyRequest {
    pub variant: DexyVariant,
    pub amount: i64,
    pub user_address: String,
    pub user_ergo_tree: String,
    pub user_inputs: Vec<Eip12InputBox>,
    pub current_height: i32,
    pub recipient_ergo_tree: Option<String>,
    /// Tokens already held by the user to deliver alongside the minted amount,
    /// so a partial balance tops up instead of being ignored. `0` mints only.
    pub recipient_held_tokens: i64,
}
```

Reject a negative value beside the existing preflight validation:

```rust
if request.recipient_held_tokens < 0 {
    return Err(TxError::BuildFailed {
        message: "recipient_held_tokens must not be negative".to_string(),
    });
}
```

Make input selection pull the held tokens in — otherwise the selector may pick ERG-only boxes and the tokens will not be in the inputs at all. Find the existing `select_inputs_for_spend(&request.user_inputs, needed as u64, None)` call in `mint.rs` and replace the `None`:

```rust
let held = request.recipient_held_tokens;
let token_requirement = if held > 0 {
    Some((state.dexy_token_id.as_str(), held as u64))
} else {
    None
};
let selected = select_inputs_for_spend(&request.user_inputs, needed as u64, token_requirement)
```

Add the held amount to the recipient output (`mint.rs:178`):

```rust
Eip12Output::change(
    constants::MIN_BOX_VALUE_NANO,
    output_ergo_tree,
    vec![Eip12Asset::new(
        &state.dexy_token_id,
        request.amount + request.recipient_held_tokens,
    )],
    request.current_height,
),
```

Exclude them from change (`mint.rs:187`). `append_change_output` treats an empty `spent_tokens` as "return every token in the inputs", so the held amount must be declared spent:

```rust
let spent = if held > 0 {
    vec![(state.dexy_token_id.as_str(), held as u64)]
} else {
    vec![]
};
append_change_output(
    &mut outputs,
    &selected,
    erg_used,
    &spent,
    &request.user_ergo_tree,
    request.current_height,
    constants::MIN_BOX_VALUE_NANO as u64,
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p dexy`

Expected: PASS, including Task 1's baseline test — the no-top-up path must be byte-identical.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/vendor/protocols/dexy/src/tx_builder/
git commit -m "feat: let a dexy mint deliver held tokens alongside minted ones"
```

---

## Task 3: Same for the LP swap route

`buildTokenSend` picks the cheaper of FreeMint and LP Swap (`dexy_service.dart:650`), so fixing only mint would make behaviour depend on which route wins.

**Files:**
- Modify: `rust/crates/vendor/protocols/dexy/src/tx_builder/swap.rs`
- Modify: `rust/crates/vendor/protocols/dexy/src/tx_builder/tests/swap_tests.rs`

**Interfaces:**
- Produces: `SwapDexyRequest.recipient_held_tokens: i64`

Only the `SwapDirection::ErgToDexy` branch is in scope. `DexyToErg` sells tokens for ERG and already passes a `spent_tokens` entry; do not touch it.

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn erg_to_dexy_swap_tops_up_held_tokens() {
    let ctx = create_swap_context();
    let state = create_test_state(1_000_000, true);
    let token_id = state.dexy_token_id.clone();

    let request = SwapDexyRequest {
        variant: DexyVariant::Gold,
        direction: SwapDirection::ErgToDexy,
        input_amount: 1_000_000_000,
        min_output: 1,
        user_address: "user_addr".to_string(),
        user_ergo_tree: "user_ergo_tree".to_string(),
        user_inputs: vec![create_test_input(
            100_000_000_000,
            vec![(token_id.as_str(), 266)],
        )],
        current_height: 100_000,
        recipient_ergo_tree: Some("recipient_ergo_tree".to_string()),
        recipient_held_tokens: 266,
    };

    let build = no_citadel_fee(|| build_swap_dexy_tx(&request, &ctx, &state))
        .expect("top-up swap should build");

    // outputs: [lp, swap_nft, recipient, change?, fee]
    let recipient = &build.unsigned_tx.outputs[2];
    assert_eq!(recipient.ergo_tree, "recipient_ergo_tree");
    let delivered: i64 = recipient.assets[0].amount.parse().unwrap();
    assert!(
        delivered > 266,
        "recipient must get swapped output plus the held 266, got {delivered}"
    );
}
```

Use whatever swap-context helper `swap_tests.rs` already defines; if it has none, add one mirroring Task 1's fixture. Add `recipient_held_tokens: 0` to every existing `SwapDexyRequest` literal — `grep -rn "SwapDexyRequest {" rust/crates/`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test -p dexy erg_to_dexy_swap_tops_up`

Expected: FAIL — no field `recipient_held_tokens`.

- [ ] **Step 3: Write the implementation**

Add the same field and negative guard to `SwapDexyRequest`. In the `ErgToDexy` branch:

- `swap.rs:137` — replace `select_inputs_for_spend(&request.user_inputs, needed as u64, None)` with the token-aware form from Task 2 Step 3.
- `swap.rs:171` — `Eip12Asset::new(&state.dexy_token_id, output_amount + request.recipient_held_tokens)`
- `swap.rs:178` — pass the same `&spent` slice instead of `&[]`.

Leave `DexyToErg` unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p dexy`

Expected: PASS — all 87 pre-existing tests plus the new ones.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/vendor/protocols/dexy/src/tx_builder/
git commit -m "feat: let an ERG-to-dexy swap deliver held tokens alongside swapped ones"
```

---

## Task 4: Thread the argument through wallet-ffi

**Files:**
- Modify: `rust/crates/wallet-ffi/src/api.rs`

**Interfaces:**
- Consumes: `MintDexyRequest.recipient_held_tokens`, `SwapDexyRequest.recipient_held_tokens`
- Produces: a `held_tokens: i64` parameter on `dexy_build_mint` (`api.rs:1508`) and `dexy_build_swap` (`api.rs:1613`)

- [ ] **Step 1: Add the parameter**

Add `held_tokens: i64,` to both signatures, immediately after `min_output` / `amount` respectively, and reject negatives before building:

```rust
if held_tokens < 0 {
    return Err(ArgusError::Generic("held_tokens must not be negative".into())
        .to_json_string());
}
```

Set `recipient_held_tokens: held_tokens` on both request structs. Include the delivered total in each response JSON so the confirm sheet can show it:

```rust
"token_amount": built.summary.token_amount + held_tokens,
"minted_amount": built.summary.token_amount,
"held_amount": held_tokens,
```

- [ ] **Step 2: Verify it compiles and the suite is green**

Run: `cd rust && cargo test --workspace`

Expected: PASS. `frb_generated.rs` will not match the new signatures until Task 5 regenerates it — if the workspace build fails only there, proceed to Task 5 and re-run.

- [ ] **Step 3: Commit**

```bash
git add rust/crates/wallet-ffi/src/api.rs
git commit -m "feat: accept a held-token top-up in the dexy build entry points"
```

---

## Task 5: Dart shortfall arithmetic and routing

**Files:**
- Modify: `app/lib/services/dexy_service.dart`
- Modify: `app/lib/ui/send_screen.dart`
- Modify: `app/test/dexy_service_test.dart`
- Regenerate: `app/lib/bridge/api.dart`

**Interfaces:**
- Produces: `int shortfallFor({required int wanted, required int held})`; `buildTokenSend(..., int heldTokens = 0)`

- [ ] **Step 1: Regenerate the bridge**

```bash
flutter_rust_bridge_codegen generate
```

Confirm `ammBuildSwap` is untouched and `dexyBuildMint` / `dexyBuildSwap` now take `heldTokens`.

- [ ] **Step 2: Write the failing test**

```dart
group('shortfall top-up', () {
  test('only the missing amount is acquired', () {
    expect(shortfallFor(wanted: 1000, held: 266), 734);
  });

  test('holding enough needs no acquisition', () {
    expect(shortfallFor(wanted: 1000, held: 1000), 0);
    expect(shortfallFor(wanted: 1000, held: 5000), 0);
  });

  test('holding none acquires the whole amount', () {
    expect(shortfallFor(wanted: 1000, held: 0), 1000);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd app && flutter test test/dexy_service_test.dart`

Expected: FAIL — `Method not found: 'shortfallFor'`.

- [ ] **Step 4: Write the implementation**

In `dexy_service.dart`:

```dart
/// Tokens that must be acquired to deliver [wanted] while holding [held].
int shortfallFor({required int wanted, required int held}) {
  final missing = wanted - held;
  return missing > 0 ? missing : 0;
}
```

Give `buildTokenSend` a `heldTokens` parameter, quote and build against `shortfallFor(...)` rather than the full amount, and pass `heldTokens` to both `buildMint` and `buildSwap`. `quoteTokenSend` must quote the shortfall too, or the displayed cost will overstate what the user pays.

**Handle a zero shortfall.** When the wallet already holds enough, `shortfallFor` returns `0`, `_planRoutes` yields no routes, and `buildTokenSend` throws `NO_ROUTE` — the auto-buy route has nothing to buy. Since the picker now offers that route unconditionally, the send screen must detect the zero case before calling `buildTokenSend` and fall back to the ordinary token send, which spends the held balance directly.

In `send_screen.dart`, the dropdown currently offers the auto-buy entry only when the wallet holds none (`:921`):

```dart
...DexyVariant.values
    .where((v) => !_args.tokens.any((t) => t.id == v.tokenId))
```

Remove that filter so the entry is always present. A wallet holding a partial balance then has both a plain entry (spend what you hold) and a buy-and-send entry (top up and deliver). Pass the held balance into `buildTokenSend` so only the shortfall is acquired.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app && flutter test && flutter analyze lib test`

Expected: PASS, analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib app/test
git commit -m "feat: acquire only the shortfall when topping up a dexy send"
```

---

## Task 6: Native build and verification

- [ ] **Step 1: Rebuild**

```bash
export ANDROID_NDK_HOME="$(ls -d ~/Android/Sdk/ndk/* | tail -1)"
./scripts/build_android.sh
```

- [ ] **Step 2: Full suite**

```bash
cd rust && cargo test --workspace
cd ../app && flutter test && flutter analyze lib test
```

- [ ] **Step 3: On-device verification**

This is the case the whole plan exists for, and no unit test covers it end to end. With a wallet holding a partial balance (e.g. 0.266 USE), send 1 USE and confirm: the confirm sheet shows 1 USE delivered; the ERG cost corresponds to acquiring ~0.734 USE, not 1; after broadcast the recipient holds 1 USE and the sender's USE balance is 0.

Also verify the unchanged path: with a zero balance, buy-and-send still delivers the full amount.

- [ ] **Step 4: Commit**

```bash
git add app/android/app/src/main/jniLibs
git commit -m "build: rebuild libwallet_ffi.so with dexy shortfall top-up"
```

---

## Task 7: Upstream to citadel

Not optional. Without it the next re-vendor reverts Tasks 2 and 3 *and* removes their tests, so the regression returns silently.

- [ ] **Step 1: Port the change**

Apply the Task 2 and Task 3 diffs — including the tests and the Task 1 fixture — to `github.com/arkadianet/citadel`, which the dexy crate is vendored from at commit `f533f15` (`docs/dependency-list.md:21`).

- [ ] **Step 2: Record the new commit**

Once merged upstream, update `docs/dependency-list.md:21` to the new commit so a future re-vendor picks up a version that already contains this work.

- [ ] **Step 3: Commit**

```bash
git add docs/dependency-list.md
git commit -m "docs: record the citadel commit carrying the dexy top-up"
```

---

## Notes for the implementer

- **Token conservation is the property to hold onto.** Held tokens must appear in exactly one output. Task 2's test asserts both halves — recipient gains them, change loses them. If you change the implementation, keep both assertions.
- **`append_change_output` with an empty `spent_tokens` means "return everything"** (`ergo-tx/src/tx_helpers.rs:42-43`). Forgetting to declare the held amount spent duplicates tokens into the change output and the transaction will fail validation.
- **Input selection is not automatic.** If `recipient_held_tokens > 0` and selection still passes `None`, the selector may choose ERG-only boxes and the held tokens will never enter the transaction.
- The `DexyToErg` swap branch already passes a `spent_tokens` entry for the tokens being sold. Do not add a top-up there — it sells tokens rather than delivering them.
- Argus's `MAX` on a Dexy send should still cap at what the user can afford to acquire; that logic is unrelated to this plan and lives in the send screen.

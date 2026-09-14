# Token send flow options

**Decision: A was chosen and built.** The send form now has a searchable,
multi-select holdings picker followed by quantity entry. B and C below remain
as the alternatives considered.

## Implementation notes

- Selection is a set of token IDs, independent of the search results. The sheet
  uses lazily built token tiles, a persistent selected count, and explicit Done;
  dismissing it cancels the selection edits.
- Quantities are reconciled by token ID, including when removing the first token
  promotes another into the existing primary serializer slot. Retained extra
  tokens reuse their controllers. New fungible selections start blank; NFTs have
  no quantity field and continue to serialize as exactly one unit.
- Every chosen fungible token has balance, MAX, and remove controls. More than ten
  selections show a compact count and ten quantity rows per page; quantities stay
  in controllers across pages. The confirmation uses a token count above ten
  instead of a long inline suffix. Existing full-draft validation still checks
  amounts on other pages, and the transaction builder still enforces its existing
  output/transaction constraints. Selection does not guarantee a transaction fits.
- The old main-recipient dropdowns are gone. Their duplicate-selection fix is
  subsumed by set membership and deduplicated holdings rows; equivalent tests
  replace the old dropdown-options test.
- Buy-and-send remains a separate mode, available through “ERG or buy and send”
  when no held tokens or additional recipients are selected. The holdings picker
  never silently chooses a buy route. Additional recipients retain their existing
  independent single-fungible-token controls; main-recipient selection edits do
  not reset their addresses or amounts. Multi-token selection applies to the main
  recipient, as the old extra-token rows did.
- No Rust, bridge, recipient serializer, or builder changes were needed. A widget
  test captures the existing single-send bridge call and checks the token ID,
  base-unit amount, minimum ERG, and addresses. This verifies the request boundary,
  not a live node transaction.

### What the proposal got right and wrong

Amount retention was a real risk because the original form has a special primary
controller plus extra-token controllers. Reconciling by ID made it manageable,
but testing only additions would have missed primary-token promotion. Buy-mode
separation was also real: the old picker automatically chooses a buy route for
some held assets. Reusing that sheet unchanged would have crossed the boundary.
The reusable part was its token tile, not its selection logic or eager list.

NFT defaults and multi-recipient isolation were cheaper than a redesign of the
transaction layer: the existing serializer and separate recipient state already
provide them. Tests now exercise these assumptions. The original compact-summary
advice was underspecified: a count alone does not let someone edit 100 amounts,
so quantity entry also needs paging and validation of off-page drafts. Ten rows
per page is the implemented cutoff, not a transaction-size limit. These findings
refine the original 2–3 day planning estimate; automated tests do not substitute
for device usability testing with large wallets.

## A. Searchable multi-select picker, followed by quantity entry (recommended)

1. Enter the recipient and tap “Choose tokens”.
2. Search by name or token ID and check any number of holdings. Selected rows
   stay checked across searches; a selected-count footer stays visible.
3. Tap “Done”. The send form shows just those tokens, each with its balance,
   amount, MAX and remove control. NFTs show one unit without a quantity field.
4. Review the existing transaction confirmation and send. Reopen the picker to
   change the selection without losing quantities for retained tokens.

This replaces repeated add-row/dropdown trips with one selection session and
puts quantity work in a short list. One token needs one selection and one amount;
ten tokens can be checked in a single visit; a hundred holdings remain searchable
and lazily rendered, with only selected tokens expanded on the form. Selecting all
hundred still makes review long; it needs a compact selected summary and existing
transaction-size validation, not a promise that every selection fits one output.

Estimated effort: 2–3 development days including tests. Reuse the existing asset
picker's search and token rows, but add multi-selection state and per-token amount
controllers keyed by ID. Main risks are losing amounts on picker edits, mixing
held-token selection with the primary asset's buy-and-send routes, NFT defaults,
and multi-recipient state. Keep buy-and-send as its own mode and preserve the
existing recipient serializer/builder boundary.

## B. Searchable holdings sheet with inline quantities

1. Enter the recipient and open “Tokens”.
2. Search the holdings; entering a positive quantity or pressing MAX selects a
   fungible token. Toggle an NFT to select its single unit.
3. A persistent footer shows the selected count and opens a selected-only review.
4. Tap “Done”, then use the existing transaction confirmation.

Choosing a token and specifying its amount happen together, with no empty rows
or repeated dropdowns. One token is very quick; ten holdings are easy to scan;
a hundred require search, lazy rows, and amount state that survives filtering and
scroll recycling. A selected-only view is essential to avoid hidden selections.

Estimated effort: 3–4 days including tests. It needs keyboard/focus management,
validation across off-screen fields, selection rules for empty/zero/invalid text,
and persistent edit state. Risks include accidental MAX taps, unseen invalid
amounts, accessibility complexity and confusing deselection while correcting a
quantity. NFT toggles must not behave like fungible amount fields.

## C. Searchable picker that adds a chosen token immediately

1. Tap “Add token” and search a picker that marks or disables chosen tokens.
2. Tap a token; the picker closes and its quantity row appears immediately.
3. Enter an amount or press that row's MAX; repeat for another token. NFTs use one.
4. Review and send through the existing confirmation.

This removes the current empty-row-then-dropdown step and makes duplicates
visible, with little change to the form. One token works well; ten require ten
picker visits; a hundred holdings are searchable, but sending many still has the
repetition the author dislikes.

Estimated effort: about 1 day including tests. It reuses the picker and existing
rows. Risks are selection/removal state, per-row MAX formatting, and preserving
the separate buy-and-send behavior. It is the smallest change, but only partially
addresses the reported frustration.

## Recommendation

A was selected because it directly removes repeated token-picking trips while keeping amount
entry and validation visible on the send form. B makes the holdings browser into
a more complicated form; C retains most of the repetition. The implemented choice keeps the transaction APIs intact.

Estimates assume the current UI components and Rust transaction APIs are retained;
they are planning estimates, not delivery commitments.

# Token send flow options

The author has not chosen a direction. This item proposes a redesign and does
not implement one. The separate duplicate-selection fix preserves the existing
flow, including primary-token MAX and fixed one-unit NFT sends.

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

Choose A. It directly removes repeated token-picking trips while keeping amount
entry and validation visible on the send form. B makes the holdings browser into
a more complicated form; C retains most of the repetition. This is a product
choice rather than an obvious small fix, so no redesign was implemented.

Estimates assume the current UI components and Rust transaction APIs are retained;
they are planning estimates, not delivery commitments.

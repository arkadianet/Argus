/// Protocol switches. The plumbing behind a switched-off protocol stays
/// in the tree, so turning it back on is one line here.

/// Dexy was exploited on 8 September 2026. Off until a patched Dexy
/// relaunches: no swap tab, no discover card, no buy route, and the
/// screen shows [dexyPausedNote] instead of its forms.
const dexyEnabled = false;

const dexyPausedNote =
    'Dexy is paused. Its contracts were exploited on 8 September 2026, so Argus '
    'does not mint, swap or route through Dexy until a patched version relaunches. '
    'Any DexyGold or USE you hold is still yours: it shows in your wallet and can '
    'be sent like any token.';

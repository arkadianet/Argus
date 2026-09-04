import '../format.dart';
import 'wallet_service.dart';

/// Money in a wallet, grouped by what spending it reveals.
///
/// The pocket is a property of the coins, not of a screen. Every surface
/// that shows or spends money names the pocket, so a balance can never
/// appear in one place and vanish in another.
enum Pocket {
  /// Ordinary boxes on this wallet's addresses.
  public('Public', 'On your addresses. Anyone watching the chain can link these to each other.'),

  /// Received to a one-time stealth script; nothing on chain ties it to you.
  stealth('Stealth', 'Received privately. Nothing on chain links these to your addresses.'),

  /// Output of a completed mix. Reserved: no mixer exists yet.
  mixed('Mixed', 'Came out of a mix. Spend it apart from the rest to keep it unlinked.'),

  /// Locked in a mix that has not finished. Reserved.
  inMix('In mix', 'Still moving through mix rounds. Not spendable until it finishes.');

  const Pocket(this.label, this.blurb);
  final String label;
  final String blurb;

  /// Whether coins here can be spent right now.
  bool get spendable => this != Pocket.inMix;
}

/// One pocket's holdings.
class PocketBalance {
  const PocketBalance({required this.pocket, required this.nanoErg, this.unknown = false});

  final Pocket pocket;
  final int nanoErg;

  /// True when the amount could not be determined, which must not be
  /// rendered as zero.
  final bool unknown;
}

/// The wallet's money split by pocket. Only non-empty pockets are returned,
/// except one that is unknown, which must still be shown as such.
List<PocketBalance> walletPockets({
  required int? publicNano,
  required int stealthNano,
  required bool stealthUnknown,
  int mixedNano = 0,
  int inMixNano = 0,
}) {
  return [
    PocketBalance(pocket: Pocket.public, nanoErg: publicNano ?? 0, unknown: publicNano == null),
    if (stealthNano > 0 || stealthUnknown)
      PocketBalance(pocket: Pocket.stealth, nanoErg: stealthNano, unknown: stealthUnknown),
    if (mixedNano > 0) PocketBalance(pocket: Pocket.mixed, nanoErg: mixedNano),
    if (inMixNano > 0) PocketBalance(pocket: Pocket.inMix, nanoErg: inMixNano),
  ];
}

/// "1.012 public · 1 stealth", or null when there is nothing worth splitting.
String? pocketBreakdown(List<PocketBalance> pockets, {bool hidden = false}) {
  final shown = pockets.where((p) => p.nanoErg > 0 || p.unknown).toList();
  if (shown.length < 2) return null;
  if (hidden) return shown.map((p) => '•••• ${p.pocket.label.toLowerCase()}').join(' · ');
  return shown
      .map((p) => p.unknown
          ? '${p.pocket.label.toLowerCase()} unknown'
          : '${formatErg(p.nanoErg, unit: false, maxFrac: 4)} ${p.pocket.label.toLowerCase()}')
      .join(' · ');
}

/// Which pockets a send draws from.
enum SpendFrom {
  public('Public'),
  stealth('Stealth'),
  both('Both');

  const SpendFrom(this.label);
  final String label;

  bool get usesStealth => this != SpendFrom.public;
  bool get usesPublic => this != SpendFrom.stealth;
}

/// The warning a send must show for [from], or null when there is none.
///
/// Two separate costs. Spending across pockets puts both sets of coins in
/// one input list, which tells any observer they share an owner. And any
/// send that spends stealth coins returns its change to an address of this
/// wallet, which ties that stealth box to that address — so a stealth send
/// is private in who paid you, not in where the remainder went.
String? spendFromWarning(SpendFrom from) {
  switch (from) {
    case SpendFrom.public:
      return null;
    case SpendFrom.stealth:
      return 'Change returns to one of your addresses, which links this '
          'stealth box to it. Send the whole amount to avoid change.';
    case SpendFrom.both:
      return 'Spending public and stealth coins together links them: the '
          'chain will show one transaction owning both, and change returns '
          'to one of your addresses.';
  }
}

/// Boxes eligible for a send from [from].
List<InputBoxInput> eligibleBoxes({
  required SpendFrom from,
  required List<InputBoxInput> publicBoxes,
  required List<InputBoxInput> stealthBoxes,
}) =>
    [
      if (from.usesPublic) ...publicBoxes,
      if (from.usesStealth) ...stealthBoxes,
    ];

/// What a send can draw on from [from], for the amount field's helper.
int? availableNano({
  required SpendFrom from,
  required int? publicNano,
  required int stealthNano,
  bool stealthUnknown = false,
}) {
  // An unknown stealth balance must not be added as a number: the last
  // figure may predate a spend, so any total including it would be a guess.
  if (from.usesStealth && stealthUnknown) return null;
  if (from == SpendFrom.stealth) return stealthNano;
  if (publicNano == null) return null;
  return from == SpendFrom.both ? publicNano + stealthNano : publicNano;
}

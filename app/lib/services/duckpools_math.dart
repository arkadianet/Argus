/// The figures a borrower thinks in, from what the contract values. Pure,
/// so the sheets can show them while the user types; the Rust quote and
/// the contract decide the transaction.
library;

/// Blocks in a day at Ergo's two-minute target.
const blocksPerDay = 720;

/// Blocks after which a Duckpools loan may be liquidated whatever the
/// price: the contract's `forcedLiquidationHeight` is the open plus this.
const forcedLiquidationBlocks = 65520;

double _pow10(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// What one whole unit of collateral counts for right now, in loan-asset
/// units: the contract's own valuation, fees included.
double collateralUnitPrice({required int collateralValue, required int collateralAmount, required int collateralDecimals}) {
  if (collateralAmount <= 0) return 0;
  return collateralValue / collateralAmount * _pow10(collateralDecimals);
}

/// The collateral unit price at which liquidation opens: the value the
/// line demands, spread over the collateral held.
double liquidationUnitPrice({required int liquidationValue, required int collateralAmount, required int collateralDecimals}) {
  if (collateralAmount <= 0) return 0;
  return liquidationValue / collateralAmount * _pow10(collateralDecimals);
}

/// How far the collateral's price can fall before liquidation, in percent;
/// zero when it is already at or past the line.
double dropToLiquidationPercent({required int collateralValue, required int liquidationValue}) {
  if (collateralValue <= 0) return 0;
  final drop = (1 - liquidationValue / collateralValue) * 100;
  return drop < 0 ? 0 : drop;
}

/// Health (10 000 is the line) after the collateral's price moves by
/// `changePercent`, everything else equal.
int healthAfterPriceChange(int healthBps, double changePercent) => (healthBps * (1 + changePercent / 100)).round();

/// Interest on `owed` over `days` at `aprBps` a year, loan-asset units.
/// The contract compounds every 120 blocks; over a month the simple
/// figure is within a fraction of a percent of it.
int interestOver({required int owed, required int aprBps, required int days}) => (owed * aprBps / 10000 * days / 365).round();

/// The most the line lets one borrow per unit of collateral value, in
/// percent: a 140% line means 71% loan-to-value.
double maxLoanToValuePercent(int threshold) => threshold <= 0 ? 0 : 100000 / threshold;

/// When a block `blocksAhead` from now lands, at two minutes a block.
DateTime blockDate(int blocksAhead, DateTime now) => now.add(Duration(minutes: blocksAhead * 2));

/// Collateral value that would put the loan at `targetHealthBps`.
int collateralValueForHealth({required int owed, required int threshold, required int targetHealthBps}) =>
    (owed * threshold / 1000 * targetHealthBps / 10000).ceil();

/// Collateral units to add to reach `targetHealthBps` at today's price,
/// or zero when the loan is already there.
int extraCollateralForHealth({
  required int owed,
  required int threshold,
  required int targetHealthBps,
  required int collateralValue,
  required int collateralAmount,
}) {
  if (collateralAmount <= 0 || collateralValue <= 0) return 0;
  final needed = collateralValueForHealth(owed: owed, threshold: threshold, targetHealthBps: targetHealthBps) - collateralValue;
  if (needed <= 0) return 0;
  return (needed * collateralAmount / collateralValue).ceil();
}

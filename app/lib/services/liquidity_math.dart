/// The pool arithmetic the Liquidity screen shows as the user types;
/// the Rust builder decides the final figures.
library;

/// Y needed for `xIn` at the pool's ratio: `xIn × reservesY / reservesX`.
BigInt depositCounterpart(BigInt reservesX, BigInt reservesY, BigInt xIn) {
  if (reservesX == BigInt.zero) return BigInt.zero;
  return xIn * reservesY ~/ reservesX;
}

/// LP tokens minted for a deposit: the smaller of the two sides' shares.
BigInt lpReward(BigInt reservesX, BigInt reservesY, BigInt supplyLp, BigInt xIn, BigInt yIn) {
  if (reservesX == BigInt.zero || reservesY == BigInt.zero || supplyLp == BigInt.zero) return BigInt.zero;
  final byX = xIn * supplyLp ~/ reservesX;
  final byY = yIn * supplyLp ~/ reservesY;
  return byX < byY ? byX : byY;
}

/// What `lpIn` LP tokens redeem: `(x, y)`.
(BigInt, BigInt) redeemShares(BigInt reservesX, BigInt reservesY, BigInt supplyLp, BigInt lpIn) {
  if (supplyLp == BigInt.zero) return (BigInt.zero, BigInt.zero);
  return (lpIn * reservesX ~/ supplyLp, lpIn * reservesY ~/ supplyLp);
}

/// The share of the pool `lp` represents, in basis points.
int poolShareBps(BigInt lp, BigInt supplyLp) {
  if (supplyLp == BigInt.zero) return 0;
  return (lp * BigInt.from(10000) ~/ supplyLp).toInt();
}

/// A new pool's first LP share: `sqrt(x × y)`, as the contract does.
BigInt initialLpShare(BigInt x, BigInt y) {
  final p = x * y;
  if (p <= BigInt.zero) return BigInt.zero;
  // Newton's method on BigInt.
  var r = p;
  var next = (r + BigInt.one) ~/ BigInt.two;
  while (next < r) {
    r = next;
    next = (r + p ~/ r) ~/ BigInt.two;
  }
  return r;
}

/// Spectrum's fee numerator for a fee percentage: 0.3% → 997.
int feeNumFor(double feePercent) => (1000 - (feePercent * 10).round()).clamp(1, 999);

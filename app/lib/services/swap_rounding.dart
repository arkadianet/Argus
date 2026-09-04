import 'amm_service.dart' show requiredInputFor;

/// A swap whose output was floored to a coarse unit, with the smaller
/// input that still yields the same output. Constant-product pools take
/// the whole input and floor the output, so paying 1 ERG for 1.85
/// DexyGold returns 1 DexyGold and leaves the value of 0.85 in the pool.
class SwapRounding {
  const SwapRounding({required this.exactInput, required this.output, required this.leftover});

  /// Smallest input that still buys [output].
  final int exactInput;
  final int output;

  /// Input the user typed minus [exactInput].
  final int leftover;
}

/// Null when the rounding costs less than [minLeftoverFraction] of the
/// input, which is always the case for outputs with several decimals.
SwapRounding? swapRoundingFor({
  required int input,
  required int output,
  required BigInt reservesIn,
  required BigInt reservesOut,
  required int feeNum,
  required int feeDenom,
  double minLeftoverFraction = 0.005,
}) {
  if (input <= 0 || output <= 0) return null;
  final exact = requiredInputFor(
    reservesIn: reservesIn,
    reservesOut: reservesOut,
    output: BigInt.from(output),
    feeNum: feeNum,
    feeDenom: feeDenom,
  );
  if (exact == null || exact >= BigInt.from(input)) return null;
  final exactInput = exact.toInt();
  final leftover = input - exactInput;
  if (leftover < input * minLeftoverFraction) return null;
  return SwapRounding(exactInput: exactInput, output: output, leftover: leftover);
}

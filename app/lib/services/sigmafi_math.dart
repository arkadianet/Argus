/// SigmaFi bond arithmetic as the contracts and SigmaFi's own interface
/// compute it. Pure, so the screen can show figures while the user
/// types; the Rust builders decide the transaction.
library;

/// Blocks in a day at Ergo's two-minute target.
const blocksPerDay = 720;

/// Blocks in a year, for annualising.
const blocksPerYear = blocksPerDay * 365;

/// The term the order contract insists on: strictly above 30 blocks and
/// under the storage rent period.
const minTermBlocks = 31;
const storagePeriodBlocks = 1051200;

/// The loan plus `interestBps` of it, rounded up so the borrower never
/// pays less than the rate they typed.
int repaymentFor(int principal, int interestBps) {
  final interest = BigInt.from(principal) * BigInt.from(interestBps);
  final ten = BigInt.from(10000);
  final up = (interest + ten - BigInt.one) ~/ ten;
  return principal + up.toInt();
}

/// `(repayment - principal) / principal` in percent; zero for no loan.
double interestPercent(int principal, int repayment) {
  if (principal <= 0) return 0;
  return (repayment - principal) / principal * 100;
}

/// The interest scaled to a year; zero for a term of no blocks.
double aprPercent(double interestPercent, int termBlocks) {
  if (termBlocks <= 0) return 0;
  return interestPercent * blocksPerYear / termBlocks;
}

int blocksForDays(int days) => days * blocksPerDay;

double daysForBlocks(int blocks) => blocks / blocksPerDay;

/// 0.5% of the loan to SigmaFi's developer on every fill.
int devFee(int principal) => _fee(principal, 500);

/// 0.4% of the loan to whoever built the fill: Argus, here.
int uiFee(int principal) => _fee(principal, 400);

/// What a lender parts with: the loan and both fees.
int lenderCost(int principal) => principal + devFee(principal) + uiFee(principal);

int _fee(int principal, int num) {
  // (num * principal) / 100000 without overflowing a 63-bit int.
  final p = BigInt.from(principal) * BigInt.from(num) ~/ BigInt.from(100000);
  return p.toInt();
}

/// Why a term in blocks is not one the contract accepts, or null.
String? termError(int termBlocks) {
  if (termBlocks < minTermBlocks) return 'The term must be at least $minTermBlocks blocks';
  if (termBlocks >= storagePeriodBlocks) return 'The term must be under $storagePeriodBlocks blocks';
  return null;
}

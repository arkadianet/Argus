import 'dexy_service.dart';
import 'sigmausd_service.dart';

/// A token whose id was checked against the chain: name, decimals and
/// emission match the issuer's, and holder counts rule out look-alikes.
class VerifiedToken {
  const VerifiedToken({
    required this.id,
    required this.ticker,
    required this.name,
    required this.project,
    required this.decimals,
  });

  final String id;
  final String ticker;
  final String name;
  final String project;
  final int decimals;
}

/// Verified 2026-09-04 against the Ergo explorer: each id was searched by
/// name, its emission and decimals compared with the issuer's, and holder
/// statistics used to reject copies (several "SigUSD", "NETA", "Paideia",
/// "CYPX" and "rsBTC" tokens exist with one holder or a mocking
/// description). Protocol tokens come from the pinned protocol constants.
const verifiedTokens = <VerifiedToken>[
  VerifiedToken(id: SigmaUsdTokens.sigUsd, ticker: 'SigUSD', name: 'SigmaUSD', project: 'AgeUSD', decimals: 2),
  VerifiedToken(id: SigmaUsdTokens.sigRsv, ticker: 'SigRSV', name: 'SigmaRSV', project: 'AgeUSD', decimals: 0),
  VerifiedToken(id: '6122f7289e7bb2df2de273e09d4b2756cda6aeb0f40438dc9d257688f45183ad', ticker: 'DexyGold', name: 'DexyGold', project: 'Dexy', decimals: 0),
  VerifiedToken(id: 'a55b8735ed1a99e46c2c89f8994aacdf4b1109bdcf682f1e5b34479c6e392669', ticker: 'USE', name: 'DexyUSD', project: 'Dexy', decimals: 3),
  VerifiedToken(id: '8b08cdd5449a9592a9e79711d7d79249d7a03c535d17efaee83e216e80a44c4b', ticker: 'RSN', name: 'Rosen', project: 'Rosen Bridge', decimals: 3),
  VerifiedToken(id: '7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0', ticker: 'rsBTC', name: 'Rosen wrapped BTC', project: 'Rosen Bridge', decimals: 8),
  VerifiedToken(id: '9a06d9e545a41fd51eeffc5e20d818073bf820c635e2a9d922269913e0de369d', ticker: 'SPF', name: 'Spectrum Finance', project: 'Spectrum', decimals: 6),
  VerifiedToken(id: 'd71693c49a84fbbecd4908c94813b46514b18b67a99952dc1e6e4791556de413', ticker: 'ergopad', name: 'ErgoPad', project: 'ErgoPad', decimals: 2),
  VerifiedToken(id: '1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489', ticker: 'Paideia', name: 'Paideia DAO', project: 'Paideia', decimals: 4),
  VerifiedToken(id: '472c3d4ecaa08fb7392ff041ee2e6af75f4a558810a74b28600549d5392810e8', ticker: 'NETA', name: 'anetaBTC', project: 'anetaBTC', decimals: 6),
  VerifiedToken(id: '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b', ticker: 'COMET', name: 'COMET', project: 'COMET', decimals: 0),
  VerifiedToken(id: '00b1e236b60b95c2c6f8007a9d89bc460fc9e78f98b09faec9449007b40bccf3', ticker: 'EGIO', name: 'ErgoGames.io', project: 'ErgoGames', decimals: 4),
  VerifiedToken(id: 'fcfca7654fb0da57ecf9a3f489bcbeb1d43b56dce7e73b352f7bc6f2561d2a1b', ticker: 'ErgOne', name: 'ErgOne', project: 'ErgOne', decimals: 8),
  VerifiedToken(id: '01dce8a5632d19799950ff90bca3b5d0ca3ebfa8aaafd06f0cc6dd1e97150e7f', ticker: 'CYPX', name: 'CyberPixels', project: 'CyberVerse', decimals: 4),
  VerifiedToken(id: 'b0b312cde931c8bbdac0dac5bfd8e2c03bf4611275dc967988c8d15bd5ec20e0', ticker: 'Bober', name: 'Bober', project: 'Bober', decimals: 3),
  VerifiedToken(id: 'e8b20745ee9d18817305f32eb21015831a48f02d40980de6e849f886dca7f807', ticker: 'Flux', name: 'Flux', project: 'Flux', decimals: 8),
];

final _byId = {for (final t in verifiedTokens) t.id: t};
final _byTicker = {for (final t in verifiedTokens) t.ticker.toLowerCase(): t};

VerifiedToken? verifiedToken(String tokenId) => _byId[tokenId];

bool isVerifiedToken(String tokenId) => _byId.containsKey(tokenId);

/// A verified token whose ticker this unverified token's name imitates, so
/// the UI can warn ("named like SigUSD, but not the verified SigUSD").
VerifiedToken? impersonatedToken({required String tokenId, String? name}) {
  if (isVerifiedToken(tokenId) || name == null) return null;
  final n = name.trim().toLowerCase();
  if (n.isEmpty) return null;
  final hit = _byTicker[n] ?? _byTicker[n.split(' ').first];
  return hit;
}

/// Ticker for the swap picker; unchanged behaviour for callers that only
/// need a label.
Map<String, String> verifiedTokenLabels() => {
      for (final t in verifiedTokens) t.id: '${t.ticker}${t.project == t.ticker || t.project == t.name ? '' : ' (${t.project})'}',
    };

// Keep DexyVariant referenced so a constant drift between the pinned Dexy
// ids and this registry fails loudly in tests.
bool dexyIdsMatchRegistry() =>
    DexyVariant.values.every((v) => v.tokenId.isEmpty || isVerifiedToken(v.tokenId));

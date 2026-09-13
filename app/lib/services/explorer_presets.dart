/// Block explorer websites the app can open transactions and tokens in.
///
/// Two different things are called "explorer" here. A [ExplorerSite] is a
/// website for people, chosen for "Open in explorer" links. An explorer
/// *API* is a data source speaking the Ergo Platform explorer's REST
/// schema, which the stealth scan, mixer, lending and bridge code read.
/// Only some sites have such an API: ErgExplorer and Kadia serve their own
/// schemas, so they are links-only and never a data source.
class ExplorerSite {
  const ExplorerSite({
    required this.id,
    required this.name,
    required this.web,
    required this.txPath,
    required this.tokenPath,
    this.api,
  });

  final String id;
  final String name;

  /// Website origin, no trailing slash.
  final String web;

  /// Path prefix a transaction id is appended to.
  final String txPath;

  /// Path prefix a token id is appended to.
  final String tokenPath;

  /// Standard explorer API origin, when the site has one.
  final String? api;

  String tx(String id) => '$web$txPath$id';
  String token(String id) => '$web$tokenPath$id';
}

const sigmaSpaceSite = ExplorerSite(
  id: 'sigmaspace',
  name: 'SigmaSpace',
  web: 'https://sigmaspace.io',
  txPath: '/en/transaction/',
  tokenPath: '/en/token/',
  api: 'https://api.sigmaspace.io',
);

const ergoPlatformSite = ExplorerSite(
  id: 'ergoplatform',
  name: 'Ergo Platform',
  web: 'https://explorer.ergoplatform.com',
  txPath: '/en/transactions/',
  tokenPath: '/en/token/',
  api: 'https://api.ergoplatform.com',
);

const ergExplorerSite = ExplorerSite(
  id: 'ergexplorer',
  name: 'ErgExplorer',
  web: 'https://ergexplorer.com',
  txPath: '/transactions/',
  tokenPath: '/token/',
);

const kadiaSite = ExplorerSite(
  id: 'kadia',
  name: 'Kadia',
  web: 'https://explorer.kadia.io',
  txPath: '/tx/',
  tokenPath: '/token/',
);

const explorerSites = [
  sigmaSpaceSite,
  ergoPlatformSite,
  ergExplorerSite,
  kadiaSite,
];

/// Sites that can also be the explorer API.
List<ExplorerSite> get explorerApiSites =>
    explorerSites.where((s) => s.api != null).toList();

/// The site id the settings store for a hand-typed website.
const customExplorerSiteId = 'custom';

ExplorerSite? explorerSiteById(String? id) {
  for (final s in explorerSites) {
    if (s.id == id) return s;
  }
  return null;
}

/// The site whose API is [api], if any: used to pick a sensible link
/// target for installs that saved an explorer API before sites existed.
ExplorerSite? explorerSiteForApi(String api) {
  final host = Uri.tryParse(api)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  for (final s in explorerSites) {
    if (s.api == null) continue;
    // The registrable domain, so api.sigmaspace.io and sigmaspace.io both
    // match, while a look-alike such as notsigmaspace.io does not.
    final domain = Uri.parse(s.api!).host.toLowerCase().replaceFirst('api.', '');
    if (host == domain || host.endsWith('.$domain')) return s;
  }
  return null;
}

String _trimSlash(String url) => url.replaceAll(RegExp(r'/$'), '');

/// Transaction page for [txId] on the chosen site, or on the [custom]
/// website using the Ergo Platform path shape when no site is chosen.
String explorerTxLink({
  required String? siteId,
  required String custom,
  required String txId,
}) {
  final site = explorerSiteById(siteId);
  if (site != null) return site.tx(txId);
  return '${_trimSlash(custom)}/en/transactions/$txId';
}

String explorerTokenLink({
  required String? siteId,
  required String custom,
  required String tokenId,
}) {
  final site = explorerSiteById(siteId);
  if (site != null) return site.token(tokenId);
  return '${_trimSlash(custom)}/en/token/$tokenId';
}

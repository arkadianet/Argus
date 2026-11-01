/// Which Ergo chain a wallet belongs to.
///
/// Network is a property of a wallet, not an app-wide switch: a mainnet and a
/// testnet wallet can be stored side by side, and the active wallet decides
/// which node, explorer and address prefix the app uses.
enum WalletNetwork {
  mainnet(
    wireName: 'mainnet',
    label: 'Mainnet',
    addressPrefix: '9',
  ),
  testnet(
    wireName: 'testnet',
    label: 'Testnet',
    addressPrefix: '3',
  );

  const WalletNetwork({
    required this.wireName,
    required this.label,
    required this.addressPrefix,
  });

  /// The value sent across the Rust bridge and stored in wallet metadata.
  final String wireName;

  /// Shown in badges and selectors.
  final String label;

  /// First character of this chain's P2PK addresses.
  final String addressPrefix;

  bool get isTestnet => this == WalletNetwork.testnet;

  static WalletNetwork fromWireName(Object? value) =>
      value == testnet.wireName ? testnet : mainnet;

  /// The chain an address belongs to, from its base58 prefix. Null when the
  /// first character is neither prefix; the Rust parser still decides whether
  /// the address is valid at all.
  static WalletNetwork? ofAddress(String address) {
    if (address.startsWith(testnet.addressPrefix)) return testnet;
    if (address.startsWith(mainnet.addressPrefix)) return mainnet;
    return null;
  }
}

/// Testnet funds are not money. Every testnet wallet surface repeats this.
const testnetWarning =
    'Testnet is for testing only. Tokens here have no value and cannot be '
    'spent on mainnet. Never send real funds to a testnet address.';

/// An address is usable only on the wallet's own chain: the same key has a
/// different base58 prefix on each, and sending across is a way to lose funds.
String? addressNetworkError(String address, WalletNetwork walletNetwork) {
  final addressNetwork = WalletNetwork.ofAddress(address);
  if (addressNetwork != null && addressNetwork != walletNetwork) {
    return 'That is a ${addressNetwork.label} address. This wallet is on '
        '${walletNetwork.label}.';
  }
  return null;
}

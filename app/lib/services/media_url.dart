/// Turns a token media link into something an image widget can load.
/// `ipfs://` goes through a public gateway; only http(s) survives.
String? resolveMediaUrl(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('ipfs://')) {
    var path = t.substring('ipfs://'.length);
    if (path.startsWith('ipfs/')) path = path.substring(5);
    return 'https://ipfs.io/ipfs/$path';
  }
  if (t.startsWith('https://') || t.startsWith('http://')) return t;
  return null;
}

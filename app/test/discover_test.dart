import 'package:argus_wallet/ui/widgets/discover_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every feature has a full explainer and one place to go', () {
    final titles = <String>{};
    for (final f in DiscoverFeature.values) {
      final e = discoverExplainers[f];
      expect(e, isNotNull, reason: '$f has an explainer');
      expect(titles.add(e!.title), isTrue, reason: 'titles are distinct');
      expect(e.blurb, isNotEmpty);
      expect(e.what.length, greaterThan(80), reason: '$f says what it is');
      expect(e.can.length, greaterThanOrEqualTo(3), reason: '$f lists what you can do');
      expect(e.risks.length, greaterThanOrEqualTo(3), reason: '$f lists what to watch for');
      expect(e.go, startsWith('Open'));
      expect((e.venue == null) != (e.route == null), isTrue, reason: '$f opens a venue or a route, not both');
      if (e.route != null) expect(e.route, startsWith('/'));
    }
  });
}

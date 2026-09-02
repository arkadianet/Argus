import 'package:argus_wallet/services/deep_link_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('push parks a link and notifies; take hands it over once', () {
    final c = DeepLinkController();
    var notified = 0;
    c.addListener(() => notified++);

    c.push('ergopay://x/y');

    expect(notified, 1);
    expect(c.pending, 'ergopay://x/y');
    expect(c.take(), 'ergopay://x/y');
    expect(c.take(), isNull);
    expect(c.pending, isNull);
  });

  test('ignores blank links', () {
    final c = DeepLinkController();
    c.push('   ');
    expect(c.pending, isNull);
  });
}

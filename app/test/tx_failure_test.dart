import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/ui/widgets/error_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a script that reduced to false is a signing failure and nothing was sent', () {
    final f = classifyTxFailure('{"code":"SIGNING_FAILED","message":"Script reduced to false"}');
    expect(f.title, 'Signing failed');
    expect(f.message, contains('Nothing was sent'));
    expect(f.message, contains('contract rejected'));
    expect(f.code, 'SIGNING_FAILED');
  });

  test('a reduction failure is reported before the network', () {
    final f = classifyTxFailure(ArgusException(code: 'TX_REDUCTION_FAILED', message: 'bad context'));
    expect(f.title, 'Signing failed');
  });

  test('a node error after signing tells the user to check activity', () {
    final f = classifyTxFailure('{"code":"NODE_ERROR","message":"timed out"}');
    expect(f.title, 'Broadcast may have failed');
    expect(f.message, contains('Check Activity'));
    expect(f.message, contains('timed out'));
  });

  test('plain strings are kept as the message', () {
    final f = classifyTxFailure(Exception('socket closed'));
    expect(f.message, contains('socket closed'));
    expect(f.code, isNull);
  });
}

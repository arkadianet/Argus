import 'dart:convert';

import 'package:argus_wallet/services/ergopay_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseErgoPayLink', () {
    test('static payload decodes base64url bytes', () {
      final link = parseErgoPayLink('ergopay:AAEC') as StaticErgoPayLink;
      expect(link.reducedTx, [0, 1, 2]);
    });

    test('static payload tolerates missing padding and standard alphabet', () {
      final link = parseErgoPayLink('ergopay:+/8') as StaticErgoPayLink;
      expect(link.reducedTx, [0xfb, 0xff]);
    });

    test('remote link becomes https', () {
      final link = parseErgoPayLink('ergopay://example.com/sign?x=1') as RemoteErgoPayLink;
      expect(link.url, 'https://example.com/sign?x=1');
      expect(link.needsAddress, isFalse);
    });

    test('remote link on a LAN host stays plain http', () {
      final link = parseErgoPayLink('ergopay://192.168.1.5:8080/x') as RemoteErgoPayLink;
      expect(link.url, 'http://192.168.1.5:8080/x');
    });

    test('address placeholder is substituted', () {
      final link = parseErgoPayLink('ergopay://example.com/#P2PK_ADDRESS#/sign') as RemoteErgoPayLink;
      expect(link.needsAddress, isTrue);
      expect(link.withAddress('9abc'), 'https://example.com/9abc/sign');
    });

    test('scheme is case-insensitive and whitespace trimmed', () {
      expect(parseErgoPayLink('  ErgoPay://Example.com/a  '), isA<RemoteErgoPayLink>());
    });

    test('non-ergopay text is null', () {
      expect(parseErgoPayLink('ergo:9abc?amount=1'), isNull);
      expect(parseErgoPayLink('https://example.com'), isNull);
      expect(parseErgoPayLink(''), isNull);
    });
  });

  group('ErgoPayRequest.fromJson', () {
    test('parses every field and decodes the transaction', () {
      final r = ErgoPayRequest.fromJson({
        'reducedTx': 'AAEC',
        'address': '9abc',
        'message': 'Buy 1 NFT',
        'messageSeverity': 'warning',
        'replyTo': 'https://dapp/reply',
      });
      expect(r.reducedTx, [0, 1, 2]);
      expect(r.address, '9abc');
      expect(r.message, 'Buy 1 NFT');
      expect(r.severity, ErgoPaySeverity.warning);
      expect(r.replyTo, 'https://dapp/reply');
    });

    test('missing transaction and severity default sensibly', () {
      final r = ErgoPayRequest.fromJson({'message': 'hi'});
      expect(r.reducedTx, isNull);
      expect(r.severity, ErgoPaySeverity.none);
    });
  });

  group('ErgoPayClient', () {
    test('fetch GETs JSON and parses the request', () async {
      late http.Request seen;
      final client = ErgoPayClient(client: MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode({'reducedTx': 'AAEC', 'message': 'm'}), 200);
      }));
      final r = await client.fetch('https://example.com/sign');
      expect(seen.method, 'GET');
      expect(seen.headers['accept'], contains('application/json'));
      expect(r.reducedTx, [0, 1, 2]);
    });

    test('fetch reports a non-200 as ErgoPayException', () async {
      final client = ErgoPayClient(client: MockClient((_) async => http.Response('nope', 500)));
      expect(() => client.fetch('https://example.com/sign'), throwsA(isA<ErgoPayException>()));
    });

    test('reply POSTs the tx id as JSON', () async {
      late http.Request seen;
      final client = ErgoPayClient(client: MockClient((req) async {
        seen = req;
        return http.Response('', 200);
      }));
      await client.reply('https://dapp/reply', 'tx123');
      expect(seen.method, 'POST');
      expect(seen.headers['content-type'], contains('application/json'));
      expect(jsonDecode(seen.body), {'txId': 'tx123'});
    });
  });
}

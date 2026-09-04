import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  _displayAddressTests();
  group('SendPreview.fromJson', () {
    final valid = {
      'preparation_id': 9,
      'recipient': '9abc',
      'amount_nano_erg': 1000000000,
      'miner_fee': 1100000,
      'change_nano_erg': 2000000,
      'input_count': 1,
    };

    test('requires all confirmation fields', () {
      final preview = SendPreview.fromJson(valid);
      expect(preview.preparationId, 9);
      expect(preview.recipient, '9abc');
      expect(preview.amountNanoErg, 1000000000);
      expect(preview.minerFee, 1100000);
      expect(preview.changeNanoErg, 2000000);
      expect(preview.inputCount, 1);
    });

    test('rejects missing or empty recipient', () {
      expect(
        () => SendPreview.fromJson({...valid, 'recipient': ''}),
        throwsFormatException,
      );
      final missing = Map<String, dynamic>.from(valid)..remove('recipient');
      expect(() => SendPreview.fromJson(missing), throwsFormatException);
    });

    test('rejects missing numeric fields', () {
      for (final key in [
        'preparation_id',
        'amount_nano_erg',
        'miner_fee',
        'change_nano_erg',
        'input_count',
      ]) {
        final missing = Map<String, dynamic>.from(valid)..remove(key);
        expect(() => SendPreview.fromJson(missing), throwsFormatException, reason: key);
      }
    });

    test('keeps token fields when present', () {
      final preview = SendPreview.fromJson({
        ...valid,
        'token_id': 'tok',
        'token_amount': 5,
      });
      expect(preview.tokenId, 'tok');
      expect(preview.tokenAmount, 5);
    });

    test('parses advanced input_boxes for the UTXO preview', () {
      final preview = SendPreview.fromJson({
        ...valid,
        'input_boxes': [
          {
            'box_id': '0123456789abcdef',
            'value_nano_erg': '2700000000',
            'creation_height': 100,
            'assets': [],
          },
          {
            'box_id': 'fedcba9876543210',
            'value_nano_erg': 1000000,
            'creation_height': 99,
            'assets': [
              {'token_id': 'nft-token-id', 'amount': '1'},
            ],
          },
        ],
      });
      expect(preview.inputBoxes, isNotEmpty);
      expect(preview.inputBoxes.length, 2);
      expect(preview.inputBoxes[0].boxId, '0123456789abcdef');
      expect(preview.inputBoxes[0].valueNanoErg, BigInt.parse('2700000000'));
      expect(preview.inputBoxes[0].creationHeight, 100);
      expect(preview.inputBoxes[0].assets, isEmpty);
      expect(preview.inputBoxes[1].valueNanoErg, BigInt.from(1000000));
      expect(preview.inputBoxes[1].assets.single.tokenId, 'nft-token-id');
      expect(preview.inputBoxes[1].assets.single.amount, BigInt.one);
    });

    test('input_boxes defaults to empty when absent (legacy preparation)', () {
      final preview = SendPreview.fromJson(valid);
      expect(preview.inputBoxes, isEmpty);
    });

    test('InputBoxInput.fromErgoBox parses camelCase node box response', () {
      final box = InputBoxInput.fromErgoBox({
        'boxId': 'node_box_id_123',
        'value': '3500000000',
        'creationHeight': 1050200,
        'assets': [
          {'tokenId': 'token_abc', 'amount': '500'},
        ],
      }, address: '9addr');
      expect(box.boxId, 'node_box_id_123');
      expect(box.valueNanoErg, BigInt.parse('3500000000'));
      expect(box.creationHeight, 1050200);
      expect(box.assets.length, 1);
      expect(box.assets.single.tokenId, 'token_abc');
      expect(box.assets.single.amount, BigInt.from(500));
      expect(box.address, '9addr');
    });
  });

  group('parseErgToNano', () {
    test('parses whole and fractional ERG', () {
      expect(parseErgToNano('1'), 1000000000);
      expect(parseErgToNano('1.0'), 1000000000);
      expect(parseErgToNano('0.001'), 1000000);
      expect(parseErgToNano('0.000000001'), 1);
      expect(parseErgToNano('.5'), 500000000);
    });

    test('accepts comma as a locale decimal separator', () {
      expect(parseErgToNano('1,5'), 1500000000);
      expect(parseErgToNano('1234,5'), 1234500000000);
      // Exactly-3-digit fractions like "0,001" are indistinguishable from
      // thousands grouping and are rejected by design (see next test).
    });

    test('rejects ambiguous or grouped comma forms', () {
      // "1,234" means 1234 in en-US but 1.234 in much of Europe — refuse
      // rather than silently mis-scaling a transfer.
      expect(parseErgToNano('1,234'), isNull);
      expect(parseErgToNano('12,345,678'), isNull);
      expect(parseErgToNano('0,001'), isNull);
      expect(parseErgToNano('1,23.4'), isNull);
    });

    test('accepts unambiguous thousands groups before a decimal point', () {
      expect(parseErgToNano('1,234.56'), 1234560000000);
    });

    test('rejects invalid input and extra precision', () {
      expect(parseErgToNano(''), isNull);
      expect(parseErgToNano('abc'), isNull);
      expect(parseErgToNano('1.2.3'), isNull);
      expect(parseErgToNano('-1'), isNull);
      expect(parseErgToNano('0.0000000001'), isNull);
    });
  });

  group('parseDecimalToBase', () {
    test('respects token decimals', () {
      expect(parseDecimalToBase('1', 0), 1);
      expect(parseDecimalToBase('1.50', 2), 150);
      expect(parseDecimalToBase('0.001', 3), 1);
    });

    test('rejects extra fractional digits', () {
      expect(parseDecimalToBase('1.001', 2), isNull);
      expect(parseDecimalToBase('x', 2), isNull);
    });

    test('rejects decimals outside 0-18', () {
      expect(parseDecimalToBase('1', -1), isNull);
      expect(parseDecimalToBase('1', 19), isNull);
    });

    test('rejects values that overflow signed 64-bit', () {
      expect(parseDecimalToBase('99999999999', 18), isNull);
    });
  });

  group('validatePin', () {
    test('enforces length', () {
      expect(validatePin('12345'), isNotNull);
      expect(validatePin('123456'), isNull);
      expect(validatePin('a' * 32), isNull);
      expect(validatePin('a' * 33), isNotNull);
    });
  });

  group('mnemonicWords', () {
    test('normalizes case and whitespace', () {
      expect(
        mnemonicWordsEqual('  Slow   SILLY start  ', 'slow silly start'),
        isTrue,
      );
      expect(mnemonicWords('one two').length, 2);
    });
  });

  group('isValidMnemonicWordCount', () {
    test('accepts all BIP-39 counts including the 15-word Ergo standard', () {
      expect(isValidMnemonicWordCount(12), isTrue);
      expect(isValidMnemonicWordCount(15), isTrue);
      expect(isValidMnemonicWordCount(18), isTrue);
      expect(isValidMnemonicWordCount(21), isTrue);
      expect(isValidMnemonicWordCount(24), isTrue);
    });

    test('rejects everything else', () {
      expect(isValidMnemonicWordCount(11), isFalse);
      expect(isValidMnemonicWordCount(13), isFalse);
      expect(isValidMnemonicWordCount(16), isFalse);
      expect(isValidMnemonicWordCount(0), isFalse);
    });
  });

  group('isAbsoluteHttpUrl', () {
    test('accepts only http(s) with a host', () {
      expect(isAbsoluteHttpUrl('https://ergo-node.eutxo.de'), isTrue);
      expect(isAbsoluteHttpUrl('http://127.0.0.1:9053'), isTrue);
      expect(isAbsoluteHttpUrl('ftp://x'), isFalse);
      expect(isAbsoluteHttpUrl('not a url'), isFalse);
    });
  });

  group('explorerTransactionUrl', () {
    test('opens SigmaSpace and official explorer pages', () {
      expect(
        explorerTransactionUrl('https://api.sigmaspace.io', 'abc'),
        'https://sigmaspace.io/en/transaction/abc',
      );
      expect(
        explorerTransactionUrl('https://api.ergoplatform.com', 'abc'),
        'https://explorer.ergoplatform.com/en/transactions/abc',
      );
    });
  });

  group('normalizeNodeUrl', () {
    test('upgrades a bare ip:port to https', () {
      expect(normalizeNodeUrl('104.131.9.252:9053'), 'https://104.131.9.252:9053');
    });

    test('keeps explicit http only for LAN hosts', () {
      expect(normalizeNodeUrl('http://192.168.1.10:9053'), 'http://192.168.1.10:9053');
      expect(normalizeNodeUrl('http://localhost:9053'), 'http://localhost:9053');
      expect(normalizeNodeUrl('http://10.0.0.5:9053'), 'http://10.0.0.5:9053');
    });

    test('rejects http for public hosts (dart:io bypasses platform TLS policy)', () {
      expect(normalizeNodeUrl('http://node.example.com'), isNull);
      expect(normalizeNodeUrl('http://104.131.9.252:9053'), isNull);
    });

    test('keeps https hosts', () {
      expect(normalizeNodeUrl('https://node.sigmaspace.io/'), 'https://node.sigmaspace.io');
    });
  });

  group('WalletRouteArgs.copyWith', () {
    test('keeps tokens and spendable when replacing the transaction', () {
      final token = TokenBalance(id: 't', amount: 1);
      final base = WalletRouteArgs(
        senderAddress: 'a',
        receiveAddress: 'b',
        changeAddress: 'c',
        historyAddresses: const ['a'],
        tokens: [token],
        spendableNano: 9,
      );
      final next = base.copyWith(transaction: {'tx_id': 'x'});
      expect(next.tokens.single.id, 't');
      expect(next.spendableNano, 9);
      expect(next.transaction?['tx_id'], 'x');
    });
  });

  group('WalletSession handleId precision', () {
    test('supports large 64-bit integer handleIds without overflow', () {
      final largeId = BigInt.parse('14285714285714285714');
      final session = WalletSession(
        walletId: 'test-wallet',
        handleId: largeId,
        encryptedSeedJson: '{"test": true}',
        wrapKey: 'deadbeef',
      );
      expect(session.handleId, largeId);
      expect(session.handleId.toString(), '14285714285714285714');
    });
  });

  group('WalletDatabaseService', () {
    test('saves and loads encrypted snapshot scoped to wallet identifier', () async {
      SharedPreferences.setMockInitialValues({});

      await WalletDatabaseService.saveCachedState(
        walletId: '9fTestReceiveAddress',
        primaryAddress: '9fTestReceiveAddress',
        usedAddresses: [
          {'index': 0, 'address': '9fTestReceiveAddress', 'balance_nano_erg': 2000000000}
        ],
        balanceNano: 2000000000,
        tokens: [
          {'id': 'token123', 'amount': 100, 'name': 'SigUSD', 'decimals': 2}
        ],
        transactions: [
          {'tx_id': 'tx123', 'value_nano_erg': 2000000000, 'timestamp': 1700000000}
        ],
        utxoCount: 5,
        lastSyncedHeight: 1205000,
      );

      // Loading with matching walletId succeeds
      final cached = await WalletDatabaseService.loadCachedState(
        expectedWalletId: '9fTestReceiveAddress',
      );
      expect(cached, isNotNull);
      expect(cached!['wallet_id'], '9fTestReceiveAddress');
      expect(cached['primary_address'], '9fTestReceiveAddress');
      expect(cached['balance_nano_erg'], 2000000000);
      expect(cached['utxo_count'], 5);
      expect((cached['tokens'] as List).length, 1);

      // Loading with mismatched walletId returns null
      final mismatched = await WalletDatabaseService.loadCachedState(
        expectedWalletId: '9fOtherWalletAddress',
      );
      expect(mismatched, isNull);

      await WalletDatabaseService.recordLineage(
        singletonTokenId: 'singleton_sigusd_bank',
        protocolName: 'SigmaUSD Bank',
        rootBoxId: 'root_box_001',
        currentBoxId: 'curr_box_009',
        lastUpdatedHeight: 1205000,
        boxJson: {'value': 50000000000},
      );

      final lineages = await WalletDatabaseService.getTrackedLineages();
      expect(lineages.containsKey('singleton_sigusd_bank'), isTrue);
      expect(lineages['singleton_sigusd_bank']['protocol_name'], 'SigmaUSD Bank');
      expect(lineages['singleton_sigusd_bank']['current_box_id'], 'curr_box_009');
    });
  });
}

// Which address a wallet shows when it is not the active one
void _displayAddressTests() {
  WalletInfo info({int? pinnedIndex, String? pinnedAddress, String? address0}) => WalletInfo(
        walletId: 'w',
        name: 'w',
        createdAt: DateTime(2026),
        address0: address0,
        pinnedAddressIndex: pinnedIndex,
        pinnedAddress: pinnedAddress,
      );

  test('a vanity address at index 0 needs no pin and is shown as is', () {
    // The first wallet's vanity address is index 0, so address0 is already
    // the address the user wants to see, pinned or not.
    expect(info(address0: '9vanity').displayAddress, '9vanity');
    expect(info(pinnedIndex: 0, address0: '9vanity').displayAddress, '9vanity');
  });

  test('a pin above index 0 shows the pinned address', () {
    expect(
      info(pinnedIndex: 97, pinnedAddress: '9pinned', address0: '9zero').displayAddress,
      '9pinned',
    );
  });

  test('a pin whose address was never stored falls back, which is what backfill repairs', () {
    // The locked wallet cannot derive index 97 without its seed, so until
    // the address is recorded it can only show index 0.
    expect(info(pinnedIndex: 97, address0: '9zero').displayAddress, '9zero');
  });
}

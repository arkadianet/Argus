import 'dart:io';
import 'dart:typed_data';

import 'package:argus_wallet/services/apk_signature.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/apk_fixture.dart';

Future<ApkSigners> read(Uint8List apkBytes) => readApkSigners(BytesApkSource(apkBytes));

Matcher failsWith(ApkSignatureProblem problem) =>
    throwsA(isA<ApkSignatureException>().having((e) => e.problem, 'problem', problem));

void main() {
  final certA = fakeCertificate(1);
  final certB = fakeCertificate(2, size: 300);
  final certC = fakeCertificate(3);

  group('a signed APK', () {
    test('yields the certificate of a v2 signature', () async {
      final signers = await read(signedApk(certA));
      expect(signers.scheme, ApkSignatureScheme.v2);
      expect(signers.certificates, [certA]);
      expect(signers.first, certA);
    });

    test('yields the certificate of a v3 signature', () async {
      final signers = await read(signedApk(certA, v3: true));
      expect(signers.scheme, ApkSignatureScheme.v3);
      expect(signers.first, certA);
    });

    test('prefers v3 when both schemes are present', () async {
      final block = signingBlock([
        (v2BlockId, schemeValue([signer([certA])])),
        (v3BlockId, schemeValue([signer([certB], v3: true)])),
      ]);
      final signers = await read(apk(block: block));
      expect(signers.scheme, ApkSignatureScheme.v3);
      expect(signers.first, certB);
    });

    test('takes the first certificate of the signer, not the rest of its chain', () async {
      final signers = await read(apk(block: schemeBlock([signer([certA, certB, certC])])));
      expect(signers.certificates, [certA]);
    });

    test('lists every signer, first signer first', () async {
      final signers = await read(apk(block: schemeBlock([signer([certB]), signer([certA])])));
      expect(signers.certificates, [certB, certA]);
      expect(signers.first, certB);
    });

    test('walks past other pairs, including padding, to the scheme block', () async {
      final block = signingBlock([
        (paddingBlockId, Uint8List(4000)),
        (0x504b4453, bytes([1, 2, 3])),
        (v2BlockId, schemeValue([signer([certA])])),
        (0x6dff800d, Uint8List(10)),
      ]);
      expect((await read(apk(block: block))).first, certA);
    });

    test('uses the first pair when an id appears twice', () async {
      final block = signingBlock([
        (v2BlockId, schemeValue([signer([certA])])),
        (v2BlockId, schemeValue([signer([certB])])),
      ]);
      expect((await read(apk(block: block))).first, certA);
    });

    test('finds the end record behind a ZIP comment', () async {
      final signers = await read(apk(block: schemeBlock([signer([certA])]), comment: List<int>.filled(500, 0x63)));
      expect(signers.first, certA);
    });

    test('is not misled by an end-record signature inside the comment', () async {
      // The last occurrence of the signature is the fake one. Its comment
      // length does not reach the end of the file, so it is not a record.
      final fake = [0x50, 0x4b, 0x05, 0x06, ...List<int>.filled(16, 0x7f), 0x09, 0x00, 1, 2, 3];
      final signers = await read(apk(block: schemeBlock([signer([certA])]), comment: fake));
      expect(signers.first, certA);
    });

    test('reads the same through a file, and only the tail of it', () async {
      final dir = await Directory.systemTemp.createTemp('apk_sig_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.apk');
      await file.writeAsBytes(apk(block: schemeBlock([signer([certA])]), entriesLength: 6 * 1024 * 1024));
      final signers = await readApkSignersFromFile(file);
      expect(signers.first, certA);
    });
  });

  group('an APK without a usable signature', () {
    test('too small to be a ZIP', () async {
      expect(read(Uint8List(0)), failsWith(ApkSignatureProblem.notAnApk));
      expect(read(bytes([0x50, 0x4b, 0x05, 0x06])), failsWith(ApkSignatureProblem.notAnApk));
    });

    test('no end-of-central-directory record', () async {
      expect(read(Uint8List.fromList(List<int>.generate(2000, (i) => i & 0x3f))), failsWith(ApkSignatureProblem.notAnApk));
    });

    test('no signing block, as with an unsigned or JAR-signed APK', () async {
      expect(read(apk()), failsWith(ApkSignatureProblem.noSigningBlock));
    });

    test('the magic is missing', () async {
      final block = schemeBlock([signer([certA])]);
      final broken = Uint8List.fromList(block)..[block.length - 3] = 0x58;
      expect(read(apk(block: broken)), failsWith(ApkSignatureProblem.noSigningBlock));
    });

    test('a block with neither v2 nor v3', () async {
      final block = signingBlock([(paddingBlockId, Uint8List(100)), (0x504b4453, bytes([9]))]);
      expect(read(apk(block: block)), failsWith(ApkSignatureProblem.noSupportedScheme));
    });

    test('an empty block', () async {
      expect(read(apk(block: signingBlock([]))), failsWith(ApkSignatureProblem.noSupportedScheme));
    });

    test('a ZIP64 archive', () async {
      final zip64Locator = [0x50, 0x4b, 0x06, 0x07, ...List<int>.filled(16, 0)];
      final block = schemeBlock([signer([certA])]);
      expect(read(apk(block: block, beforeEocd: zip64Locator)), failsWith(ApkSignatureProblem.unsupported));
      expect(read(apk(block: block, centralOffsetField: 0xffffffff)), failsWith(ApkSignatureProblem.unsupported));
    });
  });

  group('a damaged signing block', () {
    test('the central directory does not run into the end record', () async {
      final block = schemeBlock([signer([certA])]);
      expect(read(apk(block: block, beforeEocd: [0, 0, 0])), failsWith(ApkSignatureProblem.malformed));
      expect(read(apk(block: block, centralSizeDelta: 5)), failsWith(ApkSignatureProblem.malformed));
    });

    test('its two size fields disagree', () async {
      final signerBytes = signer([certA]);
      final good = schemeBlock([signerBytes]);
      final pairs = [(v2BlockId, schemeValue([signerBytes]))];
      expect(read(apk(block: signingBlock(pairs, sizeOverride: good.length - 8 + 1))), failsWith(ApkSignatureProblem.malformed));
      expect(read(apk(block: signingBlock(pairs, trailingSizeOverride: 40))), failsWith(ApkSignatureProblem.malformed));
    });

    test('it claims to be larger than the file before it', () async {
      final pairs = [(v2BlockId, schemeValue([signer([certA])]))];
      final lying = signingBlock(pairs, sizeOverride: 100000, trailingSizeOverride: 100000);
      expect(read(apk(block: lying)), failsWith(ApkSignatureProblem.malformed));
    });

    test('it claims a size beyond what is ever allocated', () async {
      final pairs = [(v2BlockId, schemeValue([signer([certA])]))];
      final lying = signingBlock(pairs, sizeOverride: 0x7fffffff, trailingSizeOverride: 0x7fffffff);
      expect(read(apk(block: lying)), failsWith(ApkSignatureProblem.malformed));
    });

    test('a size field too large to be a length', () async {
      final good = schemeBlock([signer([certA])]);
      // High bit of the trailing size set: not a length of any file.
      final broken = Uint8List.fromList(good);
      broken[good.length - 24 + 7] = 0xff;
      expect(read(apk(block: broken)), failsWith(ApkSignatureProblem.malformed));
    });

    test('it is cut short, so a pair runs past the end', () async {
      final value = schemeValue([signer([certA])]);
      final body = concat([u64(4 + value.length + 500), u32(v2BlockId), value]);
      final size = body.length + 8 + 16;
      final block = concat([u64(size), body, u64(size), 'APK Sig Block 42'.codeUnits]);
      expect(read(apk(block: block)), failsWith(ApkSignatureProblem.malformed));
    });

    test('it ends inside a pair header', () async {
      final body = bytes([1, 2, 3, 4, 5]);
      final size = body.length + 8 + 16;
      final block = concat([u64(size), body, u64(size), 'APK Sig Block 42'.codeUnits]);
      expect(read(apk(block: block)), failsWith(ApkSignatureProblem.malformed));
    });

    test('a pair too short to hold its id', () async {
      final body = concat([u64(2), bytes([1, 2]), Uint8List(12)]);
      final size = body.length + 8 + 16;
      final block = concat([u64(size), body, u64(size), 'APK Sig Block 42'.codeUnits]);
      expect(read(apk(block: block)), failsWith(ApkSignatureProblem.malformed));
    });

    test('the scheme value is cut mid-signer', () async {
      final full = schemeValue([signer([certA])]);
      final cut = Uint8List.sublistView(full, 0, full.length - 20);
      expect(read(apk(block: signingBlock([(v2BlockId, cut)]))), failsWith(ApkSignatureProblem.malformed));
    });

    test('the scheme value is too short for a length prefix', () async {
      expect(read(apk(block: signingBlock([(v2BlockId, bytes([1, 2]))]))), failsWith(ApkSignatureProblem.malformed));
      expect(read(apk(block: signingBlock([(v3BlockId, Uint8List(0))]))), failsWith(ApkSignatureProblem.malformed));
    });

    test('a length prefix points past its container', () async {
      final value = lengthPrefixed(concat([u32(9999), bytes([1, 2, 3])]));
      expect(read(apk(block: signingBlock([(v2BlockId, value)]))), failsWith(ApkSignatureProblem.malformed));
    });

    test('there are no signers', () async {
      expect(read(apk(block: schemeBlock([]))), failsWith(ApkSignatureProblem.malformed));
    });

    test('a signer has no certificate', () async {
      expect(read(apk(block: schemeBlock([signer([])]))), failsWith(ApkSignatureProblem.malformed));
    });

    test('the certificate is not DER', () async {
      final junk = bytes([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(read(apk(block: schemeBlock([signer([junk])]))), failsWith(ApkSignatureProblem.malformed));
      // A SEQUENCE whose length does not account for the bytes that follow.
      final shifted = bytes([0x30, 0x10, 1, 2, 3]);
      expect(read(apk(block: schemeBlock([signer([shifted])]))), failsWith(ApkSignatureProblem.malformed));
    });

    test('a damaged v3 block is not replaced by a good v2 one', () async {
      final block = signingBlock([
        (v2BlockId, schemeValue([signer([certA])])),
        (v3BlockId, bytes([1, 2])),
      ]);
      expect(read(apk(block: block)), failsWith(ApkSignatureProblem.malformed));
    });
  });

  // Archives signed by Android's own `apksigner` (build-tools 36) with throwaway
  // keys that were discarded: the point is that the parser agrees with the
  // tool that produced a real signing block, not just with this file's own
  // fixture builder. Each is a ZIP of two small entries, 8 KiB with the
  // signing block's alignment padding.
  //
  //   v2_only.apk  RSA-4096 key, `--v1-signing-enabled false --v3-signing-enabled false`:
  //                what a release build of Argus carries.
  //   v2_v3.apk    P-256 key, v2 and v3 together.
  //
  // The expected fingerprints are what `apksigner verify --print-certs` prints.
  group('archives signed by apksigner', () {
    const v2OnlyFingerprint = 'b18fade1976d1e326aed3583cd8a2c4eb2ee5cbef390aaf7988fd359d4f9fc3c';
    const v2v3Fingerprint = '409f5fc3f3037a3ac7827cf6ff7fce27278b24416733040f8e988889753cc96a';

    test('a v2-only signature, as Argus releases carry', () async {
      final signers = await readApkSignersFromFile(File('test/fixtures/signed/v2_only.apk'));
      expect(signers.scheme, ApkSignatureScheme.v2);
      expect(signers.certificates, hasLength(1));
      expect(certificateSha256(signers.first), v2OnlyFingerprint);
    });

    test('v2 and v3 together read as v3, with the same signer', () async {
      final signers = await readApkSignersFromFile(File('test/fixtures/signed/v2_v3.apk'));
      expect(signers.scheme, ApkSignatureScheme.v3);
      expect(signers.certificates, hasLength(1));
      expect(certificateSha256(signers.first), v2v3Fingerprint);
    });

    test('the two keys are told apart', () async {
      final a = await readApkSignersFromFile(File('test/fixtures/signed/v2_only.apk'));
      final b = await readApkSignersFromFile(File('test/fixtures/signed/v2_v3.apk'));
      expect(certificateSha256(a.first), isNot(certificateSha256(b.first)));
    });

    test('cut short, or with its magic damaged, they are refused rather than misread', () async {
      final original = await File('test/fixtures/signed/v2_only.apk').readAsBytes();
      // No end record: the file stops before the archive does.
      expect(read(Uint8List.sublistView(original, 0, original.length - 30)), failsWith(ApkSignatureProblem.notAnApk));
      expect(read(Uint8List.sublistView(original, 0, 1500)), failsWith(ApkSignatureProblem.notAnApk));

      // The magic sits just before the central directory; find it and break it.
      final text = String.fromCharCodes(original);
      final at = text.indexOf('APK Sig Block 42');
      expect(at, greaterThan(0));
      final broken = Uint8List.fromList(original)..[at + 4] = 0x58;
      expect(read(broken), failsWith(ApkSignatureProblem.noSigningBlock));
    });

    test('a file cut short is refused through the file reader too', () async {
      final dir = await Directory.systemTemp.createTemp('apk_sig_cut');
      addTearDown(() => dir.delete(recursive: true));
      final original = await File('test/fixtures/signed/v2_only.apk').readAsBytes();
      for (final length in [0, 10, 21, 22, 100, 4000, original.length - 22, original.length - 1]) {
        final file = File('${dir.path}/cut_$length.apk');
        await file.writeAsBytes(Uint8List.sublistView(original, 0, length));
        await expectLater(readApkSignersFromFile(file), throwsA(isA<ApkSignatureException>()), reason: 'cut at $length');
      }
    });

    test('damage anywhere is either read as before or refused, never a crash', () async {
      // Every byte flipped in turn, and the file cut at many lengths. The
      // parser reads what the block says and Android checks the signature
      // over it, so a damaged file may still parse; what must never happen
      // is an error of another kind, a RangeError from a length that was
      // trusted, say, escaping to the caller.
      final original = await File('test/fixtures/signed/v2_only.apk').readAsBytes();
      var parsed = 0;
      var refused = 0;
      Future<void> attempt(Uint8List bytes) async {
        try {
          await read(bytes);
          parsed++;
        } on ApkSignatureException {
          refused++;
        }
      }

      for (var i = 0; i < original.length; i++) {
        await attempt(Uint8List.fromList(original)..[i] ^= 0xff);
      }
      for (var length = 0; length < original.length; length += 7) {
        await attempt(Uint8List.sublistView(original, 0, length));
      }
      expect(parsed, greaterThan(0), reason: 'bytes outside what is read still parse');
      expect(refused, greaterThan(original.length ~/ 10), reason: 'damage to what is read is caught');
    });
  });

  group('fingerprints', () {
    test('certificateSha256 is the lower-case hex SHA-256 of the DER bytes', () {
      // SHA-256 of "abc".
      expect(
        certificateSha256('abc'.codeUnits),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('formatFingerprint prints colon-separated upper-case pairs', () {
      expect(formatFingerprint('e58b1835b7d5f32a'), 'E5:8B:18:35:B7:D5:F3:2A');
    });

    test('normalizeSha256 accepts either spelling and nothing else', () {
      const hex = 'e58b1835b7d5f32ac9830829ec949f8dd9c62c2064ad89e1973533177db47fcc';
      const colons = 'E5:8B:18:35:B7:D5:F3:2A:C9:83:08:29:EC:94:9F:8D:D9:C6:2C:20:64:AD:89:E1:97:35:33:17:7D:B4:7F:CC';
      expect(normalizeSha256(hex), hex);
      expect(normalizeSha256(colons), hex);
      expect(normalizeSha256(hex.toUpperCase()), hex);
      expect(normalizeSha256(hex.substring(1)), isNull);
      expect(normalizeSha256('${hex}0'), isNull);
      expect(normalizeSha256('zz${hex.substring(2)}'), isNull);
      expect(normalizeSha256(''), isNull);
    });
  });
}

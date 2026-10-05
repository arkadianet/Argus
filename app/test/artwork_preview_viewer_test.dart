import 'dart:io';
import 'dart:ui' as ui;

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/privacy_service.dart';
import 'package:argus_wallet/services/preview/preview_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/widgets/artwork_preview_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_preview_test.dart' show PreviewApi, NoPreviewHttp;

void main() {
  setUpAll(() => RustLib.initMock(api: PreviewApi()));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await privacyService.load();
    await previewSettings.load();
    networkController.activeUrl = 'https://node.example';
    await walletService.restoreWallet('mock', walletId: 'viewer-wallet');
  });
  tearDown(() async => walletService.lock());

  Future<ui.Image> pixels(WidgetTester tester) async {
    final result = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.red);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(8, 8);
      } finally {
        picture.dispose();
      }
    });
    return result!;
  }

  Future<ValueNotifier<int>> mount(WidgetTester tester) async {
    final generation = ValueNotifier<int>(0);
    final image = await pixels(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkPreviewViewer(
          image: image,
          label: 'My artwork',
          integrity: 'Matches issuance hash',
          walletId: walletService.currentWalletId.value,
          settingsRevision: previewSettings.revision,
          generation: generation,
          expectedGeneration: 0,
        ),
      ),
    );
    addTearDown(generation.dispose);
    return generation;
  }

  testWidgets('zoom and reset use existing pixels without a media request', (
    tester,
  ) async {
    final deny = NoPreviewHttp(), previous = HttpOverrides.current;
    HttpOverrides.global = deny;
    addTearDown(() => HttpOverrides.global = previous);
    await mount(tester);
    expect(find.text('My artwork'), findsOneWidget);
    expect(find.text('Matches issuance hash'), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.maxScale, 5);
    viewer.transformationController!.value = Matrix4.diagonal3Values(3, 3, 1);
    await tester.pump();
    await tester.tap(find.byTooltip('Reset zoom'));
    await tester.pump();
    expect(viewer.transformationController!.value, Matrix4.identity());
    expect(find.byType(RawImage), findsOneWidget);
    expect(deny.calls, 0);
  });

  testWidgets(
    'owner revocation during a sibling rebuild safely clears the viewer',
    (tester) async {
      final generation = ValueNotifier<int>(0);
      addTearDown(generation.dispose);
      final viewer = ArtworkPreviewViewer(
        image: await pixels(tester),
        label: 'My artwork',
        integrity: 'Matches issuance hash',
        walletId: walletService.currentWalletId.value,
        settingsRevision: previewSettings.revision,
        generation: generation,
        expectedGeneration: 0,
      );
      late StateSetter rebuild;
      var revoke = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Stack(
                children: [
                  viewer,
                  Builder(
                    builder: (_) {
                      if (revoke) generation.value++;
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              );
            },
          ),
        ),
      );
      rebuild(() => revoke = true);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(RawImage), findsNothing);
    },
  );

  for (final change in [
    'lock',
    'wallet',
    'hidden',
    'background',
    'offline',
    'settings',
    'owner',
  ]) {
    testWidgets('$change clears pixels and returning does not reveal them', (
      tester,
    ) async {
      final generation = await mount(tester);
      expect(find.byType(RawImage), findsOneWidget);
      switch (change) {
        case 'lock':
          await walletService.lock();
          await walletService.restoreWallet('mock', walletId: 'viewer-wallet');
        case 'wallet':
          await walletService.restoreWallet('mock', walletId: 'other-wallet');
          await walletService.restoreWallet('mock', walletId: 'viewer-wallet');
        case 'hidden':
          await privacyService.setHideBalances(true);
          await privacyService.setHideBalances(false);
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        case 'offline':
          networkController.activeUrl = null;
          // Same notification emitted by a connection probe.
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          networkController.notifyListeners();
          networkController.activeUrl = 'https://node.example';
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          networkController.notifyListeners();
        case 'settings':
          await previewSettings.setNever(true);
          await previewSettings.setNever(false);
        case 'owner':
          generation.value++;
      }
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.text('My artwork'), findsNothing);
      expect(find.textContaining('Preview hidden.'), findsOneWidget);
    });
  }
}

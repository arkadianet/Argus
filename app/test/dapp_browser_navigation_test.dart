import 'package:argus_wallet/ui/dapp_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

class BrowserPlatform extends InAppWebViewPlatform {
  final views = <BrowserView>[];
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(PlatformInAppWebViewWidgetCreationParams params) {
    final view = BrowserView(params);
    views.add(view);
    return view;
  }
}

class BrowserController extends PlatformInAppWebViewController {
  BrowserController() : super.implementation(const PlatformInAppWebViewControllerCreationParams(id: 1));
  final loads = <String>[];
  @override
  void addJavaScriptHandler({required String handlerName, required JavaScriptHandlerCallback callback}) {}
  @override
  Future<void> loadUrl({required URLRequest urlRequest, WebUri? allowingReadAccessTo, Uri? iosAllowingReadAccessTo}) async {
    loads.add(urlRequest.url.toString());
  }
}

class BrowserView extends PlatformInAppWebViewWidget {
  BrowserView(super.params) : super.implementation();
  final controller = BrowserController();
  bool created = false;
  @override
  Widget build(BuildContext context) {
    if (!created) {
      created = true;
      params.onWebViewCreated?.call(controllerFromPlatform<InAppWebViewController>(controller));
    }
    return const SizedBox();
  }
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;
  @override
  void dispose() {}
}

void main() {
  testWidgets('each return from the list opens the intended site in the new view', (tester) async {
    final platform = BrowserPlatform();
    InAppWebViewPlatform.instance = platform;
    await tester.pumpWidget(const MaterialApp(home: DappBrowserScreen()));
    expect(find.textContaining('can connect to this wallet'), findsOneWidget);
    expect(find.textContaining('as their Nautilus'), findsNothing);
    await tester.tap(find.text('SigmaFi'));
    await tester.pumpAndSettle();
    expect(platform.views.single.params.initialUrlRequest?.url.toString(), 'https://sigmafi.app');
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('dApp list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ErgoDEX'));
    await tester.pumpAndSettle();
    expect(platform.views.last.params.initialUrlRequest?.url.toString(), 'https://ergodex.io');
    expect(platform.views.first.controller.loads, isEmpty);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('dApp list'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
        find.textContaining('Back to https://ergodex.io'),
        find.ancestor(of: find.text('SigmaFi'), matching: find.byType(Scrollable)).first,
        const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Back to https://ergodex.io'));
    await tester.pumpAndSettle();
    expect(platform.views.last.params.initialUrlRequest?.url.toString(), 'https://ergodex.io');
    expect(tester.takeException(), isNull);
  });
}

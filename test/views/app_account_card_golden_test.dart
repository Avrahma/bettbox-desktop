import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/views/dashboard/widgets/app_account_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _subscription = {
  'id': 1,
  'plan_name': '旗舰套餐',
  'expires_on': '2027-09-30',
  'days_left': 311,
  'expired': false,
  'sub_url': 'http://example.com/sub/token',
  'traffic': {
    'upload': 0,
    'download': 123456789012,
    'used': 123456789012,
    'total': 536870912000,
  },
};

Map<String, dynamic> _json({required bool withSub}) => {
  'site_name': '订阅服务中心',
  'account': {
    'id': 1,
    'email': 'user@example.com',
    'username': 'user@example.com',
    'display_name': '',
    'balance': 1234.56,
    'is_active': true,
  },
  'subscriptions': withSub ? [_subscription] : const <Map<String, dynamic>>[],
  'primary': withSub ? _subscription : null,
};

Future<void> _shot(WidgetTester tester, String name, {required bool withSub}) async {
  AppAuth.instance.debugLoad(accountJson: _json(withSub: withSub));
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.topCenter,
            child: AppAccountCard(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await expectLater(
    find.byType(AppAccountCard),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('golden with sub', (tester) async {
    await _shot(tester, 'card_with_sub', withSub: true);
  });

  testWidgets('golden without sub', (tester) async {
    await _shot(tester, 'card_no_sub', withSub: false);
  });
}

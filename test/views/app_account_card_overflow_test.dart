import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/views/dashboard/widgets/app_account_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _subscription = {
  'id': 1,
  'plan_name': '旗舰套餐（不限速）',
  'expires_on': '2027-09-30',
  'days_left': 311,
  'expired': false,
  'sub_url': 'http://example.com/sub/very-long-token-value',
  'traffic': {
    'upload': 0,
    'download': 123456789012,
    'used': 123456789012,
    'total': 536870912000,
  },
};

Map<String, dynamic> _accountJson({required bool withSub}) => {
  'site_name': '订阅服务中心',
  'account': {
    'id': 1,
    'email': 'very.long.account.name@example.com',
    'username': 'very.long.account.name@example.com',
    'display_name': '',
    'balance': 1234.56,
    'is_active': true,
  },
  'subscriptions': withSub ? [_subscription] : const <Map<String, dynamic>>[],
  'primary': withSub ? _subscription : null,
};

Future<void> _render(
  WidgetTester tester,
  double logicalWidth, {
  double textScale = 1.0,
  bool withSub = true,
}) async {
  AppAuth.instance.debugLoad(accountJson: _accountJson(withSub: withSub));

  tester.view.physicalSize = Size(logicalWidth * 3, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(12),
          child: AppAccountCard(),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(AppAuth.instance.loggedIn, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('有套餐：320 逻辑宽度下不溢出且显示续费 / 管理', (tester) async {
    await _render(tester, 320);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('旗舰套餐'), findsWidgets);
    expect(find.text('续费 / 管理'), findsOneWidget);
    expect(find.text('购买套餐'), findsNothing);
    expect(find.text('到期时间'), findsOneWidget);
  });

  testWidgets('有套餐：360 逻辑宽度下不溢出', (tester) async {
    await _render(tester, 360);
    expect(tester.takeException(), isNull);
    expect(find.text('续费 / 管理'), findsOneWidget);
  });

  testWidgets('有套餐：300 宽 + 1.3 倍字号下不溢出', (tester) async {
    await _render(tester, 300, textScale: 1.3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无套餐：只显示购买套餐，不显示续费 / 管理与到期信息', (tester) async {
    await _render(tester, 320, withSub: false);
    expect(tester.takeException(), isNull);
    expect(find.text('购买套餐'), findsOneWidget);
    expect(find.text('续费 / 管理'), findsNothing);
    expect(find.text('到期时间'), findsNothing);
    expect(find.text('未开通套餐'), findsOneWidget);
  });

  testWidgets('无套餐：300 宽 + 1.3 倍字号下不溢出', (tester) async {
    await _render(tester, 300, textScale: 1.3, withSub: false);
    expect(tester.takeException(), isNull);
    expect(find.text('购买套餐'), findsOneWidget);
  });
}

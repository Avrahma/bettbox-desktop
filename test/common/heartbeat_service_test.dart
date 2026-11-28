import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/heartbeat_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设备心跳端到端（本地 mock 服务端）验证：
/// 请求形态、响应解析、错误码处置、in-flight 防抖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final List<String> paths = [];
  final List<Map<String, String>> headers = [];
  int responseStatus = 200;
  Map<String, dynamic> responseBody = {
    'ok': true,
    'online': true,
    'limit': 0,
    'online_devices': 2,
    'used_devices': 3,
  };
  Duration responseDelay = Duration.zero;

  setUp(() async {
    // flutter_test 默认把所有 HttpClient 请求改写成 400，这里恢复真实网络栈。
    HttpOverrides.global = null;
    paths.clear();
    headers.clear();
    responseStatus = 200;
    responseDelay = Duration.zero;
    responseBody = {
      'ok': true,
      'online': true,
      'limit': 0,
      'online_devices': 2,
      'used_devices': 3,
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((request) async {
      paths.add(request.uri.path);
      headers.add({
        'auth': request.headers.value('authorization') ?? '',
        'device': request.headers.value('x-device-id') ?? '',
        'platform': request.headers.value('x-device-platform') ?? '',
        'name': request.headers.value('x-device-name') ?? '',
        'content-length': '${request.headers.contentLength}',
      });
      if (responseDelay > Duration.zero) {
        await Future<void>.delayed(responseDelay);
      }
      request.response.statusCode = responseStatus;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode(responseBody));
      await request.response.close();
    });
    AppAuth.instance.debugLoad(
      token: 'tok-123',
      accountJson: {'ok': true},
      baseUrl: 'http://127.0.0.1:$port',
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('200：带齐三个设备头，解析在线/名额数据', () async {
    final result = await AppAuth.instance.heartbeat();
    expect(paths, ['/api/app/heartbeat']);
    expect(headers.single['auth'], 'Bearer tok-123');
    expect(headers.single['device'], isNotEmpty);
    expect(headers.single['platform'], isNotEmpty);
    expect(headers.single['name'], isNotEmpty);
    expect(headers.single['content-length'], anyOf('-1', '0'));
    expect(result.ok, isTrue);
    expect(result.online, isTrue);
    expect(result.limit, 0);
    expect(result.onlineDevices, 2);
    expect(result.usedDevices, 3);
  });

  test('401 DEVICE_KICKED：识别为被踢', () async {
    responseStatus = 401;
    responseBody = {
      'ok': false,
      'code': 'DEVICE_KICKED',
      'error': '该设备已被移出登录状态，请重新登录',
    };
    final result = await AppAuth.instance.heartbeat();
    expect(result.kicked, isTrue);
    expect(result.tokenInvalid, isFalse);
    expect(result.message, contains('移出登录状态'));
  });

  test('409 DEVICE_LIMIT：识别为名额超限且不抛异常', () async {
    responseStatus = 409;
    responseBody = {
      'ok': false,
      'code': 'DEVICE_LIMIT',
      'error': '该账号已在其他设备登录，本次心跳未登记',
    };
    final result = await AppAuth.instance.heartbeat();
    expect(result.limitReached, isTrue);
    expect(result.ok, isFalse);
  });

  test('401 无 code：走 token 失效流程', () async {
    responseStatus = 401;
    responseBody = {'ok': false, 'error': '登录已失效，请重新登录'};
    final result = await AppAuth.instance.heartbeat();
    expect(result.tokenInvalid, isTrue);
    expect(result.kicked, isFalse);
  });

  test('未登录：不发请求', () async {
    AppAuth.instance.debugLoad(
      token: '',
      accountJson: {'ok': true},
      baseUrl: 'http://127.0.0.1:$port',
    );
    final result = await AppAuth.instance.heartbeat();
    expect(result.statusCode, 401);
    expect(result.code, 'NO_TOKEN');
    expect(paths, isEmpty);
  });

  test('in-flight 防抖：慢响应期间重复 resumed 不叠加并发请求', () async {
    responseDelay = const Duration(milliseconds: 1200);
    final service = HeartbeatService.instance;
    service.attach();
    // attach 时 AppAuth 已登录 → 立即发一次；随后 600ms 内模拟多次回前台。
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(paths.length, 1);
    service.dispose();
  });
}

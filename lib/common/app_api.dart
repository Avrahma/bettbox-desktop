import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/device_identity.dart';
import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/print.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// 账户订阅流量信息，来自订阅响应头 subscription-userinfo。
class AppTraffic {
  const AppTraffic({
    this.upload = 0,
    this.download = 0,
    this.used = 0,
    this.total = 0,
  });

  final int upload;
  final int download;
  final int used;
  final int total;

  static AppTraffic? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    int read(String key) {
      final value = json[key];
      if (value is num) {
        return value.toInt();
      }
      return int.tryParse('${value ?? ''}') ?? 0;
    }

    return AppTraffic(
      upload: read('upload'),
      download: read('download'),
      used: read('used'),
      total: read('total'),
    );
  }

  String get usedText => appFormatBytes(used);

  String get totalText => total <= 0 ? '不限' : appFormatBytes(total);

  double get ratio =>
      total <= 0 ? 0 : (used / total).clamp(0.0, 1.0).toDouble();
}

/// 单个订阅（一个套餐周期内的分配）。
class AppSubscription {
  const AppSubscription({
    required this.id,
    required this.planName,
    required this.expiresOn,
    required this.daysLeft,
    required this.expired,
    required this.subUrl,
    this.traffic,
  });

  final int id;
  final String planName;
  final String expiresOn;
  final int daysLeft;
  final bool expired;
  final String subUrl;
  final AppTraffic? traffic;

  static AppSubscription fromJson(Map<String, dynamic> json) {
    return AppSubscription(
      id: (json['id'] as num?)?.toInt() ?? 0,
      planName: json['plan_name']?.toString() ?? '',
      expiresOn: json['expires_on']?.toString() ?? '',
      daysLeft: (json['days_left'] as num?)?.toInt() ?? -1,
      expired: json['expired'] == true,
      subUrl: json['sub_url']?.toString() ?? '',
      traffic: AppTraffic.fromJson(json['traffic']),
    );
  }

  String get statusText {
    if (expired) {
      return '已到期';
    }
    if (daysLeft < 0) {
      return '长期有效';
    }
    return '剩余 $daysLeft 天';
  }
}

/// 账号信息。
class AppAccount {
  const AppAccount({
    required this.id,
    required this.email,
    required this.username,
    required this.displayName,
    required this.balance,
    required this.isActive,
  });

  final int id;
  final String email;
  final String username;
  final String displayName;
  final double balance;
  final bool isActive;

  String get name {
    if (displayName.isNotEmpty) {
      return displayName;
    }
    if (username.isNotEmpty) {
      return username;
    }
    return email;
  }

  static AppAccount fromJson(Map<String, dynamic> json) {
    return AppAccount(
      id: (json['id'] as num?)?.toInt() ?? 0,
      email: json['email']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      balance: (json['balance'] as num?)?.toDouble() ?? 0,
      isActive: json['is_active'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'username': username,
    'display_name': displayName,
    'balance': balance,
    'is_active': isActive,
  };
}

/// 登录 / 刷新接口返回的完整数据。
class AppAccountData {
  const AppAccountData({
    required this.siteName,
    required this.account,
    required this.subscriptions,
    this.primary,
  });

  final String siteName;
  final AppAccount account;
  final List<AppSubscription> subscriptions;
  final AppSubscription? primary;

  static AppAccountData fromJson(Map<String, dynamic> json) {
    final rawAccount = json['account'];
    final rawSubs = json['subscriptions'];
    final subscriptions = <AppSubscription>[];
    if (rawSubs is List) {
      for (final item in rawSubs) {
        if (item is Map) {
          subscriptions.add(
            AppSubscription.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final rawPrimary = json['primary'];
    return AppAccountData(
      siteName: json['site_name']?.toString() ?? '',
      account: rawAccount is Map
          ? AppAccount.fromJson(Map<String, dynamic>.from(rawAccount))
          : const AppAccount(
              id: 0,
              email: '',
              username: '',
              displayName: '',
              balance: 0,
              isActive: false,
            ),
      subscriptions: subscriptions,
      primary: rawPrimary is Map
          ? AppSubscription.fromJson(Map<String, dynamic>.from(rawPrimary))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'site_name': siteName,
    'account': account.toJson(),
    'subscriptions': [
      for (final item in subscriptions)
        {
          'id': item.id,
          'plan_name': item.planName,
          'expires_on': item.expiresOn,
          'days_left': item.daysLeft,
          'expired': item.expired,
          'sub_url': item.subUrl,
          'traffic': item.traffic == null
              ? null
              : {
                  'upload': item.traffic!.upload,
                  'download': item.traffic!.download,
                  'used': item.traffic!.used,
                  'total': item.traffic!.total,
                },
        },
    ],
    'primary': primary == null
        ? null
        : {
            'id': primary!.id,
            'plan_name': primary!.planName,
            'expires_on': primary!.expiresOn,
            'days_left': primary!.daysLeft,
            'expired': primary!.expired,
            'sub_url': primary!.subUrl,
            'traffic': primary!.traffic == null
                ? null
                : {
                    'upload': primary!.traffic!.upload,
                    'download': primary!.traffic!.download,
                    'used': primary!.traffic!.used,
                    'total': primary!.traffic!.total,
                  },
          },
  };
}

/// 可购买套餐（服务端 /api/app/shop 返回）。
class AppPlan {
  const AppPlan({
    required this.id,
    required this.name,
    required this.price,
    required this.months,
    required this.description,
    this.features = const <String>[],
    this.tierLabel = '',
  });

  final int id;
  final String name;
  final double price;
  final int months;
  final String description;

  /// 服务端从套餐富文本解析出的逐条要点（流量、设备数、节点等）。
  final List<String> features;

  /// 线路等级标签：普通线路 / 高级线路 / 专线 / 定制。
  final String tierLabel;

  /// 服务端用 months<=0 表示永久套餐。
  String get periodText {
    if (months <= 0) {
      return '永久';
    }
    if (months % 12 == 0) {
      return '${months ~/ 12} 年';
    }
    return '$months 个月';
  }

  /// 折合每月价格，用于长期套餐的性价比提示。
  String get monthlyHint {
    if (months <= 1 || price <= 0) {
      return '';
    }
    final per = price / months;
    return '折合 ¥${per.toStringAsFixed(per >= 10 ? 1 : 2)}/月';
  }

  /// 站点套餐详情是富文本，这里剥离标签供列表展示。
  String get summary {
    final text = description
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.isEmpty ? '下单后由管理员确认收款并自动分配订阅' : text;
  }

  /// 列表展示用的要点：优先用服务端解析结果，回退到摘要文本。
  List<String> get bullets {
    if (features.isNotEmpty) {
      return features;
    }
    return <String>[summary];
  }

  static AppPlan fromJson(Map<String, dynamic> json) {
    final features = <String>[];
    final rawFeatures = json['features'];
    if (rawFeatures is List) {
      for (final item in rawFeatures) {
        final text = item?.toString().trim() ?? '';
        if (text.isNotEmpty) {
          features.add(text);
        }
      }
    }
    return AppPlan(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      price: (json['price'] as num?)?.toDouble() ?? 0,
      months: (json['months'] as num?)?.toInt() ?? 0,
      description: json['description']?.toString() ?? '',
      features: features,
      tierLabel: json['tier_label']?.toString() ?? '',
    );
  }
}

/// App 内订单（支付宝口令支付）。
class AppOrder {
  const AppOrder({
    required this.id,
    required this.planName,
    required this.amount,
    required this.status,
    required this.statusLabel,
    required this.alipayCode,
    required this.createdAt,
    required this.canClaim,
  });

  final int id;
  final String planName;
  final double amount;
  final String status;
  final String statusLabel;
  final String alipayCode;
  final String createdAt;
  final bool canClaim;

  bool get approved => status == 'approved';

  /// 已下单但还没粘贴口令。
  bool get waitingCode => status == 'pending' && alipayCode.isEmpty;

  /// 已粘贴口令，等待管理员确认收款。
  bool get waitingReview => status == 'pending' && alipayCode.isNotEmpty;

  static AppOrder fromJson(Map<String, dynamic> json) {
    return AppOrder(
      id: (json['id'] as num?)?.toInt() ?? 0,
      planName: json['plan_name']?.toString() ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      status: json['status']?.toString() ?? '',
      statusLabel: json['status_label']?.toString() ?? '',
      alipayCode: json['alipay_code']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
      canClaim: json['can_claim'] == true,
    );
  }
}

/// 套餐中心聚合数据：套餐、订单、站点付款说明与余额。
class AppShopData {
  const AppShopData({
    required this.plans,
    required this.orders,
    required this.payGuide,
    required this.balance,
    required this.codeLimit,
  });

  final List<AppPlan> plans;
  final List<AppOrder> orders;
  final String payGuide;
  final double balance;
  final int codeLimit;

  static AppShopData fromJson(Map<String, dynamic> json) {
    final plans = <AppPlan>[];
    final rawPlans = json['plans'];
    if (rawPlans is List) {
      for (final item in rawPlans) {
        if (item is Map) {
          plans.add(AppPlan.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final orders = <AppOrder>[];
    final rawOrders = json['orders'];
    if (rawOrders is List) {
      for (final item in rawOrders) {
        if (item is Map) {
          orders.add(AppOrder.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return AppShopData(
      plans: plans,
      orders: orders,
      payGuide: json['pay_guide']?.toString() ?? '',
      balance: (json['balance'] as num?)?.toDouble() ?? 0,
      codeLimit: (json['code_limit'] as num?)?.toInt() ?? 180,
    );
  }
}

class AppApiException implements Exception {
  AppApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 余额支付下单失败：余额不足时带上缺口金额，便于引导去充值。
class AppPurchaseException extends AppApiException {
  AppPurchaseException(
    super.message, {
    this.shortfall = 0,
    this.needRecharge = false,
  });

  final double shortfall;
  final bool needRecharge;
}

/// App 内充值申请（支付宝口令红包）。
class AppRecharge {
  const AppRecharge({
    required this.id,
    required this.amount,
    required this.status,
    required this.statusLabel,
    required this.createdAt,
    this.note = '',
  });

  final int id;
  final double amount;
  final String status;
  final String statusLabel;
  final String createdAt;

  /// 处理备注：待确认说明 / 管理员拒绝原因 / 确认到账金额。
  final String note;

  bool get pending => status == 'pending';

  bool get approved => status == 'approved';

  bool get rejected => status == 'rejected';

  static AppRecharge fromJson(Map<String, dynamic> json) {
    return AppRecharge(
      id: (json['id'] as num?)?.toInt() ?? 0,
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      status: json['status']?.toString() ?? '',
      statusLabel: json['status_label']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
    );
  }
}

/// 钱包数据：账户余额、充值记录与站点充值说明。
class AppWallet {
  const AppWallet({
    required this.balance,
    required this.recharges,
    required this.guide,
  });

  final double balance;
  final List<AppRecharge> recharges;
  final String guide;

  static AppWallet fromJson(Map<String, dynamic> json) {
    final recharges = <AppRecharge>[];
    final raw = json['recharges'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          recharges.add(AppRecharge.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return AppWallet(
      balance: (json['balance'] as num?)?.toDouble() ?? 0,
      recharges: recharges,
      guide: json['guide']?.toString() ?? '',
    );
  }
}

/// 余额支付购买结果。
class AppPurchaseResult {
  const AppPurchaseResult({
    required this.order,
    required this.balance,
    required this.message,
    required this.expiresOn,
  });

  final AppOrder order;
  final double balance;
  final String message;
  final String expiresOn;
}

/// 客户端登录态与账号数据管理。
class AppAuth extends ChangeNotifier {
  AppAuth._();

  static final AppAuth instance = AppAuth._();

  static const String defaultBaseUrl = 'https://s.553786.xyz';
  static const String _kToken = 'app_client_token';
  static const String _kTicket = 'app_client_ticket';
  static const String _kBase = 'app_client_base';
  static const String _kAccount = 'app_client_account';

  String _baseUrl = defaultBaseUrl;
  String? _token;
  String? _ticket;
  AppAccountData? _account;
  bool _restored = false;

  String get baseUrl => _baseUrl;

  String? get token => _token;

  String? get ticket => _ticket;

  AppAccountData? get account => _account;

  AppSubscription? get subscription => _account?.primary;

  bool get loggedIn => (_token?.isNotEmpty ?? false) && _account != null;

  bool get restored => _restored;

  /// 续费/管理页地址：带短效 ticket，打开即为已登录状态。
  String? get renewalUrl {
    if ((_ticket?.isEmpty ?? true)) {
      return null;
    }
    return '$_baseUrl/app/auto-login?ticket=$_ticket&next=/dashboard';
  }

  /// 购买套餐页地址：带短效 ticket 免密进入站点套餐列表。
  String? get purchaseUrl {
    if ((_ticket?.isEmpty ?? true)) {
      return null;
    }
    return '$_baseUrl/app/auto-login?ticket=$_ticket&next=/plans';
  }

  Dio _dio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        headers: {'Accept': 'application/json'},
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    // 每个请求都带上设备身份，供服务端做「套餐同时在线设备数」限制与
    // 会话心跳（服务端按 last_seen 判断设备是否仍占名额）。
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            final device = await DeviceIdentity.load();
            options.headers['X-Device-Id'] = device.id;
            options.headers['X-Device-Platform'] = device.platform;
            options.headers['X-Device-Name'] = device.name;
          } catch (_) {
            // 取不到设备信息时不阻塞业务请求，由服务端按老客户端放行。
          }
          handler.next(options);
        },
      ),
    );
    // 站点接口固定直连：App 内的 HttpClient 全局被 HttpOverrides 接管，
    // 代理运行时会把请求塞进本机 mixedPort；一旦节点失效，登录也会被拖死。
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        client.findProxy = (_) => 'DIRECT';
        return client;
      },
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          final retriable =
              error.type == DioExceptionType.connectionError ||
              error.type == DioExceptionType.connectionTimeout;
          final retried = error.requestOptions.extra['appRetried'] == true;
          if (retriable && !retried) {
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            try {
              final options = error.requestOptions;
              options.extra['appRetried'] = true;
              final response = await dio.fetch<dynamic>(options);
              handler.resolve(response);
              return;
            } catch (_) {
              // 保留原始错误，交给调用方展示
            }
          }
          handler.next(error);
        },
      ),
    );
    return dio;
  }

  Future<void> restore() async {
    if (_restored) {
      return;
    }
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final base = prefs?.getString(_kBase);
      if (base != null && base.trim().isNotEmpty) {
        final normalized = _normalizeBase(base);
        // 旧服务器已退役：老用户本地存的旧地址自动切到新默认地址，
        // 避免升级后仍指向连不通的 IP。
        if (normalized.contains('39.109.58.56')) {
          _baseUrl = defaultBaseUrl;
          await prefs?.setString(_kBase, defaultBaseUrl);
        } else {
          _baseUrl = normalized;
        }
      }
      _token = prefs?.getString(_kToken);
      _ticket = prefs?.getString(_kTicket);
      final raw = prefs?.getString(_kAccount);
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          _account = AppAccountData.fromJson(
            Map<String, dynamic>.from(decoded),
          );
        }
      }
    } catch (e) {
      commonPrint.debug('AppAuth restore failed: $e');
    }
    _restored = true;
    notifyListeners();
  }

  Future<void> setBaseUrl(String value) async {
    final normalized = _normalizeBase(value);
    if (normalized == _baseUrl) {
      return;
    }
    _baseUrl = normalized;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setString(_kBase, normalized);
    notifyListeners();
  }

  /// 逐层诊断：DNS 解析 → TCP 连接 → HTTPS 接口，便于定位连不上的原因。
  Future<List<String>> diagnose() async {
    final lines = <String>[];
    final uri = Uri.tryParse(_baseUrl);
    final host = uri?.host ?? '';
    final scheme = uri?.scheme ?? 'https';
    final port = uri?.port ?? (scheme == 'https' ? 443 : 80);
    lines.add('服务器：$_baseUrl');
    if (host.isEmpty) {
      lines.add('地址解析：失败，服务器地址格式不正确');
      return lines;
    }
    final stopwatch = Stopwatch()..start();
    var dnsOk = false;
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 6));
      final list = addresses.map((e) => e.address).toSet().join(', ');
      lines.add('DNS 解析：正常（$list，${stopwatch.elapsedMilliseconds}ms）');
      dnsOk = true;
    } catch (e) {
      lines.add('DNS 解析：失败（$e）');
    }
    stopwatch
      ..reset()
      ..start();
    if (dnsOk) {
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 6),
        );
        socket.destroy();
        lines.add('TCP $port：可连接（${stopwatch.elapsedMilliseconds}ms）');
      } catch (e) {
        lines.add('TCP $port：失败（$e）');
      }
    }
    try {
      final response = await _dio().get<dynamic>('/api/app/health');
      lines.add('HTTPS 接口：HTTP ${response.statusCode}');
    } on DioException catch (e) {
      lines.add('HTTPS 接口：失败（${_dioMessage(e)}）');
    }
    return lines;
  }

  /// 探测服务器是否可用，返回站点名称。
  Future<String?> health() async {
    try {
      final response = await _dio().get<dynamic>('/api/app/health');
      final body = response.data;
      if (body is Map && body['ok'] == true) {
        return body['site']?.toString() ?? '';
      }
    } catch (_) {
      // 探测失败不阻塞登录流程。
    }
    return null;
  }

  Future<void> login({
    required String account,
    required String password,
  }) async {
    try {
      final device = await DeviceIdentity.load();
      final response = await _dio().post<dynamic>(
        '/api/app/login',
        data: {
          'email': account.trim(),
          'password': password,
          'device_id': device.id,
          'platform': device.platform,
          'device_name': device.name,
        },
      );
      final body = response.data;
      if (body is! Map) {
        throw AppApiException('服务器返回异常');
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        throw AppApiException(data['error']?.toString() ?? '登录失败');
      }
      _token = data['token']?.toString();
      _ticket = data['web_ticket']?.toString();
      _account = AppAccountData.fromJson(data);
      await _persist();
      notifyListeners();
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 发送注册验证码。返回 null 表示发送成功，否则返回错误文案。
  Future<String?> sendRegisterCode(String email) async {
    try {
      final response = await _dio().post<dynamic>(
        '/api/app/register/send-code',
        data: {'email': email.trim().toLowerCase()},
      );
      final body = response.data;
      if (body is Map && body['ok'] == true) {
        return null;
      }
      return (body is Map ? body['error']?.toString() : null) ?? '验证码发送失败';
    } on DioException catch (e) {
      return _dioMessage(e);
    }
  }

  /// App 内注册，成功后直接写入登录态并通知界面切换。
  Future<void> register({
    required String email,
    required String password,
    String code = '',
  }) async {
    try {
      final device = await DeviceIdentity.load();
      final response = await _dio().post<dynamic>(
        '/api/app/register',
        data: {
          'email': email.trim().toLowerCase(),
          'password': password,
          'code': code.trim(),
          'device_id': device.id,
          'platform': device.platform,
          'device_name': device.name,
        },
      );
      final body = response.data;
      if (body is! Map) {
        throw AppApiException('服务器返回异常');
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        throw AppApiException(data['error']?.toString() ?? '注册失败');
      }
      _token = data['token']?.toString();
      _ticket = data['web_ticket']?.toString();
      _account = AppAccountData.fromJson(data);
      await _persist();
      notifyListeners();
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 套餐中心数据：套餐列表、我的订单、付款说明与余额。
  Future<AppShopData> fetchShop() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw AppApiException('登录已失效，请重新登录');
    }
    try {
      final response = await _dio().get<dynamic>(
        '/api/app/shop',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map) {
        throw AppApiException('服务器返回数据异常');
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        throw AppApiException(data['error']?.toString() ?? '加载失败，请稍后重试');
      }
      return AppShopData.fromJson(data);
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 钱包数据：账户余额、充值记录与站点充值说明。
  Future<AppWallet> fetchWallet() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw AppApiException('登录已失效，请重新登录');
    }
    try {
      final response = await _dio().get<dynamic>(
        '/api/app/wallet',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map) {
        throw AppApiException('服务器返回数据异常');
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        throw AppApiException(data['error']?.toString() ?? '加载失败，请稍后重试');
      }
      return AppWallet.fromJson(data);
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 提交支付宝口令红包密码：服务端建待确认充值单并邮件提醒管理员。
  Future<AppRecharge> submitRecharge(String alipayCode) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw AppApiException('登录已失效，请重新登录');
    }
    try {
      final response = await _dio().post<dynamic>(
        '/api/app/recharge',
        data: {'alipay_code': alipayCode},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map) {
        throw AppApiException('服务器返回数据异常');
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        throw AppApiException(data['error']?.toString() ?? '提交失败，请稍后重试');
      }
      final raw = data['recharge'];
      return raw is Map
          ? AppRecharge.fromJson(Map<String, dynamic>.from(raw))
          : const AppRecharge(
              id: 0,
              amount: 0,
              status: 'pending',
              statusLabel: '待确认到账',
              createdAt: '',
            );
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 余额支付购买套餐：服务端扣余额、建链并自动开通订阅。
  Future<AppPurchaseResult> purchaseWithBalance(int planId) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw AppApiException('登录已失效，请重新登录');
    }
    try {
      final response = await _dio().post<dynamic>(
        '/api/app/purchase',
        data: {'plan_id': planId},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map) {
        throw AppApiException('服务器返回数据异常');
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        throw AppPurchaseException(
          data['error']?.toString() ?? '下单失败，请稍后重试',
          shortfall: (data['shortfall'] as num?)?.toDouble() ?? 0,
          needRecharge: data['need_recharge'] == true,
        );
      }
      final rawOrder = data['order'];
      return AppPurchaseResult(
        order: rawOrder is Map
            ? AppOrder.fromJson(Map<String, dynamic>.from(rawOrder))
            : const AppOrder(
                id: 0,
                planName: '',
                amount: 0,
                status: 'approved',
                statusLabel: '已开通',
                alipayCode: '',
                createdAt: '',
                canClaim: false,
              ),
        balance: (data['balance'] as num?)?.toDouble() ?? 0,
        message: data['message']?.toString() ?? '购买成功，订阅已开通',
        expiresOn: data['expires_on']?.toString() ?? '',
      );
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 创建支付宝口令订单；[alipayCode] 为空表示先建单、稍后再补口令。
  Future<AppOrder> submitOrder({required int planId, String alipayCode = ''}) {
    return _shopOrder('/api/app/orders', {
      'plan_id': planId,
      'alipay_code': alipayCode,
    });
  }

  /// 给已有待确认订单补交支付宝口令，提交后立即提醒管理员。
  Future<AppOrder> claimOrder({
    required int orderId,
    required String alipayCode,
  }) {
    return _shopOrder('/api/app/orders/$orderId/claim', {
      'alipay_code': alipayCode,
    });
  }

  Future<AppOrder> _shopOrder(String path, Map<String, dynamic> payload) async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw AppApiException('登录已失效，请重新登录');
    }
    try {
      final response = await _dio().post<dynamic>(
        path,
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is Map && body['ok'] == true && body['order'] is Map) {
        return AppOrder.fromJson(
          Map<String, dynamic>.from(body['order'] as Map),
        );
      }
      final message = body is Map ? body['error']?.toString() : null;
      throw AppApiException(message ?? '提交失败，请稍后重试');
    } on DioException catch (e) {
      throw AppApiException(_dioMessage(e));
    }
  }

  /// 刷新账号数据。返回 false 表示登录态已失效。
  Future<bool> refresh() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      return false;
    }
    try {
      final response = await _dio().get<dynamic>(
        '/api/app/profile',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      // 请求飞行期间用户可能已退出登录或切换账号：旧响应必须丢弃，
      // 否则会把已经清掉的登录态重新写回，表现为“退出登录退不出来”。
      if (_token != token) {
        return false;
      }
      if (response.statusCode == 401) {
        return false;
      }
      final body = response.data;
      if (body is! Map) {
        return true;
      }
      final data = Map<String, dynamic>.from(body);
      if (data['ok'] != true) {
        return true;
      }
      _account = AppAccountData.fromJson(data);
      final ticket = data['web_ticket']?.toString();
      if (ticket != null && ticket.isNotEmpty) {
        _ticket = ticket;
      }
      if (_token != token) {
        return false;
      }
      await _persist();
      if (_token != token) {
        return false;
      }
      notifyListeners();
      return true;
    } on DioException {
      // 网络异常不代表登录失效，保留本地登录态。
      return true;
    }
  }

  /// 仅供测试：直接注入内存登录态，避免依赖本地存储初始化。
  void debugLoad({
    String token = 'debug-token',
    String ticket = 'debug-ticket',
    Map<String, dynamic>? accountJson,
  }) {
    _token = token;
    _ticket = ticket;
    _account = accountJson == null
        ? null
        : AppAccountData.fromJson(accountJson);
    _restored = true;
    notifyListeners();
  }

  Future<void> logout() async {
    // 先通知服务端释放本机占用的设备名额；失败不阻塞本地退出。
    final token = _token;
    if (token != null && token.isNotEmpty) {
      unawaited(_releaseServerSession(token));
    }
    // 先清内存登录态并立即通知界面切回登录页，
    // 避免本地存储 IO 异常或卡顿导致界面停留在首页退不出去。
    _token = null;
    _ticket = null;
    _account = null;
    notifyListeners();

    try {
      final prefs = await preferences.sharedPreferencesCompleter.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      if (prefs == null) {
        return;
      }
      for (final key in const [_kToken, _kTicket, _kAccount]) {
        try {
          await prefs.remove(key).timeout(const Duration(seconds: 2));
        } catch (e) {
          commonPrint.warn('AppAuth logout remove $key failed: $e');
        }
      }
    } catch (e) {
      commonPrint.warn('AppAuth logout persist failed: $e');
    }
  }

  /// 服务端退出：释放本设备的在线名额。失败只记日志，不影响本地退出。
  Future<void> _releaseServerSession(String token) async {
    try {
      final device = await DeviceIdentity.load();
      await _dio().post<dynamic>(
        '/api/app/logout',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'X-Device-Id': device.id,
            'X-Device-Platform': device.platform,
            'X-Device-Name': device.name,
          },
        ),
      ).timeout(const Duration(seconds: 6));
    } catch (e) {
      commonPrint.warn('AppAuth server logout failed: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (prefs == null) {
      return;
    }
    await prefs.setString(_kBase, _baseUrl);
    if (_token != null) {
      await prefs.setString(_kToken, _token!);
    }
    if (_ticket != null) {
      await prefs.setString(_kTicket, _ticket!);
    }
    if (_account != null) {
      await prefs.setString(_kAccount, json.encode(_account!.toJson()));
    }
  }

  static String _normalizeBase(String value) {
    var base = value.trim();
    if (base.isEmpty) {
      return defaultBaseUrl;
    }
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      // 未写协议时按 https 处理：Android 9+ 默认拦截明文请求，
      // 补 http:// 会直接表现为“无法连接服务器”。
      base = 'https://$base';
    }
    if (base.startsWith('http://')) {
      final host = Uri.tryParse(base)?.host ?? '';
      if (host == 's.553786.xyz' || host == '553786.xyz') {
        base = 'https://${base.substring(7)}';
      }
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  String _dioMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接服务器超时，请检查网络或服务器地址（$_baseUrl）';
      case DioExceptionType.connectionError:
        final raw = '${e.error ?? ''}';
        if (raw.contains('Failed host lookup') ||
            raw.contains('nodename nor servname')) {
          return '域名解析失败，请检查手机网络或 DNS 设置';
        }
        if (raw.contains('HandshakeException') ||
            raw.contains('CERTIFICATE_VERIFY_FAILED')) {
          return '证书校验失败，请检查手机系统时间是否正确';
        }
        if (raw.contains('Connection refused')) {
          return '服务器拒绝连接，请检查服务器地址（$_baseUrl）';
        }
        return '无法连接服务器，请检查网络或服务器地址（$_baseUrl）';
      case DioExceptionType.badResponse:
        final data = e.response?.data;
        if (data is Map && data['error'] != null) {
          return data['error'].toString();
        }
        return '服务器返回错误（${e.response?.statusCode ?? '未知'}）';
      default:
        return '网络异常，请稍后重试';
    }
  }
}

/// 字节数转可读文本。
String appFormatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final text = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[index]}';
}

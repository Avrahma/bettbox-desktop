import 'dart:async';
import 'dart:convert';

import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/print.dart';
import 'package:dio/dio.dart';
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

class AppApiException implements Exception {
  AppApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 客户端登录态与账号数据管理。
class AppAuth extends ChangeNotifier {
  AppAuth._();

  static final AppAuth instance = AppAuth._();

  static const String defaultBaseUrl = 'http://39.109.58.56:9563';
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
    return Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        headers: {'Accept': 'application/json'},
        validateStatus: (status) => status != null && status < 500,
      ),
    );
  }

  Future<void> restore() async {
    if (_restored) {
      return;
    }
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final base = prefs?.getString(_kBase);
      if (base != null && base.trim().isNotEmpty) {
        _baseUrl = _normalizeBase(base);
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
      final response = await _dio().post<dynamic>(
        '/api/app/login',
        data: {'email': account.trim(), 'password': password},
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
      final response = await _dio().post<dynamic>(
        '/api/app/register',
        data: {
          'email': email.trim().toLowerCase(),
          'password': password,
          'code': code.trim(),
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

  /// 刷新账号数据。返回 false 表示登录态已失效。
  Future<bool> refresh() async {
    if ((_token?.isEmpty ?? true)) {
      return false;
    }
    try {
      final response = await _dio().get<dynamic>(
        '/api/app/profile',
        options: Options(headers: {'Authorization': 'Bearer $_token'}),
      );
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
      await _persist();
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
    _token = null;
    _ticket = null;
    _account = null;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.remove(_kToken);
    await prefs?.remove(_kTicket);
    await prefs?.remove(_kAccount);
    notifyListeners();
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
      base = 'http://$base';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  static String _dioMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接服务器超时，请检查网络或服务器地址';
      case DioExceptionType.connectionError:
        return '无法连接服务器，请检查服务器地址';
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

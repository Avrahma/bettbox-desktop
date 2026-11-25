import 'dart:async';

import 'package:bett_box/common/app_visibility.dart';
import 'package:material_ui/material_ui.dart';

import '../../common/app_api.dart';
import 'register.dart';
import 'package:bett_box/state.dart';

/// 机场账号登录页，作为应用首屏。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _obscure = true;
  bool _loading = false;
  String? _error;
  bool _diagnosing = false;
  String _siteName = '';

  @override
  void initState() {
    super.initState();
    unawaited(_probeServer());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showDisclaimer());
    });
    final account = AppAuth.instance.account?.account.email ?? '';
    if (account.isNotEmpty) {
      _accountController.text = account;
    }
    // 被其他设备顶下线时，登录页给出明确原因。
    final notice = AppAuth.instance.consumeLoginNotice();
    if (notice.isNotEmpty) {
      _error = notice;
    }
  }

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// 安装后首次打开、以及退出登录后回到本页时，都先显示免责声明。
  /// 必须输入「我同意」才能继续，不同意则退出应用。
  Future<void> _showDisclaimer() async {
    if (!mounted) {
      return;
    }
    final accepted = await globalState.appController.showDisclaimer();
    if (!accepted && mounted) {
      await globalState.appController.handleExit();
    }
  }

  Future<void> _probeServer() async {
    final site = await AppAuth.instance.health();
    if (!mounted || site == null || site.isEmpty) {
      return;
    }
    setState(() => _siteName = site);
  }

  Future<void> _submit() async {
    if (_loading) {
      return;
    }
    final account = _accountController.text.trim();
    final password = _passwordController.text;
    if (account.isEmpty) {
      setState(() => _error = '请输入账号');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AppAuth.instance.login(account: account, password: password);
      if (!mounted) {
        return;
      }
      FocusScope.of(context).unfocus();
      setState(() => _loading = false);
    } on AppDeviceLimitException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = null;
      });
      final proceed = await _confirmKickOthers(e);
      if (!mounted || !proceed) {
        return;
      }
      setState(() {
        _loading = true;
        _error = null;
      });
      await _loginForce(account: account, password: password);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 强制退出其他设备后重新登录。
  Future<void> _loginForce({
    required String account,
    required String password,
  }) async {
    try {
      await AppAuth.instance.login(
        account: account,
        password: password,
        forceDevice: true,
      );
      if (!mounted) {
        return;
      }
      FocusScope.of(context).unfocus();
      setState(() => _loading = false);
    } on AppApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 设备数超限确认框：说明套餐名称、限制台数与在线设备，提供强制退出选项。
  Future<bool> _confirmKickOthers(AppDeviceLimitException error) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final limitText = error.limit > 0 ? '${error.limit}' : '当前套餐';
        final planText = error.planName.trim().isEmpty
            ? ''
            : '「${error.planName.trim()}」';
        return AlertDialog(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.devices_other_outlined),
              SizedBox(width: 8),
              Text('设备数量已达上限'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                error.message.trim().isEmpty
                    ? '你的$planText套餐最多允许 $limitText 台设备同时在线。'
                    : error.message,
                style: const TextStyle(height: 1.5),
              ),
              if (error.devices.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  '当前在线设备',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                ...error.devices.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.smartphone, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.label,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '继续登录将强制退出以上其他设备，该操作会断开对方客户端的登录状态。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(dialogContext).colorScheme.error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: error.canForce
                  ? () => Navigator.of(dialogContext).pop(true)
                  : null,
              child: const Text('强制退出并登录'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<void> _runDiagnose() async {
    if (_diagnosing) {
      return;
    }
    setState(() => _diagnosing = true);
    final lines = await AppAuth.instance.diagnose();
    if (!mounted) {
      return;
    }
    setState(() => _diagnosing = false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('网络诊断'),
        content: SelectableText(lines.join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _editServer() async {
    final controller = TextEditingController(
      text: AppAuth.instance.baseUrl,
    );
    // 隐藏入口：标题连点 3 次进入网络诊断，普通用户不会触发。
    var titleTaps = 0;
    var lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final now = DateTime.now();
              if (now.difference(lastTapAt) >
                  const Duration(milliseconds: 700)) {
                titleTaps = 0;
              }
              lastTapAt = now;
              titleTaps += 1;
              if (titleTaps >= 3) {
                titleTaps = 0;
                Navigator.of(dialogContext).pop();
                Future<void>.delayed(const Duration(milliseconds: 200), () {
                  if (mounted) {
                    unawaited(_runDiagnose());
                  }
                });
              }
            },
            child: const Text('服务器地址'),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'https://域名',
              helperText: '更换公网 IP 或端口时在此修改',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result == null || result.isEmpty) {
      return;
    }
    await AppAuth.instance.setBaseUrl(result);
    if (!mounted) {
      return;
    }
    setState(() {
      _siteName = '';
      _error = null;
    });
    unawaited(_probeServer());
  }

  Future<void> _openRegister() async {
    setState(() => _error = null);
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RegisterPage()),
    );
    if (!mounted) {
      return;
    }
    final account = AppAuth.instance.account?.account.email ?? '';
    if (account.isNotEmpty) {
      _accountController.text = account;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppVisibility.instance, AppAuth.instance]),
      builder: (context, _) => _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final title = _siteName.isNotEmpty
        ? _siteName
        : (AppAuth.instance.account?.siteName ?? '账户登录');

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: AppVisibility.instance.tapLoginTitle,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '让每一次连接都简单、稳定',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _accountController,
                    enabled: !_loading,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: '账号',
                      hintText: '邮箱或用户名',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _passwordFocus.requestFocus(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    enabled: !_loading,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: '密码',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                    onSubmitted: (_) => unawaited(_submit()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 18,
                            color: colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _loading ? null : () => unawaited(_submit()),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('登录'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '还没有账号？',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      TextButton(
                        onPressed: _loading
                            ? null
                            : () => unawaited(_openRegister()),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 34),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('注册新账号'),
                      ),
                    ],
                  ),
                  if (AppVisibility.instance.serverAddressVisible) ...[
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () => unawaited(_editServer()),
                      child: Text(
                        '服务器：${AppAuth.instance.baseUrl}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

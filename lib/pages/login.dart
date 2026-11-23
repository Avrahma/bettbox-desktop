import 'dart:async';

import 'package:bett_box/common/app_visibility.dart';
import 'package:bett_box/common/common.dart';
import 'package:material_ui/material_ui.dart';

import '../../common/app_api.dart';
import 'register.dart';

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
  String _siteName = '';

  @override
  void initState() {
    super.initState();
    unawaited(_probeServer());
    final account = AppAuth.instance.account?.account.email ?? '';
    if (account.isNotEmpty) {
      _accountController.text = account;
    }
  }

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
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

  Future<void> _editServer() async {
    final controller = TextEditingController(
      text: AppAuth.instance.baseUrl,
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('服务器地址'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'http://ip:port',
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
                    '登录后自动导入订阅',
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

import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:material_ui/material_ui.dart';

/// App 内注册页：邮箱 + 密码 + 邮箱验证码，注册成功自动登录。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  bool _sending = false;
  String? _error;
  String? _info;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool _isEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _countdown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _countdown -= 1;
        if (_countdown <= 0) {
          timer.cancel();
        }
      });
    });
  }

  Future<void> _sendCode() async {
    if (_sending || _countdown > 0) {
      return;
    }
    final email = _emailController.text.trim();
    if (!_isEmail(email)) {
      setState(() {
        _error = '请输入有效的邮箱地址';
        _info = null;
      });
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
    });
    final error = await AppAuth.instance.sendRegisterCode(email);
    if (!mounted) {
      return;
    }
    setState(() {
      _sending = false;
      if (error == null) {
        _info = '验证码已发送，请查收邮箱';
      } else {
        _error = error;
      }
    });
    if (error == null) {
      _startCountdown();
    }
  }

  Future<void> _submit() async {
    if (_loading) {
      return;
    }
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final code = _codeController.text.trim();
    if (!_isEmail(email)) {
      setState(() => _error = '请输入有效的邮箱地址');
      return;
    }
    if (password.length < 9) {
      setState(() => _error = '密码至少需要 9 位');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await AppAuth.instance.register(
        email: email,
        password: password,
        code: code,
      );
      if (!mounted) {
        return;
      }
      FocusScope.of(context).unfocus();
      Navigator.of(context).pop(true);
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

  Widget _notice(bool isError) {
    final colorScheme = Theme.of(context).colorScheme;
    final text = isError ? _error : _info;
    if (text == null || text.isEmpty) {
      return const SizedBox.shrink();
    }
    final bg = isError ? colorScheme.errorContainer : colorScheme.primaryContainer;
    final fg = isError ? colorScheme.onErrorContainer : colorScheme.onPrimaryContainer;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: fg,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('注册账号')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '创建账号',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '注册成功后自动登录并导入订阅',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _emailController,
                    enabled: !_loading,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: '邮箱',
                      hintText: 'name@example.com',
                      prefixIcon: Icon(Icons.mail_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    enabled: !_loading,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: '密码',
                      hintText: '至少 9 位',
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
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _codeController,
                          enabled: !_loading,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: '邮箱验证码',
                            hintText: '6 位数字',
                            counterText: '',
                            prefixIcon: Icon(Icons.verified_outlined),
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => unawaited(_submit()),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 56,
                        child: OutlinedButton(
                          onPressed: (_sending || _countdown > 0 || _loading)
                              ? null
                              : () => unawaited(_sendCode()),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          child: Text(
                            _sending
                                ? '发送中'
                                : _countdown > 0
                                ? '${_countdown}s'
                                : '获取验证码',
                          ),
                        ),
                      ),
                    ],
                  ),
                  _notice(true),
                  _notice(false),
                  const SizedBox(height: 22),
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
                          : const Text('注册并登录'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('已有账号，返回登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

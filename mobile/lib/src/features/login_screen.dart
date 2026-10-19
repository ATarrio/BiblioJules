import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n.dart';
import '../core/providers.dart';
import '../local/library_files.dart';
import '../theme.dart';
import '../widgets/feedback.dart';
import '../widgets/l10n_scope.dart';

/// Sign-in — or, just as valid, "keep the library on this phone".
///
/// Against a server the app needs its address plus an account on it. Local mode
/// needs neither: it is one SQLite file the phone owns, so anyone can start
/// using the app without hosting anything.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final TextEditingController _server;
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(prefsProvider);
    final session = ref.read(sessionProvider);
    _server = TextEditingController(
      text: session.baseUrl.isNotEmpty ? session.baseUrl : (prefs.baseUrl ?? ''),
    );
    _username = TextEditingController(text: prefs.username ?? '');
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(sessionProvider.notifier)
        .signIn(
          baseUrl: _server.text,
          username: _username.text.trim(),
          password: _password.text,
        );
  }

  /// Start (or reopen) a catalogue that lives on this device alone.
  Future<void> _useLocalLibrary(L10n l10n) async {
    FocusScope.of(context).unfocus();
    final name = await promptForText(
      context,
      title: l10n.tr('Library on this phone'),
      message: l10n.tr(
        'Name your library. The name also becomes its file name when you export it.',
      ),
      initial: ref.read(prefsProvider).localLibraryName ?? kDefaultLibraryName,
      label: l10n.tr('Library name'),
      icon: Icons.local_library_outlined,
      confirmLabel: l10n.tr('Use this library'),
    );
    if (name == null) return;
    await ref.read(sessionProvider.notifier).useLocalLibrary(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.localized;
    final session = ref.watch(sessionProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _brand(context, l10n),
                  const SizedBox(height: 32),
                  if (session.notice != null) ...[
                    _banner(
                      context,
                      icon: Icons.info_outline,
                      color: kAmber,
                      message: l10n.tr(session.notice!),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (session.error != null) ...[
                    _banner(
                      context,
                      icon: Icons.error_outline,
                      color: kRed,
                      message: l10n.tr(session.error!),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.tr('Backend URL'),
                      hintText: 'https://library.example.com',
                      prefixIcon: const Icon(Icons.dns_outlined),
                      helperText: l10n.tr('On the Android emulator, use http://10.0.2.2:8000'),
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _username,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: l10n.tr('Username'),
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => session.busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: l10n.tr('Password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                        tooltip: l10n.tr(_obscure ? 'Show password' : 'Hide password'),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: session.busy ? null : _submit,
                    child: session.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.tr('Sign in')),
                  ),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: session.busy ? null : () => _useLocalLibrary(l10n),
                    icon: const Icon(Icons.phone_android, size: 18),
                    label: Text(l10n.tr('Use a library on this phone')),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.tr(
                      'Kept on the device only. No server and no account needed.',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: kSlate500,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(child: _languagePicker(context, l10n, ref)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand(BuildContext context, L10n l10n) {
    return Column(
      children: [
        // The app mark, generated from images/logo.svg (same art as the
        // launcher icon).
        Image.asset('assets/images/logo.png', width: 76, height: 76),
        const SizedBox(height: 16),
        Text(
          kAppName,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.tr('Sign in to your library'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: kSlate400),
        ),
      ],
    );
  }

  Widget _banner(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _languagePicker(BuildContext context, L10n l10n, WidgetRef ref) {
    final current = ref.watch(languageProvider);
    final option = kSupportedLanguages.firstWhere(
      (item) => item.code == current,
      orElse: () => kSupportedLanguages.first,
    );
    return PopupMenuButton<String>(
      tooltip: l10n.tr('Language'),
      initialValue: current,
      onSelected: (code) => ref.read(languageProvider.notifier).set(code),
      itemBuilder: (context) => [
        for (final language in kSupportedLanguages)
          PopupMenuItem(
            value: language.code,
            child: Row(
              children: [
                Icon(
                  language.code == current ? Icons.check : Icons.translate,
                  size: 18,
                  color: language.code == current ? Theme.of(context).colorScheme.primary : kSlate500,
                ),
                const SizedBox(width: 10),
                Text(language.label),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 18, color: kSlate400),
            const SizedBox(width: 8),
            Text(option.label, style: const TextStyle(color: kSlate300)),
            const Icon(Icons.arrow_drop_down, color: kSlate400),
          ],
        ),
      ),
    );
  }
}

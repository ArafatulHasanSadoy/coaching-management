import 'package:flutter/material.dart';

import 'first_run_screen.dart';
import 'restore_screen.dart';

/// The very first screen. Two ways in, because a replacement phone is as common
/// a starting point as a new centre — and an owner whose phone just died should
/// not have to walk through creating a centre before discovering they can
/// restore one.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Icon(Icons.school_outlined,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 18),
                Text(
                  'Run your coaching centre',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Everything works without internet.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 36),
                _Choice(
                  icon: Icons.add_business_outlined,
                  title: 'Set up a new centre',
                  subtitle:
                      'Takes about two minutes. Classes and subjects come '
                      'pre-filled — you tick what you teach.',
                  primary: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FirstRunScreen(),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _Choice(
                  icon: Icons.settings_backup_restore,
                  title: 'Restore from a backup',
                  subtitle:
                      'Moving to a new phone, or recovering this one. You will '
                      'need the backup file and your master passphrase.',
                  primary: false,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RestoreScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.primary,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: primary ? 2 : 0,
      color: primary ? theme.colorScheme.primaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: primary
            ? BorderSide.none
            : BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(icon, size: 30, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

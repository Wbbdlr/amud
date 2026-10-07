import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/adaptive.dart';
import '../../core/l10n.dart';
import '../../core/sync/sync_service.dart';

/// Sync across devices: turn it on, link another device with the code, and
/// choose what this device shares.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool _showCode = false;

  SyncService get _sync => ref.read(syncProvider.notifier);

  void _snack(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr(message))));

  Future<void> _join() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('Enter your sync code')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ctx.tr('Find it under Settings → Sync across devices on a device that already syncs.')),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(hintText: 'XXXXX-XXXXX-XXXXX-XXXXX', border: OutlineInputBorder()),
            style: const TextStyle(fontFamily: 'monospace'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 12),
          Text(ctx.tr('Your synced data will replace this device\'s settings.'), style: Theme.of(ctx).textTheme.bodySmall),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(ctx.tr('Link'))),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.trim().isEmpty || !mounted) return;
    final error = await _sync.join(code);
    if (!mounted) return;
    _snack(error ?? 'This device now syncs.');
    // Linked during first-run setup: the person's own settings are here now.
    if (error == null && GoRouterState.of(context).uri.queryParameters.containsKey('setup')) context.go('/');
  }

  Future<void> _leave() async {
    if (!await showAdaptiveConfirm(context,
        title: context.tr('Stop syncing on this device?'),
        message: context.tr('This device keeps its settings and data. Your other devices go on syncing.'),
        confirm: 'Stop syncing')) {
      return;
    }
    _sync.leave();
  }

  Future<void> _delete() async {
    if (!await showAdaptiveConfirm(context,
        title: context.tr('Delete synced data?'),
        message: context.tr('Removes your data from the sync server and stops sync on every device. Each device keeps its own copy.'),
        confirm: 'Delete')) {
      return;
    }
    final error = await _sync.deleteEverywhere();
    if (mounted && error != null) _snack(error);
  }

  String _when(DateTime t) {
    final l = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final time = l.formatTimeOfDay(TimeOfDay.fromDateTime(t));
    return t.year == now.year && t.month == now.month && t.day == now.day ? time : '${l.formatShortDate(t)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(syncProvider);
    final theme = Theme.of(context);
    final code = s.code;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Sync across devices'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Text(
            context.tr('Keep your settings, location, alarms, dashboard, dates and fonts the same on your phone, computer and the web. '
                'There\'s no account: one code links your devices, and your data is encrypted with it before it leaves the device.'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (code == null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FilledButton.icon(
                icon: const Icon(Icons.sync),
                label: Text(context.tr('Turn on sync')),
                onPressed: s.busy ? null : _sync.create,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.link),
                label: Text(context.tr('I have a code from another device')),
                onPressed: s.busy ? null : _join,
              ),
              if (s.busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator.adaptive())),
            ]),
          ),
        ] else ...[
          AdaptiveSection(
            header: context.tr('Your sync code'),
            footer: context.tr('Enter this code on your other devices. Keep it somewhere safe, like a password manager: '
                'anyone with it can see and change your synced data, and it can\'t be recovered if every device is lost.'),
            children: [
              ListTile(
                title: SelectableText(
                  _showCode ? code : code.replaceAll(RegExp('[^-]'), '•'),
                  style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'monospace', letterSpacing: 1.5),
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: context.tr(_showCode ? 'Hide' : 'Show'),
                    icon: Icon(_showCode ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showCode = !_showCode),
                  ),
                  IconButton(
                    tooltip: context.tr('Copy'),
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      _snack('Sync code copied');
                    },
                  ),
                ]),
              ),
            ],
          ),
          AdaptiveSection(children: [
            ListTile(
              leading: s.busy
                  ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                  : Icon(s.error == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      color: s.error == null ? null : theme.colorScheme.error),
              title: Text(s.busy
                  ? context.tr('Syncing…')
                  : s.lastSynced == null
                      ? context.tr('Not synced yet')
                      : context.tr('Last synced {time}', {'time': _when(s.lastSynced!)})),
              subtitle: s.error == null ? null : Text(context.tr(s.error!), style: TextStyle(color: theme.colorScheme.error)),
              trailing: TextButton(onPressed: s.busy ? null : _sync.sync, child: Text(context.tr('Sync now'))),
            ),
          ]),
        ],
        AdaptiveSection(
          header: context.tr('What this device syncs'),
          footer: context.tr('Turn something off to keep this device\'s own version of it. Other devices still sync it among themselves.'),
          children: [
            for (final c in SyncCategory.values)
              AdaptiveSwitchTile(
                title: context.tr(c.label),
                subtitle: context.tr(c.description),
                value: s.shared.contains(c),
                onChanged: (v) => _sync.setShared(c, v),
              ),
          ],
        ),
        if (code != null)
          AdaptiveSection(children: [
            AdaptiveNavTile(icon: Icons.link_off, title: context.tr('Stop syncing on this device'), onTap: _leave),
            AdaptiveNavTile(icon: Icons.delete_outline, title: context.tr('Delete synced data'), onTap: _delete),
          ]),
      ]),
    );
  }
}

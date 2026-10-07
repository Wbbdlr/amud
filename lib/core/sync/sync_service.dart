import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../fonts.dart';
import '../providers.dart';
import 'sync_code.dart';
import 'sync_engine.dart';
import 'sync_items.dart';

export 'sync_items.dart' show SyncCategory;

/// Where the sync server is: this page's own on the web, amud.page's in
/// the apps, or `--dart-define=SYNC_SERVER=https://…/app/api/sync/`.
Uri get syncServer {
  const custom = String.fromEnvironment('SYNC_SERVER');
  if (custom.isNotEmpty) return Uri.parse(custom.endsWith('/') ? custom : '$custom/');
  return kIsWeb ? Uri.base.resolve('api/sync/') : Uri.parse('https://amud.page/app/api/sync/');
}

class SyncState {
  /// The sync code, or null while this device doesn't sync.
  final String? code;

  /// What this device shares; by default, everything.
  final Set<SyncCategory> shared;
  final DateTime? lastSynced;
  final bool busy;
  final String? error;

  const SyncState({this.code, this.shared = const {...SyncCategory.values}, this.lastSynced, this.busy = false, this.error});

  bool get enabled => code != null;

  SyncState copyWith({String? Function()? code, Set<SyncCategory>? shared, DateTime? lastSynced, bool? busy, String? Function()? error}) =>
      SyncState(
        code: code != null ? code() : this.code,
        shared: shared ?? this.shared,
        lastSynced: lastSynced ?? this.lastSynced,
        busy: busy ?? this.busy,
        error: error != null ? error() : this.error,
      );

  Map<String, Object?> toJson() => {
        'code': code,
        'shared': [for (final c in shared) c.name],
        'lastSynced': lastSynced?.millisecondsSinceEpoch,
      };

  factory SyncState.fromJson(Map<String, Object?> j) => SyncState(
        code: j['code'] as String?,
        shared: j['shared'] is List
            ? {for (final c in SyncCategory.values) if ((j['shared'] as List).contains(c.name)) c}
            : const {...SyncCategory.values},
        lastSynced: j['lastSynced'] is num ? DateTime.fromMillisecondsSinceEpoch((j['lastSynced'] as num).toInt()) : null,
      );
}

/// Keeps this device in step with the others that use the same code: at
/// launch, on returning to the app, a few seconds after a change here, and
/// every ten minutes while open.
class SyncService extends Notifier<SyncState> {
  static const _key = 'sync';
  static const _debounce = Duration(seconds: 4);

  SyncEngine? _engine;
  Timer? _soon;
  Timer? _periodic;
  Future<void>? _running;
  bool _again = false;

  @override
  SyncState build() {
    final storage = ref.read(storageProvider);
    final changes = storage.changes.listen((items) {
      if (state.enabled && items.any((i) => state.shared.contains(categoryOf(i)))) {
        _soon?.cancel();
        _soon = Timer(_debounce, sync);
      }
    });
    _periodic = Timer.periodic(const Duration(minutes: 10), (_) => sync());
    ref.onDispose(() {
      changes.cancel();
      _soon?.cancel();
      _periodic?.cancel();
    });
    return storage.readJson(_key, (j) => SyncState.fromJson((j as Map).cast<String, Object?>())) ?? const SyncState();
  }

  SyncEngine _engineFor(String code) {
    final keys = SyncKeys.fromCode(code);
    return _engine?.keys.token == keys.token ? _engine! : _engine = SyncEngine(ref.read(storageProvider), SyncApi(syncServer, keys.token), keys);
  }

  void _save(SyncState s) {
    state = s;
    ref.read(storageProvider).writeJson(_key, s.toJson());
  }

  /// Starts syncing with a new code, sharing everything here.
  Future<void> create() async {
    _save(SyncState(code: newSyncCode(), shared: state.shared));
    await sync();
  }

  /// Joins the devices that use [input]. Their data replaces this
  /// device's where both have it. Returns an error message, or null.
  Future<String?> join(String input) async {
    final code = normalizeSyncCode(input);
    if (code == null) return 'That isn\'t a valid sync code. Check it for typos.';
    state = state.copyWith(busy: true, error: () => null);
    try {
      if (!await _engineFor(code).exists()) {
        state = state.copyWith(busy: false);
        return 'Nothing is synced with this code yet. Turn on sync on your other device first.';
      }
    } catch (e) {
      state = state.copyWith(busy: false);
      return _message(e);
    }
    _save(state.copyWith(code: () => code, busy: false));
    await sync(preferRemote: true);
    return state.error;
  }

  void setShared(SyncCategory c, bool on) {
    _save(state.copyWith(shared: on ? {...state.shared, c} : ({...state.shared}..remove(c))));
    // Something newly shared is brought in from the other devices.
    if (on) sync();
  }

  /// Stops syncing here; this device keeps its data, and the others go on.
  void leave() {
    _soon?.cancel();
    _engine = null;
    _save(SyncState(shared: state.shared));
  }

  /// Deletes the synced data from the server; every device stops syncing.
  Future<String?> deleteEverywhere() async {
    final code = state.code;
    if (code == null) return null;
    try {
      await _engineFor(code).api.deleteAll();
    } catch (e) {
      return _message(e);
    }
    leave();
    return null;
  }

  /// One pass now (or right after the one that's running).
  Future<void> sync({bool preferRemote = false}) {
    if (!state.enabled) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _pass(preferRemote).whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        sync();
      }
    });
  }

  Future<void> _pass(bool preferRemote) async {
    final code = state.code!;
    state = state.copyWith(busy: true);
    try {
      final saved = await _engineFor(code).run(state.shared, preferRemote: preferRemote);
      if (state.code != code) return; // Left meanwhile.
      if (saved.isNotEmpty) {
        // Everything that reads storage reloads with the new data.
        ref.read(storageRevisionProvider.notifier).state++;
        if (saved.any((i) => categoryOf(i) == SyncCategory.fonts || i.endsWith('/hebrewFont'))) {
          unawaited(ref.read(fontsProvider.notifier).loadAll());
        }
      }
      _save(state.copyWith(busy: false, lastSynced: DateTime.now(), error: () => null));
    } catch (e) {
      state = state.copyWith(busy: false, error: () => _message(e));
    }
  }

  static String _message(Object e) => e is SyncException
      ? e.message
      : e is TimeoutException
          ? 'The sync server didn\'t answer. Changes will sync when it does.'
          : 'Couldn\'t reach the sync server. Changes will sync when you\'re online.';
}

final syncProvider = NotifierProvider<SyncService, SyncState>(SyncService.new);

import 'dart:async';
import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Thin persistence layer over Hive (IndexedDB on web, files elsewhere).
///
/// Everything is stored as JSON strings in a single key/value box so the
/// schema can evolve without Hive type adapters; binary blobs (user
/// fonts) live in their own box.
///
/// For sync (core/sync), every write also records when each *item* last
/// changed: a key, a blob, or one field of the keys in [fieldwise], so two
/// devices can change different settings without one undoing the other.
class Storage {
  Storage._(this._kv, this._blobs, this._stamps, this._changes);
  final Box<String> _kv;
  final Box<List<int>> _blobs;
  final Box<int> _stamps;
  final StreamController<Set<String>> _changes;

  /// Keys whose top-level fields sync on their own.
  static const fieldwise = {'settings', 'torahSettings'};

  static Future<Storage> open() async {
    // The folder keeps the app's original name so saved data survives the
    // rename to Amud.
    await Hive.initFlutter('flutter_siddur');
    return _open();
  }

  /// Opens the boxes in [dir] (tests, where there's no app directory).
  static Future<Storage> openAt(String dir) async {
    Hive.init(dir);
    return _open();
  }

  static Future<Storage> _open() async => Storage._(
        await Hive.openBox<String>('kv'),
        await Hive.openBox<List<int>>('blobs'),
        await Hive.openBox<int>('syncStamps'),
        StreamController<Set<String>>.broadcast(),
      );

  /// Another handle on the same data. Providers that watch storage rebuild
  /// when it's replaced by a new view (after sync brings in changes).
  Storage view() => Storage._(_kv, _blobs, _stamps, _changes);

  T? readJson<T>(String key, T Function(Object? json) decode) {
    final raw = _kv.get(key);
    if (raw == null) return null;
    try {
      return decode(jsonDecode(raw));
    } catch (_) {
      // Callers fall back to defaults and may save over this key; keep a
      // copy of what couldn't be read so it isn't lost for good.
      if (_kv.get('$key.unreadable') != raw) _kv.put('$key.unreadable', raw);
      return null;
    }
  }

  Future<void> writeJson(String key, Object? value) {
    final old = _kv.get(key);
    final raw = jsonEncode(value);
    final done = _kv.put(key, raw);
    _stampChanges(changedItems(key, old, raw));
    return done;
  }

  List<int>? readBlob(String key) => _blobs.get(key);

  Future<void> writeBlob(String key, List<int> bytes) {
    final done = _blobs.put(key, bytes);
    _stampChanges({blobItem(key)});
    return done;
  }

  Future<void> deleteBlob(String key) {
    final had = _blobs.containsKey(key);
    final done = _blobs.delete(key);
    if (had) _stampChanges({blobItem(key)});
    return done;
  }

  // ---- Sync support ----

  static String kvItem(String key, [String? field]) => field == null ? 'kv/$key' : 'kv/$key/$field';
  static String blobItem(String key) => 'blob/$key';

  /// The items changed by replacing [oldRaw] with [newRaw] under [key].
  static Set<String> changedItems(String key, String? oldRaw, String newRaw) {
    if (oldRaw == newRaw) return const {};
    if (fieldwise.contains(key)) {
      Map? decode(String? raw) {
        try {
          return raw == null ? null : jsonDecode(raw) as Map?;
        } catch (_) {
          return null;
        }
      }

      final a = decode(oldRaw) ?? const {}, b = decode(newRaw);
      if (b != null) {
        return {
          for (final f in {...a.keys, ...b.keys})
            if (a.containsKey(f) != b.containsKey(f) || jsonEncode(a[f]) != jsonEncode(b[f])) kvItem(key, '$f'),
        };
      }
    }
    return {kvItem(key)};
  }

  /// Items changed on this device, as they happen.
  Stream<Set<String>> get changes => _changes.stream;

  /// When [item] last changed here (ms since epoch), or 0 if it hasn't
  /// since sync came along.
  int stampOf(String item) => _stamps.get(item) ?? 0;

  Iterable<String> get stampedItems => _stamps.keys.cast<String>();
  Iterable<String> get keys => _kv.keys.cast<String>();
  Iterable<String> get blobKeys => _blobs.keys.cast<String>();
  String? readRaw(String key) => _kv.get(key);

  void _stampChanges(Set<String> items) {
    if (items.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      // Later than any stamp before it, even if the clock went back.
      final prev = _stamps.get(item) ?? 0;
      _stamps.put(item, now > prev ? now : prev + 1);
    }
    _changes.add(items);
  }

  /// Saves changes from another device: raw JSON (or null to delete) per
  /// key, bytes (or null) per blob, and their items' stamps. Unlike the
  /// writes above, this isn't reported on [changes].
  Future<void> applySynced({
    Map<String, String?> kv = const {},
    Map<String, List<int>?> blobs = const {},
    Map<String, int> stamps = const {},
  }) async {
    for (final e in kv.entries) {
      await (e.value == null ? _kv.delete(e.key) : _kv.put(e.key, e.value!));
    }
    for (final e in blobs.entries) {
      await (e.value == null ? _blobs.delete(e.key) : _blobs.put(e.key, e.value!));
    }
    await _stamps.putAll(stamps);
  }
}

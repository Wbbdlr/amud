import 'dart:convert';

import '../settings.dart';
import '../storage.dart';

/// Groups of synced data. Each device chooses which it shares; the rest it
/// keeps to itself (and leaves the other devices' copies alone).
enum SyncCategory {
  location('Location', 'Your place, elevation and travel prompts'),
  reminders('Reminders & alarms', 'Zman alerts, exact alarms, Levana, Birkat HaChama and Omer reminders'),
  home('Home screen & tabs', 'Dashboard cards, notes on them, the navigation bar and shortcuts'),
  siddur('Siddur, customs & zmanim', 'Nusach, text versions, minhagim, custom rules, zmanim opinions and learning'),
  reading('Appearance & reading', 'Theme, colors, fonts chosen, text size, layout and the Torah tab'),
  data('Personal dates & progress', 'Yahrzeits and other dates, Tehillim and Omer progress'),
  device('Device behavior', 'Keep screen awake, full screen, Do Not Disturb, tray and usage sharing'),
  fonts('Your fonts', 'Fonts you added or downloaded (can be large)');

  final String label;
  final String description;
  const SyncCategory(this.label, this.description);
}

const _settingsFields = <String, SyncCategory>{
  'location': SyncCategory.location,
  'useElevation': SyncCategory.location,
  'travelPrompts': SyncCategory.location,
  'exactAlarms': SyncCategory.reminders,
  'levanaReminder': SyncCategory.reminders,
  'hachamaReminder': SyncCategory.reminders,
  'omerBadge': SyncCategory.reminders,
  'navTabs': SyncCategory.home,
  'defaultBook': SyncCategory.siddur,
  'hebrewVersions': SyncCategory.siddur,
  'translationVersions': SyncCategory.siddur,
  'minhagim': SyncCategory.siddur,
  'openLicensesOnly': SyncCategory.siddur,
  'opinion': SyncCategory.siddur,
  'hour12': SyncCategory.siddur,
  'candleLightingMins': SyncCategory.siddur,
  'havdalahMins': SyncCategory.siddur,
  'learningSchedules': SyncCategory.siddur,
  'keepReaderAwake': SyncCategory.device,
  'fullscreenReader': SyncCategory.device,
  'readerDnd': SyncCategory.device,
  'desktopTray': SyncCategory.device,
  'shareUsage': SyncCategory.device,
};

const _keys = <String, SyncCategory>{
  'alerts': SyncCategory.reminders,
  'dashboard': SyncCategory.home,
  'dashboardVersion': SyncCategory.home,
  'iconShortcuts': SyncCategory.home,
  'customRules': SyncCategory.siddur,
  'customZmanim': SyncCategory.siddur,
  'torahSettings': SyncCategory.reading,
  'userFonts': SyncCategory.fonts,
};

/// This install's own bookkeeping, never synced.
const _localKeys = {'sync', 'update', 'updateLogged', 'analyticsCheckIn'};

/// The category of a storage item (see [Storage.kvItem]), or null if it
/// stays on this device. Data added in future versions syncs with
/// [SyncCategory.data] until it's given a category.
SyncCategory? categoryOf(String item) {
  if (item.startsWith('blob/')) {
    // Downloaded Torah texts are large and can be downloaded again.
    return item.startsWith('blob/font:') ? SyncCategory.fonts : null;
  }
  final parts = item.split('/');
  if (parts.length < 2 || parts[0] != 'kv') return null;
  final key = parts[1];
  if (_localKeys.contains(key) || key.endsWith('.unreadable')) return null;
  if (key == 'settings' && parts.length > 2) {
    // The schema version describes this install's copy.
    if (parts[2] == 'v') return null;
    return _settingsFields[parts[2]] ?? SyncCategory.reading;
  }
  return _keys[key] ?? SyncCategory.data;
}

/// One item in a sync document: when it changed ([t]) and its JSON value
/// (`v`), blob reference (`b`, and size `n`), or deletion (`d`).
typedef Entry = Map<String, Object?>;

int stampOfEntry(Entry e) => (e['t'] as num?)?.toInt() ?? 0;

/// The entry without its stamp, to compare contents.
String contentOf(Entry e) => jsonEncode({for (final k in e.keys.toList()..sort()) if (k != 't') k: e[k]});

/// This device's items in [shared] categories. [blobId] names blob contents.
Map<String, Entry> collectLocal(Storage storage, Set<SyncCategory> shared, String Function(String key, List<int> bytes) blobId) {
  bool wanted(String item) => shared.contains(categoryOf(item));
  final out = <String, Entry>{};
  for (final key in storage.keys) {
    final raw = storage.readRaw(key);
    if (raw == null) continue;
    final Object? value;
    try {
      value = jsonDecode(raw);
    } catch (_) {
      continue;
    }
    if (Storage.fieldwise.contains(key) && value is Map) {
      for (final e in value.entries) {
        final item = Storage.kvItem(key, '${e.key}');
        if (wanted(item)) out[item] = {'t': storage.stampOf(item), 'v': e.value};
      }
    } else {
      final item = Storage.kvItem(key);
      if (wanted(item)) out[item] = {'t': storage.stampOf(item), 'v': value};
    }
  }
  for (final key in storage.blobKeys) {
    final item = Storage.blobItem(key);
    final bytes = storage.readBlob(key);
    if (bytes == null || !wanted(item)) continue;
    out[item] = {'t': storage.stampOf(item), 'b': blobId(key, bytes), 'n': bytes.length};
  }
  // What was deleted here since sync came along.
  for (final item in storage.stampedItems) {
    if (!out.containsKey(item) && wanted(item)) out[item] = {'t': storage.stampOf(item), 'd': 1};
  }
  return out;
}

class MergePlan {
  /// The new shared document.
  final Map<String, Entry> doc;

  /// Entries from other devices to save here.
  final Map<String, Entry> incoming;

  /// Whether [doc] differs from what's on the server.
  final bool changed;
  const MergePlan(this.doc, this.incoming, this.changed);
}

/// Merges this device's items with the shared document. The newer change
/// to each item wins. Items this device doesn't share are left as they
/// are. With [preferRemote] (joining a code), the document wins outright,
/// so a new device's defaults don't replace a person's settings.
MergePlan merge({
  required Map<String, Entry> local,
  required Map<String, Entry> remote,
  required Set<SyncCategory> shared,
  bool preferRemote = false,
}) {
  final doc = <String, Entry>{};
  final incoming = <String, Entry>{};
  var changed = false;
  for (final item in {...local.keys, ...remote.keys}) {
    final l = local[item], r = remote[item];
    if (!shared.contains(categoryOf(item))) {
      if (r != null) doc[item] = r;
      continue;
    }
    if (r == null) {
      // A deletion nobody else knew the item for needn't be shared.
      if (l!['d'] == null) {
        doc[item] = l;
        changed = true;
      }
      continue;
    }
    if (l == null) {
      doc[item] = incoming[item] = r;
      continue;
    }
    final lc = contentOf(l), rc = contentOf(r);
    final lt = stampOfEntry(l), rt = stampOfEntry(r);
    if (lc == rc) {
      doc[item] = r;
    } else if (preferRemote || rt > lt || (rt == lt && rc.compareTo(lc) > 0)) {
      doc[item] = incoming[item] = r;
    } else {
      doc[item] = l;
      changed = true;
    }
  }
  return MergePlan(doc, incoming, changed);
}

/// Turns [incoming] entries into writes for [Storage.applySynced]. Blob
/// entries are left out; their bytes are fetched separately.
({Map<String, String?> kv, Map<String, int> stamps}) kvWrites(Storage storage, Map<String, Entry> incoming) {
  final kv = <String, String?>{};
  final fields = <String, Map<String, Entry>>{};
  final stamps = <String, int>{};
  for (final e in incoming.entries) {
    final parts = e.key.split('/');
    if (parts[0] != 'kv') continue;
    stamps[e.key] = stampOfEntry(e.value);
    if (parts.length > 2) {
      (fields[parts[1]] ??= {})[parts.sublist(2).join('/')] = e.value;
    } else {
      kv[parts[1]] = e.value['d'] != null ? null : jsonEncode(e.value['v']);
    }
  }
  for (final f in fields.entries) {
    Map<String, Object?> map;
    try {
      map = ((jsonDecode(storage.readRaw(f.key) ?? '{}') as Map?) ?? {}).cast<String, Object?>();
    } catch (_) {
      map = {};
    }
    for (final e in f.value.entries) {
      if (e.value['d'] != null) {
        map.remove(e.key);
      } else {
        map[e.key] = e.value['v'];
      }
    }
    // Settings that arrive before any were saved here are current ones.
    if (f.key == 'settings') map['v'] ??= AppSettings.schemaVersion;
    kv[f.key] = jsonEncode(map);
  }
  return (kv: kv, stamps: stamps);
}

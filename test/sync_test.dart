import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:amud/core/settings.dart';
import 'package:amud/core/storage.dart';
import 'package:amud/core/sync/sync_code.dart';
import 'package:amud/core/sync/sync_engine.dart';
import 'package:amud/core/sync/sync_items.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hebcal/hebcal.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// tool/sync/server.py's behavior, in memory.
class FakeServer {
  final docs = <String, (int, String?)>{};
  final blobs = <String, Map<String, List<int>>>{};

  http.Client get client => MockClient((req) async {
        final owner = req.headers['Authorization']!.substring('Bearer '.length);
        final path = req.url.path.substring('/api/sync/'.length);
        if (path == 'doc') {
          final (rev, data) = docs[owner] ?? (0, null);
          switch (req.method) {
            case 'GET':
              return docs.containsKey(owner) ? http.Response(jsonEncode({'rev': rev, 'data': data}), 200) : http.Response('{"rev":0}', 404);
            case 'PUT':
              final j = jsonDecode(req.body) as Map;
              if (j['rev'] != rev) return http.Response(jsonEncode({'rev': rev}), 409);
              docs[owner] = (rev + 1, j['data'] as String);
              blobs[owner]?.removeWhere((id, _) => !(j['blobs'] as List).contains(id));
              return http.Response(jsonEncode({'rev': rev + 1}), 200);
            case 'DELETE':
              docs.remove(owner);
              blobs.remove(owner);
              return http.Response('', 204);
          }
        }
        final id = path.substring('blobs/'.length);
        if (req.method == 'PUT') {
          docs.putIfAbsent(owner, () => (0, null));
          (blobs[owner] ??= {})[id] = req.bodyBytes;
          return http.Response('', 204);
        }
        final b = blobs[owner]?[id];
        return b == null ? http.Response('', 404) : http.Response.bytes(b, 200);
      });
}

void main() {
  setUpAll(initHebcal);

  group('sync code', () {
    test('round-trips and catches typos', () {
      final code = newSyncCode(Random(1));
      expect(code, matches(RegExp(r'^[0-9A-Z]{5}(-[0-9A-Z]{5}){3}$')));
      expect(normalizeSyncCode(code), code);
      expect(normalizeSyncCode(' ${code.toLowerCase().replaceAll('-', ' ')} '), code);
      // One wrong character, or two swapped, is caught.
      final chars = code.replaceAll('-', '');
      final wrong = chars.replaceRange(3, 4, chars[3] == 'A' ? 'B' : 'A');
      expect(normalizeSyncCode(wrong), isNull);
      final swapped = chars[1] == chars[2] ? null : chars.replaceRange(1, 3, '${chars[2]}${chars[1]}');
      if (swapped != null) expect(normalizeSyncCode(swapped), isNull);
      expect(normalizeSyncCode('short'), isNull);
    });

    test('derives separate keys', () {
      final a = SyncKeys.fromCode(newSyncCode(Random(2)));
      final b = SyncKeys.fromCode(newSyncCode(Random(3)));
      expect(a.token, isNot(b.token));
      expect(a.token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(a.encryptionKey, hasLength(32));
      expect(a.encryptionKey, isNot(a.blobIdKey));
    });
  });

  test('settings changes are tracked per field', () {
    final before = jsonEncode({'v': 2, 'textScale': 1.0, 'location': {'name': 'A'}});
    final after = jsonEncode({'v': 2, 'textScale': 1.2, 'location': {'name': 'A'}, 'warmth': 0.5});
    expect(Storage.changedItems('settings', before, after), {'kv/settings/textScale', 'kv/settings/warmth'});
    expect(Storage.changedItems('alerts', '[]', '[1]'), {'kv/alerts'});
    expect(Storage.changedItems('alerts', '[1]', '[1]'), isEmpty);
  });

  test('categories', () {
    expect(categoryOf('kv/settings/location'), SyncCategory.location);
    expect(categoryOf('kv/settings/themeMode'), SyncCategory.reading);
    expect(categoryOf('kv/settings/v'), isNull);
    expect(categoryOf('kv/alerts'), SyncCategory.reminders);
    expect(categoryOf('kv/sync'), isNull);
    expect(categoryOf('kv/settings.unreadable'), isNull);
    expect(categoryOf('kv/somethingNew'), SyncCategory.data);
    expect(categoryOf('blob/font:user_1'), SyncCategory.fonts);
    expect(categoryOf('blob/torah:mishnah'), isNull);
  });

  group('merge', () {
    const all = {...SyncCategory.values};
    test('the newer change wins', () {
      final plan = merge(
        local: {'kv/alerts': {'t': 5, 'v': 'mine'}, 'kv/dashboard': {'t': 1, 'v': 'old'}},
        remote: {'kv/alerts': {'t': 3, 'v': 'theirs'}, 'kv/dashboard': {'t': 2, 'v': 'new'}},
        shared: all,
      );
      expect(plan.doc['kv/alerts']!['v'], 'mine');
      expect(plan.incoming.keys, ['kv/dashboard']);
      expect(plan.changed, isTrue);
    });

    test('joining takes the shared copy', () {
      final plan = merge(
        local: {'kv/alerts': {'t': 9, 'v': 'defaults'}, 'kv/personalDates': {'t': 9, 'v': 'only here'}},
        remote: {'kv/alerts': {'t': 3, 'v': 'theirs'}},
        shared: all,
        preferRemote: true,
      );
      expect(plan.incoming['kv/alerts']!['v'], 'theirs');
      expect(plan.doc['kv/personalDates']!['v'], 'only here');
    });

    test('what this device keeps to itself is left alone', () {
      final plan = merge(
        local: const {},
        remote: {'kv/settings/location': {'t': 3, 'v': 'there'}},
        shared: all.difference({SyncCategory.location}),
      );
      expect(plan.incoming, isEmpty);
      expect(plan.doc['kv/settings/location']!['v'], 'there');
      expect(plan.changed, isFalse);
    });
  });

  group('two devices', () {
    late Directory dir;
    late FakeServer server;
    late String code;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sync');
      server = FakeServer();
      code = newSyncCode(Random(4));
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    // Hive has one set of boxes per process, so the devices take turns.
    Future<T> device<T>(String name, Future<T> Function(Storage s, SyncEngine e) body) async {
      await Hive.close();
      final storage = await Storage.openAt('${dir.path}/$name');
      final keys = SyncKeys.fromCode(code);
      return body(storage, SyncEngine(storage, SyncApi(Uri.parse('https://example.test/api/sync/'), keys.token, server.client), keys));
    }

    AppSettings settingsOf(Storage s) => s.readJson('settings', (j) => AppSettings.fromJson((j as Map).cast()))!;
    const all = {...SyncCategory.values};

    test('a new device gets everything, then changes flow both ways', () async {
      await device('phone', (s, e) async {
        await s.writeJson('settings', const AppSettings(textScale: 1.3, levanaReminder: true, setupDone: true).toJson());
        await s.writeJson('alerts', [{'id': 1}]);
        await s.writeBlob('font:user_1', [1, 2, 3]);
        await s.writeBlob('torah:big', [9, 9]);
        await e.run(all);
      });
      // The server can't read any of it.
      final stored = server.docs.values.single.$2!;
      expect(utf8.decode(base64.decode(stored), allowMalformed: true), isNot(contains('alerts')));

      await device('laptop', (s, e) async {
        await s.writeJson('settings', const AppSettings(setupDone: true).toJson());
        expect(await e.exists(), isTrue);
        await e.run(all, preferRemote: true);
        expect(settingsOf(s).textScale, 1.3);
        expect(settingsOf(s).levanaReminder, isTrue);
        expect(s.readJson('alerts', (j) => j), [{'id': 1}]);
        expect(s.readBlob('font:user_1'), [1, 2, 3]);
        expect(s.readBlob('torah:big'), isNull);
        // A change here, to one setting.
        await s.writeJson('settings', settingsOf(s).copyWith(themeMode: AppThemeMode.dark).toJson());
        await s.deleteBlob('font:user_1');
        await e.run(all);
      });

      await device('phone', (s, e) async {
        // Meanwhile, a different setting changed here.
        await s.writeJson('settings', settingsOf(s).copyWith(warmth: 0.7).toJson());
        await e.run(all);
        expect(settingsOf(s).themeMode, AppThemeMode.dark);
        expect(settingsOf(s).warmth, 0.7);
        expect(s.readBlob('font:user_1'), isNull);
        expect(s.readBlob('torah:big'), [9, 9]);
      });
      expect(server.blobs.values.expand((b) => b.keys), isEmpty);
    });

    test('a device can keep its own location', () async {
      await device('home', (s, e) async {
        await s.writeJson('settings', AppSettings(location: SavedLocation.newYork, setupDone: true).toJson());
        await e.run(all);
      });
      await device('travel', (s, e) async {
        await s.writeJson('settings', const AppSettings(setupDone: true, textScale: 1.1).toJson());
        final own = all.difference({SyncCategory.location});
        await e.run(own, preferRemote: true);
        await s.writeJson('settings', settingsOf(s).copyWith(location: const SavedLocation(name: 'Jerusalem', latitude: 31.78, longitude: 35.22, tzid: 'Asia/Jerusalem', il: true)).toJson());
        await e.run(own);
      });
      await device('home', (s, e) async {
        await e.run(all);
        expect(settingsOf(s).location.name, SavedLocation.newYork.name);
      });
    });

    test('concurrent syncs merge instead of overwriting', () async {
      await device('a', (s, e) async {
        await s.writeJson('personalDates', ['a']);
        await e.run(all);
      });
      // Device b read the document, then a synced again before b saved.
      var raced = false;
      final keys = SyncKeys.fromCode(code);
      final racing = MockClient((req) async {
        if (req.method == 'PUT' && req.url.path.endsWith('/doc') && !raced) {
          raced = true;
          final (rev, data) = server.docs.values.single;
          server.docs[server.docs.keys.single] = (rev + 1, data);
        }
        return server.client.send(http.Request(req.method, req.url)
              ..headers.addAll(req.headers)
              ..bodyBytes = req.bodyBytes)
            .then(http.Response.fromStream);
      });
      await Hive.close();
      final s = await Storage.openAt('${dir.path}/b');
      await s.writeJson('customZmanim', ['b']);
      await SyncEngine(s, SyncApi(Uri.parse('https://example.test/api/sync/'), keys.token, racing), keys).run(all);
      expect(raced, isTrue);
      expect(s.readJson('personalDates', (j) => j), ['a']);
    });

    test('the wrong code reads nothing', () async {
      await device('a', (s, e) async {
        await s.writeJson('alerts', [1]);
        await e.run(all);
      });
      code = newSyncCode(Random(5));
      await device('b', (s, e) async => expect(await e.exists(), isFalse));
    });
  });
}

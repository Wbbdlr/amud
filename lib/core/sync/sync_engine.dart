import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../storage.dart';
import 'sync_code.dart';
import 'sync_items.dart';

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

class _Conflict implements Exception {}

/// The sync server (tool/sync/server.py). It stores only what the device
/// encrypted, under the token's hash.
class SyncApi {
  final Uri base;
  final String token;
  final http.Client client;
  SyncApi(this.base, this.token, [http.Client? client]) : client = client ?? http.Client();

  static const _timeout = Duration(seconds: 30);
  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Never _fail(http.Response res) => throw SyncException(switch (res.statusCode) {
        413 => 'Too much to sync: remove some fonts or stop syncing them.',
        429 => 'Too many new sync codes from this network. Try again later.',
        _ => 'The sync server answered ${res.statusCode}.',
      });

  /// The document's revision and encrypted contents (null if there's none).
  Future<(int, String?)> getDoc() async {
    final res = await client.get(base.resolve('doc'), headers: _auth).timeout(_timeout);
    if (res.statusCode == 404) return (0, null);
    if (res.statusCode != 200) _fail(res);
    final j = jsonDecode(res.body) as Map;
    return ((j['rev'] as num).toInt(), j['data'] as String?);
  }

  /// Saves the document if it's still at [rev]; returns the new revision.
  Future<int> putDoc(int rev, String data, Iterable<String> blobs) async {
    final res = await client
        .put(base.resolve('doc'),
            headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'rev': rev, 'data': data, 'blobs': blobs.toList()}))
        .timeout(_timeout);
    if (res.statusCode == 409) throw _Conflict();
    if (res.statusCode != 200) _fail(res);
    return ((jsonDecode(res.body) as Map)['rev'] as num).toInt();
  }

  Future<void> putBlob(String id, List<int> data) async {
    final res = await client
        .put(base.resolve('blobs/$id'), headers: {..._auth, 'Content-Type': 'application/octet-stream'}, body: data)
        .timeout(const Duration(minutes: 5));
    if (res.statusCode != 204) _fail(res);
  }

  Future<List<int>?> getBlob(String id) async {
    final res = await client.get(base.resolve('blobs/$id'), headers: _auth).timeout(const Duration(minutes: 5));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) _fail(res);
    return res.bodyBytes;
  }

  Future<void> deleteAll() async {
    final res = await client.delete(base.resolve('doc'), headers: _auth).timeout(_timeout);
    if (res.statusCode != 204) _fail(res);
  }
}

/// Encrypts with AES-256-GCM. The associated data ties each ciphertext to
/// its place, so the server can't swap one blob or document for another.
class SyncCipher {
  final SecretKey _key;
  SyncCipher(List<int> key) : _key = SecretKey(key);
  static final _aes = AesGcm.with256bits();

  Future<List<int>> seal(List<int> plain, String purpose) async =>
      (await _aes.encrypt(plain, secretKey: _key, aad: utf8.encode(purpose))).concatenation();

  Future<List<int>> open(List<int> sealed, String purpose) async {
    try {
      final box = SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16, copy: false);
      return await _aes.decrypt(box, secretKey: _key, aad: utf8.encode(purpose));
    } catch (_) {
      throw const SyncException('Synced data could not be decrypted. Check the sync code.');
    }
  }
}

/// The document format; a device that finds a newer one asks to be updated.
const _format = 1;

/// One sync pass: fetch the shared document, merge, upload and save.
class SyncEngine {
  final Storage storage;
  final SyncApi api;
  final SyncKeys keys;
  final SyncCipher _cipher;
  SyncEngine(this.storage, this.api, this.keys) : _cipher = SyncCipher(keys.encryptionKey);

  // Blob ids by key, length and stamp, so unchanged fonts aren't rehashed.
  final _blobIds = <String, (int, int, String)>{};

  String _blobId(String key, List<int> bytes) {
    final stamp = storage.stampOf(Storage.blobItem(key));
    final known = _blobIds[key];
    if (known != null && known.$1 == bytes.length && known.$2 == stamp) return known.$3;
    final id = keys.blobId(bytes);
    _blobIds[key] = (bytes.length, stamp, id);
    return id;
  }

  Future<Map<String, Entry>> _decode(String? data) async {
    if (data == null) return {};
    final plain = await _cipher.open(base64.decode(data), 'doc');
    final j = jsonDecode(utf8.decode(const GZipDecoder().decodeBytes(plain))) as Map;
    if ((j['format'] as num? ?? 0) > _format) {
      throw const SyncException('Another device uses a newer version of Amud. Update this one to keep syncing.');
    }
    return {for (final e in (j['items'] as Map).entries) e.key as String: (e.value as Map).cast<String, Object?>()};
  }

  Future<String> _encode(Map<String, Entry> items) async {
    final plain = const GZipEncoder().encodeBytes(utf8.encode(jsonEncode({'format': _format, 'items': items})));
    return base64.encode(await _cipher.seal(plain, 'doc'));
  }

  /// Whether the server has anything under this code.
  Future<bool> exists() async => (await api.getDoc()).$2 != null;

  /// Syncs the [shared] categories; returns the items saved here.
  Future<Set<String>> run(Set<SyncCategory> shared, {bool preferRemote = false}) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final (rev, data) = await api.getDoc();
      final remote = await _decode(data);
      final local = collectLocal(storage, shared, _blobId);
      final plan = merge(local: local, remote: remote, shared: shared, preferRemote: preferRemote);

      // Fonts first, so the document never names a blob that isn't there.
      final onServer = {for (final e in remote.values) e['b']};
      for (final e in plan.doc.entries) {
        final id = e.value['b'] as String?;
        if (id == null || onServer.contains(id) || plan.incoming.containsKey(e.key)) continue;
        final bytes = storage.readBlob(e.key.substring('blob/'.length));
        if (bytes == null) continue;
        await api.putBlob(id, await _cipher.seal(bytes, 'blob:$id'));
        onServer.add(id);
      }

      final blobs = <String, List<int>?>{};
      final skipped = <String>{};
      for (final e in plan.incoming.entries) {
        if (!e.key.startsWith('blob/')) continue;
        final key = e.key.substring('blob/'.length);
        final id = e.value['b'] as String?;
        if (id == null) {
          blobs[key] = null;
          continue;
        }
        final sealed = await api.getBlob(id);
        final bytes = sealed == null ? null : await _cipher.open(sealed, 'blob:$id');
        // A blob that's missing or isn't what it should be waits for next time.
        if (bytes == null || keys.blobId(bytes) != id) {
          skipped.add(e.key);
        } else {
          blobs[key] = bytes;
        }
      }

      if (plan.changed) {
        try {
          await api.putDoc(rev, await _encode(plan.doc), {for (final e in plan.doc.values) ?e['b'] as String?});
        } on _Conflict {
          continue; // Another device synced meanwhile: merge again.
        }
      }

      final incoming = {...plan.incoming}..removeWhere((k, _) => skipped.contains(k));
      final writes = kvWrites(storage, incoming);
      await storage.applySynced(kv: writes.kv, blobs: blobs, stamps: {
        ...writes.stamps,
        for (final e in incoming.entries)
          if (e.key.startsWith('blob/')) e.key: stampOfEntry(e.value),
      });
      return incoming.keys.toSet();
    }
    throw const SyncException('Other devices kept syncing at the same time. Try again.');
  }
}

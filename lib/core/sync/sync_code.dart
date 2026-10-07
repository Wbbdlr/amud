import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A sync code: the one secret that links a person's devices. It works as
/// both username and password, so there's no account, email or reset.
///
/// 19 random Crockford base32 characters (95 bits) and a check character,
/// shown as four groups of five: `7K4QM-X2D9P-…`.
const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String _check(String body) {
  var sum = 0;
  for (var i = 0; i < body.length; i++) {
    sum += (i + 1) * _alphabet.indexOf(body[i]);
  }
  return _alphabet[sum % 32];
}

String _group(String chars) => [for (var i = 0; i < chars.length; i += 5) chars.substring(i, i + 5)].join('-');

/// A new random code.
String newSyncCode([Random? random]) {
  final r = random ?? Random.secure();
  final body = String.fromCharCodes([for (var i = 0; i < 19; i++) _alphabet.codeUnitAt(r.nextInt(32))]);
  return _group(body + _check(body));
}

/// [input] as a well-formed code, or null if it isn't one (a typo).
/// Case, spaces and dashes don't matter, and O, I and L read as 0, 1, 1.
String? normalizeSyncCode(String input) {
  final chars = input
      .toUpperCase()
      .replaceAll(RegExp(r'[\s-]'), '')
      .replaceAll('O', '0')
      .replaceAll(RegExp('[IL]'), '1');
  if (chars.length != 20 || chars.split('').any((c) => !_alphabet.contains(c))) return null;
  return _check(chars.substring(0, 19)) == chars[19] ? _group(chars) : null;
}

/// What a code unlocks, each derived separately so none reveals another:
/// the server sees only [token]; [encryptionKey] and [blobIdKey] never
/// leave the device.
class SyncKeys {
  final String token;
  final List<int> encryptionKey;
  final List<int> blobIdKey;
  const SyncKeys._(this.token, this.encryptionKey, this.blobIdKey);

  /// The code has 95 random bits, so a fast derivation is enough.
  factory SyncKeys.fromCode(String code) {
    final hmac = Hmac(sha256, utf8.encode(code.replaceAll('-', '')));
    List<int> derive(String label) => hmac.convert(utf8.encode('amud-sync/$label')).bytes;
    return SyncKeys._(
      base64Url.encode(derive('auth')).replaceAll('=', ''),
      derive('encryption'),
      derive('blob-id'),
    );
  }

  /// The name a blob's content is stored under (unguessable without the code).
  String blobId(List<int> bytes) => Hmac(sha256, blobIdKey).convert(bytes).toString().substring(0, 32);
}

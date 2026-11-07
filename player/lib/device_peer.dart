import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'history_files.dart';

enum PairPurpose {
  youtube('YouTube Music sign-in', 'Connect from Windows'),
  history('listening history', 'Pair Wi-Fi history');

  const PairPurpose(this.label, this.androidAction);
  final String label, androidAction;
}

bool privateAddress(String value) {
  final bytes = InternetAddress.tryParse(value)?.rawAddress;
  return bytes != null &&
      bytes.length == 4 &&
      (bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168));
}

Future<List<InternetAddress>> lanAddresses() async => [
  for (final network in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  ))
    ...network.addresses.where((address) => privateAddress(address.address)),
];

final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
String _randomToken() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

class PairCode {
  const PairCode(this.purpose, this.host, this.port, this.pin, this.secret);
  final PairPurpose purpose;
  final String host, pin, secret;
  final int port;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'purpose': purpose.name,
    'host': host,
    'port': port,
    'pin': pin,
    'secret': secret,
  };

  String encode() =>
      base64UrlEncode(utf8.encode(jsonEncode(toJson()))).replaceAll('=', '');

  factory PairCode.decode(String text, PairPurpose purpose) {
    final PairCode code;
    try {
      text = text.trim();
      if (text.length > 512) throw const FormatException();
      code = PairCode.fromJson(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(text)))),
      );
    } catch (_) {
      throw const FormatException(
        'Use a fresh pairing code from Personal Radio on Windows.',
      );
    }
    if (code.purpose != purpose) {
      throw FormatException(
        'This code is for ${code.purpose.label}. '
        'Choose ${code.purpose.androidAction} on your phone.',
      );
    }
    return code;
  }

  factory PairCode.fromJson(Map<String, dynamic> data) {
    final host = data['host'] as String;
    final port = data['port'] as int;
    final pin = data['pin'] as String;
    final secret = data['secret'] as String;
    if (data['version'] != 1 ||
        !privateAddress(host) ||
        port < 1 ||
        port > 65535 ||
        !_tokenPattern.hasMatch(pin) ||
        !_tokenPattern.hasMatch(secret)) {
      throw const FormatException('Invalid pairing information.');
    }
    return PairCode(
      PairPurpose.values.byName(data['purpose']),
      host,
      port,
      pin,
      secret,
    );
  }

  Future<dynamic> request(
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = ((_) => 'DIRECT')
      ..badCertificateCallback = ((certificate, remote, remotePort) =>
          remote == host &&
          remotePort == port &&
          _fingerprint(certificate.der) == pin);
    try {
      return await (() async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          Uri.parse('https://$host:$port$path'),
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const FormatException(
            'Desktop declined or the pairing code expired.',
          );
        }
        return _readJson(response);
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

Future<Map<String, dynamic>> _readJson(Stream<List<int>> input) async {
  final bytes = <int>[];
  await for (final chunk in input.timeout(const Duration(seconds: 15))) {
    if (bytes.length + chunk.length > 16 * 1024 * 1024) {
      throw const FormatException('History page is too large.');
    }
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

String _fingerprint(List<int> der) =>
    base64UrlEncode(const DartSha256().hashSync(der).bytes).replaceAll('=', '');

class _Certificate {
  const _Certificate(this.cert, this.key);
  final String cert, key;

  factory _Certificate.create() {
    final keys = CryptoUtils.generateEcKeyPair();
    final key = keys.privateKey as ECPrivateKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'Personal Radio'},
      key,
      keys.publicKey as ECPublicKey,
    );
    return _Certificate(
      X509Utils.generateSelfSignedCertificate(key, csr, 3650),
      CryptoUtils.encodePrivateEcdsaKeyToPkcs8(key),
    );
  }

  SecurityContext context() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(cert))
    ..usePrivateKeyBytes(utf8.encode(key));

  String fingerprint() {
    final der = base64Decode(
      cert
          .split(RegExp(r'\r?\n'))
          .where((line) => !line.startsWith('-----'))
          .join(),
    );
    return _fingerprint(der);
  }
}

class PairOffer {
  PairOffer(this.code);
  final PairCode code;
  final expires = DateTime.now().add(const Duration(minutes: 5));
  final incoming = ValueNotifier<String?>(null);
  final decision = Completer<bool>();
  final finished = Completer<bool>();
  void decide(bool approved) {
    if (!decision.isCompleted) decision.complete(approved);
  }
}

class DevicePeer extends ChangeNotifier {
  DevicePeer(this._api);
  final RadioApi? Function() _api;
  static const _storage = FlutterSecureStorage();
  static const _storageKey = 'standalone_history_peer_v1';
  PairCode? _peer;
  HttpServer? _historyServer, _pairServer;
  PairOffer? _offer;
  bool _syncing = false;
  int _sent = 0, _received = 0;
  int _generation = 0;
  bool get paired => _peer != null;
  bool get serving => _historyServer != null;
  bool get syncing => _syncing;

  RadioApi get _local {
    final api = _api();
    if (api == null) {
      throw const FormatException('Local engine is unavailable.');
    }
    return api;
  }

  Future<void> restore() async {
    final generation = _generation;
    try {
      final value = await _storage.read(key: _storageKey);
      if (value == null || generation != _generation) return;
      final data = jsonDecode(value) as Map<String, dynamic>;
      final peer = PairCode.fromJson(data['peer']);
      if (peer.purpose != PairPurpose.history) return;
      _peer = peer;
      _sent = data['sent'] as int? ?? 0;
      _received = data['received'] as int? ?? 0;
      if (Platform.isWindows) {
        final certificate = _Certificate(data['cert'], data['key']);
        final server = await _serveHistory(peer, certificate);
        if (generation != _generation) {
          await server.close(force: true);
          return;
        }
        _historyServer = server;
      }
    } catch (_) {
      // Keep the saved pairing visible so the user can unpair after an IP change.
    }
    notifyListeners();
  }

  Future<PairOffer> offer(InternetAddress address, PairPurpose purpose) async {
    if (!privateAddress(address.address)) {
      throw const FormatException('Choose your private Wi-Fi address.');
    }
    if (purpose == PairPurpose.history && paired) {
      throw const FormatException('Unpair history before pairing a new phone.');
    }
    await closeOffer();
    final generation = _generation;
    final certificate = await compute((_) => _Certificate.create(), null);
    final pin = certificate.fingerprint();
    final server = await HttpServer.bindSecure(
      address,
      0,
      certificate.context(),
    );
    if (generation != _generation) {
      await server.close(force: true);
      throw const FormatException('Pairing was cancelled.');
    }
    _pairServer = server;
    final offer = PairOffer(
      PairCode(purpose, address.address, server.port, pin, _randomToken()),
    );
    _offer = offer;
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      var claimed = false;
      try {
        final remote = request.connectionInfo?.remoteAddress.address ?? '';
        if (request.method != 'POST' ||
            request.uri.path != '/pair' ||
            !privateAddress(remote) ||
            !_authorized(request, offer.code.secret) ||
            DateTime.now().isAfter(offer.expires) ||
            offer.incoming.value != null) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        claimed = true;
        offer.incoming.value = remote;
        final approved = await offer.decision.future.timeout(
          offer.expires.difference(DateTime.now()),
          onTimeout: () => false,
        );
        if (!approved || _offer != offer) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        if (purpose == PairPurpose.youtube) {
          final credentials = await _local.call(
            '/api/local/accounts/youtube/transfer',
            body: {},
          );
          if (_offer != offer) return;
          response.write(jsonEncode(credentials));
        } else {
          final historyServer = await HttpServer.bindSecure(
            address,
            0,
            certificate.context(),
          );
          final peer = PairCode(
            purpose,
            address.address,
            historyServer.port,
            pin,
            _randomToken(),
          );
          try {
            if (_offer != offer) {
              throw const FormatException('Pairing was cancelled.');
            }
            await _save(peer, 0, 0, certificate);
            if (_offer != offer) {
              throw const FormatException('Pairing was cancelled.');
            }
            _peer = peer;
            _historyServer = historyServer;
            _listenHistory(historyServer, peer);
            notifyListeners();
            response.write(jsonEncode(peer.toJson()));
          } catch (_) {
            await historyServer.close(force: true);
            rethrow;
          }
        }
        await response.close();
        offer.finished.complete(true);
      } catch (_) {
        response.statusCode = HttpStatus.serviceUnavailable;
      } finally {
        await response.close();
        if (claimed && !offer.finished.isCompleted) {
          offer.finished.complete(false);
        }
      }
    });
    return offer;
  }

  bool _authorized(HttpRequest request, String token) {
    final value = request.headers.value(HttpHeaders.authorizationHeader);
    final expected = 'Bearer $token';
    if (value == null || value.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= value.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<HttpServer> _serveHistory(
    PairCode peer,
    _Certificate certificate,
  ) async {
    final server = await HttpServer.bindSecure(
      peer.host,
      peer.port,
      certificate.context(),
    );
    _listenHistory(server, peer);
    return server;
  }

  void _listenHistory(HttpServer server, PairCode peer) {
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      try {
        if (request.uri.path != '/history' ||
            _peer != peer ||
            !privateAddress(
              request.connectionInfo?.remoteAddress.address ?? '',
            ) ||
            !_authorized(request, peer.secret)) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        if (request.method == 'GET') {
          final query = request.uri.queryParameters;
          final uri = Uri(
            path: historyPath,
            queryParameters: {
              'after': query['after'] ?? '0',
              if (query.containsKey('through')) 'through': query['through']!,
              'local_only': 'true',
            },
          );
          response.write(jsonEncode(await _local.call(uri.toString())));
        } else if (request.method == 'POST') {
          final archive = await _readJson(request);
          if (_peer != peer) return;
          response.write(
            jsonEncode(await _local.call(historyPath, body: archive)),
          );
        } else {
          response.statusCode = HttpStatus.methodNotAllowed;
        }
      } catch (_) {
        response.statusCode = HttpStatus.badRequest;
      } finally {
        await response.close();
      }
    });
  }

  Future<void> accept(String encoded, PairPurpose purpose) async {
    if (purpose == PairPurpose.history && paired) {
      throw const FormatException(
        'Unpair history before pairing a new desktop.',
      );
    }
    final generation = _generation;
    final code = PairCode.decode(encoded, purpose);
    final result = await code.request(
      '/pair',
      body: {},
      timeout: const Duration(minutes: 5),
    );
    if (generation != _generation) return;
    if (purpose == PairPurpose.youtube) {
      await _local.call(
        '/api/local/accounts/youtube',
        body: {'text': jsonEncode(result['auth'])},
      );
    } else {
      final peer = PairCode.fromJson(result);
      if (peer.purpose != purpose ||
          peer.host != code.host ||
          peer.pin != code.pin) {
        throw const FormatException('Desktop pairing details changed.');
      }
      await _save(peer, 0, 0);
      if (generation != _generation) return;
      _peer = peer;
      notifyListeners();
    }
  }

  Future<void> _save(
    PairCode peer,
    int sent,
    int received, [
    _Certificate? certificate,
  ]) => _storage.write(
    key: _storageKey,
    value: jsonEncode({
      'peer': peer.toJson(),
      'sent': sent,
      'received': received,
      if (certificate != null) ...{
        'cert': certificate.cert,
        'key': certificate.key,
      },
    }),
  );

  Future<void> sync() async {
    final peer = _peer;
    if (peer == null || serving || _syncing) return;
    final api = _local;
    _syncing = true;
    notifyListeners();
    try {
      await readHistoryPages(
        after: _sent,
        localOnly: true,
        read: (query) => api.call('$historyPath$query'),
        consume: (archive, cursor) async {
          if (_peer != peer) {
            throw const FormatException('History sync was cancelled.');
          }
          if ((archive['events'] as List).isNotEmpty) {
            await peer.request('/history', body: archive);
          }
          if (_peer != peer) return;
          await _save(peer, cursor, _received);
          _sent = cursor;
        },
      );
      await readHistoryPages(
        after: _received,
        read: (query) => peer.request('/history$query'),
        consume: (archive, cursor) async {
          if (_peer != peer) {
            throw const FormatException('History sync was cancelled.');
          }
          if ((archive['events'] as List).isNotEmpty) {
            await api.call(historyPath, body: archive);
          }
          if (_peer != peer) return;
          await _save(peer, _sent, cursor);
          _received = cursor;
        },
      );
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> closeOffer() async {
    final server = _pairServer;
    _pairServer = null;
    _offer?.decide(false);
    _offer = null;
    await server?.close(force: true);
  }

  Future<void> close() async {
    _generation++;
    _peer = null;
    _sent = _received = 0;
    final server = _historyServer;
    _historyServer = null;
    await closeOffer();
    await server?.close(force: true);
    notifyListeners();
  }

  Future<void> unpair() async {
    await close();
    await _storage.delete(key: _storageKey);
  }
}

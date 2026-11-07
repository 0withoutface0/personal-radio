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
  history('listening history', 'Pair Wi-Fi history'),
  setup('full Android setup', 'Set up from Windows');

  const PairPurpose(this.label, this.androidAction);
  final String label, androidAction;
}

typedef ServerConnection = ({String origin, String token});
typedef _HistoryOffer = ({HttpServer server, PairCode peer});

ServerConnection shareableServer(String address, String token) {
  final origin = validateServer(address);
  final host = Uri.parse(origin).host;
  if (host == 'localhost' ||
      host == '10.0.2.2' ||
      InternetAddress.tryParse(host)?.isLoopback == true ||
      token.trim().isEmpty) {
    throw const FormatException(
      'Connect Windows using a server address your phone can reach, such as its Tailscale address.',
    );
  }
  return (origin: origin, token: token);
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
  _HistoryOffer? _history;
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

  Future<PairOffer> offer(
    InternetAddress address,
    PairPurpose purpose, {
    bool shareHistory = false,
    ServerConnection? serverConnection,
  }) async {
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
    var delivered = false;
    var acknowledged = false;
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      bool? finished;
      try {
        final remote = request.connectionInfo?.remoteAddress.address ?? '';
        if (request.method != 'POST' ||
            !privateAddress(remote) ||
            !_authorized(request, offer.code.secret) ||
            DateTime.now().isAfter(offer.expires) ||
            _offer != offer) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        if (request.uri.path == '/confirm' && purpose == PairPurpose.setup) {
          if (!delivered || acknowledged || offer.incoming.value != remote) {
            response.statusCode = HttpStatus.forbidden;
            return;
          }
          acknowledged = true;
          finished = false;
          final installed = (await _readJson(request))['installed'] == true;
          if (installed && offer._history != null) {
            await _activateHistory(offer, certificate);
          }
          if (_offer != offer) {
            response.statusCode = HttpStatus.forbidden;
            return;
          }
          finished = installed;
          response.write('{}');
          return;
        }
        if (request.uri.path != '/pair' || offer.incoming.value != null) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        finished = false;
        offer.incoming.value = remote;
        final approved = await offer.decision.future.timeout(
          offer.expires.difference(DateTime.now()),
          onTimeout: () => false,
        );
        if (!approved || _offer != offer) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        final dynamic payload;
        switch (purpose) {
          case PairPurpose.youtube:
            payload = await _local.call(
              '/api/local/accounts/youtube/transfer',
              body: {},
            );
          case PairPurpose.history:
            await _prepareHistory(offer, address, certificate);
            await _activateHistory(offer, certificate);
            payload = _peer!.toJson();
          case PairPurpose.setup:
            final details = await _readJson(request);
            if (serverConnection != null) {
              payload = {
                'mode': 'server',
                'origin': serverConnection.origin,
                'token': serverConnection.token,
              };
            } else {
              final accounts = await _local.call(
                '/api/local/accounts/setup/transfer',
                body: {},
              );
              if (shareHistory &&
                  details['history_available'] == true &&
                  !paired) {
                await _prepareHistory(offer, address, certificate);
              }
              payload = {
                'mode': 'local',
                'accounts': accounts,
                if (offer._history != null)
                  'history': offer._history!.peer.toJson(),
              };
            }
        }
        if (_offer != offer) {
          response.statusCode = HttpStatus.forbidden;
          return;
        }
        response.write(jsonEncode(payload));
        delivered = true;
        // Full setup waits for the receiving app to confirm it installed the settings.
        finished = purpose == PairPurpose.setup ? null : true;
      } catch (_) {
        response.statusCode = HttpStatus.serviceUnavailable;
      } finally {
        try {
          await response.close();
        } catch (_) {
          finished = false;
        }
        if (finished != null && !offer.finished.isCompleted) {
          offer.finished.complete(finished);
        }
      }
    });
    return offer;
  }

  Future<void> _prepareHistory(
    PairOffer offer,
    InternetAddress address,
    _Certificate certificate,
  ) async {
    final server = await HttpServer.bindSecure(
      address,
      0,
      certificate.context(),
    );
    if (_offer != offer || paired) {
      await server.close(force: true);
      throw const FormatException('History pairing is no longer available.');
    }
    final peer = PairCode(
      PairPurpose.history,
      address.address,
      server.port,
      offer.code.pin,
      _randomToken(),
    );
    offer._history = (server: server, peer: peer);
  }

  Future<void> _activateHistory(
    PairOffer offer,
    _Certificate certificate,
  ) async {
    if (_offer != offer || paired) {
      throw const FormatException('History pairing is no longer available.');
    }
    final history = offer._history!;
    await _save(history.peer, 0, 0, certificate);
    if (_offer != offer) {
      await _storage.delete(key: _storageKey);
      throw const FormatException('Pairing was cancelled.');
    }
    offer._history = null;
    _peer = history.peer;
    _historyServer = history.server;
    _listenHistory(history.server, history.peer);
    notifyListeners();
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
      await _receiveHistory(_historyFrom(result, code), generation);
    }
  }

  PairCode _historyFrom(dynamic data, PairCode source) {
    final peer = PairCode.fromJson(data);
    if (peer.purpose != PairPurpose.history ||
        peer.host != source.host ||
        peer.pin != source.pin) {
      throw const FormatException('Desktop pairing details changed.');
    }
    return peer;
  }

  Future<void> _receiveHistory(PairCode peer, int generation) async {
    await _save(peer, 0, 0);
    if (generation != _generation) return;
    _peer = peer;
    _sent = _received = 0;
    notifyListeners();
  }

  Future<void> acceptSetup(
    String encoded,
    Future<void> Function(Map<String, dynamic>) install,
  ) async {
    final code = PairCode.decode(encoded, PairPurpose.setup);
    final canShareHistory =
        !paired && await _storage.read(key: _storageKey) == null;
    final payload = await code.request(
      '/pair',
      body: {'history_available': canShareHistory},
      timeout: const Duration(minutes: 5),
    ) as Map<String, dynamic>;
    PairCode? history;
    try {
      if (canShareHistory &&
          payload['mode'] == 'local' &&
          payload['history'] != null) {
        history = _historyFrom(payload['history'], code);
      }
      await install(payload);
    } catch (_) {
      // The desktop can release its proposed history listener immediately.
      try {
        await code.request(
          '/confirm',
          body: {'installed': false},
          timeout: const Duration(seconds: 3),
        );
      } catch (_) {
        // The offer will expire if the desktop is no longer reachable.
      }
      rethrow;
    }
    try {
      await code.request('/confirm', body: {'installed': true});
      if (history != null) await _receiveHistory(history, _generation);
    } catch (_) {
      throw FormatException(
        history == null
            ? 'Setup saved on this phone. Windows could not confirm it.'
            : 'Accounts connected. Wi-Fi history pairing did not complete.',
      );
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
    final offer = _offer;
    _offer = null;
    offer?.decide(false);
    await server?.close(force: true);
    await offer?._history?.server.close(force: true);
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

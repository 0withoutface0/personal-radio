import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiFailure implements Exception {
  final int status;
  final String message;
  ApiFailure(this.status, this.message);
  @override
  String toString() => message;
}

String validateServer(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      !['http', 'https'].contains(uri.scheme)) {
    throw FormatException(
      'Enter the server origin, for example https://radio.your-tailnet.ts.net',
    );
  }
  final octets = uri.host.split('.').map(int.tryParse).toList();
  final tailscale =
      octets.length == 4 &&
      octets[0] == 100 &&
      octets[1] != null &&
      octets[1]! >= 64 &&
      octets[1]! <= 127 &&
      octets.every((v) => v != null && v >= 0 && v <= 255);
  if (uri.scheme == 'http' &&
      !['localhost', '127.0.0.1', '::1', '10.0.2.2'].contains(uri.host) &&
      !tailscale) {
    throw const FormatException(
      'Use HTTPS or your server’s Tailscale IP for remote connections.',
    );
  }
  return uri.toString().replaceFirst(RegExp(r'/$'), '');
}

class RadioApi {
  final String origin, token, deviceId;
  final http.Client _client;
  RadioApi(this.origin, this.token, this.deviceId, {http.Client? client})
    : _client = client ?? http.Client();
  Map<String, String> get headers => {
    'Authorization': 'Bearer $token',
    'X-Device-ID': deviceId,
  };
  Future<dynamic> call(
    String path, {
    Map<String, dynamic>? body,
    String method = 'POST',
  }) async {
    final request = http.Request(
      body == null && method == 'POST' ? 'GET' : method,
      Uri.parse('$origin$path'),
    );
    request.headers.addAll({...headers, 'Content-Type': 'application/json'});
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 45)),
    );
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw ApiFailure(
        response.statusCode,
        'The server returned an unreadable response.',
      );
    }
    if (response.statusCode >= 400) {
      final detail = data is Map ? data['detail'] : null;
      throw ApiFailure(
        response.statusCode,
        detail is String
            ? detail
            : 'The server could not complete this request.',
      );
    }
    return data;
  }

  void close() => _client.close();
}

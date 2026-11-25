import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import 'session_service.dart';

class HttpResult {
  final int status;
  final String text;
  final Uint8List? bytes;
  final Uri uri;
  final Map<String, String> headers;

  const HttpResult({
    required this.status,
    required this.text,
    required this.uri,
    this.bytes,
    this.headers = const {},
  });

  bool get ok => status >= 200 && status < 300;
}

/// Cliente HTTP con cookie jar por host y cabeceras de navegador.
///
/// Las rutas /lector/* devuelven 404 si faltan las cabeceras sec-fetch-* y
/// sec-ch-ua, así que se envían siempre en ese perfil.
class AedexHttp {
  static const String base = 'https://aedexnox.com';

  static const String ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36';

  static const Map<String, String> lectoHeaders = {
    'Accept': '*/*',
    'sec-ch-ua': '"Not(A:Brand";v="8", "Chromium";v="144"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Linux"',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-origin',
    'priority': 'u=1, i',
  };

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15);

  final Map<String, Map<String, String>> _jar = {};

  AedexHttp() {
    seedCookies('aedexnox.com', SessionService.cookies);
  }

  void seedCookies(String host, Map<String, String> values) {
    if (values.isEmpty) return;
    _jar.putIfAbsent(host, () => <String, String>{}).addAll(values);
  }

  String cookieHeaderFor(Uri uri) {
    final values = _jar[uri.host];
    if (values == null || values.isEmpty) return '';
    return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _absorb(Uri uri, HttpClientResponse response) {
    for (final cookie in response.cookies) {
      _jar.putIfAbsent(uri.host, () => <String, String>{})[cookie.name] =
          cookie.value;
    }
  }

  Map<String, String> _apiHeaders() {
    final headers = <String, String>{
      'System': 'aedex',
      'X-FK-Sistema': '1',
      'Accept': 'application/json',
    };
    final token = SessionService.accessToken;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<HttpResult> send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
    bool follow = true,
    bool keepBytes = false,
  }) async {
    Uri current = uri;
    String currentMethod = method;
    List<int>? currentBody = body;

    for (int attempt = 0; attempt < 7; attempt++) {
      final request = await _client.openUrl(currentMethod, current);
      request.followRedirects = false;
      request.headers.set('User-Agent', ua);
      request.headers.set('Accept-Language', 'es-ES,es;q=0.9');
      headers?.forEach((k, v) => request.headers.set(k, v));
      final cookie = cookieHeaderFor(current);
      if (cookie.isNotEmpty) request.headers.set('Cookie', cookie);
      if (currentBody != null) {
        request.contentLength = currentBody.length;
        request.add(currentBody);
      }

      final response =
          await request.close().timeout(const Duration(seconds: 60));
      _absorb(current, response);

      if (follow && _isRedirect(response.statusCode)) {
        final location = response.headers.value('location');
        await response.drain<void>();
        if (location == null || location.isEmpty) {
          return HttpResult(status: response.statusCode, text: '', uri: current);
        }
        current = current.resolve(location);
        if (response.statusCode == 303 ||
            (response.statusCode <= 302 && currentMethod != 'GET')) {
          currentMethod = 'GET';
          currentBody = null;
        }
        continue;
      }

      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(',');
      });

      if (keepBytes) {
        final chunks = await response.fold<List<int>>(
          <int>[],
          (previous, element) => previous..addAll(element),
        );
        return HttpResult(
          status: response.statusCode,
          text: '',
          uri: current,
          bytes: Uint8List.fromList(chunks),
          headers: responseHeaders,
        );
      }

      final text = await response.transform(utf8.decoder).join();
      return HttpResult(
        status: response.statusCode,
        text: text,
        uri: current,
        headers: responseHeaders,
      );
    }

    throw Exception('Demasiadas redirecciones');
  }

  bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  Future<HttpResult> get(
    Uri uri, {
    bool api = false,
    bool lector = false,
    bool keepBytes = false,
    Map<String, String>? headers,
  }) {
    final all = <String, String>{
      'Accept': lector ? '*/*' : 'text/html,application/xhtml+xml',
      ...?headers,
      if (lector) ...lectoHeaders,
      if (api) ..._apiHeaders(),
    };
    return send('GET', uri, headers: all, keepBytes: keepBytes);
  }

  Future<HttpResult> postJson(
    Uri uri,
    Map<String, dynamic> body, {
    bool api = false,
    bool lector = false,
    Map<String, String>? headers,
  }) {
    final all = <String, String>{
      'Content-Type': 'application/json',
      'Accept': lector ? '*/*' : 'application/json',
      ...?headers,
      if (lector) ...lectoHeaders,
      if (api) ..._apiHeaders(),
    };
    return send(
      'POST',
      uri,
      headers: all,
      body: utf8.encode(jsonEncode(body)),
    );
  }

  Future<HttpResult> postForm(
    Uri uri,
    String body, {
    Map<String, String>? headers,
    bool follow = true,
  }) {
    return send(
      'POST',
      uri,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'text/html',
        ...?headers,
      },
      body: utf8.encode(body),
      follow: follow,
    );
  }

  Map<String, String> exportCookies(String host) =>
      Map<String, String>.from(_jar[host] ?? const <String, String>{});
}

class CatalogPage {
  final List<SeriesItem> items;
  final int totalPages;

  const CatalogPage(this.items, this.totalPages);
}

class SystemInfo {
  final String capEndpoint;
  final String capSitekey;
  final String turnstileSitekey;

  const SystemInfo({
    required this.capEndpoint,
    required this.capSitekey,
    required this.turnstileSitekey,
  });
}

class AedexApi {
  static const String base = AedexHttp.base;

  final AedexHttp http;

  AedexApi([AedexHttp? client]) : http = client ?? AedexHttp();

  Future<HttpResult> _apiGet(Uri uri) async {
    var result = await http.get(uri, api: true);
    if (result.status == 401) {
      await SessionService.saveAccessToken(null);
      result = await http.get(uri, api: true);
    }
    return result;
  }

  Future<CatalogPage> catalog({int page = 1, int limit = 50}) async {
    final uri = Uri.parse('$base/api/backend/mangas').replace(
      queryParameters: {
        'page': '$page',
        'limit': '$limit',
        'sort': '-n_visitas',
      },
    );
    final result = await _apiGet(uri);
    if (!result.ok) {
      throw Exception('HTTP ${result.status} al cargar el catálogo');
    }
    final data = jsonDecode(result.text) as Map<String, dynamic>;
    final items = (data['data'] as List)
        .map((e) => SeriesItem.fromApi(Map<String, dynamic>.from(e as Map)))
        .toList();
    return CatalogPage(items, (data['total_pages'] as num?)?.toInt() ?? 1);
  }

  Future<List<ChapterItem>> chapters(String slug) async {
    final result = await _apiGet(Uri.parse('$base/api/backend/mangas/$slug'));
    if (!result.ok) {
      throw Exception('HTTP ${result.status} al cargar los capítulos');
    }
    final data = jsonDecode(result.text) as Map<String, dynamic>;
    final chapters = <ChapterItem>[];
    for (final raw in (data['capitulos'] as List? ?? const [])) {
      final map = Map<String, dynamic>.from(raw as Map);
      final estado = map['estado'];
      if (estado != null && estado != 'publicado') continue;
      chapters.add(ChapterItem.fromApi(map));
    }
    chapters.sort((a, b) => a.number.compareTo(b.number));
    return chapters;
  }

  Future<SystemInfo> system() async {
    final result = await _apiGet(Uri.parse('$base/api/backend/system'));
    if (!result.ok) throw Exception('HTTP ${result.status} en /system');
    final data = jsonDecode(result.text) as Map<String, dynamic>;
    return SystemInfo(
      capEndpoint: (data['cap_api_endpoint'] ?? '').toString(),
      capSitekey: (data['cap_sitekey'] ?? '').toString(),
      turnstileSitekey: (data['turnstile_sitekey'] ?? '').toString(),
    );
  }

  Future<String?> sessionToken() async {
    final result = await http.get(Uri.parse('$base/api/auth/session'));
    if (!result.ok) return null;
    try {
      final data = jsonDecode(result.text);
      if (data is! Map) return null;
      final user = data['user'];
      return (data['access_token'] ??
              data['accessToken'] ??
              (user is Map ? user['access_token'] : null) ??
              (user is Map ? user['accessToken'] : null))
          ?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Login completo desde Dart, sin WebView ni captcha.
  ///
  /// Primero visita /auth/login para que el sitio deje sus cookies; con ellas
  /// el POST de credenciales no pide Turnstile y solo hay que mandar un
  /// User-Agent de navegador normal (el que trae [AedexHttp.ua]).
  Future<String> loginDirect({
    required String email,
    required String password,
  }) async {
    await http.get(Uri.parse('$base/auth/login'));
    final csrfToken = await csrf();
    return login(
      email: email,
      password: password,
      csrfToken: csrfToken,
      turnstileToken: '',
    );
  }

  Future<String> csrf() async {
    final result = await http.get(
      Uri.parse('$base/api/auth/csrf'),
      headers: {'Accept': 'application/json'},
    );
    if (!result.ok) throw Exception('HTTP ${result.status} en csrf');
    final data = jsonDecode(result.text) as Map<String, dynamic>;
    final token = (data['csrfToken'] ?? '').toString();
    if (token.isEmpty) throw Exception('El sitio no devolvió el CSRF');
    return token;
  }

  /// Login NextAuth desde Dart: la verificación de Turnstile se resuelve en un
  /// WebView, pero el POST de credenciales no sale del WebView, así que el
  /// sitio no lo rechaza por X-Requested-With.
  Future<String> login({
    required String email,
    required String password,
    required String csrfToken,
    required String turnstileToken,
  }) async {
    final fields = <String, String>{
      'csrfToken': csrfToken,
      'callbackUrl': '$base/',
      'username': email.trim().toLowerCase(),
      'password': password,
      'turnstileToken': turnstileToken,
    };
    final body = fields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    final result = await http.postForm(
      Uri.parse('$base/api/auth/callback/credentials'),
      body,
      follow: false,
      headers: {
        'Accept': 'text/html,application/xhtml+xml',
        'Origin': base,
        'Referer': '$base/auth/login',
        'Upgrade-Insecure-Requests': '1',
        'sec-fetch-site': 'same-origin',
        'sec-fetch-mode': 'navigate',
        'sec-fetch-dest': 'document',
      },
    );

    final location = result.headers['location'] ?? '';
    final errorMatch = RegExp(r'[?&]error=([^&]+)').firstMatch(location);
    if (errorMatch != null) {
      final code = Uri.decodeQueryComponent(errorMatch.group(1)!);
      throw Exception(_loginError(code));
    }
    if (result.status != 302 && result.status != 303) {
      if (result.status == 200 && result.text.contains('error=')) {
        throw Exception(
          'No se pudo iniciar sesión. Revisa los datos o la verificación.',
        );
      }
      throw Exception('Login HTTP ${result.status}');
    }
    if (location.contains('/auth/verify')) {
      throw Exception('Verifica tu correo en la web de Aedex antes de continuar.');
    }

    final token = await sessionToken();
    if (token == null || token.isEmpty) {
      throw Exception('El sitio no devolvió el token de sesión.');
    }
    return token;
  }

  String _loginError(String code) {
    switch (code) {
      case 'CredentialsSignin':
        return 'Correo o contraseña incorrectos.';
      case 'EmailNotVerified':
        return 'Verifica tu correo en la web de Aedex antes de continuar.';
      case 'WebViewNotAllowed':
        return 'El sitio rechazó el inicio de sesión. Repite la verificación.';
      case 'TurnstileFailed':
        return 'La verificación de Cloudflare falló. Repítela.';
      default:
        return 'No se pudo iniciar sesión ($code).';
    }
  }

  static String coverUrl(String path) {
    if (path.startsWith('http')) return path;
    if (path.startsWith('/assets/')) return '$base$path';
    return '$base/assets/$path';
  }
}

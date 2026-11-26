import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import 'browser_ua.dart';
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

  /// El lector del sitio manda el access_token como Bearer; con cookies solas
  /// sigue contando como invitado y corta a los 3 capítulos.
  Map<String, String> _bearerHeader() {
    final token = SessionService.accessToken;
    if (token == null || token.isEmpty) return const {};
    return {'Authorization': 'Bearer $token'};
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
    String? userAgent,
  }) async {
    Uri current = uri;
    String currentMethod = method;
    List<int>? currentBody = body;

    for (int attempt = 0; attempt < 7; attempt++) {
      final request = await _client.openUrl(currentMethod, current);
      request.followRedirects = false;
      request.headers.set('User-Agent', userAgent ?? ua);
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
      if (lector) ..._bearerHeader(),
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
      if (lector) ..._bearerHeader(),
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
    String? userAgent,
  }) {
    return send(
      'POST',
      uri,
      userAgent: userAgent,
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

  /// Obtiene el access_token de la sesión NextAuth.
  ///
  /// Retorna null si la sesión existe pero no incluye access_token;
  /// en ese caso la autenticación se hace via cookie de sesión.
  Future<String?> sessionToken() async {
    final result = await http.get(
      Uri.parse('$base/api/auth/session'),
      headers: {'Accept': 'application/json'},
    );
    // ignore: avoid_print
    print('[LOGIN] sessionToken HTTP ${result.status}: ${result.text}');
    if (!result.ok) return null;
    try {
      final data = jsonDecode(result.text);
      if (data is Map && data.isNotEmpty) {
        final user = data['user'];
        return (data['access_token'] ??
                data['accessToken'] ??
                (user is Map ? user['access_token'] : null) ??
                (user is Map ? user['accessToken'] : null))
            ?.toString();
      }
    } catch (_) {}
    return null;
  }

  /// Devuelve el access_token guardado y, si no hay, lo pide a /api/auth/session
  /// con las cookies de la sesión. Lo guarda cuando lo consigue.
  Future<String?> ensureAccessToken() async {
    final saved = SessionService.accessToken;
    if (saved != null && saved.isNotEmpty) return saved;
    final fresh = await sessionToken();
    if (fresh != null && fresh.isNotEmpty) {
      await SessionService.saveAccessToken(fresh);
      return fresh;
    }
    return null;
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
    String? userAgent,
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

    final ua = userAgent ?? AedexHttp.ua;
    final result = await http.postForm(
      Uri.parse('$base/api/auth/callback/credentials'),
      body,
      follow: false,
      userAgent: ua,
      headers: {
        'Accept': '*/*',
        'Origin': base,
        'Referer': '$base/auth/login',
        'sec-fetch-site': 'same-origin',
        'sec-fetch-mode': 'cors',
        'sec-fetch-dest': 'empty',
        ...BrowserUa.mobileHints(ua),
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
    // Si la redirección va fuera del sitio (p.ej. a Cloudflare), no hay sesión.
    if (location.isNotEmpty &&
        !location.startsWith('/') &&
        !location.startsWith(base)) {
      throw Exception(
        'El inicio de sesión fue bloqueado (redirigido a: '
        '${location.length > 80 ? location.substring(0, 80) : location})',
      );
    }
    if (location.contains('/auth/verify')) {
      throw Exception('Verifica tu correo en la web de Aedex antes de continuar.');
    }

    // El access_token puede no estar en la sesión NextAuth si el sitio usa
    // auth por cookie de sesión para el backend. Se devuelve '' en ese caso;
    // las cookies guardadas son el mecanismo de autenticación real.
    final sessionAccess = await sessionToken();
    if (sessionAccess != null && sessionAccess.isNotEmpty) return sessionAccess;

    // Intento alternativo: obtener el token directamente del backend.
    // Funciona cuando el servidor expone un endpoint de autenticación propio.
    final backendToken = await _backendLogin(
      email: email.trim().toLowerCase(),
      password: password,
      turnstileToken: turnstileToken,
      ua: ua,
    );
    return backendToken ?? '';
  }

  /// Llama directamente al endpoint de login del backend (/api/backend/auth/login).
  /// Si tiene éxito devuelve el JWT; si falla devuelve null sin lanzar.
  Future<String?> _backendLogin({
    required String email,
    required String password,
    required String turnstileToken,
    required String ua,
  }) async {
    try {
      final result = await http.postJson(
        Uri.parse('$base/api/backend/auth/login'),
        {
          'email': email,
          'password': password,
          'turnstileToken': turnstileToken,
        },
        headers: {
          'Origin': base,
          'Referer': '$base/auth/login',
          ...BrowserUa.mobileHints(ua),
        },
      );
      final snippet =
          result.text.length > 200 ? result.text.substring(0, 200) : result.text;
      // ignore: avoid_print
      print('[LOGIN] backendLogin HTTP ${result.status}: $snippet');
      if (!result.ok) return null;
      final data = jsonDecode(result.text);
      if (data is! Map) return null;
      return (data['token'] ??
              data['access_token'] ??
              data['accessToken'] ??
              data['jwt'])
          ?.toString();
    } catch (e) {
      // ignore: avoid_print
      print('[LOGIN] backendLogin error: $e');
      return null;
    }
  }

  String _loginError(String code) {
    switch (code) {
      case 'CredentialsSignin':
        return 'Correo o contraseña incorrectos.';
      case 'EmailNotVerified':
        return 'Verifica tu correo en la web de Aedex antes de continuar.';
      case 'WebViewNotAllowed':
        return 'El sitio rechazó la petición (WebViewNotAllowed).';
      case 'TurnstileFailed':
        return 'La verificación de Cloudflare falló (TurnstileFailed).';
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

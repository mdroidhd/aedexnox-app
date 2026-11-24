import 'package:hive_flutter/hive_flutter.dart';

/// Cookies de la sesión de Aedexnox y token de acceso.
///
/// El login se hace en un WebView; al terminar se guardan aquí las cookies
/// (incluidas las HttpOnly) para que el cliente HTTP directo las use.
class SessionService {
  static late Box _box;

  static Future<void> init() async {
    _box = await Hive.openBox('session');
  }

  static Map<String, String> get cookies {
    final raw = _box.get('cookies');
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return <String, String>{};
  }

  static String? get accessToken {
    final v = _box.get('accessToken');
    return v == null ? null : v.toString();
  }

  static bool get isLoggedIn =>
      cookies.keys.any((name) => name.toLowerCase().contains('session-token'));

  static Future<void> saveCookies(Map<String, String> values) async {
    await _box.put('cookies', values);
  }

  static Future<void> saveAccessToken(String? token) async {
    if (token == null || token.isEmpty) {
      await _box.delete('accessToken');
    } else {
      await _box.put('accessToken', token);
    }
  }

  static Future<void> clear() async {
    await _box.delete('cookies');
    await _box.delete('accessToken');
  }
}

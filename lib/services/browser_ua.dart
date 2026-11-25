import 'dart:io' show Platform;

/// User-Agent del WebView sin los marcadores que el sitio rechaza.
class BrowserUa {
  static const String fallbackAndroid =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static const String fallbackIos =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  static String get fallback =>
      Platform.isAndroid ? fallbackAndroid : fallbackIos;

  /// Quita `; wv` y `Version/4.0` del UA nativo del WebView.
  static String clean(String raw) {
    if (raw.isEmpty) return fallback;
    var ua = raw
        .replaceAll(RegExp(r';\s*wv\b'), '')
        .replaceAll(RegExp(r'\bVersion/4\.0\s+'), '');
    if (RegExp(r';\s*wv\b|Version/4\.0|Android WebView', caseSensitive: false)
        .hasMatch(ua)) {
      return fallback;
    }
    return ua;
  }

  /// Versión completa de Chrome que aparece en el UA.
  static String chromeVersion(String ua) {
    final m = RegExp(r'Chrome/([0-9][0-9.]*)').firstMatch(ua);
    final v = m?.group(1) ?? '131.0.0.0';
    return v.split('.').length >= 3 ? v : '$v.0.0.0';
  }

  /// Client hints de Chrome móvil (sin la marca "Android WebView").
  static Map<String, String> mobileHints(String ua) {
    final full = chromeVersion(ua);
    final major = full.split('.').first;
    return {
      'sec-ch-ua':
          '"Chromium";v="$major", "Google Chrome";v="$major", "Not-A.Brand";v="99"',
      'sec-ch-ua-mobile': '?1',
      'sec-ch-ua-platform': '"Android"',
    };
  }
}

import 'dart:convert';

/// Parches JS para que la página no detecte el WebView como navegador
/// integrado: UA coherente, marcas de Chrome en vez de "Android WebView",
/// `window.chrome`, `webdriver` y sin `X-Requested-With`.
class WebViewSpoof {
  static const String capture = r'''
(() => {
  try {
    const d = navigator.userAgentData;
    return JSON.stringify({
      ua: navigator.userAgent || '',
      brands: d ? d.brands : [],
      mobile: d ? !!d.mobile : false,
      platform: d ? d.platform : ''
    });
  } catch(e) { return '{}'; }
})();
''';

  static String script(String ua, Map<String, dynamic> uaCh) {
    final rawBrands = (uaCh['brands'] as List? ?? const []);
    final brands = rawBrands.map<Map<String, String>>((b) {
      final brand = (b['brand'] ?? '') as String;
      final version = (b['version'] ?? '') as String;
      final isWebView = brand.toLowerCase().contains('webview');
      return {'brand': isWebView ? 'Google Chrome' : brand, 'version': version};
    }).toList();
    if (brands.isEmpty) {
      brands.addAll(const [
        {'brand': 'Chromium', 'version': '131'},
        {'brand': 'Google Chrome', 'version': '131'},
        {'brand': 'Not-A.Brand', 'version': '99'},
      ]);
    }
    final mobile = uaCh['mobile'] ?? true;
    final platform = uaCh['platform'] ?? 'Android';

    return '''
(() => {
  const UA = ${jsonEncode(ua)};
  const BRANDS = ${jsonEncode(brands)};
  const MOBILE = ${jsonEncode(mobile)};
  const PLATFORM = ${jsonEncode(platform)};

  const define = (obj, prop, value) => {
    try { Object.defineProperty(obj, prop, { get: () => value, configurable: true }); } catch(e) {}
  };

  define(Navigator.prototype, 'userAgent', UA);
  define(navigator, 'userAgent', UA);

  try {
    const real = navigator.userAgentData;
    if (real) {
      const patched = Object.create(real);
      Object.defineProperty(patched, 'brands',   { get: () => BRANDS,   configurable: true });
      Object.defineProperty(patched, 'mobile',   { get: () => MOBILE,   configurable: true });
      Object.defineProperty(patched, 'platform', { get: () => PLATFORM, configurable: true });
      const origHigh = real.getHighEntropyValues ? real.getHighEntropyValues.bind(real) : null;
      if (origHigh) {
        Object.defineProperty(patched, 'getHighEntropyValues', {
          configurable: true,
          value: async (hints) => {
            const r = await origHigh(hints);
            if (r) {
              if (Array.isArray(r.brands)) r.brands = BRANDS;
              if (Array.isArray(r.fullVersionList)) {
                r.fullVersionList = r.fullVersionList.map(b =>
                  b.brand.toLowerCase().includes('webview')
                    ? { brand: 'Google Chrome', version: b.version }
                    : b
                );
              }
            }
            return r;
          }
        });
      }
      define(Navigator.prototype, 'userAgentData', patched);
      define(navigator, 'userAgentData', patched);
    }
  } catch(e) {}

  try {
    if (typeof window.chrome === 'undefined') {
      window.chrome = { runtime: {}, loadTimes: () => {}, csi: () => {}, app: {} };
    }
  } catch(e) {}

  define(Navigator.prototype, 'webdriver', false);

  // Sin X-Requested-With (el JS de la web lo añade con axios/fetch).
  try {
    const drop = (headers) => {
      if (!headers) return;
      if (headers instanceof Headers) {
        headers.delete('X-Requested-With');
      } else if (Array.isArray(headers)) {
        for (let i = headers.length - 1; i >= 0; i--) {
          if (String(headers[i][0]).toLowerCase() === 'x-requested-with') headers.splice(i, 1);
        }
      } else {
        for (const key of Object.keys(headers)) {
          if (key.toLowerCase() === 'x-requested-with') delete headers[key];
        }
      }
    };
    const origFetch = window.fetch;
    window.fetch = function(input, init) {
      try { if (init) drop(init.headers); } catch(e) {}
      return origFetch.call(window, input, init);
    };
    const origSet = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
      if (String(name).toLowerCase() === 'x-requested-with') return;
      return origSet.call(this, name, value);
    };
  } catch(e) {}
})();
''';
  }
}

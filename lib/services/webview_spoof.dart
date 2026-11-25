
/// Parche JS mínimo para que la guardia anti-WebView de la web no bloquee la
/// página, sin falsear el navegador (falsearlo rompe Cloudflare Turnstile).
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

  /// Parche mínimo: la guardia de la web se sale por arriba si la página se
  /// cree instalada (display-mode standalone), así que no hace falta falsear
  /// el navegador. Falsear `userAgentData` rompía Cloudflare Turnstile porque
  /// las marcas de JS dejaban de coincidir con la cabecera `sec-ch-ua`.
  static String script(String ua, Map<String, dynamic> uaCh) {
    return '''
(() => {
  // La guardia hace: if (matchMedia('(display-mode: standalone)').matches) return;
  try {
    const orig = window.matchMedia;
    window.matchMedia = function(q) {
      const r = orig.call(window, q);
      try {
        if (String(q).indexOf('display-mode: standalone') !== -1) {
          Object.defineProperty(r, 'matches', { get: () => true, configurable: true });
        }
      } catch (e) {}
      return r;
    };
  } catch (e) {}

  try { Object.defineProperty(navigator, 'standalone', { get: () => true, configurable: true }); } catch (e) {}

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
      try { if (init) drop(init.headers); } catch (e) {}
      return origFetch.call(window, input, init);
    };
    const origSet = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
      if (String(name).toLowerCase() === 'x-requested-with') return;
      return origSet.call(this, name, value);
    };
  } catch (e) {}
})();
''';
  }
}

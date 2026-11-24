# Aedexnox App

App Flutter (Android/iOS) para navegar el catálogo de **aedexnox.com**, ver portadas, abrir capítulos y **leerlos en vertical desde el móvil**, con las páginas guardadas en local.

El downloader ya **no usa el WebView del lector**: habla directamente con la API y el protocolo firmado del sitio. El WebView queda solo para el login.

## Qué hace

- **Catálogo** por la API interna (`/api/backend/mangas`), con portadas, buscador y paginación.
- **Capítulos** por `/api/backend/mangas/<slug>`.
- **Descarga directa**: resuelve el Cap proof-of-work, firma las llamadas del lector, obtiene las páginas y las descifra/desordena en Dart.
- **Lector vertical** con las imágenes ya guardadas, sin conexión.
- **Caché** en Hive para catálogo/capítulos y archivos PNG para las páginas.
- **Login** en un WebView parcheado para saltar el bloqueo de WebViews del sitio.

## Requisitos

- Flutter 3.32 o superior (Dart 3.8+).
- Android 5.0+ / iOS 12+.

## Puesta en marcha

```bash
git clone https://github.com/mdroidhd/aedexnox-app.git
cd aedexnox-app

# Genera android/ e ios/ (no sobrescribe el código de lib/)
flutter create --platforms=android,ios --project-name aedexnox_app .

flutter pub get
flutter run
```

O usa `./setup.sh`.

## Nota sobre Android / AGP

La versión estable de `flutter_inappwebview` (6.1.5) falla con AGP 8.9+ porque usa
`proguard-android.txt`. Este proyecto usa `6.2.0-beta.3`, que ya trae
`proguard-android-optimize.txt` y el arreglo para AGP 9.

## Cómo funciona la descarga

1. **Catálogo/capítulos**: API `/api/backend` con `System: aedex` y `X-FK-Sistema: 1`.
2. **Ficha del capítulo**: de `#aedex-reader-vault` salen `data-t` y `data-s`; con ellos se deriva el firmante `ax`.
3. **Pase de lector**: se resuelve el **Cap proof-of-work** de `/api/backend/system` (FNV-1a + xorshift32 + SHA-256), se canjea y se pide `/lector/pase` → cookie `ax_rp`.
4. **Apertura**: `POST /lector/capitulo` con una clave ECDSA P-256 (`X-Catharsis-Ws-Pub`) y los headers `ax-build`/`ax-sig`.
5. **Cuenta atrás**: WebSocket `/ws/free-reader`; cada reto se firma con la clave ECDSA (raw r||s) y al final llega `redirect_url` + `redirect_data`.
6. **Lector**: se hace el POST al ad-gate y se lee el HTML; de ahí salen `data-seed` y `window.readerContext` (`t`, `h`, `now`, `pages`). Se deriva el firmante `bv`.
7. **Token de vida**: `POST /lector/<vivo>/` con `{h}`; dura 45 s y se renueva.
8. **Páginas**: `GET /lector/p/<handle>/?q=hq` con `bv-build`, `bv-sig` y `bv-live`.
9. **Imagen**: el sitio añade un **trailer** al final con la clave real, el XOR y el gutter, enmascarado con `sha256(t:m0:handle)` y `sha256(t:m1:handle)`. Se desenmascara, se aplica XOR y se reconstruye el mosaico 8×8 con el PRNG mulberry32 (semilla = hash Java de la clave).
10. Se guarda como PNG y se apunta en Hive.

Las páginas quedan a resolución completa (1128×1600) y sin el recorte `?hp=1` que daba el sitio.

## Login

El sitio bloquea WebViews con el chunk `6800-*.js`:

- UA con `; wv` o `Version/4.0 ... Chrome`.
- UA-CH con marca "Google Chrome" y `window.chrome` indefinido.

La pantalla de login usa un UA de Chrome móvil sin `wv`, define `window.chrome` antes de que corra el JS del sitio y quita `X-Requested-With` de `fetch`/XHR. Al pulsar **Listo**, guarda las cookies (incluidas HttpOnly) y pide `/api/auth/session` para el token.

Con sesión, el límite de 3 capítulos desaparece. El pase `ax_rp` sigue siendo por IP y se resuelve igual.

Si el sitio cambia el bloqueo o rechaza el login del WebView, la app sigue funcionando como invitado para los 3 primeros capítulos.

## Estructura

```
lib/
  main.dart
  models/
    series_item.dart
    chapter_item.dart
  services/
    aedex_api.dart        HTTP, cookies, API y /system
    reader_service.dart   Cap, ECDSA, WebSocket, trailer y mosaico
    download_service.dart Orquesta la descarga de un capítulo
    cache_service.dart    Hive + archivos
    session_service.dart  Cookies y token
  screens/
    home_screen.dart
    series_screen.dart
    download_screen.dart
    login_screen.dart
    reader_screen.dart
  widgets/
    series_card.dart
```

## Límites conocidos

- **Invitado**: 3 capítulos. Con cuenta gratuita se quita el límite.
- **Cloudflare/Cap**: el Cap es proof-of-work y se resuelve en código; si el sitio lo cambia, habrá que ajustar `CapSolver`.
- **Marcas de agua**: las páginas llevan la marca tenue del lector (IP + `guest`).
- **Cambios del sitio**: si cambian el trailer o el mosaico, hay que ajustar `PageCrypto`.
- **WebView**: si el login sigue rechazándose, el bloqueo es del lado servidor y haría falta un WebView nativo con el header `X-Requested-With` stripping.

## Aviso

Herramienta personal para leer contenido al que ya tienes acceso. Respeta las condiciones del sitio y los derechos de autor.

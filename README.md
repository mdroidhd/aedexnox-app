# Aedexnox App

App Flutter (Android/iOS) para navegar el catálogo de **aedexnox.com**, ver las portadas, abrir la lista de capítulos y **leer los capítulos completos en vertical desde el móvil**, con las páginas guardadas en local.

> Código listo para compilar. No incluye las carpetas `android/` ni `ios/`; se generan con `flutter create`.

## Qué hace

- **Catálogo**: lee `/comics` y muestra las series en una cuadrícula con portada, título y buscador local.
- **Ficha de serie**: lista los capítulos (incluidos los decimales tipo `8.5`).
- **Descarga de capítulo**: abre un `WebView` en la página del capítulo, deja que el lector monte el canvas y extrae cada página a un WebP local.
- **Lector vertical**: muestra las páginas guardadas con scroll vertical, sin volver a pedir nada a la web.
- **Caché**: Hive para catálogo/capítulos y archivos en el directorio privado de la app para las imágenes.
- **Anti-baneo**: pausa entre peticiones, catálogo y capítulos cacheados, y las páginas solo se piden una vez.

## Requisitos

- Flutter 3.22 o superior (Dart 3.3+).
- Android 5.0+ / iOS 12+.
- Conexión a internet solo para la primera carga del catálogo y para descargar capítulos nuevos.

## Puesta en marcha

```bash
git clone https://github.com/mdroidhd/aedexnox-app.git
cd aedexnox-app

# Genera android/ e ios/ (no sobrescribe el código de lib/)
flutter create --platforms=android,ios --project-name aedexnox_app .

flutter pub get
flutter run
```

Si `flutter create` se queja porque la carpeta no está vacía, ignóralo: solo crea lo que falta. Si sobrescribe `pubspec.yaml` o `lib/`, recupera los archivos del repo:

```bash
git checkout -- pubspec.yaml lib
flutter pub get
```

## Uso

1. Abre la app. La primera vez descarga el catálogo (puede tardar unos segundos).
2. Toca una serie para ver sus capítulos.
3. Toca un capítulo sin descargar. Se abre el lector en un WebView.
4. Si aparece **"Verificación anti-bot"**, toca la casilla de Cloudflare en la página. Es la única interacción manual; después la app extrae las páginas sola.
5. Cuando termina, se abre el lector vertical con las imágenes ya guardadas.
6. Los capítulos descargados aparecen con el icono rojo y se pueden leer sin conexión.

## Estructura

```
lib/
  main.dart                 Arranque + tema
  models/
    series_item.dart
    chapter_item.dart
  services/
    aedex_client.dart       Catálogo y capítulos por HTTP
    cache_service.dart      Hive + archivos locales
  screens/
    home_screen.dart        Cuadrícula del catálogo
    series_screen.dart      Ficha y capítulos
    download_screen.dart    WebView + extracción de canvas
    reader_screen.dart      Lectura vertical offline
  widgets/
    series_card.dart
```

## Cómo funciona la extracción

El lector de la web no expone imágenes normales: monta cada página en un `<canvas>` y las protege con detección de devtools y trampas de copia.

La app:

1. Inyecta un script al inicio del documento que neutraliza los detectores basados en consola.
2. Espera a que existan los `canvas.manga-page-canvas`.
3. Hace scroll para que se carguen las páginas perezosas.
4. Por cada canvas, dibuja en un canvas nuevo y lo exporta como WebP.
5. Envía el base64 a Flutter por trozos y lo guarda en disco.

No usa las imágenes `?hp=1` del precargador: esas son versiones recortadas/degradadas (media página) y se ven cortadas.

## Límites conocidos

- **Invitado**: la web solo deja leer los **3 primeros capítulos**. Del 4 en adelante pide cuenta; la app mostrará que no hay páginas.
- **Cloudflare**: si la verificación no aparece o no pasa, prueba a abrir la página en el WebView y resolverla a mano.
- **Marcas de agua**: las páginas llevan una marca tenue del lector con IP y `guest`. Es del propio sitio.
- **Cambios del sitio**: si aedexnox cambia el lector (nombres de clases, canvas o verificación), habrá que ajustar `_initScript` y la consulta de `canvas.manga-page-canvas`.

## Aviso

Este proyecto es una herramienta personal para leer contenido al que ya tienes acceso. Respeta las condiciones del sitio y los derechos de autor. No lo uses para redistribuir contenido.

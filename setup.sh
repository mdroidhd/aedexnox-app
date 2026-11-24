#!/usr/bin/env bash
set -e

# Genera las carpetas de Android/iOS que no están en el repo.
flutter create --platforms=android,ios --project-name aedexnox_app .

# Por si flutter create tocó archivos nuestros.
git checkout -- pubspec.yaml lib 2>/dev/null || true

flutter pub get

echo ""
echo "Listo. Conecta el móvil y ejecuta: flutter run"

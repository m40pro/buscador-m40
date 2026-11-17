#!/bin/bash
# Compila "Buscador M40.app" en esta misma carpeta y la abre.
# Uso: abre Terminal, escribe "bash " y arrastra este archivo a la ventana.
cd "$(dirname "$0")" || exit 1
APP="Buscador M40.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Faltan las herramientas de línea de comandos de Apple."
  echo "Acepta la instalación en la ventana que aparece y vuelve a ejecutar este archivo al terminar."
  xcode-select --install
  exit 1
fi

echo "Compilando Buscador M40…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if ! xcrun swiftc -swift-version 5 -parse-as-library -O -o "$APP/Contents/MacOS/BuscadorM40" fuente/main.swift; then
  echo "Error de compilación."
  exit 1
fi
codesign --force -s - "$APP"
echo "Listo: $APP"
open "$APP"

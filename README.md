# Webcam Control

Control de webcams USB (UVC) en macOS sin drivers: exposición, balance de blancos, ganancia, brillo, contraste, gamma, nitidez, saturación, contraluz y frecuencia de línea. Habla directo con la cámara por IOKit, así que funciona con cualquier cámara UVC y aplica los cambios aunque otra app (Zoom, OBS, QuickTime) la esté usando.

Incluye dos herramientas que comparten el mismo motor:

- **`app/`** — app SwiftUI con preview en vivo, sliders, toggles auto/manual y perfiles por cámara.
- **`cli/`** — `uvcctl`, herramienta de línea de comandos para scripts y diagnóstico.

Probado con una UGREEN Camera 2K (chip Sonix, `0c45:636f`).

## Por qué IOKit

AVFoundation casi no expone los controles de cámaras USB externas en macOS, y el driver UVC del sistema reclama la interfaz VideoControl en exclusiva. El motor abre el *dispositivo* (`USBDeviceOpen`) y manda los control requests UVC (`GET_CUR`, `GET_MIN`, `GET_MAX`, `SET_CUR`…) por el endpoint 0 con `DeviceRequest`; si eso falla, intenta la interfaz como respaldo. Los IDs del Camera Terminal y Processing Unit, y qué controles soporta la cámara, se leen del descriptor de configuración.

## App

```bash
cd app
chmod +x build.sh
./build.sh          # compila, genera "Webcam Control.app" y la abre
```

Requiere Xcode Command Line Tools (`xcode-select --install`) y macOS 14+. Si pones un `icon.png` (1024×1024) junto a los fuentes, el script lo convierte a `.icns` y lo usa como icono.

- Los sliders con toggle **Auto** (exposición, balance de blancos) se desactivan mientras el modo automático está activo; moverlos lo apaga.
- La exposición usa slider logarítmico y se muestra en ms (unidades UVC de 100 µs).
- **Guardar** crea un perfil con nombre; **Aplicar al conectar** guarda los valores actuales como perfil que se aplica cada vez que la app detecta esa cámara (macOS resetea los ajustes al reconectar).
- Para instalarla: arrastra `Webcam Control.app` a `/Applications`.

## CLI

```bash
cd cli
swiftc -O uvcctl.swift -o uvcctl

./uvcctl list                 # cámaras UVC detectadas
./uvcctl info                 # controles soportados, rangos y valor actual
./uvcctl get exposure
./uvcctl set exposure 500     # pasa exposure-auto a manual automáticamente
./uvcctl set white-balance 3200
./uvcctl set exposure-auto 8  # regresa a auto
./uvcctl controls             # nombres de controles y ayuda
./uvcctl info -d 1            # segunda cámara
```

## Notas

- La app se firma ad‑hoc; en otra Mac hay que abrirla con clic derecho → Abrir la primera vez.
- Escribir un valor manual mientras su modo auto está activo provoca un *stall* (`0xe000404f`); por eso el orden de aplicación es: autos → manual, valores, autos.
- Los perfiles se guardan en `UserDefaults` bajo `profiles-<vid>:<pid>`.
- `app/UVC.swift` es el mismo motor que `cli/uvcctl.swift` sin la parte de línea de comandos.

## Licencia

MIT.

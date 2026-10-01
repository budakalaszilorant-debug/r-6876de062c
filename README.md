# Subaru Impreza OBD2 társ

ESP32 + ELM327 modul az OBD2 porton, és egy iPhone app, ami Bluetooth-on olvassa az adatokat.
A rendszer csak olvas: az autónak semmilyen parancsot nem küld, és az appból sem lehet küldeni.

## Mappák

| Mappa | Tartalom |
|---|---|
| `esp32-firmware/` | ESP32 firmware (PlatformIO). OBD2 lekérdezés, BLE adás. |
| `ios-app/` | iPhone app (SwiftUI) és widget. A projektfájlt az XcodeGen generálja. |
| `.github/workflows/` | Felhős fordítás GitHubon, Mac nélkül. |

## Firmware

Bekötés (a `src/main.cpp` elején is szerepel):

- OBD2 16-os láb (+12 V) → step-down (5 V) → ESP32 VIN és ELM327 VCC
- OBD2 4/5-ös láb → közös GND
- ELM327 TX → feszültségosztó (5 V → 3,3 V) → ESP32 GPIO16
- ESP32 GPIO17 → ELM327 RX

Fordítás és feltöltés:

```
pip install platformio
cd esp32-firmware
pio run -t upload
pio device monitor
```

A soros monitoron (115200 baud) látszik, hogy az adapter válaszol-e, milyen protokollt talált,
és a kiküldött JSON csomag.

Értelmező tesztek hardver nélkül (ELM327 válaszok, hibakódok, VIN, csak-olvasás lista):

```
sh esp32-firmware/test/host/run.sh
```

## iOS app

Mac-en:

```
brew install xcodegen
cd ios-app
xcodegen generate
open SubaruCompanion.xcodeproj
```

Xcode-ban mindkét targetnél (SubaruCompanion, SubaruWidget) állítsd be a saját Team-edet a
Signing & Capabilities fülön, majd futtasd a telefonra.

Autó nélkül: Beállítások → Demo mód. Szimulált hidegindítást, bemelegedést és menetet ad.

## Hibakeresés az autóban

Az app Beállítások → Diagnosztika része megmutatja:

- jönnek-e csomagok az ESP32-ről (Fogadott csomagok nő),
- válaszol-e az ELM327 adapter az ESP32-nek,
- válaszol-e a motorvezérlő (gyújtás nélkül nem fog).

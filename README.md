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
# Kétautós Garázs

A Beállítások → Garázs alatt külön profil tartozik a 2008-as Ford Fiesta 1.4 benzineshez
(59 kW, 1388 cm³) és az Opel Combo D 1.6 dízelhez (88 kW, 1598 cm³).
A név, VIN, üzemanyag, óraállás, tankméret és kijelzési küszöbök szerkeszthetők;
új autó is hozzáadható. Az utak, tankolások, hibakódok, akkumulátoradatok, parkolóhelyek,
szerviztételek és lejáratok autónként külön tárolódnak.

- Első kapcsolatkor válaszd ki a csatlakoztatott autót. Ezután az ismert VIN alapján
  automatikusan vált. VIN nélkül minden új Bluetooth-kapcsolatnál választani kell.
- Valós kapcsolat közben kézi autóváltás és adat-visszaállítás nem elérhető.
- A szervizterv a Garázsban külön szerkeszthető, a csere rögzítése nélkül is.
  Az új Ford/Opel profilok km-intervallumai beállításra várnak: az app nem állítja,
  hogy a sablon gyári szervizelőírás. Az évjárat és motorkód szerinti szervizkönyvet használd.
- Dízel esetén a pillanatnyi fogyasztás csak az ECU közvetlen üzemanyagáram-adatából
  jelenik meg, ha támogatott. A tankolási napló ettől függetlenül használható.
- A régi adatokat a frissítés külön korábbi profilban őrzi meg. Az új mentés az összes
  autót tartalmazza, hibás importnál az adatbázis változatlan marad.
- Frissítsd az ESP32 firmware-t is: a modul új kapcsolatkor újra kiolvassa a VIN-t,
  és nem használja egy korábbi autó elmentett VIN-jét.

Ellenőrzések: `sh ios-app/Tests/Garage/run.sh` macOS alatt a tényleges tároló- és
migrációs kódot ellenőrzi. A GitHub Actions ezen felül szimulátorra és telefonra is fordít.

# Bolti Bluetooth LE OBD dugó (ESP32 nélkül)

Az app közvetlenül is tud beszélni egy bolti, ELM327-kompatibilis **Bluetooth LE** dugóval
(pl. Vgate iCar Pro BLE / Bluetooth 4.0). Ilyenkor nem kell ESP32 és firmware: a lekérdezést
maga az app végzi, ugyanazzal a csak-olvasás szűrővel (`ios-app/SubaruCompanion/Core/ElmParser.swift`).

- Dugd be a dugót az OBD2 csatlakozóba, add rá a gyújtást, nyisd meg az appot.
- A telefon Bluetooth beállításaiban **ne** párosítsd; az app magától megtalálja.
- Az első csatlakozás után az app megjegyzi a dugót, legközelebb magától csatlakozik.
- Beállítások → Diagnosztika: látszik, melyik eszköz csatlakozott, és ott lehet elfelejteni.

Dugóval nem érhető el: az állás közbeni (éjszakai) akkufeszültség és a rejtett fogyasztó figyelés,
mert a dugó parkoláskor alszik. Az indításkori feszültségesés csak akkor mérhető, ha az app fut.

Tesztek: `sh ios-app/Tests/Elm/run.sh` (macOS), ugyanazokkal az esetekkel, mint a firmware tesztjei.

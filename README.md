# Autós társ app (OBD2)

iPhone app, ami egy bolti **Bluetooth LE OBD2 dugón** keresztül olvassa az autó adatait
(pl. Vgate iCar Pro BLE / Bluetooth 4.0). Más hardver nem kell.
A rendszer csak olvas: az app a hibatörlést és minden írási parancsot letilt, mielőtt a dugóhoz érne.

## Mappák

| Mappa | Tartalom |
|---|---|
| `ios-app/` | iPhone app (SwiftUI) és widget. A projektfájlt az XcodeGen generálja. |
| `ios-app/Tests/` | Tesztek: garázs adatbázis és mentés, OBD válasz-értelmező és csak-olvasás szűrő. |
| `.github/workflows/` | Felhős tesztelés és fordítás GitHubon, Mac nélkül. |

## Használat az autóban

1. Dugd be a dugót az OBD2 csatlakozóba (általában a kormány alatt), add rá a gyújtást.
2. Nyisd meg az appot. A telefon Bluetooth beállításaiban **ne** párosítsd: az app magától megtalálja.
3. Első csatlakozáskor válaszd ki, melyik autó; utána a VIN alapján magától vált.
4. Add meg az autó km óra állását (ezeket az autók OBD2-n általában nem adják ki).

Autó nélkül: Beállítások → Demo mód.

## Hibakeresés

Beállítások → Diagnosztika:

- **Eszköz:** melyik dugóhoz csatlakozott az app (ha „—", nem találja a dugót).
- **Fogadott csomagok:** nő, ha a dugó válaszol.
- **OBD adapter / Motorvezérlő:** a dugó válaszol-e, és eléri-e az autót (gyújtás nélkül nem fogja).
- **Eszköz elfelejtése:** ha másik dugóra váltasz, vagy rossz eszközhöz csatlakozott.

## Garázs (több autó)

A Beállítások → Garázs alatt autónként külön profil van (név, VIN, üzemanyag, km óra, tank,
kijelzési határok, szervizterv). Az utak, tankolások, hibakódok, akkuadatok, parkolóhelyek,
szerviztételek és lejáratok autónként külön tárolódnak.

- Első kapcsolatkor válaszd ki a csatlakoztatott autót, utána a VIN alapján automatikusan vált.
- A szervizterv km-intervallumait az autó szervizkönyve alapján állítsd be.
- Dízelnél a pillanatnyi fogyasztás csak akkor látszik, ha a motorvezérlő kiadja; a tankolási napló ettől függetlenül működik.

## Felhő mentés

Google bejelentkezéssel a mentés a saját Google Drive rejtett app-mappájába kerül.
Bekapcsolásához egy Google Cloud iOS OAuth kliens azonosító kell (bundle ID: `hu.kocsi.subaru`),
amit a GitHub repó **Settings → Secrets and variables → Actions → Variables** részén
`GOOGLE_IOS_CLIENT_ID` néven kell megadni.

## Fordítás

Mac-en:

```
brew install xcodegen
cd ios-app
xcodegen generate
open SubaruCompanion.xcodeproj
```

Mac nélkül: minden feltöltés után a GitHub Actions teszteli és lefordítja az appot, képernyőképeket
készít, és telefonra telepíthető csomagot (`telefonra-ipa`) állít elő, ami Sideloadlyval feltehető.

## Korlátok

- A dugó parkoláskor alszik, ezért az éjszakai akkufeszültség nem mérhető.
- Az indításkori feszültségesés csak akkor mérhető, ha az app fut indításkor.
- Az app adatgyűjtéséhez futnia kell (háttérben is elég).

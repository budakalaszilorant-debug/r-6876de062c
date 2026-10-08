# Autós társ app (OBD2)

iPhone app, ami egy bolti **Bluetooth LE OBD2 dugón** keresztül olvassa az autó adatait
(pl. Vgate iCar Pro BLE / Bluetooth 4.0). Más hardver nem kell.
Az automatikus adatgyűjtés csak olvas. Külön, kézzel megerősített javítási műveletként elérhető a tárolt emissziós hibakódok törlése (Mode 04). Minden más író parancs továbbra is tiltott.

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

## Fiók, felhőmentés és telefoncsere

Az app fiók és internet nélkül is működik. A választható **Supabase-fiók** e-mailes
regisztrációt, bejelentkezést, jelszó-visszaállítást és fióktörlést biztosít.
Az autók, utak, költségek és beállítások PostgreSQL-ben tárolt, verziózott mentésekbe kerülnek.
A beállítást lépésről lépésre a [Supabase útmutató](supabase/README.md) írja le.

- Bejelentkezéskor automatikusan a fiók saját garázsa nyílik meg.
- Offline minden adat SQLite-ba mentődik. Az automatikus szinkron induláskor, hálózat visszatérésekor,
  az app futása alatt kétpercenként és háttérbe lépéskor próbálkozik. Feltöltés OBD-kapcsolat mellett is lehetséges; visszaállítás csak álló, bontott kapcsolatnál, demo nélkül.
- Két eszköz eltérő módosításai választást kérnek; nincs csendes felülírás vagy automatikus összevonás.
- A szerver biztonsági célból 20 verziót őriz; ezekhez nincs külön előzménylista az appban. A mentés legfeljebb 20 MB.
- Visszaállítás előtt külön helyi biztonsági másolat készül a `Backups/SafetyCopies` mappába.
- A fiók Google-belépése a Supabase szolgáltatói beállításait használja, nem a Google Drive-ot.

A szinkron jelenleg egy teljes garázs változataival dolgozik. Családi megosztás és soronkénti,
automatikus összefésülés nincs bekapcsolva. A bejelentkezési tokenek nem kerülnek a mentésekbe.

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


## Saját autó, átadás és javítás követése

- **Eltérésfigyelő:** a legutóbbi út fogyasztását és bemelegedését legalább öt hasonló korábbi úthoz hasonlítja. Minimum 90% adatteljeség, hasonló táv, átlagsebesség, alapjárati arány és indulási hőfok szükséges. PID- és MAF-alapú fogyasztást nem kever. Az appban kikapcsolható. Új mérési történetet gyűjt; korábbi utakból nem talál ki hiányzó hőfokadatot.
- **Autóátadás:** név, dátum, ellenőrzött kilométeróra, opcionális tankszint, megjegyzés és fotó átadáskor és visszavételkor. Összesíti a megtett távot és az időszak naplózott kiadásait.
- **Élő tevékenység:** autónév, bemelegedés és becsült hátralévő idő, menetadatok, parkolóóra. Friss adat nélkül nem mutat régi sebességet élőként. Új tevékenységet csak előtérben indít; a parkolási értesítések ettől függetlenül ütemezettek.
- **Saját kezdőképernyő:** autónként fotó, szín, kártyasorrend és láthatóság. A fejlécen szerkeszthető. Új, saját rajzolt Garázs ikon.
- **Javítás követése:** a Diagnosztika képernyőről. Friss VIN-egyezés, nulla fordulat és sebesség, 12–15 V adapterfeszültség szükséges. Előzetes ECU-válaszmentés nélkül nem küld törlést. A Mode 04 parancs egyszeri, kapcsolatvesztésnél nincs újraküldés. Utána tárolt/pending/permanent kódok és readiness visszaolvasása; későbbi kódvisszatérés jelölése. Ez nem ABS/légzsák szervizeszköz és nem motorhangolás.

A hibakódtörlés az ECU freeze frame és readiness adatait is törölheti; az app jelentése nem állítható vissza az ECU-ba. A mentett jelentés megosztható. Az új adatok és tömörített, metaadat nélküli fotók a helyi SQLite `garage_plus` táblában vannak, így a teljes JSON/Supabase-mentés és az autónkénti törlés is kezeli őket. Régi mentések továbbra is visszaállíthatók. Valódi adapteres és autós ellenőrzés szükséges; a CI nem helyettesíti azt.


## Fiókonkénti garázs és egyszerűsített beállítások

A bejelentkezett fiók automatikusan szinkronizál, külön kapcsoló és kézi szinkronizálás nélkül. A fiókműveletek az e-mail-címre koppintva nyílnak meg. A korábbi felhőverziók nincsenek a felületen; a szerver biztonsági verziózása megmarad. Valódi kétoldali ütközésnél továbbra is választás szükséges, az app nem dobja el csendben az egyik eszköz módosításait.

A helyi garázstábla-váltás és tulajdonosváltás egy SQLite-tranzakció. Az inaktív fiókok mentése külön, nem exportált táblába kerül; a widgetek és értesítések fiókváltáskor ürülnek. A korábbi személyes garázs csak a hitelesített tulajdonosi e-mailnek migrálható. Friss telepítésen más felhasználó nem kap Ford/Opel mintautókat. A fiókonkénti fájlmentések az alkalmazás privát könyvtárában vannak; megosztásuk az appból indítható.

Az eladási adatlap fényképes, többoldalas PDF, a saját napló összefoglalója. Elkülöníti a tulajdonosi bejegyzéseket és a dátumozott OBD-leolvasást; nem független állapotigazolás. A költségkategóriák teljes szélességű választólistában jelennek meg. A biztosítási lejárati emlékeztető megszűnt.

Google szolgáltatói beállítások: [SOCIAL_LOGIN.md](supabase/SOCIAL_LOGIN.md).

### Telefonos GPS-útnapló

Az **Utak → Telefonos út → Út indítása** gomb autós Bluetooth/OBD kapcsolat nélkül is rögzít. Indításkor az Utak oldalon marad egy egyszerű állapotkártya, a képernyő lezárható. Az **Út befejezése** gomb nyitja meg az összesítőt: táv, másodperc pontos idő, térképes visszajátszás és becsült vezetési események. A rögzítés állapota engedélyezett Élő tevékenységnél a zárolási képernyőn és a Dynamic Islanden is megjelenik. A GPS-utak nem módosítják a kilométerórát, és nem állítanak fogyasztási, telefonhasználati vagy sebességhatár-adatokat.

- Helyhozzáférés és pontos helymeghatározás szükséges; engedéllyel lezárt képernyő mellett is rögzít. Kényszerített bezárás után a mentett pontok megmaradnak, az út megszakítottként jelenik meg.
- Állóhelyzet-szűrés (2. verzió): legalább 5 egymást követő megbízható mérés, legalább 4 másodperc, legalább 25 méter nettó elmozdulás (rosszabb pontosságnál több) és következetes irány szükséges a mozgás megerősítéséhez. Az indulás megerősített pontjai utólag kerülnek a nyomvonalba. Sebességadat nélküli koordinátasodródásból nincs távolságbecslés. A telefon mozgásfelismerésének megbízható álló jelzése további szűrő; enélkül is működik a GPS-szűrés.
- Álló helyzetben nem mentünk útvonalpontokat, nem nő a maximális sebesség és nincs hamis kis kör a térképen. A 10 másodpercnél nagyobb jelkimaradáson nincs vonal vagy hozzáadott távolság, utána újra meg kell erősíteni a mozgást. A térkép legalább 600 méteres környezetet mutat, a jelölők címe koppintásra jelenik meg.
- Eseménybecslés: csak megerősített mozgásnál, legalább 3 m/s² GPS-sebességváltozás, megfelelő sebességpontosság, legfeljebb 3 másodperces mintaköz, 10 másodperces eseményköz. Nem hitelesített vezetési minősítés. Az összesítő megmutatja a leállítás okát is (kézi, helyengedély megszűnése, mentési hiba, fiókváltás vagy megszakítás). A korábbi, nyers méréseket nem minősítjük át utólag pontos mérésnek.
- A rögzítés helyben ment minden elfogadott pontot; internet csak a térképcsempékhez és a meglévő fiókszinkronhoz kell. A fiók-/autóváltás és az automatikus OBD-útnapló nem keveredik az aktív telefonos úttal.
- Telefonos ellenőrzés: engedély elutasítása/engedélyezése, 10–15 perces út lezárt kijelzővel, megállás, jelkimaradás, app újranyitása, fiókváltás és felhőből visszaállítás. Az automatikus tesztek nem helyettesítik ezt a valós GPS-próbát.

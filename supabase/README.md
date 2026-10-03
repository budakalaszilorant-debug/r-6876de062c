# Garázs – Supabase bekapcsolása

A kód konfiguráció nélkül is fordul és offline használható. Az élő fiókhoz egy saját
Supabase-projektet kell létrehozni; a kód nem hoz létre fizetős szolgáltatást.

## 1. Projekt és adatbázis

1. A https://supabase.com/dashboard oldalon hozz létre egy projektet, lehetőleg EU-régióban.
2. A SQL Editorban futtasd le egyszer a `migrations/202610030001_garage_cloud.sql` teljes tartalmát.
   Új táblákat hoz létre; meglévő appadatokhoz nem nyúl. CLI esetén `supabase db push` használható
   a saját projekt linkelése és a szokásos CLI-inicializálás után.
3. A Database / Tables alatt megjelenik a `garage_heads` és `garage_versions`.
   Mindkettőn RLS van. Kliens csak a saját sorait olvashatja; írni a revíziót ellenőrző RPC-vel lehet.

## 2. Bejelentkezés

- Authentication / Providers: engedélyezd az Email szolgáltatót és az e-mail-megerősítést.
- A minimális jelszóhossz legyen legalább 8 karakter.
- Authentication / URL Configuration / Redirect URLs: add hozzá pontosan:
  `garazs://auth/callback`
- E-mail-megerősítés és jelszó-visszaállítás az appot nyitja meg. A PKCE miatt a visszaállító
  levelet azon az iPhone-on nyisd meg, amelyiken kérted. Másik eszközön megerősített regisztráció
  után a telefonon normál e-mail/jelszó belépést használj.
- A Supabase beépített tesztlevél-küldője korlátozott. Saját, ellenőrzött SMTP-szolgáltatót állíts be
  az Authentication beállításaiban, mielőtt más felhasználókat engedsz regisztrálni.
- A munkamenetet és tokenfrissítést a hivatalos Supabase Swift SDK kezeli. Jelszavakat nem tárolunk.

## 3. GitHub build

Repo → Settings → Secrets and variables → Actions → **Variables**:

| Név | Érték |
|---|---|
| `SUPABASE_URL` | A projekt HTTPS URL-je, például `https://projektazonosito.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | A nyilvános `sb_publishable_…` kulcs vagy a régi `anon` JWT |
| `GOOGLE_IOS_CLIENT_ID` | Csak a korábbi Drive-mentések importálásához, ha használtál ilyet |

Ezek kliensbe építhető beállítások. `service_role`, `sb_secret_…`, adatbázis-jelszó vagy
Supabase személyes hozzáférési token **nem kerülhet az appba vagy a repóba**.
A konfiguráló script elutasítja a privilegizált kulcsot. A felhasználók elkülönítését az RLS biztosítja.

Indíts új Actions buildet, és telepítsd a kapott IPA-t. A beállítások a szimulátoros és telefonos
csomagba egyaránt bekerülnek. Helyi Mac-buildnél a `project.yml` két SUPABASE értékét állítsd be
XcodeGen előtt, vagy használd a `scripts/configure_cloud.py` scriptet a megfelelő környezeti változókkal.

## 4. Első használat és a korábbi adatok

1. Készíts fájlmentést a jelenlegi appból.
2. Beállítások → Fiók és felhő → regisztráció; erősítsd meg az e-mailt.
3. Válaszd a **telefon garázsát**, ha ezen van a megőrzendő adat. Ez az első feltöltést is elindítja.
4. Új telefonon ugyanazzal a fiókkal belépve válaszd a **felhő garázsát**.
5. Régi Drive-adatokhoz használd a külön letöltés/importálás gombot. A Google eredeti mentése megmarad.
   Konfigurálatlan Google-import esetén a régi appból exportált JSON a fájl-visszaállítással olvasható.

Az automatikus szinkron csak összekapcsolás után aktív, és külön kapcsolóval kikapcsolható.
A helyi SQLite a tartós várakozási sor: a sikertelen feltöltés nem törli a módosításokat.
Az app előtérben kétpercenként, hálózat-visszatéréskor és életciklus-eseményeknél újrapróbálkozik.
iOS felfüggesztés alatt nem garantálható az azonnali szinkron. Az appot megnyitva és az
OBD-kapcsolatot bontva kézzel is szinkronizálhatsz. Demoadatot nem szinkronizálunk demo üzemmódban.

## 5. Ütközések, visszaállítás és korlátok

- A garázs teljes, atomi JSONB-pillanatképe kerül PostgreSQL-be; benne autonként külön táblázatos
  adatokkal. Ez **nem** rekordokonkénti, valós idejű összevonás és nem közös családi fiókrendszer.
- Minden írás megadja az ismert szerverrevíziót. Ha közben másik telefon mentett, a szerver elutasítja
  a régi revízióra írást. A felület két változat közötti választást kínál.
- Felhőváltozat választása előtt helyi biztonsági másolat készül. Helyi változat feltöltésekor
  az előző felhőváltozat a történetben marad. Korábbi mentés visszaállítása új változatként tölthető fel.
- A legutóbbi **20 változat**, legfeljebb **20 MB változatonként** marad meg. Ez tárhelyet fogyaszt,
  és nem helyettesíti a külön, időszakosan exportált fájlmentést vagy a szolgáltatói katasztrófa-mentést.
- A helyi `Backups/SafetyCopies` fájlokat nem töröljük automatikusan; időnként a Fájlok appban kezelhetők.
- A szinkron visszaállítása csak megszakított OBD-kapcsolatnál, leállított demónál engedélyezett.
  Letöltés közben módosult helyi adatot nem írunk felül.
- A felhő menti az útvonalak helyadatait és a VIN-t is, kizárólag a hozzákapcsolt fiók alá.
  HTTPS védi az átvitelt; ez nem végpontok közötti titkosítás.
- Kijelentkezéskor a helyi adatok megmaradnak. Másik fiókba feltöltéshez újra külön döntés kell.
- Fióktörlés az appból végleg törli a fiókot és a felhőváltozatokat; a telefon adatai megmaradnak.

## Ellenőrzések

A GitHub workflow PostgreSQL 16-on ellenőrzi az RLS-t, az ütközést, az ismételt kérés idempotenciáját,
a 20-verziós korlátot és a fióktörlés elkülönítését. A Swift garázsteszt ellenőrzi a szinkrondöntéseket,
a stabil tartalomazonosítót és a helyi biztonsági másolatot; az iOS appot szimulátorra és telefonra is fordítja.

Projekt létrehozása után két külön tesztfiókkal és két eszközzel ellenőrizd a belépést, e-mailt,
jelszó-visszaállítást, offline mentést, telefoncserét és az ütközésfeloldást. Ezek az élő szolgáltatói
beállításoktól függnek, és konfigurálatlan buildben nem tesztelhetők.

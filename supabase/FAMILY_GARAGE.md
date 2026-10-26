# Családi garázs bekapcsolása

Az app többi újdonsága helyben működik. A meghívásos közös garázshoz egyszer telepíteni kell az új adatbázisrészt a meglévő Supabase-projektbe:

1. Supabase Dashboard → a meglévő projekt → SQL Editor → New query.
2. Másold be a `migrations/202610260001_family_garage.sql` teljes tartalmát, és futtasd. Ez új táblákat és egy függvényt hoz létre, a saját garázs mentéseit nem módosítja. Egyszer futtatandó, tranzakcióban települ.
3. Az appban Garázs → Családi garázs → közös autó létrehozása.
4. Nyisd meg az autót, a megosztandó naplót, majd válaszd az átvételt a kijelölt saját autóból. Megosztás előtt ellenőrizd az előnézetet.
5. Meghívások és jogosultságok: válaszd ki a látható/szerkeszthető naplókat. A kód egyszer használható, hét napig érvényes. A másik személy saját fiókkal, a Családi garázs oldalon csatlakozhat.

Nincs új alkalmazáskulcs vagy GitHub-változó. Service-role kulcsot ne tegyél az appba. A telefon a meglévő felhasználói munkamenettel hívja a jogosultságokat ellenőrző műveleteket.

## Adathatárok

- A közös napló külön adatforrás; a privát teljes mentés soha nem válik megosztottá.
- Külön olvasási/írási jog a szerviz, költség és út összesítőire, autónként. A tulajdonos bármikor visszavonhatja a hozzáférést és a függő meghívókat.
- Az utak exportja dátumot, távot és időtartamot tartalmaz; koordinátákat, címeket, privát helyneveket nem.
- A szerviz- és költségjegyzetek csak az előnézet jóváhagyásakor kerülnek át. Dokumentumok, VIN, fotók és más autók adatai nincsenek automatikusan megosztva.
- A közös szerkesztés a közös naplóra hat. A privát szervizterv, kilométeróra és költséglista változatlan. Ismételt átvétel megtartja a közös naplóban már szereplő bejegyzéseket.
- Párhuzamos szerkesztésnél a szerver elutasítja az elavult változatot; frissítés szükséges, nincs csendes felülírás.
- Meghívás visszavonása a további szerverhozzáférést állítja le; a korábban már megtekintett vagy kézzel lementett információt nem lehet visszahívni.

## Ellenőrzés

A CI külön tesztadatbázison futtatja a `tests/cloud.sql` és `tests/family.sql` ellenőrzéseket. Ez nem telepíti a produkciós adatbázist. A valódi szerverre telepítés után két külön tesztfiókkal ellenőrizhető az olvasási jog, szerkesztés, meghívókód, visszavonás és a saját garázs elkülönítése.

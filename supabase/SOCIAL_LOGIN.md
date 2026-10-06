# Google bejelentkezés

Az app a meglévő Supabase Auth-fiókokat használja, böngészős OAuth-belépéssel és PKCE-visszatéréssel. Nem hoz létre külön Google Drive-mentést.

## Google

1. Google Cloud Console → Google Auth Platform: állítsd be a hozzájárulási képernyőt és egy **Web application** típusú OAuth-klienst.
2. Authorized redirect URI: a Supabase projekt Google provider oldalán megjelenő callback, `https://<projekt>.supabase.co/auth/v1/callback`.
3. Supabase Dashboard → Authentication → Sign In / Providers → Google: engedélyezd, add meg a webes kliensazonosítót és a kliens titkos kulcsát.
4. Authentication → URL Configuration → Redirect URLs: add hozzá pontosan a `garazs://auth/callback` címet.
5. Tesztelési állapotú Google OAuth-projektnél add hozzá a belépő felhasználókat a tesztelőkhöz. Nyilvános használathoz a Google közzétételi feltételeit is teljesíteni kell.

A kliens titkos kulcsa csak a Supabase szolgáltatói beállításába kerülhet. Ne tedd GitHub-változóba, az IPA-ba vagy forráskódba. A már beállított Supabase URL és publishable kulcs elegendő az appnak. A belépőképernyő újranyitásakor az app lekéri az engedélyezett szolgáltatókat, új build nem szükséges a Google bekapcsolásához.

Az app Google- és e-mailes bejelentkezést kínál. Apple-belépés nincs benne.

Az app nem kapcsol össze különböző e-mail-című fiókokat. A két előre megadott autó csak a hitelesített `balazskiss01@proton.me` fiók új, üres garázsába kerül be; más fiók saját üres garázzsal kezd.

Források: [Supabase Google](https://supabase.com/docs/guides/auth/social-login/auth-google), [Swift OAuth](https://supabase.com/docs/reference/swift/auth-signinwithoauth).

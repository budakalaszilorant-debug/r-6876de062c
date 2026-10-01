// PC-n futó teszt az ELM327 válaszok értelmezésére és a csak-olvasás whitelistre.
// Futtatás: test/host/run.sh
#include "Arduino.h"
#include "../../src/obd_parse.h"

static int failed = 0, passed = 0;

#define CHECK(cond) do { if (cond) passed++; else { failed++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

static bool same(const std::vector<String>& got, std::initializer_list<const char*> want) {
  if (got.size() != want.size()) return false;
  size_t i = 0;
  for (const char* w : want) if (!(got[i++] == w)) return false;
  return true;
}

int main() {
  uint8_t b[4] = {0};

  // ── Whitelist: csak olvasás ──
  CHECK(isCommandAllowed("010C"));
  CHECK(isCommandAllowed("0105"));
  CHECK(isCommandAllowed("01A6"));
  CHECK(isCommandAllowed("03"));
  CHECK(isCommandAllowed("0902"));
  CHECK(isCommandAllowed("ATRV"));
  CHECK(isCommandAllowed("ATSP0"));
  CHECK(isCommandAllowed("ATSP6"));
  CHECK(isCommandAllowed(" atz "));
  CHECK(!isCommandAllowed("04"));        // hibakód törlés
  CHECK(!isCommandAllowed("0400"));
  CHECK(!isCommandAllowed("08"));        // vezérlés
  CHECK(!isCommandAllowed("0800"));
  CHECK(!isCommandAllowed("2E1234"));    // UDS írás
  CHECK(!isCommandAllowed("3101"));      // UDS rutin
  CHECK(!isCommandAllowed("1003"));      // diagnosztikai session
  CHECK(!isCommandAllowed("0904"));
  CHECK(!isCommandAllowed("01"));
  CHECK(!isCommandAllowed("010C1"));
  CHECK(!isCommandAllowed("010C\r04"));
  CHECK(!isCommandAllowed("ATMA"));
  CHECK(!isCommandAllowed("ATPP2CSV01"));
  CHECK(!isCommandAllowed("ATSH7E0"));
  CHECK(!isCommandAllowed("ATSPZ"));
  CHECK(!isCommandAllowed(""));

  // ── Mode 01 PID ──
  CHECK(parsePid("410C1AF8", 0x0C, 2, b) && (b[0] * 256 + b[1]) / 4 == 1726);
  CHECK(parsePid("41 0C 1A F8", 0x0C, 2, b) && b[0] == 0x1A && b[1] == 0xF8);   // szóközös válasz
  CHECK(parsePid("41057B", 0x05, 1, b) && b[0] - 40 == 83);
  CHECK(parsePid("410C0FA0\r410C0FA0", 0x0C, 2, b) && b[0] == 0x0F);            // két vezérlő válaszol
  CHECK(parsePid("BUSINIT:...OK\r4100BE3FA813", 0x00, 4, b) && b[0] == 0xBE && b[3] == 0x13);
  CHECK(parsePid("014\r0:4100BE3FA813", 0x00, 4, b) && b[1] == 0x3F);
  CHECK(!parsePid("NO DATA", 0x0C, 2, b));
  CHECK(!parsePid("CAN ERROR", 0x0C, 2, b));
  CHECK(!parsePid("UNABLE TO CONNECT", 0x0C, 2, b));
  CHECK(!parsePid("?", 0x0C, 2, b));
  CHECK(!parsePid("", 0x0C, 2, b));
  CHECK(!parsePid("410C1A", 0x0C, 2, b));          // csonka válasz
  CHECK(!parsePid("41051A", 0x0C, 1, b));          // másik PID válasza
  CHECK(parsePid("41421388", 0x42, 2, b) && (b[0] * 256 + b[1]) == 5000);

  // ── VIN ──
  // CAN, több keret: 49 02 01 + 17 karakter
  CHECK(parseVin("014\r0:4902014A4631\r1:47523745353941\r2:47303030303031") == "JF1GR7E59AG000001");
  CHECK(parseVin("014\r0: 49 02 01 4A 46 31\r1: 47 52 37 45 35 39 41\r2: 47 30 30 30 30 30 31") == "JF1GR7E59AG000001");
  // ISO 9141 / KWP: 5 sor, soronként 4 adatbájt, elöl nullákkal kitöltve
  CHECK(parseVin("4902010000004A\r49020246314752\r49020337453539\r49020441473030\r49020530303031") == "JF1GR7E59AG000001");
  CHECK(parseVin("NO DATA") == "");
  CHECK(parseVin("014\r0:4902014A4631") == "");    // csonka
  CHECK(parseVin("") == "");

  // ── Hibakódok ──
  std::vector<String> d;
  CHECK(parseDtcs("43020420030100", true, 10, d) && same(d, {"P0420", "P0301"}));          // CAN egy keret
  CHECK(parseDtcs("4300", true, 10, d) && d.empty());                                      // CAN, nincs kód
  CHECK(parseDtcs("00A\r0:430401330420\r1:03010302000000", true, 10, d) &&
        same(d, {"P0133", "P0420", "P0301", "P0302"}));                                    // CAN több keret
  CHECK(parseDtcs("43010420\r4300", true, 10, d) && same(d, {"P0420"}));                   // két vezérlő
  CHECK(parseDtcs("43013304200000", false, 10, d) && same(d, {"P0133", "P0420"}));         // régi protokoll
  CHECK(parseDtcs("43013304200301\r43030200000000", false, 10, d) &&
        same(d, {"P0133", "P0420", "P0301", "P0302"}));
  CHECK(parseDtcs("4301C100", true, 10, d) && same(d, {"U0100"}));
  CHECK(parseDtcs("43014300", true, 10, d) && same(d, {"C0300"}));
  CHECK(parseDtcs("43019234", true, 10, d) && same(d, {"B1234"}));
  CHECK(parseDtcs("43020420042000", true, 10, d) && same(d, {"P0420"}));                   // duplikátum
  CHECK(parseDtcs("NO DATA", true, 10, d) && d.empty());
  d.clear(); d.push_back("P0420");
  CHECK(!parseDtcs("CAN ERROR", true, 10, d) && same(d, {"P0420"}));   // hibánál marad a régi lista
  CHECK(!parseDtcs("", true, 10, d) && same(d, {"P0420"}));
  CHECK(!parseDtcs("7F0312", true, 10, d) && same(d, {"P0420"}));      // negatív válasz
  CHECK(parseDtcs("43030101010201030104", true, 2, d) && d.size() == 2);   // felső korlát

  // ── Feszültség ──
  CHECK(fabs(parseVoltage("14.2V") - 14.2f) < 0.01f);
  CHECK(fabs(parseVoltage("ATRV\r12.6V") - 12.6f) < 0.01f);            // echo bent maradt
  CHECK(std::isnan(parseVoltage("?")));
  CHECK(std::isnan(parseVoltage("")));
  CHECK(std::isnan(parseVoltage("0.0V")));

  printf("%d passed, %d failed\n", passed, failed);
  return failed ? 1 : 0;
}

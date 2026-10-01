/*
 * Subaru Impreza OBD2 -> BLE híd (ESP32 + ELM327 UART)
 *
 * CSAK OLVASÁS. A firmware egy whitelist-en keresztül küld parancsot az ELM327-nek:
 *   - AT parancsok (csak az adapter beállítása, az autóhoz nem jut el)
 *   - Mode 01 (élő adatok), Mode 03 (tárolt hibakódok), Mode 09 PID 02 (VIN)
 * Minden más (pl. 04 = hibakód törlés, 08, 2E, 31 ...) blokkolva van.
 * A BLE karakterisztika csak READ + NOTIFY, az iPhone nem tud parancsot küldeni.
 *
 * Bekötés:
 *   OBD2 pin 16 (+12V) -> step-down (5V) -> ESP32 VIN + ELM327 VCC
 *   OBD2 pin 4/5 (GND) -> közös GND
 *   ELM327 TX -> feszültségosztó (5V -> 3.3V) -> ESP32 GPIO16 (RX2)
 *   ELM327 RX <- ESP32 GPIO17 (TX2)
 *
 * BLE kimenet: JSON + '\n', MTU méretű darabokban notify-olva.
 * Az app a '\n'-ig gyűjti össze a csomagot.
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_sleep.h>
#include <vector>
#include "obd_parse.h"

// ───────────── Konfiguráció ─────────────
#define DEVICE_NAME          "SUBARU-OBD"
#define SERVICE_UUID         "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define LIVE_CHAR_UUID       "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

#define ELM_RX_PIN           16
#define ELM_TX_PIN           17
// Az ELM327 modulok sebessége típusonként eltér: sorban kipróbáljuk.
static const uint32_t ELM_BAUDS[] = {38400, 9600, 115200};

#define ELM_TIMEOUT_MS       1500
#define ELM_SEARCH_TIMEOUT   12000  // automata protokoll keresés (ATSP0) lassú lehet
#define ELM_PROBE_TIMEOUT    2500   // rögzített protokollnál gyors a válasz
#define ELM_RETRY_MS         15000  // ennyi időnként próbáljuk újra, ha az adapter nem válaszol
#define ELM_DEAD_MS          20000  // ennyi ideig nincs válasz -> adapter hibásnak tekintve

#define PACKET_INTERVAL_MS   250    // 4 Hz: fordulat/sebesség/MAF
#define MEDIUM_INTERVAL_MS   1000   // terhelés, gázpedál
#define COOLANT_INTERVAL_MS  2000
#define VOLTAGE_INTERVAL_MS  2000
#define SLOW_INTERVAL_MS     5000   // üzemanyag, szívott levegő
#define DTC_INTERVAL_MS      30000
#define DIST_INTERVAL_MS     60000
#define OFFLINE_PROBE_MS     10000

#define RPM_RUNNING          400    // e felett jár a motor
#define ECU_FAIL_LIMIT       3      // ennyi hibás válasz után ECU offline

#define MAX_DTCS             10

// Mély alvás, hogy ne merítse az aksit gyújtás nélkül.
// Megjegyzés: az ELM327 modul ettől még fogyaszt, ha nincs külön kapcsolva.
#define ENABLE_DEEP_SLEEP    true
#define SLEEP_AFTER_MS       (10UL * 60UL * 1000UL)
#define SLEEP_WAKE_SEC       60
#define CHARGING_VOLTAGE     13.2f  // e felett tölt a generátor = jár a motor

#define ELM Serial2

// ───────────── Állapot ─────────────
Preferences prefs;

BLEServer*         bleServer = nullptr;
BLECharacteristic* liveChar  = nullptr;
volatile bool      bleConnected   = false;
volatile bool      bleNeedsAdvert = false;
volatile uint16_t  bleConnId      = 0;

bool     elmReady    = false;
uint32_t lastElmReply = 0;   // utoljára mikor jött '>' prompt az adaptertől
uint32_t tElmRetry    = 0;
char     savedProto   = 0;   // utoljára működő OBD protokoll száma (ELM jelölés), 0 = nincs
uint32_t chargingNoEcuSince = 0;
bool     ecuOnline   = false;
bool     isCan       = true;
uint8_t  ecuFails    = 0;
uint32_t lastEcuSeen = 0;
bool     supported[0xC1] = {false};

String   vin;
uint32_t startId = 0;
bool     engineRunning = false;
uint32_t engineStoppedAt = 0;

float rpm = NAN, coolant = NAN, voltage = NAN, speed = NAN, load = NAN,
      throttle = NAN, fuel = NAN, intake = NAN, distSinceClear = NAN, odometer = NAN,
      maf = NAN;
const char* voltageSrc = "adapter";
double   tripKm = 0;
uint32_t lastSpeedAt = 0;
std::vector<String> dtcs;

uint32_t seq = 0;
uint32_t tPacket = 0, tCoolant = 0, tVoltage = 0, tSlow = 0, tDtc = 0, tDist = 0, tProbe = 0, tVin = 0, tMedium = 0;

uint32_t probeTimeout();

// ───────────── ELM327 kommunikáció ─────────────
String elmSend(const String& cmd, uint32_t timeoutMs = ELM_TIMEOUT_MS) {
  if (!isCommandAllowed(cmd)) {
    Serial.printf("[SAFETY] tiltott parancs blokkolva: %s\n", cmd.c_str());
    return "BLOCKED";
  }
  while (ELM.available()) ELM.read();
  ELM.print(cmd);
  ELM.print('\r');

  String resp;
  bool gotPrompt = false;
  uint32_t start = millis();
  while (!gotPrompt && millis() - start < timeoutMs) {
    while (ELM.available()) {
      char c = ELM.read();
      if (c == '>') { gotPrompt = true; break; }
      if (c != 0) resp += c;
    }
    if (!gotPrompt) delay(1);
  }
  resp.replace("SEARCHING...", "");
  resp.trim();
  if (gotPrompt) lastElmReply = millis();
  else Serial.printf("[ELM] timeout: %s\n", cmd.c_str());
  return resp;
}

// Megkeresi, melyik sebességen válaszol az adapter.
bool elmFindBaud() {
  for (uint32_t baud : ELM_BAUDS) {
    ELM.updateBaudRate(baud);
    delay(50);
    String r = elmSend("ATZ", 2500);
    if (r.indexOf("ELM") >= 0) {
      Serial.printf("[ELM] %s @ %u baud\n", r.c_str(), baud);
      return true;
    }
  }
  Serial.println("[ELM] nem válaszol egyik sebességen sem (bekötés? táp?)");
  return false;
}

bool elmInit() {
  if (!elmFindBaud()) return false;
  delay(300);
  // Ha ismert a protokoll, azt rögzítjük: gyorsabb csatlakozás, és gyújtás nélkül sem akad meg keresésben.
  String sp = String("ATSP") + (savedProto ? savedProto : '0');
  const char* cmds[] = {"ATE0", "ATL0", "ATS0", "ATH0", "ATAT1", sp.c_str()};
  for (const char* c : cmds) {
    String r = elmSend(c);
    if (r.indexOf("OK") < 0) {
      Serial.printf("[ELM] init hiba: %s -> %s\n", c, r.c_str());
      return false;
    }
  }
  Serial.println("[ELM] kész");
  return true;
}

// Mode 01 PID lekérdezés, n adatbájt -> out
bool queryPid(uint8_t pid, uint8_t n, uint8_t* out, uint32_t timeoutMs = ELM_TIMEOUT_MS) {
  return parsePid(elmSend("01" + hex2(pid), timeoutMs), pid, n, out);
}

float readAdapterVoltage() {
  return parseVoltage(elmSend("ATRV"));
}

void detectProtocol() {
  String r = elmSend("ATDPN");
  r.trim();
  char p = r.length() ? r[r.length() - 1] : '0';
  isCan = (p >= '6' && p <= '9');
  if (((p >= '1' && p <= '9') || (p >= 'A' && p <= 'C')) && p != savedProto) {
    savedProto = p;
    prefs.putUChar("proto", (uint8_t)p);
    elmSend(String("ATSP") + p);
  }
  Serial.printf("[ELM] protokoll: %s (%s)\n", r.c_str(), isCan ? "CAN" : "nem CAN");
}

void readSupportedPids() {
  memset(supported, 0, sizeof(supported));
  for (uint8_t base = 0x00; base <= 0xA0; base += 0x20) {
    uint8_t b[4];
    if (!queryPid(base, 4, b, base == 0 ? probeTimeout() : ELM_TIMEOUT_MS)) break;
    for (int i = 0; i < 32; i++) {
      if (b[i / 8] & (0x80 >> (i % 8))) supported[base + 1 + i] = true;
    }
    if (!supported[base + 0x20]) break;
  }
  Serial.printf("[ELM] 0142:%d 012F:%d 0131:%d 01A6:%d\n",
                supported[0x42], supported[0x2F], supported[0x31], supported[0xA6]);
}

void readVin() {
  String v = parseVin(elmSend("0902", 3000));
  if (v.length() == 17) {
    vin = v;
    prefs.putString("vin", vin);
    Serial.printf("[OBD] VIN: %s\n", vin.c_str());
  }
}

void readDtcs() {
  parseDtcs(elmSend("03", 3000), isCan, MAX_DTCS, dtcs);
}

// ───────────── Járműállapot ─────────────
void clearLiveValues() {
  rpm = speed = load = throttle = fuel = intake = coolant = maf = NAN;
}

void markEcuResult(bool ok) {
  if (ok) {
    ecuFails = 0;
    lastEcuSeen = millis();
    if (!ecuOnline) {
      ecuOnline = true;
      Serial.println("[OBD] ECU online");
      detectProtocol();
      readSupportedPids();
      if (vin.length() != 17) readVin();
      tDtc = 0;  // azonnal olvassunk hibakódot
    }
  } else if (++ecuFails >= ECU_FAIL_LIMIT && ecuOnline) {
    ecuOnline = false;
    clearLiveValues();
    Serial.println("[OBD] ECU offline");
  }
}

void updateEngineState() {
  bool running = !isnan(rpm) && rpm >= RPM_RUNNING;
  if (running && !engineRunning) {
    // Új indítási ciklus, ha legalább 5 mp-ig állt
    if (engineStoppedAt == 0 || millis() - engineStoppedAt > 5000) {
      startId++;
      prefs.putUInt("start_id", startId);
      tripKm = 0;
      Serial.printf("[OBD] motor indítás #%u\n", startId);
    }
  }
  if (!running && engineRunning) engineStoppedAt = millis();
  engineRunning = running;
}

void pollFast() {
  uint8_t b[4];
  bool ok = queryPid(0x0C, 2, b);
  markEcuResult(ok);
  if (!ecuOnline) return;
  rpm = ok ? ((b[0] * 256 + b[1]) / 4.0f) : NAN;

  if (queryPid(0x0D, 1, b)) {
    uint32_t now = millis();
    if (lastSpeedAt && !isnan(speed)) tripKm += speed * (now - lastSpeedAt) / 3600000.0;
    speed = b[0];
    lastSpeedAt = now;
  } else {
    speed = NAN;
    lastSpeedAt = 0;
  }
  // MAF g/s -> az app ebből számol fogyasztást
  maf = (supported[0x10] && queryPid(0x10, 2, b)) ? (b[0] * 256 + b[1]) / 100.0f : NAN;
}

void pollScheduled(uint32_t now) {
  uint8_t b[4];

  if (now - tVoltage >= VOLTAGE_INTERVAL_MS) {
    tVoltage = now;
    if (ecuOnline && supported[0x42] && queryPid(0x42, 2, b)) {
      voltage = (b[0] * 256 + b[1]) / 1000.0f;
      voltageSrc = "pid";
    } else {
      voltage = readAdapterVoltage();
      voltageSrc = "adapter";
    }
  }

  if (!ecuOnline) return;

  if (now - tMedium >= MEDIUM_INTERVAL_MS) {
    tMedium = now;
    load     = queryPid(0x04, 1, b) ? b[0] * 100.0f / 255.0f : NAN;
    throttle = queryPid(0x11, 1, b) ? b[0] * 100.0f / 255.0f : NAN;
  }
  if (now - tCoolant >= COOLANT_INTERVAL_MS) {
    tCoolant = now;
    coolant = queryPid(0x05, 1, b) ? b[0] - 40.0f : NAN;
  }
  if (now - tSlow >= SLOW_INTERVAL_MS) {
    tSlow = now;
    intake = queryPid(0x0F, 1, b) ? b[0] - 40.0f : NAN;
    fuel   = (supported[0x2F] && queryPid(0x2F, 1, b)) ? b[0] * 100.0f / 255.0f : NAN;
  }
  if (now - tDist >= DIST_INTERVAL_MS) {
    tDist = now;
    if (supported[0x31] && queryPid(0x31, 2, b)) distSinceClear = b[0] * 256 + b[1];
    if (supported[0xA6] && queryPid(0xA6, 4, b)) {
      odometer = ((uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]) / 10.0f;
    }
  }
  if (tDtc == 0 || now - tDtc >= DTC_INTERVAL_MS) {
    tDtc = now ? now : 1;
    readDtcs();
  }
  if (vin.length() != 17 && now - tVin >= 30000) {
    tVin = now;
    readVin();
  }
}

// ───────────── BLE ─────────────
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s, esp_ble_gatts_cb_param_t* param) override {
    bleConnId = param->connect.conn_id;
    bleConnected = true;
    Serial.println("[BLE] csatlakozva");
  }
  void onDisconnect(BLEServer* s) override {
    bleConnected = false;
    bleNeedsAdvert = true;
    Serial.println("[BLE] lecsatlakozva");
  }
};

void bleInit() {
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(517);

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService* service = bleServer->createService(SERVICE_UUID);
  liveChar = service->createCharacteristic(
      LIVE_CHAR_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);  // nincs WRITE
  liveChar->addDescriptor(new BLE2902());
  service->start();

  // Adv: service UUID (iOS háttérben UUID alapján tud keresni), scan response: név
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  BLEAdvertisementData advData;
  advData.setFlags(0x06);
  advData.setCompleteServices(BLEUUID(SERVICE_UUID));
  BLEAdvertisementData scanData;
  scanData.setName(DEVICE_NAME);
  adv->setAdvertisementData(advData);
  adv->setScanResponseData(scanData);
  BLEDevice::startAdvertising();
  Serial.println("[BLE] hirdetés indult");
}

void bleSend(const String& json) {
  liveChar->setValue((uint8_t*)json.c_str(), json.length());
  if (!bleConnected) return;

  String framed = json + "\n";
  uint16_t mtu = bleServer->getPeerMTU(bleConnId);
  size_t chunk = (mtu > 23) ? mtu - 3 : 20;
  for (size_t i = 0; i < framed.length(); i += chunk) {
    size_t n = min(chunk, (size_t)(framed.length() - i));
    liveChar->setValue((uint8_t*)framed.c_str() + i, n);
    liveChar->notify();
    delay(4);
  }
  liveChar->setValue((uint8_t*)json.c_str(), json.length());  // READ a teljes JSON-t adja
}

// ───────────── JSON ─────────────
void putNum(JsonDocument& doc, const char* key, float v, int decimals) {
  if (isnan(v)) { doc[key] = nullptr; return; }
  if (decimals == 0) { doc[key] = (long)lroundf(v); return; }
  double p = pow(10, decimals);
  doc[key] = round(v * p) / p;
}

String buildPacket() {
  JsonDocument doc;
  doc["seq"] = ++seq;
  doc["uptime_ms"] = millis();
  doc["elm"] = elmReady;
  doc["ecu"] = ecuOnline;
  doc["engine_running"] = engineRunning;
  doc["start_id"] = startId;
  putNum(doc, "rpm", rpm, 0);
  putNum(doc, "coolant_temp", coolant, 0);
  putNum(doc, "battery_voltage", voltage, 2);
  doc["voltage_src"] = voltageSrc;
  putNum(doc, "vehicle_speed", speed, 0);
  putNum(doc, "engine_load", load, 1);
  putNum(doc, "throttle_pos", throttle, 1);
  putNum(doc, "fuel_level", fuel, 0);
  putNum(doc, "intake_temp", intake, 0);
  putNum(doc, "maf", maf, 2);
  JsonArray arr = doc["fault_codes"].to<JsonArray>();
  for (const String& c : dtcs) arr.add(c);
  if (vin.length() == 17) doc["vin"] = vin; else doc["vin"] = nullptr;
  putNum(doc, "odometer_km", odometer, 1);
  putNum(doc, "dist_since_clear_km", distSinceClear, 0);
  doc["trip_km"] = round(tripKm * 100) / 100.0;

  String out;
  serializeJson(doc, out);
  return out;
}

// ───────────── Alvás ─────────────
void goToSleep() {
  Serial.println("[PWR] mély alvás");
  Serial.flush();
  esp_sleep_enable_timer_wakeup((uint64_t)SLEEP_WAKE_SEC * 1000000ULL);
  esp_deep_sleep_start();
}

uint32_t probeTimeout() {
  return savedProto ? ELM_PROBE_TIMEOUT : ELM_SEARCH_TIMEOUT;
}

// Ha a generátor tölt (jár a motor), de a rögzített protokollon nincs ECU válasz,
// a mentett protokoll rossz: visszaállunk automata keresésre.
void checkProtocolFallback(uint32_t now) {
  bool charging = !isnan(voltage) && voltage >= CHARGING_VOLTAGE;
  if (ecuOnline || !charging || !savedProto) { chargingNoEcuSince = 0; return; }
  if (chargingNoEcuSince == 0) { chargingNoEcuSince = now ? now : 1; return; }
  if (now - chargingNoEcuSince > 30000) {
    Serial.println("[ELM] mentett protokoll nem működik -> automata keresés");
    savedProto = 0;
    prefs.remove("proto");
    elmSend("ATSP0");
    chargingNoEcuSince = 0;
  }
}

// Ébredés után gyors ellenőrzés BLE nélkül: jár a motor / van gyújtás?
void checkWakeOrSleep() {
  if (esp_sleep_get_wakeup_cause() != ESP_SLEEP_WAKEUP_TIMER) return;
  // Ha az adapter nem válaszol, ébren maradunk: így az app BLE-n látja a hibát.
  if (!elmInit()) return;
  float v = readAdapterVoltage();
  if (!isnan(v) && v >= CHARGING_VOLTAGE) return;
  uint8_t b[4];
  if (queryPid(0x00, 4, b, probeTimeout())) return;  // gyújtás ráadva
  goToSleep();
}

// ───────────── Setup / loop ─────────────
void setup() {
  Serial.begin(115200);
  ELM.begin(ELM_BAUDS[0], SERIAL_8N1, ELM_RX_PIN, ELM_TX_PIN);
  delay(200);

  prefs.begin("obd", false);
  vin = prefs.getString("vin", "");
  startId = prefs.getUInt("start_id", 0);
  savedProto = (char)prefs.getUChar("proto", 0);

  if (ENABLE_DEEP_SLEEP) checkWakeOrSleep();

  bleInit();
  elmReady = elmInit();

  // Első próba keresési timeouttal
  uint8_t b[4];
  if (elmReady) markEcuResult(queryPid(0x00, 4, b, probeTimeout()));
  lastEcuSeen = millis();
  tElmRetry = millis();
}

void loop() {
  uint32_t now = millis();

  if (bleNeedsAdvert) {
    bleNeedsAdvert = false;
    delay(200);
    BLEDevice::startAdvertising();
  }

  // Adapter figyelés: ha régóta nem jött tőle válasz, hibásnak vesszük és újra inicializáljuk.
  if (elmReady && now - lastElmReply > ELM_DEAD_MS) {
    Serial.println("[ELM] nem válaszol");
    elmReady = false;
    ecuOnline = false;
    clearLiveValues();
    voltage = NAN;
    tElmRetry = now;
  }
  if (!elmReady && now - tElmRetry >= ELM_RETRY_MS) {
    tElmRetry = now;
    elmReady = elmInit();
    now = millis();
  }

  if (now - tPacket < PACKET_INTERVAL_MS) { delay(5); return; }
  tPacket = now;

  // Adapter nélkül is megy csomag ("elm": false), hogy az app ki tudja írni a hibát.
  if (elmReady) {
    if (ecuOnline) {
      pollFast();
    } else if (now - tProbe >= OFFLINE_PROBE_MS) {
      tProbe = now;
      uint8_t b[4];
      markEcuResult(queryPid(0x00, 4, b, probeTimeout()));
    }
    pollScheduled(now);
    checkProtocolFallback(now);
  }
  updateEngineState();

  String json = buildPacket();
  bleSend(json);
  if (seq % 4 == 0) Serial.println(json);

  if (ENABLE_DEEP_SLEEP && !ecuOnline && millis() - lastEcuSeen > SLEEP_AFTER_MS &&
      (isnan(voltage) || voltage < CHARGING_VOLTAGE)) {
    goToSleep();
  }
}

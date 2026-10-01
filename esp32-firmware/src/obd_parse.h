/*
 * ELM327 válaszok értelmezése és a parancs whitelist.
 * Külön fájlban, hardver nélkül is tesztelhető (lásd test/test_parse.cpp).
 * Feltételezés: ATE0 (nincs echo), ATL0, ATS0 (nincs szóköz), ATH0 (nincs fejléc).
 */
#pragma once
#include <Arduino.h>
#include <vector>

// ───────────── Biztonsági whitelist ─────────────
static const char* const AT_WHITELIST[] = {
  "ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATAT1", "ATRV", "ATDPN", "ATI"
};

inline bool isHexChar(char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F');
}

/// Csak olvasó parancsok mehetnek ki. Minden más (pl. 04 = hibakód törlés) tiltott.
inline bool isCommandAllowed(String c) {
  c.trim();
  c.toUpperCase();
  for (const char* a : AT_WHITELIST) {
    if (c == a) return true;
  }
  // Protokoll választás: csak az adapter beállítása, az autónak nem megy ki semmi
  if (c.length() == 5 && c.startsWith("ATSP") && isHexChar(c[4])) return true;
  if (c == "03") return true;                        // tárolt hibakódok olvasása
  if (c == "0902") return true;                      // VIN
  if (c.length() == 4 && c.startsWith("01") && isHexChar(c[2]) && isHexChar(c[3])) {
    return true;                                     // Mode 01 élő adat
  }
  return false;
}

inline bool isElmError(const String& r) {
  return r.length() == 0 || r.indexOf("NO DATA") >= 0 || r.indexOf("UNABLE") >= 0 ||
         r.indexOf("ERROR") >= 0 || r.indexOf("STOPPED") >= 0 || r.indexOf("?") >= 0 ||
         r.indexOf("BLOCKED") >= 0;
}

/// Sorokra bontás; a szóközöket eldobja (ha az ATS0 nem érvényesült volna).
inline std::vector<String> splitLines(const String& r) {
  std::vector<String> out;
  String cur;
  for (size_t i = 0; i < r.length(); i++) {
    char c = r[i];
    if (c == '\r' || c == '\n') {
      if (cur.length()) out.push_back(cur);
      cur = "";
    } else if (c != ' ') {
      cur += c;
    }
  }
  if (cur.length()) out.push_back(cur);
  return out;
}

// CAN multi-frame sor: "0:4902...", "1:..."
inline bool isFrameLine(const String& line) {
  return line.length() >= 2 && isHexChar(line[0]) && line[1] == ':';
}

// "0:4902..." -> "4902..."
inline String stripFramePrefix(const String& line) {
  return isFrameLine(line) ? line.substring(2) : line;
}

inline uint8_t hexByte(const String& s, int idx) {
  return (uint8_t)strtol(s.substring(idx, idx + 2).c_str(), nullptr, 16);
}

inline String hex2(uint8_t v) {
  char b[3];
  snprintf(b, sizeof(b), "%02X", v);
  return String(b);
}

/// Mode 01 válasz: megkeresi a "41<pid>" sort és kiolvas n adatbájtot.
inline bool parsePid(const String& resp, uint8_t pid, uint8_t n, uint8_t* out) {
  if (isElmError(resp)) return false;
  String prefix = String("41") + hex2(pid);
  for (const String& raw : splitLines(resp)) {
    String line = stripFramePrefix(raw);
    if (line.startsWith(prefix) && line.length() >= (unsigned)(4 + 2 * n)) {
      for (uint8_t i = 0; i < n; i++) out[i] = hexByte(line, 4 + 2 * i);
      return true;
    }
  }
  return false;
}

/// Mode 09 PID 02 válasz -> 17 karakteres VIN, vagy üres string.
/// CAN (több keretes) és ISO 9141/KWP (soronként 4 karakter) formátumot is kezel.
inline String parseVin(const String& resp) {
  if (isElmError(resp)) return String("");
  String hex;
  for (const String& raw : splitLines(resp)) {
    if (!isFrameLine(raw) && raw.length() <= 3) continue;      // CAN hossz sor, pl. "014"
    String line = stripFramePrefix(raw);
    if (line.startsWith("4902")) line = line.substring(6);     // 49 02 + sorszám
    hex += line;
  }
  String out;
  for (size_t i = 0; i + 1 < hex.length(); i += 2) {
    char c = (char)hexByte(hex, i);
    if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z' && c != 'I' && c != 'O' && c != 'Q')) {
      out += c;
    }
  }
  if (out.length() < 17) return String("");
  return out.substring(out.length() - 17);
}

inline String formatDtc(uint8_t a, uint8_t b) {
  const char letters[] = {'P', 'C', 'B', 'U'};
  char buf[6];
  snprintf(buf, sizeof(buf), "%c%X%X%02X", letters[a >> 6], (a >> 4) & 0x03, a & 0x0F, b);
  return String(buf);
}

/// Mode 03 válasz -> hibakód lista. CAN-en a 43 után darabszám bájt jön, régi protokollon nem.
/// - Returns: false, ha a válasz hibás (ilyenkor a korábbi lista maradjon érvényben).
inline bool parseDtcs(const String& resp, bool isCan, size_t maxCodes, std::vector<String>& out) {
  if (resp.indexOf("NO DATA") >= 0) { out.clear(); return true; }  // nincs tárolt hiba
  if (isElmError(resp)) return false;

  std::vector<String> lines = splitLines(resp);
  std::vector<String> msgs;
  bool multiFrame = false;
  for (const String& l : lines) if (isFrameLine(l)) multiFrame = true;

  if (multiFrame) {
    String joined;
    for (const String& l : lines) if (isFrameLine(l)) joined += stripFramePrefix(l);
    msgs.push_back(joined);
  } else {
    msgs = lines;
  }

  std::vector<String> found;
  bool sawReply = false;
  for (const String& m : msgs) {
    if (!m.startsWith("43")) continue;
    sawReply = true;
    int pos = 2;
    int count = 99;
    if (isCan) { count = hexByte(m, 2); pos = 4; }
    for (int i = 0; i < count && pos + 4 <= (int)m.length(); i++, pos += 4) {
      uint8_t a = hexByte(m, pos), b = hexByte(m, pos + 2);
      if (a == 0 && b == 0) continue;
      String code = formatDtc(a, b);
      bool dup = false;
      for (const String& f : found) if (f == code) dup = true;
      if (!dup && found.size() < maxCodes) found.push_back(code);
    }
  }
  if (!sawReply) return false;
  out = found;
  return true;
}

/// ATRV válasz ("14.2V") -> volt, vagy NAN.
inline float parseVoltage(const String& resp) {
  for (const String& line : splitLines(resp)) {
    if (line.length() < 2 || line[0] < '0' || line[0] > '9') continue;
    float v = line.toFloat();
    if (v > 5.0f && v < 20.0f) return v;
  }
  return NAN;
}

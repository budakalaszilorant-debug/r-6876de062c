// Az OBD dugó (ELM327) válasz-értelmezőjének és csak-olvasás szűrőjének tesztjei.
import Foundation

var failed = 0, passed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL line \(line): \(what)") }
}
func rpm(_ b: [UInt8]?) -> Int? { b.map { (Int($0[0]) * 256 + Int($0[1])) / 4 } }

// ── Whitelist: csak olvasás ──
for c in ["010C", "0105", "01A6", "03", "07", "0A", "0902", "020C00", "020200", "ATRV", "ATSP0", "ATSP6", " atz "] {
    check(Elm.isAllowed(c), "allowed \(c)")
}
for c in ["04", "0400", "08", "0800", "2E1234", "3101", "1003", "0904", "01", "010C1", "010C\r04", "ATMA",
          "ATPP2CSV01", "ATSH7E0", "ATSPZ", "020C01", "020C", ""] {
    check(!Elm.isAllowed(c), "blocked \(c)")
}

// ── Mode 01 ──
check(rpm(Elm.pid("410C1AF8", 0x0C, count: 2)) == 1726, "rpm")
check(Elm.pid("41 0C 1A F8", 0x0C, count: 2) == [0x1A, 0xF8], "rpm spaced")
check(Elm.pid("41057B", 0x05, count: 1).map { Int($0[0]) - 40 } == 83, "coolant")
check(Elm.pid("410C0FA0\r410C0FA0", 0x0C, count: 2)?[0] == 0x0F, "two ECUs")
check(Elm.pid("BUSINIT:...OK\r4100BE3FA813", 0x00, count: 4) == [0xBE, 0x3F, 0xA8, 0x13], "bus init")
check(Elm.pid("014\r0:4100BE3FA813", 0x00, count: 4)?[1] == 0x3F, "framed")
for bad in ["NO DATA", "CAN ERROR", "UNABLE TO CONNECT", "?", "", "410C1A"] {
    check(Elm.pid(bad, 0x0C, count: 2) == nil, "pid error \(bad)")
}
check(Elm.pid("41051A", 0x0C, count: 1) == nil, "other pid")
check(Elm.pid("41421388", 0x42, count: 2).map { Int($0[0]) * 256 + Int($0[1]) } == 5000, "module voltage")

// ── Freeze frame ──
check(rpm(Elm.freeze("420C001AF8", 0x0C, count: 2)) == 1726, "freeze rpm")
check(Elm.freeze("42 05 00 7B", 0x05, count: 1)?[0] == 0x7B, "freeze spaced")
check(Elm.freeze("4202000420", 0x02, count: 2).map { Elm.formatDtc($0[0], $0[1]) } == "P0420", "freeze dtc")
check(Elm.freeze("NO DATA", 0x0C, count: 2) == nil, "freeze no data")
check(Elm.freeze("420C00", 0x0C, count: 2) == nil, "freeze short")
check(Elm.freeze("410C1AF8", 0x0C, count: 2) == nil, "freeze wrong mode")

// ── VIN ──
check(Elm.vin("014\r0:4902014A4631\r1:47523745353941\r2:47303030303031") == "JF1GR7E59AG000001", "vin can")
check(Elm.vin("014\r0: 49 02 01 4A 46 31\r1: 47 52 37 45 35 39 41\r2: 47 30 30 30 30 30 31") == "JF1GR7E59AG000001", "vin spaced")
check(Elm.vin("4902010000004A\r49020246314752\r49020337453539\r49020441473030\r49020530303031") == "JF1GR7E59AG000001", "vin iso")
check(Elm.vin("NO DATA") == nil, "vin no data")
check(Elm.vin("014\r0:4902014A4631") == nil, "vin short")

// ── Hibakódok ──
check(Elm.dtcs("43020420030100", isCan: true, max: 10) == ["P0420", "P0301"], "can single")
check(Elm.dtcs("4300", isCan: true, max: 10) == [], "can none")
check(Elm.dtcs("00A\r0:430401330420\r1:03010302000000", isCan: true, max: 10) == ["P0133", "P0420", "P0301", "P0302"], "can multi")
check(Elm.dtcs("43010420\r4300", isCan: true, max: 10) == ["P0420"], "two ECUs")
check(Elm.dtcs("43013304200000", isCan: false, max: 10) == ["P0133", "P0420"], "iso")
check(Elm.dtcs("4301C100", isCan: true, max: 10) == ["U0100"], "U code")
check(Elm.dtcs("43014300", isCan: true, max: 10) == ["C0300"], "C code")
check(Elm.dtcs("43019234", isCan: true, max: 10) == ["B1234"], "B code")
check(Elm.dtcs("43020420042000", isCan: true, max: 10) == ["P0420"], "dedupe")
check(Elm.dtcs("NO DATA", isCan: true, max: 10) == [], "no data")
check(Elm.dtcs("CAN ERROR", isCan: true, max: 10) == nil, "error keeps old")
check(Elm.dtcs("7F0312", isCan: true, max: 10) == nil, "negative reply")
check(Elm.dtcs("43030101010201030104", isCan: true, max: 2)?.count == 2, "cap")
check(Elm.dtcs("47010171", isCan: true, max: 10, replyPrefix: "47") == ["P0171"], "pending")
check(Elm.dtcs("43010171", isCan: true, max: 10, replyPrefix: "47") == nil, "pending wrong mode")
check(Elm.dtcs("4A010420", isCan: true, max: 10, replyPrefix: "4A") == ["P0420"], "permanent")

// ── Feszültség ──
check(abs((Elm.voltage("14.2V") ?? 0) - 14.2) < 0.01, "volt")
check(abs((Elm.voltage("ATRV\r12.6V") ?? 0) - 12.6) < 0.01, "volt echo")
check(Elm.voltage("?") == nil && Elm.voltage("") == nil && Elm.voltage("0.0V") == nil, "volt invalid")

// Repair safety: malformed, absent, moving and mixed ECU responses never count as stopped.
check(Elm.stoppedReply("41 0C 00 00", pid: "0C", bytes: 2), "engine-off positive response")
check(Elm.stoppedReply("410D00", pid: "0D", bytes: 1), "stationary positive response")
for r in ["", "NO DATA", "410C", "410CZZZZ", "410C000", "410C0001", "410C0000\r410C0100", "410C0000\r7F0111"] {
    check(!Elm.stoppedReply(r, pid: "0C", bytes: 2), "unsafe engine reply rejected \(r)")
}
check(Elm.clearAcknowledged("44\r440000"), "multiple positive clear acknowledgements")
for r in ["", "OK", "NO DATA", "7F0411", "4401", "44\r7F0411", "440", "0444"] {
    check(!Elm.clearAcknowledged(r), "ambiguous clear ack rejected \(r)")
}
check(Elm.confirmedDTCs("4300", isCan: true) == [], "positive empty code list")
check(Elm.confirmedDTCs("43010300", isCan: true) == ["P0300"], "confirmed code")
check(Elm.confirmedDTCs("430000", isCan: false) == [], "legacy positive empty list")
for r in ["", "NO DATA", "4301", "430", "4300ZZ", "4302FFFF", "4300\r7F0311"] {
    check(Elm.confirmedDTCs(r, isCan: true) == nil, "no false successful verification \(r)")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

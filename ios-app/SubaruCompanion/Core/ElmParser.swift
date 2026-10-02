import Foundation

/// ELM327 parancs-szűrő és válasz-értelmező a közvetlenül csatlakoztatott OBD dugóhoz.
/// Feltételezés: ATE0 (nincs echo), ATL0, ATS0 (nincs szóköz), ATH0 (nincs fejléc).
enum Elm {
    // MARK: Biztonsági whitelist: csak olvasó parancsok mehetnek ki

    private static let atWhitelist: Set<String> = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATAT1", "ATRV", "ATDPN", "ATI"]

    private static func isHex(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("A"..."F").contains(c)
    }

    /// Csak olvasó parancsok engedélyezettek. Minden más (pl. 04 = hibakód törlés, 08, 2E, 31) tiltott.
    static func isAllowed(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ch = Array(c)
        if atWhitelist.contains(c) { return true }
        // Protokoll választás: csak az adapter beállítása, az autónak nem megy ki semmi
        if ch.count == 5, c.hasPrefix("ATSP"), isHex(ch[4]) { return true }
        if c == "03" || c == "07" || c == "0A" || c == "0902" { return true }       // hibakódok, VIN olvasása
        if ch.count == 4, c.hasPrefix("01"), isHex(ch[2]), isHex(ch[3]) { return true }   // Mode 01 élő adat
        // Mode 02: a hibakód keletkezésekor rögzített adatok (freeze frame), 00-s keret
        if ch.count == 6, c.hasPrefix("02"), isHex(ch[2]), isHex(ch[3]), ch[4] == "0", ch[5] == "0" { return true }
        return false
    }

    // MARK: Válaszok

    static func isError(_ r: String) -> Bool {
        r.isEmpty || r.contains("NO DATA") || r.contains("UNABLE") || r.contains("ERROR") ||
            r.contains("STOPPED") || r.contains("?") || r.contains("BLOCKED")
    }

    /// Sorokra bontás; a szóközöket eldobja (ha az ATS0 nem érvényesült volna).
    static func lines(_ r: String) -> [String] {
        r.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.filter { $0 != " " } }
            .filter { !$0.isEmpty }
    }

    /// CAN több keretes sor: "0:4902...", "1:..."
    static func isFrameLine(_ line: String) -> Bool {
        let c = Array(line)
        return c.count >= 2 && isHex(c[0]) && c[1] == ":"
    }

    static func stripFrame(_ line: String) -> String {
        isFrameLine(line) ? String(line.dropFirst(2)) : line
    }

    /// Két hex karakter a megadott pozíción (érvénytelen vagy hiányzó karakternél 0).
    static func hexByte(_ s: String, _ index: Int) -> UInt8 {
        let c = Array(s)
        guard index >= 0, index + 2 <= c.count else { return 0 }
        return UInt8(String(c[index..<index + 2]), radix: 16) ?? 0
    }

    static func hex2(_ v: UInt8) -> String { String(format: "%02X", v) }

    private static func bytes(_ resp: String, prefix: String, dataStart: Int, count: Int) -> [UInt8]? {
        guard !isError(resp) else { return nil }
        for raw in lines(resp) {
            let line = stripFrame(raw)
            if line.hasPrefix(prefix), line.count >= dataStart + 2 * count {
                return (0..<count).map { hexByte(line, dataStart + 2 * $0) }
            }
        }
        return nil
    }

    /// Mode 01 válasz: a "41<pid>" sorból `count` adatbájt.
    static func pid(_ resp: String, _ pid: UInt8, count: Int) -> [UInt8]? {
        bytes(resp, prefix: "41" + hex2(pid), dataStart: 4, count: count)
    }

    /// Mode 02 válasz: "42<pid><keret>" után `count` adatbájt.
    static func freeze(_ resp: String, _ pid: UInt8, count: Int) -> [UInt8]? {
        bytes(resp, prefix: "42" + hex2(pid), dataStart: 6, count: count)
    }

    /// Mode 09 PID 02 válasz -> 17 karakteres VIN. CAN (több keretes) és ISO 9141/KWP formátum is.
    static func vin(_ resp: String) -> String? {
        guard !isError(resp) else { return nil }
        var hex = ""
        for raw in lines(resp) {
            if !isFrameLine(raw) && raw.count <= 3 { continue }        // CAN hossz sor, pl. "014"
            var line = stripFrame(raw)
            if line.hasPrefix("4902") { line = String(line.dropFirst(6)) }  // 49 02 + sorszám
            hex += line
        }
        var out = ""
        var i = 0
        let count = hex.count
        while i + 1 < count {
            let c = Character(UnicodeScalar(hexByte(hex, i)))
            if c.isASCII, c.isNumber || (c.isUppercase && c != "I" && c != "O" && c != "Q") { out.append(c) }
            i += 2
        }
        return out.count >= 17 ? String(out.suffix(17)) : nil
    }

    static func formatDtc(_ a: UInt8, _ b: UInt8) -> String {
        let letters: [Character] = ["P", "C", "B", "U"]
        return String(letters[Int(a >> 6)]) + String(format: "%X%X%02X", (a >> 4) & 0x03, a & 0x0F, b)
    }

    /// Mode 03 / 07 / 0A válasz -> hibakódok. A válasz első bájtja a mód + 0x40 (43, 47, 4A).
    /// CAN-en ezután darabszám bájt jön, régi protokollon nem.
    /// - Returns: nil, ha a válasz hibás (ilyenkor a korábbi lista maradjon érvényben).
    static func dtcs(_ resp: String, isCan: Bool, max: Int, replyPrefix: String = "43") -> [String]? {
        if resp.contains("NO DATA") { return [] }   // nincs tárolt hiba
        guard !isError(resp) else { return nil }

        let all = lines(resp)
        let multiFrame = all.contains(where: isFrameLine)
        let messages = multiFrame ? [all.filter(isFrameLine).map(stripFrame).joined()] : all

        var found: [String] = []
        var sawReply = false
        for m in messages where m.hasPrefix(replyPrefix) {
            sawReply = true
            var pos = 2
            var count = 99
            if isCan {
                count = Int(hexByte(m, 2))
                pos = 4
            }
            var i = 0
            while i < count && pos + 4 <= m.count {
                let a = hexByte(m, pos), b = hexByte(m, pos + 2)
                if a != 0 || b != 0 {
                    let code = formatDtc(a, b)
                    if !found.contains(code) && found.count < max { found.append(code) }
                }
                i += 1
                pos += 4
            }
        }
        return sawReply ? found : nil
    }

    /// ATRV válasz ("14.2V") -> volt, vagy nil.
    static func voltage(_ resp: String) -> Double? {
        for line in lines(resp) {
            guard let first = line.first, first.isNumber, line.count >= 2 else { continue }
            let number = line.prefix { $0.isNumber || $0 == "." }
            if let v = Double(number), v > 5, v < 20 { return v }
        }
        return nil
    }
}

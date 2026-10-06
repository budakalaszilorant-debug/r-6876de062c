import Foundation
import UIKit

/// Printable, paginated owner report. Its identifier is not a certification or signature.
enum SaleReport {
    static func create(_ sheet: SaleSheetData) throws -> URL {
        let created = Date()
        let id = UUID().uuidString
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let pdf = renderer.pdfData { context in
            var y: CGFloat = 48
            var page = 0
            func newPage() {
                context.beginPage(); page += 1; y = 48
                UIColor.white.setFill(); context.cgContext.fill(bounds)
                ("GARÁZS  /  " + tr("ELADÁSI ADATLAP", "VEHICLE REPORT") as NSString).draw(at: CGPoint(x: 40, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.darkGray])
                ("\(page) · \(id.prefix(8))" as NSString).draw(at: CGPoint(x: 40, y: 810), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
            }
            func text(_ value: String, size: CGFloat = 12, bold: Bool = false, color: UIColor = .black) {
                let style = NSMutableParagraphStyle(); style.lineSpacing = 4
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), .paragraphStyle: style, .foregroundColor: color]
                let measured = (value as NSString).boundingRect(with: CGSize(width: 515, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).height
                if y + measured > 780 { newPage() }
                (value as NSString).draw(in: CGRect(x: 40, y: y, width: 515, height: measured + 2), withAttributes: attrs)
                y += measured + 14
            }
            func heading(_ value: String) {
                if y > 700 { newPage() }
                y += 12
                text(value.uppercased(), size: 10, bold: true, color: UIColor(red: 0.15, green: 0.35, blue: 0.65, alpha: 1))
            }
            newPage()
            text(sheet.carName, size: 26, bold: true)
            text(sheet.fuel + " · " + Fmt.date(created), color: .darkGray)
            if let encoded = AppSettings.shared.carPhoto, let bytes = Data(base64Encoded: encoded), let image = UIImage(data: bytes) {
                let height: CGFloat = 180
                let scale = min(515 / image.size.width, height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: 40 + (515-size.width)/2, y: y, width: size.width, height: size.height))
                y += height + 18
            }
            if let vin = sheet.vin { text("VIN: " + vin, bold: true) }
            text(tr("Kilométeróra: ", "Odometer: ") + (sheet.odometer.map { Fmt.km($0) + " km" } ?? tr("nincs megadva", "not provided")))
            text(tr("A kilométeróra kézzel megadott vagy az app által továbbvezetett érték; nem hitelesített futásteljesítmény.", "The odometer is entered by the owner or accumulated by the app; it is not verified mileage."), size: 10, color: .darkGray)
            heading(tr("Rögzített használat", "Recorded use"))
            text(tr("\(sheet.trips) út · \(Fmt.km(sheet.totalKm)) km · \(sheet.fills) tankolás", "\(sheet.trips) trips · \(Fmt.km(sheet.totalKm)) km · \(sheet.fills) fill-ups"), size: 17, bold: true)
            if let first = sheet.firstRecord { text(tr("Napló kezdete: ", "Records since: ") + Fmt.date(first)) }
            text(tr("Tankolásokból számított átlag: ", "Average from fuel logs: ") + (sheet.avgL100.map { Fmt.one($0) + " l/100 km" } ?? tr("nincs elég adat", "insufficient data")))
            heading(tr("Diagnosztikai pillanatkép", "Diagnostic snapshot"))
            if let reading = sheet.diagnostic {
                text(Fmt.date(reading.date))
                text(reading.codes.isEmpty ? tr("A méréskor nem érkezett tárolt emissziós hibakód.", "No stored emissions fault codes were returned at the time of measurement.") : reading.codes.joined(separator: ", "))
                text(tr("Ez egy korábbi OBD-leolvasás, nem teljes körű állapotvizsgálat.", "This is a recorded OBD reading, not a comprehensive inspection."), size: 10, color: .darkGray)
            } else { text(tr("Nincs mentett, visszaigazolt OBD-hibakód-leolvasás.", "No confirmed OBD fault-code reading has been saved.")) }
            heading(tr("Szerviznyilvántartás", "Service records"))
            text(tr("A tulajdonos által rögzített bejegyzések. A számlák külön ellenőrizhetők.", "Entries recorded by the owner. Receipts should be checked separately."), size: 10, color: .darkGray)
            if sheet.services.isEmpty { text(tr("Nincs rögzített szerviz.", "No service records.")) }
            for service in sheet.services {
                text(service.name + "\n" + Fmt.date(service.date) + " · " + Fmt.km(service.km) + " km", bold: true)
            }
            heading(tr("A dokumentumról", "About this report"))
            text(tr("A Garázs app helyi naplójából készült tulajdonosi összefoglaló. Nem független szakvélemény, nem bizonyítja az előélet teljességét vagy az adatok módosíthatatlanságát.", "An owner report generated from the Garage app's local records. It is not an independent inspection and does not prove a complete or tamper-proof history."), size: 10, color: .darkGray)
            text(tr("Dokumentumazonosító: ", "Document ID: ") + id, size: 9, color: .gray)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SaleReports/" + AccountGarage.exportNamespace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Garazs-\(id.prefix(8)).pdf")
        try pdf.write(to: file, options: .atomic)
        return file
    }
}

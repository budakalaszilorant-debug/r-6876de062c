import SwiftUI
import Charts

struct OwnershipMonth: Identifiable {
    var date: Date
    var total: Double
    var km: Double
    var id: Date { date }
}
struct OwnershipCostsView: View {
    @State private var months: [OwnershipMonth] = []
    private var total: Double { months.reduce(0) { $0 + $1.total } }
    private var km: Double { months.reduce(0) { $0 + $1.km } }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            SectionLabel(text: tr("FENNTARTÁS · 12 HÓNAP", "OWNERSHIP · 12 MONTHS"))
            HStack(alignment: .top) {
                VStack(alignment: .leading) { Text("\(Fmt.km(total/12)) Ft").font(.title2.bold()); Text(tr("havi átlag", "monthly average")).font(.caption).foregroundStyle(Theme.text2) }
                Spacer()
                VStack(alignment: .trailing) { Text(km > 10 ? "\(Fmt.one(total/km)) Ft/km" : "—").font(.title2.bold()); Text(tr("rögzített km alapján", "per logged km")).font(.caption).foregroundStyle(Theme.text2) }
            }
            Chart(months) { month in
                BarMark(x: .value(tr("Hónap", "Month"),month.date,unit: .month),y: .value("Ft",month.total)).foregroundStyle(Theme.accent)
            }.frame(height: 150)
            Text(tr("Az összes felvitt tankolás és költség alapján. \(Fmt.km(km)) km szerepel az útnaplóban. A hiányzó utak, számlák és az értékcsökkenés nincsenek megbecsülve; ez nem a teljes valós költség igazolása.", "Based on recorded refuelling and expenses, with \(Fmt.km(km)) km in the trip log. Missing trips, receipts and depreciation are not estimated; this is not a verified total ownership cost.")).font(.caption).foregroundStyle(Theme.text2)
        }.onAppear {
            let calendar = Calendar.current
            let current = calendar.date(from: calendar.dateComponents([.year,.month],from: Date()))!
            months = (-11...0).map { offset in
                let start = calendar.date(byAdding: .month,value: offset,to: current)!
                let end = calendar.date(byAdding: .month,value: 1,to: start)!
                let args: [Any?] = [CarStore.activeId,start.timeIntervalSince1970,end.timeIntervalSince1970]
                let db = Database.shared
                let fuel = db.query("SELECT SUM(cost) FROM fills WHERE car_id=? AND date>=? AND date<?",args) { $0.double(0) }.first ?? 0
                let expenses = db.query("SELECT SUM(amount) FROM expenses WHERE car_id=? AND date>=? AND date<?",args) { $0.double(0) }.first ?? 0
                let distance = db.query("SELECT SUM(distance_km) FROM trips WHERE car_id=? AND start>=? AND start<? AND end_t IS NOT NULL",args) { $0.double(0) }.first ?? 0
                return OwnershipMonth(date: start,total: fuel+expenses,km: distance)
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Műszerfal testreszabása

struct DashboardEditor: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(settings.dashOrder) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !settings.dashHidden.contains(section) },
                        set: { on in
                            if on { settings.dashHidden.remove(section) } else { settings.dashHidden.insert(section) }
                        }))
                    .tint(Theme.ok)
                }
                .onMove { from, to in
                    settings.dashOrder.move(fromOffsets: from, toOffset: to)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle(tr("Műszerfal", "Dashboard"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Lejáratok

struct RemindersCard: View {
    @State private var dates: [String: Date] = [:]
    @State private var editing: ReminderItem?

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Reminders.items) { item in
                    Button {
                        editing = item
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.text3)
                                .frame(width: 24)
                            Text(item.name)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            status(for: item)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    if item.id != Reminders.items.last?.id {
                        Divider().overlay(Theme.stroke).padding(.leading, 52)
                    }
                }
            }
        }
        .onAppear { dates = Reminders.all() }
        .sheet(item: $editing) { item in
            ReminderSheet(item: item, current: dates[item.id]) { dates = Reminders.all() }
                .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private func status(for item: ReminderItem) -> some View {
        if let date = dates[item.id] {
            let days = Reminders.daysLeft(date)
            Text(days < 0 ? tr("Lejárt", "Expired")
                          : (days == 0 ? tr("Ma jár le", "Expires today") : tr("\(days) nap", "\(days) days")))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(days < 0 ? Theme.bad : (days <= 30 ? Theme.warn : Theme.ok))
        } else {
            Text(tr("Beállítás", "Set"))
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
        }
    }
}

struct ReminderSheet: View {
    let item: ReminderItem
    let current: Date?
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(tr("Lejárat napja", "Expiry date"), selection: $date, displayedComponents: .date)
                if current != nil {
                    Button(tr("Emlékeztető törlése", "Remove reminder"), role: .destructive) {
                        Reminders.set(item.id, date: nil)
                        onChange()
                        dismiss()
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Mégse", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Mentés", "Save")) {
                        Reminders.set(item.id, date: date)
                        Haptics.success()
                        onChange()
                        dismiss()
                    }
                }
            }
            .onAppear { if let current { date = current } }
        }
    }
}

// MARK: - Észlelt tankolás

struct SuggestedFillCard: View {
    let liters: Double
    let onLog: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "fuelpump.fill").foregroundStyle(Theme.accent)
                    Text(tr("Tankolás észlelve: kb. \(Int(liters)) l", "Fill-up detected: about \(Int(liters)) l"))
                        .font(.system(size: 16, weight: .semibold))
                }
                HStack(spacing: 10) {
                    PrimaryButton(title: tr("Rögzítés", "Log it"), action: onLog)
                    PrimaryButton(title: tr("Elvetés", "Dismiss"), tint: Theme.surface2, action: onDismiss)
                }
            }
        }
    }
}

// MARK: - Mentés és visszaállítás (Beállítások)

struct BackupSection: View {
    @EnvironmentObject var monitor: VehicleMonitor
    @State private var shareURL: URL?
    @State private var importing = false
    @State private var pendingImport: URL?
    @State private var message: String?

    var body: some View {
        Section(tr("Adatmentés", "Backup")) {
            HStack {
                Text(tr("Utolsó mentés", "Last backup"))
                Spacer()
                Text(Backup.lastBackup.map(Fmt.date) ?? "—").foregroundStyle(Theme.text2)
            }
            Button(tr("Mentés készítése és megosztása", "Create and share backup")) {
                if let url = Backup.writeFile() {
                    shareURL = url
                } else {
                    message = tr("A mentés nem sikerült.", "Backup failed.")
                }
            }
            Button(tr("Visszaállítás fájlból", "Restore from file")) { importing = true }.disabled(!monitor.canManageGarage)
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ActivityView(items: [shareURL]) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { pendingImport = url }
        }
        .alert(tr("Visszaállítod az adatokat?", "Restore data?"),
               isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button(tr("Visszaállítás", "Restore"), role: .destructive) {
                guard monitor.canManageGarage, let url = pendingImport else { return }
                do {
                    let rows = try Backup.restore(from: url)
                    monitor.reloadAfterRestore()
                    message = tr("Visszaállítva: \(rows) sor.", "Restored \(rows) rows.")
                } catch {
                    message = tr("A fájl nem érvényes mentés.", "This file is not a valid backup.")
                }
            }
            Button(tr("Mégse", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("A jelenlegi utak, tankolások és beállítások helyére a fájl tartalma kerül.",
                    "Current trips, fill-ups and settings will be replaced with the file's contents."))
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

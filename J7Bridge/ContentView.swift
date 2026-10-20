import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView {
            PhoneView()
                .tabItem { Label("Phone", systemImage: "phone.fill") }
            RecentsView()
                .tabItem { Label("Recents", systemImage: "clock") }
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.green)
        .onAppear { app.start() }
    }
}

struct PhoneView: View {
    @EnvironmentObject var app: AppModel

    private let buttons = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    numberDisplay
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(buttons, id: \.self) { button in
                            Button(button) { app.tapDialpad(button) }
                                .font(.system(size: 30, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .frame(height: 64)
                                .background(.thinMaterial, in: Circle())
                        }
                    }
                    actionRow
                }
                .padding()
            }
            .navigationTitle("J7Bridge")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Wi-Fi " + app.wifiStatus, systemImage: app.wifiStatus == "Connected" ? "wifi" : "wifi.exclamationmark")
                Spacer()
                Text("J7 " + app.j7Host).foregroundStyle(.secondary)
            }
            HStack {
                Label("BLE " + app.bleStatus, systemImage: app.bleStatus == "Connected" ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                Spacer()
            }
            HStack {
                Label("iPhone IP", systemImage: "iphone")
                Spacer()
                Text(app.iPhoneIPv4).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var numberDisplay: some View {
        let display: String
        if app.callStatus == "ACTIVE" {
            display = app.callerName.isEmpty ? app.number : app.callerName
        } else if app.callStatus == "DIALING" || app.callStatus == "RINGING" {
            display = app.callerName.isEmpty ? app.number : app.callerName
        } else {
            display = app.dialString.isEmpty ? "Enter number" : app.dialString
        }

        return HStack {
            Text(display)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer()
            if !app.dialString.isEmpty && app.callStatus == "IDLE" {
                Button { app.backspaceDialpad() } label: { Image(systemName: "delete.left") }
            }
        }
        .padding(.horizontal, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            if app.callStatus == "ACTIVE" || app.callStatus == "DIALING" || app.callStatus == "RINGING" {
                Button(role: .destructive) { app.endCall() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .frame(width: 74, height: 58)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { app.makeCall() } label: {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .frame(width: 74, height: 58)
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.dialString.isEmpty)
            }
        }
    }
}

struct RecentsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                if app.history.records.isEmpty {
                    EmptyStateView(title: "No Calls", systemImage: "clock", message: "J7Bridge call history will appear here.")
                } else {
                    ForEach(app.history.records) { record in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: record.direction))
                                .foregroundStyle(record.direction == .missed ? .red : .green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name ?? record.number).font(.headline)
                                if let name = record.name { Text(record.number).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(record.date, style: .time).font(.caption)
                                Text(record.direction.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button { app.dialString = record.number } label: {
                                Label("Dial", systemImage: "phone.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recents")
            .toolbar {
                if !app.history.records.isEmpty {
                    Button("Clear") { app.clearHistory() }
                }
            }
        }
    }

    private func icon(for direction: CallDirection) -> String {
        switch direction {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed: return "phone.arrow.down.left"
        }
    }
}

struct ContactsView: View {
    @EnvironmentObject var app: AppModel
    @State private var search = ""
    @State private var showAdd = false

    var filtered: [AppContact] {
        guard !search.isEmpty else { return app.contacts.contacts }
        return app.contacts.contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.contacts.authorization != .authorized {
                    EmptyStateView(title: "Contacts Access", systemImage: "person.crop.circle.badge.xmark", message: "Allow Contacts access to resolve caller names and add contacts.")
                } else {
                    List(filtered) { contact in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contact.displayName).font(.headline)
                            ForEach(contact.phones, id: \.self) { phone in
                                Button(phone) { app.dialString = phone }
                                    .font(.subheadline)
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Search contacts")
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { app.requestContacts() } label: { Image(systemName: "arrow.clockwise") }
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .onAppear { app.requestContacts() }
            .sheet(isPresented: $showAdd) { NewContactView() }
        }
    }
}

struct NewContactView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppModel
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                Button("Save") {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !phone.isEmpty else { return }
                    app.contacts.addContact(name: name, phone: phone)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || phone.isEmpty)
            }
            .navigationTitle("New Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}


struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var j7HostDraft = ""
    @State private var j7HostError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("IKOS K7").font(.headline)
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(app.wifiStatus).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("BLE control")
                            Spacer()
                            Text(app.bleStatus).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Device")
                            Spacer()
                            Text("J7 " + app.j7Host).foregroundStyle(.secondary)
                        }
                        Picker("SIM slot", selection: $app.simSlot) {
                            Text("SIM 1").tag(0)
                            Text("SIM 2").tag(1)
                        }
                        Button("Refresh J7 info") { app.requestDeviceInfo() }
                        HStack {
                            Text("Battery")
                            Spacer()
                            Text(app.battery).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Firmware")
                            Spacer()
                            Text(app.firmware).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack {
                            Text("IMEI")
                            Spacer()
                            Text(app.imei).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("J7 Hotspot IP").font(.headline)
                        TextField("192.168.45.94", text: $j7HostDraft)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save J7 IP") { saveJ7Host() }
                            .buttonStyle(.borderedProminent)
                        if let error = j7HostError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        Text("Enter the J7's current hotspot IPv4 address. The setting is saved on this iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Calling").font(.headline)
                        Toggle("Auto-start Wi-Fi", isOn: $app.autoConnect)
                        Toggle("Resolve caller names", isOn: $app.resolveCallerNames)
                        Toggle("Missed-call notifications", isOn: $app.missedCallNotifications)
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Permissions").font(.headline)
                        Button("Allow Contacts") { app.requestContacts() }
                        Button("Allow Notifications") { app.notifications.requestPermission() }
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Audio").font(.headline)
                        HStack {
                            Text("Microphone")
                            Spacer()
                            Text(app.voiceStatus == "CLOSED" ? "OFF — idle" : "ON — active call")
                                .foregroundStyle(.secondary)
                        }
                        Text("Wi-Fi voice uses raw 48 kHz stereo PCM. During real calls, audio starts after CallKit activates the audio session.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("About").font(.headline)
                        HStack {
                            Text("CALLSHARE")
                            Spacer()
                            Text("Wi-Fi R1")
                        }
                        Text("UDP 50005 • J7WV raw PCM")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding()
            }
            .navigationTitle("Settings")
            .onAppear {
                if j7HostDraft.isEmpty {
                    j7HostDraft = app.j7Host
                }
            }
            .onChange(of: app.j7Host) { newValue in
                j7HostDraft = newValue
                j7HostError = nil
            }
        }
    }

    private func saveJ7Host() {
        let cleaned = j7HostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        let validIPv4 = octets.count == 4 && octets.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        }

        guard validIPv4 else {
            j7HostError = "Enter a valid IPv4 address, e.g. 192.168.45.94."
            return
        }

        let normalized = octets.map { String($0) }.joined(separator: ".")
        app.j7Host = normalized
        j7HostDraft = normalized
        j7HostError = nil
    }
}

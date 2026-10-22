import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    private var shouldShowCallScreen: Bool {
        app.callStatus == "DIALING" || app.callStatus == "RINGING" || app.callStatus == "ACTIVE"
    }

    var body: some View {
        ZStack {
            TabView(selection: $app.selectedTab) {
                PhoneView()
                    .tabItem { Label("Phone", systemImage: "phone.fill") }
                    .tag(0)
                RecentsView()
                    .tabItem { Label("Recents", systemImage: "clock") }
                    .tag(1)
                ContactsView()
                    .tabItem { Label("Contacts", systemImage: "person.2") }
                    .tag(2)
                SMSInboxView()
                    .tabItem { Label("Messages", systemImage: "message.fill") }
                    .tag(3)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(4)
            }
            .tint(.green)

            if shouldShowCallScreen {
                InAppCallView()
                    .environmentObject(app)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: app.callStatus)
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
                        Button {
                            app.makeCall(to: record.number)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: record.direction))
                                    .foregroundStyle(record.direction == .missed ? .red : .green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.name ?? record.number).font(.headline)
                                    if record.name != nil {
                                        Text(record.number).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(record.date, style: .time).font(.caption)
                                    Text(record.direction.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button { app.makeCall(to: record.number) } label: {
                                Label("Call", systemImage: "phone.fill")
                            }
                            .tint(.green)
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
                            // Tapping a contact starts a call to its primary phone number.
                            Button {
                                if let phone = contact.phones.first {
                                    app.makeCall(to: phone)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(contact.displayName).font(.headline)
                                        if let phone = contact.phones.first {
                                            Text(phone).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "phone.fill").foregroundStyle(.green)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // Extra numbers remain individually selectable for contacts with multiple numbers.
                            ForEach(Array(contact.phones.dropFirst()), id: \.self) { phone in
                                Button {
                                    app.makeCall(to: phone)
                                } label: {
                                    Label(phone, systemImage: "phone")
                                }
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


struct SMSInboxView: View {
    @EnvironmentObject var app: AppModel
    @State private var path: [CallshareSMSRoute] = []
    @State private var pendingDeleteAddress: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.smsConversations.isEmpty {
                    EmptyStateView(
                        title: "No Messages Yet",
                        systemImage: "message",
                        message: "Incoming SMS messages from the J7 SIM will appear here while CALLSHARE is connected over BLE."
                    )
                } else {
                    List(app.smsConversations) { conversation in
                        NavigationLink(value: CallshareSMSRoute(address: conversation.address, targetMessageID: nil)) {
                            HStack(spacing: 12) {
                                Image(systemName: "message.fill")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(conversation.address).font(.headline)
                                        Spacer(minLength: 8)
                                        Text(conversation.latestMessage.date, style: .time)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(conversation.latestMessage.body.isEmpty ? "(Empty message)" : conversation.latestMessage.body)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(conversation.latestMessage.isOutgoing ? "You" : "Received")
                                        Text("·")
                                        Text(smsStatusLabel(conversation.latestMessage))
                                        if conversation.unreadCount > 0 {
                                            Spacer(minLength: 4)
                                            Text("NEW")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(conversation.latestMessage.status.caseInsensitiveCompare("failed") == .orderedSame ? Color.red : Color.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteAddress = conversation.address
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Messages")
            .navigationDestination(for: CallshareSMSRoute.self) { route in
                SMSConversationView(address: route.address, targetMessageID: route.targetMessageID) {
                    path.removeAll()
                }
            }
            .confirmationDialog("Delete conversation?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Conversation", role: .destructive) {
                    if let address = pendingDeleteAddress {
                        app.deleteSMSConversation(forAddress: address)
                    }
                    pendingDeleteAddress = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteAddress = nil }
            } message: {
                Text("This removes the conversation from CALLSHARE on this iPhone only. It does not delete SMS messages from the J7 SIM.")
            }
            .onAppear { routePendingNotification() }
            .onChange(of: app.pendingSMSNavigationID) { _ in routePendingNotification() }
        }
    }

    private func routePendingNotification() {
        guard let messageID = app.pendingSMSNavigationID else { return }
        app.pendingSMSNavigationID = nil
        guard let message = app.smsMessage(id: messageID) else { return }
        path.append(CallshareSMSRoute(address: message.address, targetMessageID: message.id))
    }
}

struct SMSConversationView: View {
    @EnvironmentObject var app: AppModel
    let address: String
    let targetMessageID: String?
    let onDeleteConversation: () -> Void
    @State private var draft = ""
    @State private var showSendError = false
    @State private var showDeleteConfirmation = false
    @State private var sendError = "The SMS could not be queued. Check BLE connection and the recipient number."

    private var messages: [CallshareSMSMessage] {
        app.smsMessages.filter { $0.address == address }.sorted { $0.timestampMs < $1.timestampMs }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                            Text(message.body.isEmpty ? "(Empty message)" : message.body)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
                            HStack(spacing: 8) {
                                Text(message.date, style: .date)
                                Text(message.date, style: .time)
                                Text("·")
                                Text(smsStatusLabel(message))
                                if message.isOutgoing && message.status.caseInsensitiveCompare("failed") == .orderedSame {
                                    Button("Retry") {
                                        if !app.retrySMS(id: message.id) {
                                            sendError = "Retry could not be queued. Confirm BLE is connected and try again."
                                            showSendError = true
                                        }
                                    }
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(message.status.caseInsensitiveCompare("failed") == .orderedSame ? Color.red : Color.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
                        .background(
                            message.isOutgoing ? Color.green.opacity(0.18) : Color.gray.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .overlay {
                            if message.id == targetMessageID {
                                RoundedRectangle(cornerRadius: 16).stroke(Color.green.opacity(0.8), lineWidth: 1.5)
                            }
                        }
                        .id(message.id)
                    }
                }
                .padding()
            }
            .onAppear {
                app.markSMSRead(forAddress: address)
                scrollToInitialMessage(using: proxy)
            }
            .onChange(of: messages.count) { _ in
                guard targetMessageID == nil, let latest = messages.last else { return }
                withAnimation { proxy.scrollTo(latest.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Text Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Button(action: sendReply) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend ? Color.green : Color.secondary)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send SMS")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .navigationTitle(address)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete conversation")
            }
        }
        .confirmationDialog("Delete conversation?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                app.deleteSMSConversation(forAddress: address)
                onDeleteConversation()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the conversation from CALLSHARE on this iPhone only. It does not delete SMS messages from the J7 SIM.")
        }
        .alert("SMS Not Sent", isPresented: $showSendError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sendError)
        }
        .onAppear { app.markSMSRead(forAddress: address) }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && app.ble.isReady
    }

    private func sendReply() {
        let body = draft
        guard app.sendSMSReply(to: address, body: body) else {
            sendError = "SMS could not be queued. Check that BLE GATT is connected and the number is valid."
            showSendError = true
            return
        }
        draft = ""
    }

    private func scrollToInitialMessage(using proxy: ScrollViewProxy) {
        if let targetMessageID, messages.contains(where: { $0.id == targetMessageID }) {
            DispatchQueue.main.async {
                proxy.scrollTo(targetMessageID, anchor: .center)
            }
        } else if let latest = messages.last {
            DispatchQueue.main.async {
                proxy.scrollTo(latest.id, anchor: .bottom)
            }
        }
    }
}

private func smsStatusLabel(_ message: CallshareSMSMessage) -> String {
    let status = message.status.trimmingCharacters(in: .whitespacesAndNewlines)
    if status.isEmpty { return message.isOutgoing ? "Sending" : "Received" }
    if status.caseInsensitiveCompare("failed") == .orderedSame {
        if let detail = message.statusDetail, !detail.isEmpty { return "Failed · \(detail)" }
        return "Failed"
    }
    switch status.lowercased() {
    case "sending", "pending", "queued": return "Sending"
    case "sent", "success": return "Sent"
    case "delivered": return "Delivered"
    case "received", "incoming": return "Received"
    default: return status.capitalized
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

// CALLSHARE's in-app call screen. The existing CallKit/BLE/audio call path remains authoritative.
struct InAppCallView: View {
    @EnvironmentObject var app: AppModel
    @State private var showsKeypad = false

    private let keypadDigits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    private var displayName: String {
        let name = app.callerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return app.number.isEmpty ? "Unknown caller" : app.number
    }

    private var avatarInitial: String {
        String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.15, blue: 0.22),
                    Color(red: 0.025, green: 0.045, blue: 0.075),
                    Color(red: 0.015, green: 0.025, blue: 0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("CALLSHARE")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .tracking(2.2)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(app.bleStatus == "Connected" ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(app.bleStatus == "Connected" ? "J7 CONNECTED" : "CONNECTING")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)

                Spacer(minLength: 18)

                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.055))
                            .frame(width: 152, height: 152)
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.18, green: 0.55, blue: 0.48), Color(red: 0.08, green: 0.28, blue: 0.34)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 124, height: 124)
                            .overlay {
                                Text(avatarInitial.isEmpty ? "?" : avatarInitial)
                                    .font(.system(size: 46, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                    }

                    Text(displayName)
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 26)

                    if !app.callerName.isEmpty && !app.number.isEmpty {
                        Text(app.number)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.67))
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(statusText(at: timeline.date))
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(app.callStatus == "ACTIVE" ? Color.green : Color.white.opacity(0.78))
                    }
                    .padding(.top, 2)

                    if app.callStatus == "ACTIVE" {
                        Label(app.voiceStatus == "ACTIVE" ? "Voice connected" : "Setting up audio", systemImage: app.voiceStatus == "ACTIVE" ? "waveform" : "hourglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.top, 1)
                    } else if app.callStatus == "DIALING" {
                        Text("Calling through the J7 SIM")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                Spacer(minLength: 20)

                if showsKeypad && app.callStatus == "ACTIVE" {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 12) {
                        ForEach(keypadDigits, id: \.self) { digit in
                            Button { app.tapDialpad(digit) } label: {
                                Text(digit)
                                    .font(.system(size: 24, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color.white.opacity(0.10), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Send DTMF \(digit)")
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.bottom, 16)
                }

                if app.callStatus == "RINGING" {
                    HStack(spacing: 54) {
                        actionButton(title: "Decline", symbol: "phone.down.fill", color: Color(red: 0.83, green: 0.20, blue: 0.25)) {
                            app.endCall()
                        }
                        actionButton(title: "Answer", symbol: "phone.fill", color: Color(red: 0.15, green: 0.68, blue: 0.36)) {
                            app.answerCurrentCallFromInAppScreen()
                        }
                    }
                    .padding(.bottom, 48)
                } else {
                    HStack(spacing: 30) {
                        if app.callStatus == "ACTIVE" {
                            actionButton(
                                title: app.isMuted ? "Unmute" : "Mute",
                                symbol: app.isMuted ? "mic.slash.fill" : "mic.fill",
                                color: app.isMuted ? Color(red: 0.15, green: 0.48, blue: 0.38) : Color.white.opacity(0.13)
                            ) {
                                app.toggleMuteFromInAppScreen()
                            }

                            actionButton(
                                title: showsKeypad ? "Hide Keypad" : "Keypad",
                                symbol: "circle.grid.3x3.fill",
                                color: Color.white.opacity(0.13)
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) { showsKeypad.toggle() }
                            }
                        }

                        actionButton(title: "End Call", symbol: "phone.down.fill", color: Color(red: 0.83, green: 0.20, blue: 0.25)) {
                            app.endCall()
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CALLSHARE call screen")
    }

    private func statusText(at date: Date) -> String {
        switch app.callStatus {
        case "RINGING":
            return "Incoming GSM call"
        case "DIALING":
            return "Calling…"
        case "ACTIVE":
            guard let connectedAt = app.callConnectedAt else { return "Connected" }
            let elapsed = max(0, Int(date.timeIntervalSince(connectedAt)))
            return "Connected · \(formattedDuration(elapsed))"
        default:
            return "Connecting…"
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func actionButton(title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(color, in: Circle())
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }
            .frame(minWidth: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


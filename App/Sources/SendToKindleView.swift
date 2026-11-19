import KSSCore
import SwiftUI
import UniformTypeIdentifiers

/// Right column: drop zone and setup.
struct SendToKindleView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var stk: SendToKindleService
    @State private var targeted = false
    @State private var showPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("An Kindle senden")).font(.system(size: 28, weight: .bold))
                    Text(L("Bücher und Dokumente drahtlos auf deinen Kindle – einfach hierher ziehen. PDFs bleiben im Original-Layout, auf dem Scribe kannst du darauf schreiben."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                dropZone

                if !model.lastSendRejections.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L("Nicht übernommen"), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warm)
                                .font(.callout.weight(.semibold))
                            ForEach(model.lastSendRejections, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }

                setup
            }
            .padding(36)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .navigationTitle(L("An Kindle senden"))
        .fileImporter(isPresented: $showPicker, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.sendToKindle(urls) }
        }
        .sheet(isPresented: $stk.showSignIn) { STKSignInView().environmentObject(model) }
    }

    static let types: [UTType] = STK.formats.sorted().compactMap { UTType(filenameExtension: $0) }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? Theme.accent : .secondary)
                .symbolEffect(.bounce, value: targeted)
            Text(targeted ? L("Loslassen zum Senden") : L("EPUB, PDF, Word, Text oder Bilder hierher ziehen"))
                .font(.title3.weight(.medium))
            Text(L("oder auf das Programmsymbol im Dock ziehen"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("Dateien auswählen …")) { showPicker = true }
                .controlSize(.large)
            if let hint = stk.readinessHint {
                Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.warm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(targeted ? Theme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(targeted ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [7, 5])))
        .animation(.snappy, value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.sendToKindle(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    // MARK: setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("Übertragung"), selection: $stk.method) {
                ForEach(SendToKindleService.Method.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            switch stk.method {
            case .app: appSetup
            case .email: emailSetup
            }

            if let e = stk.lastError {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warm)
            }
        }
    }

    @ViewBuilder private var appSetup: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                if let reg = stk.registration {
                    HStack {
                        Label(reg.userName.isEmpty ? L("Angemeldet") : L("Angemeldet als %@", reg.userName),
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Button(L("Abmelden")) { stk.signOut() }.controlSize(.small)
                    }
                    Divider()
                    HStack {
                        Text(L("Senden an")).font(.headline)
                        Spacer()
                        if stk.loadingDevices { ProgressView().controlSize(.small) }
                        Button { Task { await stk.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help(L("Geräteliste neu laden"))
                    }
                    if stk.devices.isEmpty && !stk.loadingDevices {
                        Text(L("Keine Kindle-Geräte gefunden.")).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(stk.devices) { d in
                        Toggle(isOn: Binding(get: { stk.selectedDevices.contains(d.serial) },
                                             set: { on in
                                                 if on { stk.selectedDevices.insert(d.serial) } else { stk.selectedDevices.remove(d.serial) }
                                             })) {
                            Label(d.name, systemImage: d.name.localizedCaseInsensitiveContains("scribe") ? "pencil.and.scribble" : "book")
                        }
                        .toggleStyle(.checkbox)
                    }
                    Divider()
                    Toggle(L("PDFs im Original-Layout senden (zum Beschreiben auf dem Scribe)"), isOn: $stk.keepPDFLayout)
                        .toggleStyle(.checkbox)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Einmalig anmelden")).font(.headline)
                        Text(L("Scribe Sync meldet sich wie Amazons „Send to Kindle“-App für Mac an. Danach wählst du dein Gerät und ziehst einfach Dateien hierher."))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L("Bei Amazon anmelden …")) { stk.showSignIn = true }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder private var emailSetup: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Deine „Send to Kindle“-Adresse")).font(.headline)
                TextField("name_abc@kindle.com", text: $stk.kindleEmail)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { stk.resume() }
                Text(L("Die Datei geht als Anhang über die App Mail an diese Adresse (höchstens 50 MB). Deine Absenderadresse muss bei Amazon als „genehmigte E-Mail-Adresse“ eingetragen sein."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link(L("Adresse und genehmigte Absender bei Amazon …"),
                         destination: URL(string: "https://www.amazon.de/hz/mycd/myx#/home/settings/pdoc")!)
                        .font(.caption)
                    Spacer()
                    Button(L("Übernehmen")) { stk.resume() }.controlSize(.small)
                }
            }
        }
    }
}

/// Middle column: what was sent, with progress and status.
struct SendHistoryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var stk: SendToKindleService

    var body: some View {
        List {
            ForEach(stk.jobs) { job in
                SendJobRow(job: job, stk: stk)
                    .contextMenu {
                        if case .failed = job.state { Button(L("Erneut senden")) { stk.retry(job) } }
                        Button(L("Aus der Liste entfernen")) { stk.remove(job) }
                    }
            }
        }
        .listStyle(.inset)
        .navigationTitle(L("Gesendet"))
        .navigationSubtitle(stk.jobs.isEmpty ? "" : L("%ld Dateien", stk.jobs.count))
        .toolbar {
            ToolbarItem {
                Button { stk.clearFinished() } label: { Label(L("Liste leeren"), systemImage: "trash") }
                    .help(L("Gesendete Einträge aus der Liste entfernen"))
                    .disabled(!stk.jobs.contains { $0.state == .sent })
            }
        }
        .overlay {
            if stk.jobs.isEmpty {
                ContentUnavailableView(L("Noch nichts gesendet"), systemImage: "paperplane",
                                       description: Text(L("Gesendete Bücher und Dokumente erscheinen hier.")))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.sendToKindle(urls); return true }
    }
}

struct SendJobRow: View {
    let job: SendJob
    @ObservedObject var stk: SendToKindleService

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.headline).lineLimit(2)
                Text([job.author, STK.formatBytes(job.bytes)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch (job.fileName as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "epub": return "book.closed"
        case "png", "jpg", "jpeg", "gif", "bmp": return "photo"
        default: return "doc.text"
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .waiting:
            Label(stk.isReady ? L("Wartet") : (stk.readinessHint ?? L("Wartet")), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        case .uploading(let p):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: p).progressViewStyle(.linear).controlSize(.small)
                Text(L("Wird hochgeladen … %ld %%", Int(p * 100))).font(.caption).foregroundStyle(.secondary)
            }
        case .delivering:
            Label(L("Wird zugestellt …"), systemImage: "paperplane").font(.caption).foregroundStyle(Theme.accent)
        case .sent:
            Label {
                Text(L("Gesendet an %@ · ", job.devices.joined(separator: ", ")))
                    + Text(job.date, format: .relative(presentation: .named).locale(Loc.locale))
            } icon: { Image(systemName: "checkmark.circle.fill") }
                .font(.caption).foregroundStyle(Theme.accent)
        case .failed(let e):
            VStack(alignment: .leading, spacing: 4) {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warm)
                    .lineLimit(3)
                Button(L("Erneut senden")) { stk.retry(job) }.controlSize(.small)
            }
        }
    }
}

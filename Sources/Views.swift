import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Group {
            if engine.phase == .needsSetup || isInstallingFresh { SetupView() } else { PlayView() }
        }
        .sheet(isPresented: $engine.askDirectX) { DirectXConsent().interactiveDismissDisabled() }
    }

    private var isInstallingFresh: Bool {
        if case .installing = engine.phase, !engine.isInstalled { return true }
        if case .failed = engine.phase, !engine.isInstalled { return true }
        return false
    }
}

// MARK: - Play

struct PlayView: View {
    @EnvironmentObject var engine: Engine
    @State private var gearHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 640×480 art under a 32 pt hidden title bar. isMovableByWindowBackground would eat the gear's clicks.
    var body: some View {
        Group {
            if #available(macOS 15, *) { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) } else { Color.clear }
        }
        .frame(width: 640, height: 448)
        .overlay(alignment: .bottom) { bar }
        .background {
            Group {
                if let img = engine.splashImage {
                    // Scale the art's baked-in frame line out of view.
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).scaleEffect(1.03)
                } else {
                    Color.black
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            status
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.white.opacity(0.9))
                    .rotationEffect(.degrees(gearHover ? 26 : 0))
                    .animation(reduceMotion ? nil : .timingCurve(0.34, 1.56, 0.64, 1, duration: 0.35), value: gearHover)
            }
            .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings").onHover { gearHover = $0 }
            if engine.phase == .running {
                Button("Quit Game") { engine.stopGame() }.controlSize(.large)
            } else {
                Button("Play") { Task { await engine.play() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction).disabled(engine.isBusy)
            }
        }
        .padding(.horizontal, 20).padding(.top, 56).padding(.bottom, 18)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var status: some View {
        switch engine.phase {
        case .installing(let m):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m).foregroundStyle(.secondary) }
        case .failed(let m):
            Text(m).foregroundStyle(.secondary).lineLimit(2).help(m)
        case .running:
            Text("Running").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

// MARK: - DirectX consent

struct DirectXConsent: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download Microsoft DirectX files?").font(.headline)
            Text("ZT2 Launcher will download the “DirectX End-User Runtimes (June 2010)” package (96 MB) from Microsoft and add two of its files, d3dx9_31.dll and d3dx9_32.dll, to your copy of the game.")
            Text("These files are Microsoft's and are provided under the Microsoft Software License Terms for the DirectX End User Runtime. By continuing, you agree to those terms. The licence is included in the package.")
            Link("View on Microsoft's site", destination: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109")!)
            HStack {
                Spacer()
                Button("Cancel") { engine.answerDirectX(false) }.keyboardShortcut(.cancelAction)
                Button("Agree and Download") { engine.answerDirectX(true) }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Drop in your copy of Zoo Tycoon 2 and the app that will run it.")
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                DropWell(title: "Zoo Tycoon 2", hint: "Game folder, installer or disc image",
                         invalid: "No zt.exe, setup.exe or .iso found", placeholder: .folder,
                         path: $engine.gameSourcePath, valid: Engine.isGameSource,
                         types: [.folder, .exe, UTType(filenameExtension: "iso") ?? .diskImage])
                DropWell(title: "CrossOver or Sikarugir", hint: "Drop the app here",
                         invalid: "Not CrossOver or a Sikarugir wrapper", placeholder: .application,
                         path: $engine.crossoverPath, valid: Engine.isEngine, types: [.application])
            }
            .disabled(engine.isBusy)
            footer.frame(minHeight: 44)
            Text("Not affiliated with Microsoft, Blue Fang Games, CodeWeavers or Sikarugir. Requires your own copy of the game.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 24)
        .frame(width: 500)
    }

    @ViewBuilder private var footer: some View {
        switch engine.phase {
        case .installing(let m):
            VStack(spacing: 6) { ProgressView().progressViewStyle(.linear).frame(width: 200); Text(m).font(.callout).foregroundStyle(.secondary) }
        case .failed(let m):
            VStack(spacing: 6) {
                installButton
                Text(m).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2).help(m)
            }
        default:
            installButton
        }
    }

    private var installButton: some View {
        Button("Install") { Task { await engine.install() } }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!Engine.isEngine(engine.crossoverPath) || !Engine.isGameSource(engine.gameSourcePath))
            .keyboardShortcut(.defaultAction)
    }
}

struct DropWell: View {
    let title: String, hint: String, invalid: String, placeholder: UTType
    @Binding var path: String
    let valid: (String) -> Bool
    let types: [UTType]
    @State private var targeted = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let ok = !path.isEmpty && valid(path)
        VStack(spacing: 6) {
            Image(nsImage: ok ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: placeholder))
                .resizable().frame(width: 48, height: 48).opacity(ok ? 1 : 0.4)
            Text(title).font(.headline)
            Text(ok ? FileManager.default.displayName(atPath: path) : (path.isEmpty ? hint : invalid))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…") { choose() }.controlSize(.small)
        }
        .padding(14)
        .frame(width: 210, height: 160)
        .background(targeted ? AnyShapeStyle(.selection) : AnyShapeStyle(.fill.quinary), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled, let u = urls.first else { return false }
            path = u.path
            return true
        } isTargeted: { targeted = isEnabled && $0 }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = types.contains(.folder)
        p.canChooseFiles = types.contains { $0 != .folder }
        p.allowedContentTypes = types
        p.treatsFilePackagesAsDirectories = false
        if p.runModal() == .OK, let u = p.url { path = u.path }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModsSettings().frame(height: 460).tabItem { Label("Mods", systemImage: "puzzlepiece.extension") }
            SavesSettings().frame(height: 320).tabItem { Label("Saved Zoos", systemImage: "tray.full") }
        }
        .formStyle(.grouped)
        .frame(width: 500)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var engine: Engine
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: Binding(
                    get: { current },
                    set: { engine.width = $0.w; engine.height = $0.h })) {
                    // Keep a size chosen on another display selectable.
                    ForEach(Resolution.options.contains(current) ? Resolution.options : [current] + Resolution.options) { r in
                        Text(r == Resolution.recommended ? "\(r.label) (Recommended)" : r.label).tag(r)
                    }
                }
                Picker("Video memory", selection: $engine.videoMemoryMB) {
                    ForEach([512, 1024, 2048, 4096], id: \.self) { Text("\($0) MB").tag($0) }
                }
            } footer: {
                if engine.phase == .running { Text("Changes apply the next time you start the game.") }
            }
            Section {
                LabeledContent("Runs on") {
                    HStack {
                        Text(engine.engineName)
                        Button("Change…") { changeEngine() }.disabled(engine.isBusy)
                    }
                }
            }
            Section {
                LabeledContent("Reinstall the game") {
                    Button("Reset…") { confirmReset = true }.disabled(engine.isBusy)
                }
            } footer: {
                Text("Moves the game to the Trash and starts setup again.")
            }
        }
        .confirmationDialog("Reset Zoo Tycoon 2?", isPresented: $confirmReset) {
            Button("Move to Trash", role: .destructive) { Task { await engine.resetBottle() } }
        } message: {
            Text(engine.isSikarugir ? "Installed mods go to the Trash with it. Saved zoos stay in the wrapper."
                                    : "Your saved zoos and installed mods go to the Trash with it. Back up your saves first.")
        }
    }

    private var current: Resolution { Resolution(w: engine.width, h: engine.height) }

    private func changeEngine() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        guard p.runModal() == .OK, let u = p.url else { return }
        if Engine.isEngine(u.path) { engine.crossoverPath = u.path } else { NSSound.beep() }
    }
}

struct ModsSettings: View {
    @EnvironmentObject var engine: Engine
    @State private var note: String?

    var body: some View {
        Form {
            group("Mods", kind: .mod)
            group("Download Packs", kind: .dlc)
            group("Game and Expansions", kind: .core)
        }
        .safeAreaInset(edge: .bottom) {
            ActionBar {
                Text(note ?? "Drop .z2f, .zip or folders here.").foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(engine.gameDir) }.disabled(!engine.isInstalled)
                Button("Add Mods…") { add() }.disabled(!engine.isInstalled || engine.isBusy)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard engine.isInstalled, !engine.isBusy else { return false }
            install(urls)
            return true
        }
        .onAppear { engine.refreshMods() }
    }

    @ViewBuilder private func group(_ title: String, kind: Mod.Kind) -> some View {
        let items = engine.mods.filter { $0.kind == kind }
        Section(title) {
            if items.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(items) { mod in
                Toggle(isOn: Binding(get: { mod.enabled }, set: { engine.setEnabled(mod, $0) })) {
                    Text(mod.displayName)
                    Text(ByteCountFormatter.string(fromByteCount: mod.size, countStyle: .file))
                }
                .disabled(kind == .core || engine.isBusy)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([mod.url]) }
                    if kind == .mod { Button("Move to Trash") { engine.remove(mod) } }
                }
            }
        }
    }

    private func add() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [UTType(filenameExtension: "z2f") ?? .data, .zip, .folder]
        if p.runModal() == .OK { install(p.urls) }
    }

    private func install(_ urls: [URL]) {
        Task {
            let n = await engine.addMods(urls)
            note = n == 0 ? "No .z2f files found." : "Installed \(n) pack\(n == 1 ? "" : "s")."
            try? await Task.sleep(for: .seconds(3))
            note = nil
        }
    }
}

struct SavesSettings: View {
    @EnvironmentObject var engine: Engine
    @State private var message: String?
    @State private var restoreFrom: URL?

    var body: some View {
        Form {
            Section {
                if saves.isEmpty { Text("Zoos you save in the game appear here.").foregroundStyle(.secondary) }
                ForEach(saves, id: \.url) { s in
                    LabeledContent(s.url.deletingPathExtension().lastPathComponent,
                                   value: s.date.formatted(date: .abbreviated, time: .shortened))
                        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ActionBar {
                if let message { Text(message).foregroundStyle(.secondary) }
                Spacer()
                Group {
                    Button("Show in Finder") { if let d = engine.savesDir { NSWorkspace.shared.open(d) } }
                    Button("Back Up…") { backup() }
                }
                .disabled(saves.isEmpty)
                Button("Restore…") { chooseBackup() }.disabled(!engine.isInstalled || engine.isBusy)
            }
        }
        .confirmationDialog("Restore Saved Zoos?", isPresented: Binding(get: { restoreFrom != nil }, set: { if !$0 { restoreFrom = nil } }),
                            presenting: restoreFrom) { u in
            Button("Restore") { restore(u) }
        } message: { _ in Text("Saved zoos and game settings with the same names are replaced by the ones in the backup.") }
    }

    private var saves: [(url: URL, date: Date)] {
        guard let d = engine.savesDir,
              let urls = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
        else { return [] }
        return urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }

    private func backup() {
        let p = NSSavePanel()
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        p.nameFieldStringValue = "Zoo Tycoon 2 Saves \(stamp).zip"
        p.allowedContentTypes = [.zip]
        guard p.runModal() == .OK, let u = p.url else { return }
        Task {
            do { try await engine.backupSaves(to: u); message = "Backed up." }
            catch { message = error.localizedDescription }
        }
    }

    private func chooseBackup() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.zip]
        if p.runModal() == .OK { restoreFrom = p.url }
    }

    private func restore(_ u: URL) {
        Task {
            do { try await engine.restoreSaves(from: u); message = "Restored." }
            catch { message = error.localizedDescription }
        }
    }
}

/// Buttons pinned under a scrolling settings list.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack { content }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(.bar)
    }
}

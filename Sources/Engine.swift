import AppKit
import CryptoKit
import Foundation

/// Everything that touches CrossOver, the bottle and the game files.
@MainActor
final class Engine: ObservableObject {
    static let bottleName = "ZooTycoon2"

    enum Phase: Equatable { case needsSetup, installing(String), ready, running, failed(String) }

    @Published var phase: Phase = .needsSetup
    @Published var mods: [Mod] = []
    /// True while the DirectX download waits for the player's consent.
    @Published var askDirectX = false

    @Published var crossoverPath: String {
        didSet {
            d.set(crossoverPath, forKey: "crossover")
            if !isBusy { phase = isInstalled ? .ready : .needsSetup }
        }
    }
    @Published var gameSourcePath: String { didSet { d.set(gameSourcePath, forKey: "gameSource") } }
    @Published var width: Int { didSet { d.set(width, forKey: "width") } }
    @Published var height: Int { didSet { d.set(height, forKey: "height") } }
    @Published var videoMemoryMB: Int { didSet { d.set(videoMemoryMB, forKey: "vram") } }

    private let d = UserDefaults.standard
    private var directXAnswer: CheckedContinuation<Bool, Never>?
    private var gameProcess: Process?   // retains the running game

    init() {
        // Fall back to a fresh search if the saved CrossOver was moved or deleted.
        let saved = d.string(forKey: "crossover")
        crossoverPath = saved.flatMap { Engine.isEngine($0) ? $0 : nil } ?? Engine.findCrossOver() ?? saved ?? ""
        gameSourcePath = d.string(forKey: "gameSource") ?? ""
        let def = Resolution.recommended
        width = d.object(forKey: "width") as? Int ?? def.w
        height = d.object(forKey: "height") as? Int ?? def.h
        videoMemoryMB = d.object(forKey: "vram") as? Int ?? 2048
        phase = isInstalled ? .ready : .needsSetup
        refreshMods()
    }

    var isBusy: Bool {
        if case .installing = phase { return true }
        return phase == .running
    }

    // MARK: - Paths

    var cxBin: URL { URL(fileURLWithPath: crossoverPath).appendingPathComponent("Contents/SharedSupport/CrossOver/bin") }
    var bottlesRoot: URL {
        if let p = ProcessInfo.processInfo.environment["CX_BOTTLE_PATH"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    }
    /// A Sikarugir wrapper keeps its own Wine prefix inside the .app; CrossOver uses a named bottle.
    var bottleDir: URL {
        isSikarugir ? URL(fileURLWithPath: crossoverPath).appendingPathComponent("Contents/SharedSupport/prefix")
                    : bottlesRoot.appendingPathComponent(Engine.bottleName)
    }
    var isSikarugir: Bool { !Engine.isCrossOver(crossoverPath) && Engine.sikarugirWine(crossoverPath) != nil }
    var engineName: String {
        let name = ((crossoverPath as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: " \\(.*\\)", with: "", options: .regularExpression)
        if isSikarugir { return "\(name) (Sikarugir)" }
        return crossoverVersion.map { "\(name) \($0)" } ?? "Not found"
    }
    var crossoverVersion: String? {
        Bundle(url: URL(fileURLWithPath: crossoverPath))?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var gameDir: URL { bottleDir.appendingPathComponent("drive_c/ZooTycoon2") }
    var disabledModsDir: URL { gameDir.appendingPathComponent("Disabled Mods") }
    /// zt.exe lands early in a copy, so the marker is what says the install finished.
    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: gameDir.appendingPathComponent("zt.exe").path) && !fm.fileExists(atPath: installMarker.path)
    }
    private var installMarker: URL { gameDir.appendingPathComponent(".install-incomplete") }
    /// %APPDATA%\Microsoft Games\Zoo Tycoon 2 for whichever Windows user the bottle has.
    var profileRoot: URL? {
        let users = bottleDir.appendingPathComponent("drive_c/users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        guard let u = names.first(where: { $0 != "Public" && !$0.hasPrefix(".") }) else { return nil }
        return users.appendingPathComponent(u).appendingPathComponent("AppData/Roaming/Microsoft Games/Zoo Tycoon 2")
    }
    var savesDir: URL? { profileRoot?.appendingPathComponent("Default Profile/Saved") }
    var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ZT2 Launcher/game.log")
    }
    var splashImage: NSImage? {
        for dir in [gameDir, URL(fileURLWithPath: gameSourcePath)] {
            if let img = NSImage(contentsOf: dir.appendingPathComponent("SplashImage.bmp")) { return img }
        }
        return nil
    }

    // MARK: - Validation

    static func isCrossOver(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path + "/Contents/SharedSupport/CrossOver/bin/wine")
    }

    /// The Wine binary inside a Sikarugir (formerly Wineskin/Kegworks) wrapper, if `path` is one.
    static func sikarugirWine(_ path: String) -> URL? {
        let fm = FileManager.default
        let support = path + "/Contents/SharedSupport"
        guard fm.fileExists(atPath: support + "/prefix/drive_c") else { return nil }
        return ["wine", "wine64"].map { "\(support)/wine/bin/\($0)" }
            .first(where: fm.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func isEngine(_ path: String) -> Bool { isCrossOver(path) || sikarugirWine(path) != nil }

    static func findCrossOver() -> String? {
        let fm = FileManager.default
        let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.path + "/Applications"]
        let apps = dirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("CrossOver") && $0.hasSuffix(".app") }.map { "\(dir)/\($0)" }
        }
        // Prefer the plain "CrossOver.app" release over previews and betas.
        return apps.sorted { ($0.hasSuffix("/CrossOver.app") ? 0 : 1, $0.count) < ($1.hasSuffix("/CrossOver.app") ? 0 : 1, $1.count) }
            .first(where: isCrossOver)
    }

    /// Accepts an installed game folder (zt.exe), an installer folder or setup.exe, or a .iso disc image.
    static func isGameSource(_ path: String) -> Bool {
        findGameRoot(in: path) != nil || findInstaller(in: path) != nil
            || (path.lowercased().hasSuffix(".iso") && FileManager.default.fileExists(atPath: path))
    }

    /// The folder that directly contains zt.exe, searching a few levels down.
    static func findGameRoot(in path: String) -> URL? {
        let root = URL(fileURLWithPath: path)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        while let u = e.nextObject() as? URL {
            if e.level > 4 { e.skipDescendants(); continue }
            if u.lastPathComponent.lowercased() == "zt.exe" { return u.deletingLastPathComponent() }
        }
        return nil
    }

    /// setup.exe itself, or one at the top of a folder.
    static func findInstaller(in path: String) -> URL? {
        let u = URL(fileURLWithPath: path)
        if u.lastPathComponent.lowercased() == "setup.exe" { return u }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.first { $0.lowercased() == "setup.exe" }.map { u.appendingPathComponent($0) }
    }

    // MARK: - Install

    // Quitting mid-install leaves the copy or installer running; the next launch starts over.
    func install() async {
        guard !isBusy else { return }
        guard Engine.isEngine(crossoverPath) else { return fail("That doesn't look like CrossOver or a Sikarugir wrapper.") }
        guard Engine.isGameSource(gameSourcePath) else { return fail("Couldn't find zt.exe, setup.exe or a disc image there.") }
        phase = .installing("Preparing…")
        do {
            if !isSikarugir, !FileManager.default.fileExists(atPath: bottleDir.path) {
                phase = .installing("Creating a Windows bottle…")
                try await run(cxBin.appendingPathComponent("cxbottle"),
                              ["--bottle", Engine.bottleName, "--create", "--template", "win7_64", "--description", "Zoo Tycoon 2"])
            }
            if let src = Engine.findGameRoot(in: gameSourcePath) {
                phase = .installing("Copying game files…")
                try markIncomplete()
                try await run(URL(fileURLWithPath: "/usr/bin/ditto"), [src.path, gameDir.path])
            } else {
                try await runInstaller()
                try markIncomplete()
            }
            phase = .installing("Loading expansion and download packs…")
            flattenPacks()
            try await installDirectXHelpers()
            // Files copied off a disc keep their read-only bit.
            try await run(URL(fileURLWithPath: "/bin/chmod"), ["-R", "u+w", gameDir.path])
            phase = .installing("Applying Mac fixes…")
            try await applyBottleSettings()
            writeOptions()
            refreshMods()
            try? FileManager.default.removeItem(at: installMarker)
            phase = .ready
        } catch is CancellationError {
            phase = .needsSetup   // declined the DirectX download
        } catch { fail(error.localizedDescription) }
    }

    private func markIncomplete() throws {
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data().write(to: installMarker)
    }

    func answerDirectX(_ ok: Bool) {
        askDirectX = false
        directXAnswer?.resume(returning: ok)
        directXAnswer = nil
    }

    // Wine's D3DX9 can't compile the terrain and sky shaders (black ground and sky); Microsoft's can.
    private static let directXRedist = "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe"
    private static let directXSHA256 = "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"
    private static let directXHelpers = ["d3dx9_31.dll": "OCT2006_d3dx9_31_x86.cab", "d3dx9_32.dll": "DEC2006_d3dx9_32_x86.cab"]

    private func installDirectXHelpers() async throws {
        let fm = FileManager.default
        let missing = Engine.directXHelpers.filter { !fm.fileExists(atPath: gameDir.appendingPathComponent($0.key).path) }
        guard !missing.isEmpty else { return }
        let agreed = await withCheckedContinuation { directXAnswer = $0; askDirectX = true }
        guard agreed else { throw CancellationError() }
        phase = .installing("Downloading Microsoft DirectX files (96 MB)…")
        let tmp = fm.temporaryDirectory.appendingPathComponent("zt2-directx-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let exe = tmp.appendingPathComponent("dx.exe").path
        do {
            try await run(URL(fileURLWithPath: "/usr/bin/curl"),
                          ["-fsSL", "--retry", "2", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "30",
                           "--speed-limit", "10000", "--speed-time", "60", "-o", exe, Engine.directXRedist])
        } catch {
            throw err("Couldn't download the DirectX files from Microsoft. Check your internet connection and try again.")
        }
        let digest = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: exe), options: .alwaysMapped))
        }.value
        guard digest.map({ String(format: "%02x", $0) }).joined() == Engine.directXSHA256 else {
            throw err("The file from Microsoft wasn't the expected one.")
        }
        let tar = URL(fileURLWithPath: "/usr/bin/bsdtar")   // reads the self-extractor and the .cab files inside it
        for (dll, cab) in missing {
            try await run(tar, ["-xf", exe, "-C", tmp.path, cab])
            try await run(tar, ["-xf", tmp.appendingPathComponent(cab).path, "-C", tmp.path, dll])
            try fm.copyItem(at: tmp.appendingPathComponent(dll), to: gameDir.appendingPathComponent(dll))
        }
    }

    // One installer only; expansions aren't chained, and disc checks at launch fail.
    /// Runs the game's installer in the bottle, then moves the result to gameDir.
    private func runInstaller() async throws {
        let fm = FileManager.default
        var mount: URL?
        defer {
            if let mount {
                Task {
                    if (try? await run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"])) != nil {
                        try? fm.removeItem(at: mount)
                    }
                }
            }
        }
        var source = gameSourcePath
        if source.lowercased().hasSuffix(".iso") {
            phase = .installing("Opening the disc image…")
            let m = fm.temporaryDirectory.appendingPathComponent("zt2-disc-\(UUID().uuidString)")
            try fm.createDirectory(at: m, withIntermediateDirectories: true)
            try await run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-nobrowse", "-readonly", "-mountpoint", m.path, source])
            mount = m
            source = m.path
        }
        guard let setup = Engine.findInstaller(in: source) else { throw err("No setup.exe found there.") }
        try await applyBottleSettings()
        phase = .installing("Follow the installer's steps…")
        let p = makeWine([setup.path])
        p.currentDirectoryURL = setup.deletingLastPathComponent()   // installers look for their files beside them
        try? await run(p)   // installers often exit non-zero on success; finding zt.exe is the real check

        let driveC = bottleDir.appendingPathComponent("drive_c")
        var found: URL?
        if let e = fm.enumerator(at: driveC, includingPropertiesForKeys: nil) {
            while let u = e.nextObject() as? URL {
                let name = u.lastPathComponent.lowercased()
                if (e.level == 1 && (name == "windows" || name == "users")) || e.level > 6 { e.skipDescendants(); continue }
                if name == "zt.exe" { found = u.deletingLastPathComponent(); break }
            }
        }
        guard let found else { throw err("The installer finished but Zoo Tycoon 2 wasn't found in the bottle.") }
        if found.standardizedFileURL != gameDir.standardizedFileURL {
            if fm.fileExists(atPath: gameDir.path) { try fm.trashItem(at: gameDir, resultingItemURL: nil) }
            try fm.moveItem(at: found, to: gameDir)
        }
    }

    /// The game only reads .z2f packs sitting in its own folder, not in subfolders.
    private func flattenPacks() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: gameDir, includingPropertiesForKeys: nil) else { return }
        while let u = e.nextObject() as? URL {
            if u.path.hasPrefix(disabledModsDir.path) { e.skipDescendants(); continue }
            guard e.level > 1, u.pathExtension.lowercased() == "z2f" else { continue }
            let dest = gameDir.appendingPathComponent(u.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: u, to: dest) }
        }
    }

    private func reg(_ key: String, _ name: String, _ value: String) async throws {
        try await wine(["reg", "add", key, "/v", name, "/t", "REG_SZ", "/d", value, "/f"])
    }

    func applyBottleSettings() async throws {
        // Apple GPUs report 0 MB of video memory to old games, and ZT2 then refuses to start.
        try await reg(#"HKCU\Software\Wine\Direct3D"#, "VideoMemorySize", String(videoMemoryMB))
        // macOS reports ~130 display modes, which ZT2 can't handle; a virtual desktop reports a few.
        try await reg(#"HKCU\Software\Wine\Explorer"#, "Desktop", "Default")
        try await reg(#"HKCU\Software\Wine\Explorer\Desktops"#, "Default", "\(width)x\(height)")
        // Load the Microsoft D3DX9 helpers beside zt.exe instead of Wine's.
        for dll in Engine.directXHelpers.keys {
            try await reg(#"HKCU\Software\Wine\DllOverrides"#, String(dll.dropLast(4)), "native,builtin")
        }
    }

    /// Writes the game's own options.xml, keeping any settings the player changed in game.
    func writeOptions() {
        guard let root = profileRoot?.appendingPathComponent("Default Profile") else { return }
        // The game never creates its Saved folder, and without it every save fails as "read only".
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Saved"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("options.xml")
        let doc: XMLDocument
        if FileManager.default.fileExists(atPath: file.path) {
            guard let parsed = try? XMLDocument(contentsOf: file) else { return }   // never clobber a file we can't read
            doc = parsed
        } else {
            doc = XMLDocument(rootElement: XMLElement(name: "BFUserOptions"))
        }
        guard let top = doc.rootElement() else { return }
        func el(_ name: String) -> XMLElement {
            if let e = top.elements(forName: name).first { return e }
            let e = XMLElement(name: name); top.addChild(e); return e
        }
        func set(_ e: XMLElement, _ k: String, _ v: String) {
            e.removeAttribute(forName: k)
            if let a = XMLNode.attribute(withName: k, stringValue: v) as? XMLNode { e.addAttribute(a) }
        }
        let g = el("Graphics")
        set(g, "fullScreen", "1")
        set(g, "screenWidth", String(width))
        set(g, "screenHeight", String(height))
        // The game otherwise picks 16-bit colour, and Wine draws its text as striped noise.
        set(g, "screenDepth", "32")
        // A profile without sound settings starts silent, so write the game's own defaults.
        let snd = el("Sound")
        if snd.attribute(forName: "WantSound") == nil {
            for (k, v) in ["WantSound": "true", "SampleRate": "44100", "Bits": "16", "Channels": "2", "MixerChannels": "32",
                           "Mixer3DChannels": "32", "MasterVolume": "1.000000", "MusicVolume": "1.000000",
                           "inRangeDist": "2500.000000", "outRangeDist": "3000.000000", "rolloff": "1.000000",
                           "Provider3D": "Miles Fast 2D Positional Audio"] { set(snd, k, v) }
        }
        // Unknown GPUs get the lowest detail; start on High once, then leave the player's choices alone.
        let a = el("Attributes")
        if a.attribute(forName: "shaderDetail") == nil {
            for (k, v) in ["shaderDetail": "2", "environmentDetail": "2", "ambientsOn": "true", "skyboxQuality": "2",
                           "lightingDetail": "2", "shadowsOn": "true", "shadowDetail": "1", "specularEffects": "1", "terrainResolution": "2",
                           "terrainTextureSize": "2", "waterDetail": "3", "detailObjects": "1", "objectDetail": "2",
                           "physAnimOn": "true", "propAttachOn": "true", "objectTextureDetail": "2", "textureReplaceOn": "true",
                           "animationDetail": "2", "viewDistance": "2", "maxOverheadZoom": "2", "detailLevel": "3"] { set(a, k, v) }
        }
        try? doc.xmlData(options: .nodePrettyPrint).write(to: file)
    }

    // MARK: - Play

    // A game left running from an earlier launch isn't tracked; Game > Quit Game still stops it.
    func play() async {
        guard !isBusy else { return }
        guard isInstalled else { return phase = .needsSetup }
        guard Engine.isEngine(crossoverPath) else { return fail("CrossOver or the Sikarugir wrapper can't be found. Choose it again in Settings.") }
        phase = .installing("Starting…")
        do {
            try await installDirectXHelpers()   // no-op once installed; upgrades older installs
            try await applyBottleSettings()
            writeOptions()
        } catch is CancellationError {
            return phase = .ready
        } catch { return fail(error.localizedDescription) }
        let p = isSikarugir ? makeWine(["zt.exe"]) : makeWine(["--workdir", #"C:\ZooTycoon2"#, "--cx-app", #"C:\ZooTycoon2\zt.exe"#])
        let fm = FileManager.default
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logFile.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logFile)
        if let log { p.standardOutput = log; p.standardError = log }
        p.terminationHandler = { _ in
            Task { @MainActor in try? log?.close(); self.gameProcess = nil; self.phase = .ready }
        }
        do { try p.run(); gameProcess = p; phase = .running } catch { fail(error.localizedDescription) }
    }

    func stopGame() {
        Task { try? await wine(["wineboot", "-k"]) }
    }

    // MARK: - Mods

    func refreshMods() {
        func list(_ dir: URL, enabled: Bool) -> [Mod] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? [])
                .filter { $0.pathExtension.lowercased() == "z2f" }
                .map { Mod(url: $0, enabled: enabled) }
        }
        mods = (list(gameDir, enabled: true) + list(disabledModsDir, enabled: false))
            .sorted { ($0.kind.rawValue, $0.name.lowercased()) < ($1.kind.rawValue, $1.name.lowercased()) }
    }

    func setEnabled(_ mod: Mod, _ on: Bool) {
        guard mod.kind != .core, mod.enabled != on else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: disabledModsDir, withIntermediateDirectories: true)
        try? fm.moveItem(at: mod.url, to: (on ? gameDir : disabledModsDir).appendingPathComponent(mod.url.lastPathComponent))
        refreshMods()
    }

    /// Adds .z2f files, folders or .zips of them; same-named packs go to the Trash. Returns the count.
    func addMods(_ urls: [URL]) async -> Int {
        let fm = FileManager.default
        var added = 0
        for url in urls {
            var packs: [URL] = []
            let tmp = fm.temporaryDirectory.appendingPathComponent("zt2-mod-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            if url.pathExtension.lowercased() == "z2f" {
                packs = [url].filter(Engine.isRegularFile)
            } else if url.pathExtension.lowercased() == "zip" {
                try? await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, tmp.path])
                packs = z2fFiles(in: tmp)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                packs = z2fFiles(in: url)
            }
            for p in packs {
                // A pack already inside the game folder would be trashed before it could be copied.
                guard !p.standardizedFileURL.path.hasPrefix(gameDir.standardizedFileURL.path + "/") else { continue }
                let dest = gameDir.appendingPathComponent(p.lastPathComponent)
                for old in [dest, disabledModsDir.appendingPathComponent(p.lastPathComponent)] where fm.fileExists(atPath: old.path) {
                    try? fm.trashItem(at: old, resultingItemURL: nil)
                }
                if (try? fm.copyItem(at: p, to: dest)) != nil { added += 1 }
            }
        }
        refreshMods()
        return added
    }

    /// Skips symlinks and the "._" AppleDouble files that zips made on a Mac carry.
    private func z2fFiles(in dir: URL) -> [URL] {
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return all.filter { $0.pathExtension.lowercased() == "z2f" && !$0.lastPathComponent.hasPrefix("._") && Engine.isRegularFile($0) }
    }

    private static func isRegularFile(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }

    func remove(_ mod: Mod) {
        guard mod.kind == .mod else { return }
        try? FileManager.default.trashItem(at: mod.url, resultingItemURL: nil)
        refreshMods()
    }

    // MARK: - Saves

    func backupSaves(to dest: URL) async throws {
        guard let root = profileRoot, FileManager.default.fileExists(atPath: root.path) else { throw err("No saves yet.") }
        try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", root.path, dest.path])
    }

    /// Merges a backup into the profile; files with the same name are replaced.
    func restoreSaves(from zip: URL) async throws {
        guard let root = profileRoot else { throw err("Install the game before restoring.") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("zt2-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, tmp.path])
        let backup = tmp.appendingPathComponent(root.lastPathComponent)
        guard fm.fileExists(atPath: backup.path) else { throw err("That isn't a Zoo Tycoon 2 saves backup.") }
        let items = fm.enumerator(at: backup, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey])?.allObjects as? [URL] ?? []
        for u in items where !Engine.isRegularFile(u) && (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            try? fm.removeItem(at: u)   // no symlinks into the profile
        }
        try await run(URL(fileURLWithPath: "/usr/bin/ditto"), [backup.path, root.path])
    }

    // MARK: - Maintenance

    func resetBottle() async {
        guard !isBusy else { return }
        phase = .installing("Removing game…")
        // Trash, not cxbottle --delete: the bottle holds the saved zoos. A Sikarugir prefix isn't ours to remove.
        let target = isSikarugir ? gameDir : bottleDir
        try? await wine(["wineboot", "-k"])
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
        } catch { return fail(error.localizedDescription) }
        refreshMods()
        phase = .needsSetup
    }

    func openWineConfig() { Task { try? await wine(["winecfg"]) } }

    // MARK: - Processes

    /// Wine pointed at our bottle: CrossOver's wrapper script, or the Sikarugir wrapper's own Wine and prefix.
    private func makeWine(_ args: [String]) -> Process {
        let p = Process()
        if isSikarugir, let wine = Engine.sikarugirWine(crossoverPath) {
            p.executableURL = wine
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(["WINEPREFIX": bottleDir.path]) { $1 }
            p.currentDirectoryURL = FileManager.default.fileExists(atPath: gameDir.path) ? gameDir : bottleDir
        } else {
            p.executableURL = cxBin.appendingPathComponent("wine")
            p.arguments = ["--bottle", Engine.bottleName] + args
        }
        return p
    }

    private func wine(_ args: [String]) async throws { try await run(makeWine(args)) }

    private func run(_ exe: URL, _ args: [String]) async throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        try await run(p)
    }

    /// Throws with the tool's last line of output on failure.
    private func run(_ p: Process) async throws {
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // Drain before waiting, or a full pipe blocks the process.
        let out = await Task.detached { () -> Data in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        }.value
        guard p.terminationStatus != 0 else { return }
        let name = p.executableURL?.lastPathComponent ?? "command"
        let last = String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline).last
        throw err(last.map { "\(name) failed: \($0)" } ?? "\(name) failed (\(p.terminationStatus)).")
    }

    private func err(_ s: String) -> NSError { NSError(domain: "ZT2", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
    private func fail(_ s: String) { phase = .failed(s) }
}

// MARK: - Mod

struct Mod: Identifiable, Hashable {
    enum Kind: Int { case dlc, mod, core }
    let url: URL
    let enabled: Bool
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var size: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    static let officialDLC: Set<String> = [
        "addax", "beautificationpack_061305", "challengepack1", "elephantasian_050505", "guestpack",
        "holidaypack", "leopardanddummy", "pdlc1_2", "scenerypack", "tundraandmuskox",
    ]

    var kind: Kind {
        let n = name.lowercased()
        if n.range(of: #"^x\d+_\d+$"#, options: .regularExpression) != nil { return .core }
        return Mod.officialDLC.contains(n) ? .dlc : .mod
    }

    var displayName: String {
        switch name.lowercased() {
        case "addax": "Addax"
        case "beautificationpack_061305": "Beautification Pack"
        case "challengepack1": "Challenge Pack"
        case "elephantasian_050505": "Asian Elephant"
        case "guestpack": "Guest Pack"
        case "holidaypack": "Holiday Pack"
        case "leopardanddummy": "Clouded Leopard"
        case "pdlc1_2": "Dino Danger Pack"
        case "scenerypack": "Scenery Pack"
        case "tundraandmuskox": "Tundra & Musk Ox"
        // Modders prefix names with z's and underscores to force load order; hide that.
        default: name.replacingOccurrences(of: "^[zZ_]+(?=[A-Z0-9])", with: "", options: .regularExpression)
                     .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Resolution

struct Resolution: Hashable, Identifiable {
    let w: Int, h: Int
    var id: String { "\(w)x\(h)" }
    var label: String { "\(w) × \(h)" }

    /// The main display's size in points, rounded down to even numbers.
    static var display: Resolution {
        let s = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        return Resolution(w: Int(s.width) & ~1, h: Int(s.height) & ~1)
    }

    static var recommended: Resolution {
        let d = display
        return options.first { $0.w <= d.w && $0.h <= d.h && abs(Double($0.w) / Double($0.h) - Double(d.w) / Double(d.h)) < 0.02 } ?? d
    }

    static var options: [Resolution] {
        let common = [(2560, 1600), (2560, 1440), (1920, 1200), (1920, 1080), (1680, 1050), (1600, 900),
                      (1440, 900), (1366, 768), (1280, 800), (1280, 720), (1280, 1024), (1024, 768)]
        var all = common.map { Resolution(w: $0.0, h: $0.1) }
        if !all.contains(display) { all.insert(display, at: 0) }
        return all.sorted { $0.w * $0.h > $1.w * $1.h }
    }
}

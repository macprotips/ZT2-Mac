import SwiftUI

/// Quit with the window, and never restore windowless. A running game is left alone.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private let credits: NSAttributedString = {
    let text = """
    Installs and launches your own copy of Zoo Tycoon 2 on a Mac, using CrossOver or a Sikarugir wrapper.

    Not affiliated with, endorsed by or sponsored by Microsoft, Blue Fang Games, CodeWeavers or the Sikarugir project. Zoo Tycoon is a trademark of Microsoft Corporation. CrossOver is a trademark of CodeWeavers, Inc. All other trademarks belong to their owners.

    Requires your own copy of Zoo Tycoon 2 and your own copy of CrossOver, or an existing Sikarugir wrapper. No game files are included.

    Acknowledgements
    CrossOver by CodeWeavers
    Wine by the Wine project (LGPL)
    Sikarugir, an open-source Wine wrapper tool
    DirectX End-User Runtime © Microsoft, downloaded from Microsoft under its own licence terms
    Zoo Tycoon 2 © Microsoft, developed by Blue Fang Games
    """
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                         .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
}()

@main
struct ZT2LauncherApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        Window("ZT2 Launcher", id: "main") {
            RootView().environmentObject(engine)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ZT2 Launcher") { NSApp.orderFrontStandardAboutPanel(options: [.credits: credits]) }
            }
            CommandMenu("Game") {
                Button("Play") { Task { await engine.play() } }
                    .keyboardShortcut("p")
                    .disabled(!engine.isInstalled || engine.isBusy)
                // Not tied to .running, so it also stops a game from an earlier launch.
                Button("Quit Game") { engine.stopGame() }
                    .disabled(!engine.isInstalled)
                Divider()
                Group {
                    Button("Show Game Files") { NSWorkspace.shared.open(engine.gameDir) }
                    Button("Wine Configuration…") { engine.openWineConfig() }
                }
                .disabled(!engine.isInstalled)
                Button("Open Game Log") { NSWorkspace.shared.open(engine.logFile) }
                    .disabled(!FileManager.default.fileExists(atPath: engine.logFile.path))
            }
        }

        Settings {
            SettingsView().environmentObject(engine)
        }
    }
}

import SwiftUI

@main
struct JimVizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine: Engine

    init() {
        SelfCheck.runIfRequested()
        _engine = State(initialValue: Engine())
    }

    var body: some Scene {
        Window("jim-viz", id: "main") {
            ContentView()
                .environment(engine)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
                        text.undoManager?.undo()
                    } else {
                        engine.undo()
                    }
                }
                .keyboardShortcut("z")
                .disabled(!engine.canUndo)

                Button("Redo") {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
                        text.undoManager?.redo()
                    } else {
                        engine.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!engine.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Empty Scene") { engine.createNewScene() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Scene") { engine.saveCurrent() }
                    .keyboardShortcut("s")
                Button("Duplicate Scene") { if let url = engine.currentURL { engine.duplicateScene(url) } }
                    .keyboardShortcut("d")
                    .disabled(engine.currentURL == nil)
                Button("Rename Scene…") { engine.renamingScene = engine.currentURL }
                    .disabled(engine.currentURL == nil)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Mappings") { engine.copyMappings() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Paste Mappings") { engine.pasteMappings() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                Button(engine.showInspector ? "Hide Mappings" : "Show Mappings") { engine.showInspector.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandMenu("Scene") {
                Button("Next Scene") { engine.stepScene(1) }
                    .keyboardShortcut("]")
                Button("Previous Scene") { engine.stepScene(-1) }
                    .keyboardShortcut("[")
                Divider()
                Button("Reload Scenes and Shaders") { engine.reloadAll() }
                    .keyboardShortcut("r")
                Button("Open Content Folder") { NSWorkspace.shared.open(engine.contentRoot) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Transport") {
                Button("Tap Tempo") { engine.tap() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Snap to Downbeat") { engine.resync() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
            CommandMenu("Control") {
                Button("Rescan MIDI Devices") { engine.midi.refreshEndpoints() }
            }
            CommandMenu("Output") {
                Button("Toggle Fullscreen Output") { engine.output.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Windowed Output") { engine.output.setMode(.windowed) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Turn Off Output") { engine.output.setMode(.off) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable via `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

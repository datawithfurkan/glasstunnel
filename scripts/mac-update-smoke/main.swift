// A throwaway app for scripts/mac-update-smoke.sh. It embeds the same Sparkle
// as Glasstunnel, checks its feed in the background, installs the update it
// finds at once, and records the version it is running as in a status file.
import AppKit
import Sparkle

final class SmokeDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private let info = Bundle.main.infoDictionary ?? [:]

    private func record(_ line: String) {
        guard let path = info["GTSmokeStatusFile"] as? String else { return }
        let entry = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(entry.utf8))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        record("running \(version)")
        if version == info["GTSmokeTargetVersion"] as? String {
            NSApp.terminate(nil)
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.automaticallyDownloadsUpdates = true
        do {
            try controller.updater.start()
        } catch {
            record("error \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        controller.updater.checkForUpdatesInBackground()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record("found \(item.displayVersionString)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        record("no-update \(error.localizedDescription)")
        NSApp.terminate(nil)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        record("error \(error.localizedDescription)")
        NSApp.terminate(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        record("installing \(item.displayVersionString)")
        immediateInstallHandler()
        return true
    }
}

let app = NSApplication.shared
let delegate = SmokeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

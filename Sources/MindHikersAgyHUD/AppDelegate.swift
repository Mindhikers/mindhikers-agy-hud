import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = TelemetryService()
    private var floatingHUD: FloatingHUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        floatingHUD = FloatingHUDController(
            service: service,
            onCopy: { [weak self] in self?.copyTextReport() },
            onQuit: { NSApp.terminate(nil) }
        )

        service.onPayloadChanged = { [weak self] _ in
            self?.floatingHUD?.onTelemetryUpdated()
        }
        service.start()
        floatingHUD?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.stop()
    }

    private func copyTextReport() {
        guard let text = service.payload?.textReport, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

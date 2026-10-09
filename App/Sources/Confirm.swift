import AppKit

/// Human in the loop: anything that can't be undone or that goes public (a live
/// room, a stream, deleting files) waits for the user's OK, whoever asked for
/// it: a button, the assistant, Voice Mode, or an agent over MCP.
@MainActor
enum Confirm {
    /// Shows the question as a sheet on the main window (where the user is
    /// looking; a dialog if the window is hidden). True if they chose the first button.
    static func ask(_ alert: NSAlert) async -> Bool {
        VoiceMode.current?.announceConfirmation()
        #if DEBUG
        if let delay = autoApproveAfter {
            // Tours film the question being answered.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                alert.buttons.first?.performClick(nil)
            }
        }
        #endif
        if let window = NSApp.windows.first(where: { $0.title == "Snazzy Pro" && $0.isVisible && $0.attachedSheet == nil }) {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    #if DEBUG
    /// Tours: click the first button after this many seconds.
    static var autoApproveAfter: Double?
    #endif
}

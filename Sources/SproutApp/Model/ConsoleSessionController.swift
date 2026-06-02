import AppKit
import Foundation
import SproutEngine
import SwiftTerm

/// Owns one SwiftTerm `TerminalView` and bridges it to an engine `PTYHandle`:
/// PTY output → `feed`, user keystrokes → `send`, grid resize → `resize`. Kept alive by
/// `ProjectStore` for the life of the session so closing the tab/window does not destroy
/// the terminal buffer or the underlying process.
@MainActor
final class ConsoleSessionController: NSObject, TerminalViewDelegate {
    let id: UUID
    let terminalView: TerminalView
    private let handle: PTYHandle
    private var pumpTask: Task<Void, Never>?

    init(id: UUID, handle: PTYHandle) {
        self.id = id
        self.handle = handle
        self.terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: nil)
        super.init()
        terminalView.terminalDelegate = self
        startPump()
    }

    private func startPump() {
        let handle = self.handle
        pumpTask = Task { [weak self] in
            for await chunk in handle.output {
                let bytes = [UInt8](chunk)
                await MainActor.run { self?.terminalView.feed(byteArray: bytes[...]) }
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
    }

    // MARK: TerminalViewDelegate
    //
    // The protocol requirements are `nonisolated`, so these methods must be too.
    // They only touch the `Sendable` `handle`, so no MainActor hop is needed.

    /// User typed something — forward the raw bytes to the pty.
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        handle.send(Data(data))
    }

    /// The view's grid changed size — tell the pty so the child reflows.
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        handle.resize(cols: newCols, rows: newRows)
    }

    // Required by the protocol; no behavior needed for an embedded console.
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // v1.13.0 has no macOS default impl for clipboardCopy (only iOS/SwiftUI), so it is required.
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
}

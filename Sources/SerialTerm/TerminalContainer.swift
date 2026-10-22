// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import AppKit
import SwiftTerm
import SwiftUI

/// Hosts SwiftTerm's terminal view in SwiftUI and wires it to the model.
struct TerminalContainer: NSViewRepresentable {
    let model: TerminalModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> SerialTerminalView {
        let view = SerialTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: model.prefs.fontSize, weight: .regular)
        )
        view.terminalDelegate = context.coordinator
        view.onDropFiles = { [weak model] urls in model?.sendFiles(urls) }
        view.onTerminalSend = { [weak model] data, fromUser in model?.sendFromTerminal(data, fromUser: fromUser) }
        model.terminalView = view  // applies Option-as-Meta, Backspace and font settings
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: SerialTerminalView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: TerminalModel

        init(model: TerminalModel) {
            self.model = model
        }

        /// Keys and typed text (replies and pastes come through `SerialTerminalView.onTerminalSend`).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model.sendFromTerminal(data, fromUser: true)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            model.terminalResized(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Terminal view that accepts files dropped on it (sent with ZMODEM), and tells what the user
/// typed or pasted apart from replies the terminal makes by itself.
final class SerialTerminalView: TerminalView {
    var onDropFiles: (([URL]) -> Void)?
    /// Bytes the terminal produced by itself (answers to queries, focus and mouse reports), or a
    /// paste (`fromUser`). Keys and typed text go to the delegate's `send` instead.
    var onTerminalSend: ((_ data: ArraySlice<UInt8>, _ fromUser: Bool) -> Void)?

    private var pasting = false

    override func paste(_ sender: Any) {
        pasting = true
        defer { pasting = false }
        super.paste(sender)
    }

    // SwiftTerm routes its replies, and pasted text, through here; it may call from its parsing
    // thread. Delivered on the main queue later, as SwiftTerm itself does.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        let fromUser = Thread.isMainThread && MainActor.assumeIsolated { pasting }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onTerminalSend?(bytes[...], fromUser) }
        }
    }

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        // Batch protocols send files, not folders.
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}

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
        view.optionAsMetaKey = true
        view.onDropFiles = { [weak model] urls in model?.sendFiles(urls) }
        model.terminalView = view
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

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model.sendFromTerminal(data)
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

/// Terminal view that accepts files dropped on it (sent with ZMODEM).
final class SerialTerminalView: TerminalView {
    var onDropFiles: (([URL]) -> Void)?

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

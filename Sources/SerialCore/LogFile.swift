// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pat Welch

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An append-only file for session logs and protocol traces.
///
/// It never replaces an existing file: if the name is taken it uses "name-2.log", "name-3.log"
/// and so on, so two sessions starting in the same second get a file each. Writes never raise
/// (Foundation's `FileHandle.write(_:)` throws an Objective-C exception on an I/O error, which
/// aborts the app): the first failure, such as a full disk or a volume that went away, closes
/// the file and is returned once, and later writes are dropped.
///
/// Not thread-safe: owners serialise access on their own queue.
final class LogFile {
    /// The file actually created.
    let url: URL
    private var fd: Int32

    init(creatingNewFileAt url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for n in 1...1000 {
            let name = n == 1 ? url.lastPathComponent : (ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            let candidate = directory.appendingPathComponent(name)
            let fd = sysOpen(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
            if fd >= 0 {
                self.url = candidate
                self.fd = fd
                return
            }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    deinit {
        if fd >= 0 { _ = sysClose(fd) }
    }

    /// Appends `data`. Returns the error the first time a write fails, nil otherwise.
    @discardableResult
    func write(_ data: Data) -> Error? {
        guard fd >= 0, !data.isEmpty else { return nil }
        let failure: Int32? = data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = sysWrite(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return n < 0 ? errno : EIO
                }
            }
            return nil
        }
        guard let failure else { return nil }
        _ = sysClose(fd)
        fd = -1
        return POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    func synchronize() {
        if fd >= 0 { _ = fsync(fd) }
    }

    /// For tests that simulate a failing disk.
    var fileDescriptor: Int32 { fd }
}

private func sysOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { open(path, flags, mode) }
private func sysClose(_ fd: Int32) -> Int32 { close(fd) }
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buf, count) }

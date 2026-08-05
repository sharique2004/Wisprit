import Foundation

enum AtomicWrite {
    /// Write-to-temp + fsync + `rename(2)`, mirroring the Python
    /// `mkstemp` → `fsync` → `os.replace` sequence: a crash mid-write can never
    /// leave a truncated config.json behind. The temp file is created in the
    /// destination directory so the rename stays within one filesystem.
    static func write(_ text: String, to url: URL, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let template = directory.appendingPathComponent(url.lastPathComponent + ".XXXXXX.tmp")
        var buffer = Array(template.path.utf8CString)
        // suffix length excludes the trailing NUL that utf8CString carries.
        let fd = buffer.withUnsafeMutableBufferPointer { mkstemps($0.baseAddress!, 4) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let tempPath = String(cString: buffer)

        func cleanup() { unlink(tempPath) }

        do {
            let bytes = Array(text.utf8)
            var written = 0
            while written < bytes.count {
                let n = bytes[written...].withUnsafeBufferPointer {
                    Darwin.write(fd, $0.baseAddress!, $0.count)
                }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += n
            }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(fd)
            guard fchmodat(AT_FDCWD, tempPath, permissions, 0) == 0 || errno == ENOTSUP else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard rename(tempPath, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(fd)
            cleanup()
            throw error
        }
    }

    /// Append one already-newline-terminated line, creating the file if needed.
    /// `O_APPEND` keeps concurrent writers (app + share/keyboard extension)
    /// from interleaving inside a line.
    static func appendLine(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBufferPointer {
                Darwin.write(fd, $0.baseAddress!, $0.count)
            }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            written += n
        }
    }
}

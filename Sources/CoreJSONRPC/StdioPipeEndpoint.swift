import Darwin
import Foundation

enum StdioPipeError: Error, Sendable {
    case configuration(Int32)
    case closed
    case write(Int32)
}

protocol StdioPipeSink: Sendable {
    func attempt(_ data: Data, offset: Int) throws -> StdioPipeEndpoint.Attempt
    func close()
}

/// Owns this pipe writer's FileHandle. Native writes and close cannot overlap, and a closed
/// descriptor is never cached across an await or raw-closed behind Foundation's ownership.
final class StdioPipeEndpoint: StdioPipeSink, @unchecked Sendable {
    enum Attempt: Sendable { case progress(Int), wouldBlock, interrupted }
    private let lock = NSLock()
    private var handle: FileHandle?
    // Chosen syscall chunk budget, not PIPE_BUF, a protocol maximum or a latency measurement.
    private let maximumChunkBytes: Int

    init(taking handle: FileHandle, maximumChunkBytes: Int = 16 * 1024) throws {
        guard maximumChunkBytes > 0 else { throw StdioPipeError.configuration(EINVAL) }
        self.maximumChunkBytes = maximumChunkBytes
        let descriptor = handle.fileDescriptor
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw StdioPipeError.configuration(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else { throw StdioPipeError.configuration(EINVAL) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { throw StdioPipeError.configuration(errno) }
        guard flags & O_ACCMODE == O_WRONLY else { throw StdioPipeError.configuration(EINVAL) }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw StdioPipeError.configuration(errno) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw StdioPipeError.configuration(errno) }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0 else { throw StdioPipeError.configuration(errno) }
        guard fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { throw StdioPipeError.configuration(errno) }
        let verified = fcntl(descriptor, F_GETFL)
        let verifiedDescriptorFlags = fcntl(descriptor, F_GETFD)
        guard verified >= 0, verified & O_NONBLOCK != 0,
              fcntl(descriptor, F_GETNOSIGPIPE) == 1,
              verifiedDescriptorFlags >= 0, verifiedDescriptorFlags & FD_CLOEXEC != 0 else { throw StdioPipeError.configuration(EINVAL) }
        self.handle = handle
    }

    func attempt(_ data: Data, offset: Int) throws -> Attempt {
        try lock.withLock {
            guard let handle else { throw StdioPipeError.closed }
            guard offset >= 0, offset < data.count else { throw StdioPipeError.write(EINVAL) }
            let count = min(maximumChunkBytes, data.count - offset)
            let (written, code) = data.withUnsafeBytes { bytes in
                let written = Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), count)
                return (written, written < 0 ? errno : 0) // Before Foundation unwinds the borrowed buffer.
            }
            if written > 0 { return .progress(written) }
            if written == 0 { throw StdioPipeError.write(EIO) }
            if code == EAGAIN { return .wouldBlock }
            if code == EINTR { return .interrupted }
            throw StdioPipeError.write(code)
        }
    }

    func close() {
        let owned = lock.withLock { let owned = handle; handle = nil; return owned }
        // The same mutex made any native write finish first; no future attempt can obtain
        // the handle. Do not retry a failed close (the descriptor slot may already be reused).
        try? owned?.close()
    }
    deinit { close() }
}

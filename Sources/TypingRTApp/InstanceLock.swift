import Darwin
import Foundation

/// Held for the lifetime of the process, including when every window is closed.
final class InstanceLock {
    private var descriptor: Int32 = -1

    func acquire(namespace: String) throws -> Bool {
        precondition(descriptor == -1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        return true
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}

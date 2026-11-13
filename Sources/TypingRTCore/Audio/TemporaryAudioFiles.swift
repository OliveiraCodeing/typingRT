import Darwin
import Foundation

/// Called only off the UI/audio callback queues and before a capture can own a file.
/// The caller must hold the app's instance lock and request cleanup only once per launch.
public enum TemporaryAudioFiles {
    public enum Failure: Error, LocalizedError {
        case unsafeLocation

        public var errorDescription: String? {
            "Das temporäre Aufnahmeverzeichnis ist nicht sicher zugänglich."
        }
    }

    /// Opens each app-owned path component without following links. Cleanup is
    /// nonrecursive and descriptor-relative, so replacement of a pathname cannot
    /// redirect deletion into another directory. Unknown files are never removed.
    public static func prepareDirectory(
        namespace: String = AppIdentity.current.namespace,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        removeOrphans: Bool = true
    ) throws -> URL {
        guard !namespace.isEmpty, namespace != ".", namespace != "..", namespace.utf8.count <= 255,
            namespace.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95
            }), temporaryDirectory.isFileURL
        else { throw Failure.unsafeLocation }

        // macOS itself aliases /var and /tmp. Resolve only the supplied system
        // base; app-owned components below it must always be real directories.
        let base = temporaryDirectory.resolvingSymlinksInPath()
        let baseFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard baseFD >= 0 else { throw systemError() }
        defer { close(baseFD) }
        let rootFD = try openPrivateDirectory("typingRT-audio", parent: baseFD)
        defer { close(rootFD) }
        let namespaceFD = try openPrivateDirectory(namespace, parent: rootFD)
        defer { close(namespaceFD) }
        if removeOrphans { try removeOwnedRecordings(in: namespaceFD) }
        return base.appendingPathComponent("typingRT-audio", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static func openPrivateDirectory(_ name: String, parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw systemError() }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeLocation }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
            status.st_mode & S_IFMT == S_IFDIR
        else {
            close(descriptor)
            throw Failure.unsafeLocation
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            let error = systemError()
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func removeOwnedRecordings(in descriptor: Int32) throws {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw systemError() }
        guard let directory = fdopendir(duplicate) else {
            let error = systemError()
            close(duplicate)
            throw error
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw systemError() }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard isRecordingName(name) else { continue }
            var status = stat()
            // Links (including hard links), directories and foreign ownership are
            // deliberately retained. Only files produced by this app match all gates.
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
                status.st_nlink == 1
            else { continue }
            if unlinkat(descriptor, name, 0) != 0, errno != ENOENT { throw systemError() }
        }
    }

    private static func isRecordingName(_ name: String) -> Bool {
        guard name.hasSuffix(".wav"), name.utf8.count == 77,
              name.utf8.allSatisfy({ $0 < 128 }) else { return false }
        let identifiers = name.dropLast(4)
        let separator = identifiers.index(identifiers.startIndex, offsetBy: 36)
        guard identifiers[separator] == "-" else { return false }
        return UUID(uuidString: String(identifiers[..<separator])) != nil
            && UUID(uuidString: String(identifiers[identifiers.index(after: separator)...])) != nil
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

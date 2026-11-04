import Foundation

// Watches the local data-source paths for the four readers and fires a single
// debounced callback whenever any of them changes, so collection can be event
// driven instead of polling every few seconds.
//
// Directory trees (Openclaw /tmp/agents, Codex ~/.codex/sessions) are watched with
// an FSEventStream because their contents change in nested subpaths that a single
// file-descriptor source cannot observe. Individual SQLite files are watched with a
// DispatchSourceFileSystemObject on an open fd; SQLite in WAL mode renames/replaces
// files, so each source re-arms itself on a .delete/.rename event.
final class FileWatcher {
    struct Paths {
        var directories: [String]
        var files: [String]

        // Default watch set derived from the reader default paths. Missing paths are
        // simply skipped; watchers re-arm as parents appear on the debounced rescan.
        static func defaultLocal() -> Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let hermesDBs = HermesReader().discoverDatabasePaths()
            return Paths(
                directories: [
                    OpenclawReader.defaultSessionsBasePath,
                    "\(home)/.codex/sessions"
                ],
                files: OpenCodeReader.defaultPaths + [
                    CodexReader.defaultPath,
                    ContinueReader.defaultPath
                ] + hermesDBs
            )
        }
    }

    private let paths: Paths
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.tokentrace.filewatcher", qos: .utility)
    private let onChange: () -> Void

    private var eventStream: FSEventStreamRef?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var isRunning = false

    init(paths: Paths = .defaultLocal(), debounceInterval: TimeInterval = 0.75, onChange: @escaping () -> Void) {
        self.paths = paths
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.startDirectoryStream()
            for file in self.paths.files {
                self.armFileSource(for: file)
            }
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            if let stream = eventStream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                eventStream = nil
            }
            for source in fileSources.values {
                source.cancel()
            }
            fileSources.removeAll()
        }
    }

    // MARK: - Directory watching (FSEventStream)

    private func startDirectoryStream() {
        let existing = paths.directories.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleDebouncedChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // MARK: - File watching (DispatchSource)

    private func armFileSource(for path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            self.scheduleDebouncedChange()
            // SQLite WAL replaces the file on checkpoint; re-open a fresh fd on the new inode.
            if mask.contains(.delete) || mask.contains(.rename) {
                self.fileSources[path] = nil
                self.queue.asyncAfter(deadline: .now() + self.debounceInterval + 0.25) { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.armFileSource(for: path)
                }
            }
        }

        source.setCancelHandler {
            close(descriptor)
        }

        fileSources[path]?.cancel()
        fileSources[path] = source
        source.resume()
    }

    // MARK: - Debounce

    private func scheduleDebouncedChange() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

import Foundation

final class FileSystemMonitor: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.adang.ClawFind.fsmonitor")
    private var debounceWorkItem: DispatchWorkItem?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start(path: String) {
        stop()

        queue.sync {
            let pathsToWatch = [path] as CFArray

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventCallback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,   // FSEvents 自身的合并延迟
                UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            ) else {
                return
            }

            self.streamRef = stream
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        queue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil

            guard let stream = streamRef else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    fileprivate func handleEvents() {
        // 在 queue 上防抖，500ms 内的连续事件只触发一次回调
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}

private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(info).takeUnretainedValue()
    monitor.handleEvents()
}

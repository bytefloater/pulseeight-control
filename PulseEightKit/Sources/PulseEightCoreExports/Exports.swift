import Foundation
import PulseEightCore

// The C interface to PulseEightCore, declared in include/pulseeight_core.h. Strings crossing the
// boundary are UTF-8; every string returned to the caller is owned by the caller and must be
// released with p8_free_string.

private final class Handle {
    let core: AppCore
    var observerToken: UUID?
    // Guarded by `lock`: the observer can fire while the caller replaces or clears it.
    let lock = NSLock()
    var callback: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?
    var context: UnsafeMutableRawPointer?

    init(core: AppCore) { self.core = core }
}

private func handle(_ pointer: UnsafeMutableRawPointer?) -> Handle? {
    pointer.map { Unmanaged<Handle>.fromOpaque($0).takeUnretainedValue() }
}

private func duplicate(_ string: String) -> UnsafeMutablePointer<CChar>? {
    strdup(string)
}

private final class ResultBox<V>: @unchecked Sendable {
    var value: V?
}

/// Runs async work to completion on the calling thread.
private func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

/// Version of this interface; bumped on breaking changes.
@_cdecl("p8_abi_version")
public func p8_abi_version() -> Int32 { 1 }

/// Creates a core that loads saved settings and begins connecting in the background.
@_cdecl("p8_create")
public func p8_create() -> UnsafeMutableRawPointer? {
    let handle = Handle(core: AppCore())
    let core = handle.core
    Task { await core.start() }
    return Unmanaged.passRetained(handle).toOpaque()
}

@_cdecl("p8_destroy")
public func p8_destroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let handle = Unmanaged<Handle>.fromOpaque(pointer).takeRetainedValue()
    if let token = handle.observerToken { handle.core.removeObserver(token) }
    handle.lock.lock()
    handle.callback = nil
    handle.lock.unlock()
    // Without this the core's polling loops would outlive the handle and keep talking to the matrix.
    let core = handle.core
    blocking { await core.stop() }
}

/// Current state as a JSON snapshot (see docs/core-interface.md).
@_cdecl("p8_snapshot")
public func p8_snapshot(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    guard let handle = handle(pointer) else { return nil }
    return duplicate(CoreSnapshot(core: handle.core).jsonString())
}

/// Sends one JSON command and waits for its JSON response. Blocks, so call it off the UI thread.
@_cdecl("p8_call")
public func p8_call(_ pointer: UnsafeMutableRawPointer?, _ request: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let handle = handle(pointer), let request else { return duplicate("{\"ok\":false,\"error\":\"Invalid handle or request\"}") }
    let text = String(cString: request)
    let core = handle.core
    return duplicate(blocking { await core.handle(requestJSON: text) })
}

/// Registers (or with a NULL callback, clears) the function called with a fresh snapshot after every
/// change. It runs on a background thread; the snapshot string is only valid during the call.
@_cdecl("p8_set_observer")
public func p8_set_observer(
    _ pointer: UnsafeMutableRawPointer?,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let handle = handle(pointer) else { return }
    handle.lock.lock()
    handle.callback = callback
    handle.context = context
    handle.lock.unlock()

    guard handle.observerToken == nil else { return }
    let core = handle.core
    handle.observerToken = core.addObserver { [weak handle] _ in
        guard let handle else { return }
        handle.lock.lock()
        let callback = handle.callback
        let context = handle.context
        handle.lock.unlock()
        guard let callback else { return }
        CoreSnapshot(core: core).jsonString().withCString { callback(context, $0) }
    }
}

@_cdecl("p8_free_string")
public func p8_free_string(_ string: UnsafeMutablePointer<CChar>?) {
    free(string)
}

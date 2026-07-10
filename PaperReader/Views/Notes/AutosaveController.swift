import Foundation

/// Debounces save requests: after `schedule()` is called, `onSave` fires once the
/// caller stops calling `schedule()` for `debounce` seconds. `flush()` saves
/// immediately if a save is pending (e.g. when the window closes).
@MainActor
final class AutosaveController {
    private let debounce: TimeInterval
    private let onSave: () -> Void
    private var pending: DispatchWorkItem?

    init(debounce: TimeInterval = 1.5, onSave: @escaping () -> Void) {
        self.debounce = debounce
        self.onSave = onSave
    }

    /// (Re)start the debounce timer. Call on every edit.
    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onSave()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// If a save is pending, cancel the timer and save right now.
    func flush() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        onSave()
    }

    /// Cancel any pending save without saving.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

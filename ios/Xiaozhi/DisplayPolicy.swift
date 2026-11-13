import UIKit

/// Foreground-only policy: never change the user's Auto-Lock setting globally.
@MainActor
final class DisplayPolicy {
    private var timer: Timer?
    private var savedBrightness: CGFloat?
    private let nightBrightness: CGFloat = 0.15
    private var isActive = false

    func activate() {
        guard !isActive else { return }
        isActive = true
        UIApplication.shared.isIdleTimerDisabled = true
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    func deactivate() {
        isActive = false
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        restoreBrightness()
    }

    private func update() {
        guard isActive else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 22 || hour < 6
        if isNight {
            if savedBrightness == nil {
                savedBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = min(UIScreen.main.brightness, nightBrightness)
            }
        } else {
            restoreBrightness()
        }
    }

    private func restoreBrightness() {
        guard let previous = savedBrightness else { return }
        savedBrightness = nil
        // Do not overwrite a brightness adjustment made manually while dimmed.
        if abs(UIScreen.main.brightness - min(previous, nightBrightness)) < 0.015 {
            UIScreen.main.brightness = previous
        }
    }
}

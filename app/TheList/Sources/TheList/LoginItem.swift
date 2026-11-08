import Foundation
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "login-item")

/// E7.4 "Open at login", through `SMAppService.mainApp`. Off by default. The choice is also kept
/// in UserDefaults, because `build-app.sh` replaces and re-signs the app on every rebuild, which
/// can drop the login item; `refresh()` puts it back at the next launch.
@MainActor
@Observable
final class LoginItem {
    private(set) var isOn = false
    /// A short note for the popover footer. Clears itself.
    private(set) var message: String?

    @ObservationIgnored private let wantedKey = "openAtLogin"

    func refresh() {
        let service = SMAppService.mainApp
        if UserDefaults.standard.bool(forKey: wantedKey), service.status != .enabled {
            do {
                try service.register()
            } catch {
                log.error("re-register failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        update()
    }

    func setOn(_ on: Bool) {
        let service = SMAppService.mainApp
        UserDefaults.standard.set(on, forKey: wantedKey)
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            log.error("\(on ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            if service.status != .requiresApproval {
                show("Couldn't change Open at login: \(error.localizedDescription)")
            }
        }
        update()
    }

    private func update() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        if status == .requiresApproval, UserDefaults.standard.bool(forKey: wantedKey) {
            show("Allow The Companion in Login Items to open it at login.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func show(_ text: String) {
        message = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.message == text { self?.message = nil }
        }
    }
}

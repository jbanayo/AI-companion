import Foundation
import IOKit.pwr_mgt
import Observation
import os

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "agent-mode")

/// What agent mode needs from the system, so `--selftest` can swap in a fake that never
/// touches power settings or asks for a password.
protocol PowerControl: Sendable {
    /// Keeps the Mac from idle-sleeping while the screen is off (what `caffeinate -i` does).
    /// Needs no permission. Returns false if macOS refused the assertion.
    @MainActor func holdAwake() -> Bool
    @MainActor func releaseAwake()
    /// `pmset -g` reports `SleepDisabled 1`: the Mac stays awake with the lid closed.
    func lidAwake() -> Bool
    /// Runs `pmset -a disablesleep 0|1` as admin, which shows the macOS password prompt.
    /// Throws if it was cancelled or failed.
    func setLidAwake(_ on: Bool) throws
}

/// E9: keeps Claude Code and Codex running while the screen is off, and (with the admin
/// password) while the lid is closed. Not remembered across launches on purpose: a reboot
/// shouldn't quietly keep a closed Mac awake in a bag. The lid state is read back from
/// `pmset`, so one left on by a crash still shows as on.
@MainActor
@Observable
final class AgentMode {
    /// The idle-sleep assertion is held.
    private(set) var screenAwake = false
    /// Sleep on lid close is disabled system-wide.
    private(set) var lidAwake = false
    /// Waiting on the password prompt.
    private(set) var busy = false
    /// A short note for the popover footer. Clears itself.
    private(set) var message: String?

    var isOn: Bool { screenAwake || lidAwake }

    @ObservationIgnored private let power: PowerControl

    init(power: PowerControl = SystemPower()) {
        self.power = power
    }

    func refresh() {
        let power = power
        Task.detached {
            let lid = power.lidAwake()
            await MainActor.run { self.lidAwake = lid }
        }
    }

    func setOn(_ on: Bool) {
        guard !busy else { return }
        if on {
            screenAwake = power.holdAwake()
            if !screenAwake { show("macOS wouldn't keep the Mac awake.") }
        } else {
            power.releaseAwake()
            screenAwake = false
        }
        guard on != lidAwake else { return }
        busy = true
        let power = power
        Task.detached {
            let outcome = Result { try power.setLidAwake(on) }
            let lid = power.lidAwake()
            await MainActor.run {
                self.busy = false
                self.lidAwake = lid
                if case let .failure(error) = outcome { log.info("pmset: \(String(describing: error), privacy: .public)") }
                if on && !lid {
                    self.show("Agent mode on, but closing the lid will still sleep the Mac.")
                } else if !on && lid {
                    self.show("The Mac still stays awake with the lid closed. Turn agent mode off again to fix that.")
                }
            }
        }
    }

    /// On Quit: let the Mac sleep again. The password prompt blocks, which is fine here.
    func shutdown() {
        power.releaseAwake()
        screenAwake = false
        if power.lidAwake() { try? power.setLidAwake(false) }
    }

    private func show(_ text: String) {
        message = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.message == text { self?.message = nil }
        }
    }
}

struct PowerError: Error, CustomStringConvertible {
    let description: String
}

/// The real thing: an IOKit assertion for the screen, `pmset disablesleep` for the lid.
final class SystemPower: PowerControl, @unchecked Sendable {
    /// Only touched on the main actor.
    private var assertion: IOPMAssertionID = 0

    @MainActor func holdAwake() -> Bool {
        if assertion != 0 { return true }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "The Companion agent mode: keeping Claude Code and Codex running" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return false }
        assertion = id
        return true
    }

    @MainActor func releaseAwake() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    func lidAwake() -> Bool {
        guard let out = try? run("/usr/bin/pmset", ["-g"]) else { return false }
        return out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.first == "SleepDisabled" && parts.dropFirst().first == "1"
        }
    }

    func setLidAwake(_ on: Bool) throws {
        let script = #"do shell script "/usr/bin/pmset -a disablesleep \#(on ? 1 : 0)" with administrator privileges"#
        _ = try run("/usr/bin/osascript", ["-e", script])
    }

    private func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PowerError(description: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

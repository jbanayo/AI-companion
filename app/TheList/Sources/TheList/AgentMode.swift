import Foundation
import IOKit.pwr_mgt
import Observation
import os

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "agent-mode")

/// What Saiyan mode needs from the system, so `--selftest` can swap in a fake that never
/// touches power settings or asks for a password.
protocol PowerControl: Sendable {
    /// Keeps the Mac from idle-sleeping while the screen is off (what `caffeinate -i` does).
    /// Needs no permission. Returns false if macOS refused the assertion.
    @MainActor func holdAwake() -> Bool
    @MainActor func releaseAwake()
    /// `pmset -g` reports `SleepDisabled 1`: the Mac stays awake with the lid closed.
    func lidAwake() -> Bool
    /// Runs `pmset -a disablesleep 0|1` as admin, which shows the macOS password prompt.
    /// Throws if it was cancelled or failed. The same prompt installs the sudoers rule that lets
    /// `releaseLidQuietly` work from then on.
    func setLidAwake(_ on: Bool) throws
    /// Lets the Mac sleep with the lid closed again without a password (E11), through that
    /// sudoers rule. False if the rule isn't there or it failed.
    func releaseLidQuietly() -> Bool
    /// E12.2: sleep now (`pmset sleepnow`, no password). Lid sleep must be allowed again first.
    func sleepNow() throws
    /// E12.2: the normal shutdown, through System Events, so apps get to quit. Needs the
    /// Automation permission, which macOS asks for the first time.
    func shutDown() throws
}

/// E9, E11 "Saiyan mode": keeps Claude Code and Codex running while the screen is off, and (with
/// the admin password) while the lid is closed. Turning it off never asks for the password. Not remembered across launches on purpose: a reboot
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

    /// `askPassword: false` is for turning off with nobody at the Mac (E12.2): without the
    /// sudoers rule the lid part stays on rather than wait on a prompt no one will answer.
    func setOn(_ on: Bool, askPassword: Bool = true) {
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
            // Off goes through the sudoers rule; the password prompt only if that isn't set up.
            let outcome: Result<Void, Error> = if !on && power.releaseLidQuietly() {
                .success(())
            } else if !on && !askPassword {
                .failure(PowerError(description: "no sudoers rule, and no one to ask for the password"))
            } else {
                Result { try power.setLidAwake(on) }
            }
            let lid = power.lidAwake()
            await MainActor.run {
                self.busy = false
                self.lidAwake = lid
                if case let .failure(error) = outcome { log.info("pmset: \(String(describing: error), privacy: .public)") }
                if on && !lid {
                    self.show("Saiyan mode on, but closing the lid will still sleep the Mac.")
                } else if !on && lid {
                    self.show("The Mac still stays awake with the lid closed. Turn Saiyan mode off again to fix that.")
                }
            }
        }
    }

    /// On Quit: let the Mac sleep again. Without the sudoers rule the password prompt blocks,
    /// which is fine here.
    func shutdown() {
        power.releaseAwake()
        screenAwake = false
        if power.lidAwake(), !power.releaseLidQuietly() { try? power.setLidAwake(false) }
    }

    func show(_ text: String) {
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
            "The Companion Saiyan mode: keeping Claude Code and Codex running" as CFString,
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

    /// The one command the sudoers rule allows without a password. It can only give the Mac its
    /// normal lid sleep back.
    static let quietOff = ["/usr/bin/pmset", "-a", "disablesleep", "0"]
    static let sudoersFile = "/etc/sudoers.d/the-companion"

    func setLidAwake(_ on: Bool) throws {
        // While we have admin rights anyway, install the rule if it's missing: written to a temp
        // file, checked with visudo, then moved into place as root:wheel 0440. A failure there
        // leaves pmset's result alone.
        let user = NSUserName().filter { $0.isLetter || $0.isNumber || "._-".contains($0) }
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.quietOff.joined(separator: " "))"
        let f = Self.sudoersFile
        let shell = "/usr/bin/pmset -a disablesleep \(on ? 1 : 0) || exit 1; "
            + "if [ ! -f \(f) ]; then t=$(/usr/bin/mktemp) && echo '\(rule)' > $t && /usr/sbin/visudo -cf $t >/dev/null "
            + "&& /usr/sbin/chown root:wheel $t && /bin/chmod 0440 $t && /bin/mv $t \(f) || /bin/rm -f $t; fi; exit 0"
        _ = try run("/usr/bin/osascript", ["-e", "do shell script \"\(shell)\" with administrator privileges"])
    }

    func releaseLidQuietly() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.sudoersFile) else { return false }
        return (try? run("/usr/bin/sudo", ["-n"] + Self.quietOff)) != nil
    }

    func sleepNow() throws {
        _ = try run("/usr/bin/pmset", ["sleepnow"])
    }

    func shutDown() throws {
        _ = try run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to shut down"])
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

import AppKit

let apps = NSWorkspace.shared.runningApplications
    .filter { $0.activationPolicy == .regular }
    .compactMap { $0.localizedName }

print("Regular apps: \(apps)")

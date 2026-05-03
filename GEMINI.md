# Flux - Project Overview (for Gemini)

## Project Description
Flux is a lightweight, high-performance macOS system monitor that lives in the menu bar. It provides real-time tracking of battery health, memory pressure, CPU usage, and per-process energy impact.

## Core Technologies
- **Language:** Swift (6.2+)
- **Framework:** SwiftUI
- **API:** IOKit (for battery stats), sysctl (for CPU/Memory), SMAppService (for Launch at Login)
- **Monitoring Method:** Asynchronous stream of the `top` utility for low-overhead process tracking.

## Key Features (v2.0.0+)
- **Settings Window**: Customizable via a dedicated gear icon in the popover.
- **Dynamic Menu Bar**: Toggle between Icon Only, Icon + Percentage, and Icon + Time Remaining.
- **Memory Pressure**: Real-time tracking of system memory stress (Normal, Warn, Critical).
- **Smoothed Graphs**: EMA-smoothed battery history and process sparklines for a polished look.
- **Launch at Login**: Native integration via macOS ServiceManagement.

## Architecture
- **`FluxApp.swift`**: The entry point. Manages the `MenuBarExtra` and `Settings` scenes.
- **`BatteryMonitor.swift`**: The core data provider. Handles battery info, memory pressure parsing, and the `top` process stream.
- **`ContentView.swift`**: The main popover UI. Displays metrics, dynamic 1h charts, and the process list.
- **`SettingsView.swift`**: Handles user preferences (Menu bar style, update intervals, login items).
- **`Sources/Flux/Info.plist`**: Configured as `LSUIElement` to run as a background application.

## Build & Run Instructions
Flux is a menu bar app and should be built as a bundle:

1. **Build the binary:**
   ```bash
   swift build
   ```
2. **Update the .app bundle:**
   ```bash
   mkdir -p Flux.app/Contents/MacOS
   cp .build/arm64-apple-macosx/debug/Flux Flux.app/Contents/MacOS/Flux
   cp Sources/Flux/Info.plist Flux.app/Contents/Info.plist
   ```
3. **Launch:**
   ```bash
   open Flux.app
   ```

## Notarization & Distribution
Flux is designed for Developer ID distribution.
- **Certificate:** `Developer ID Application: Rishi Singhal (Q542L49V3D)`
- **Notarization Profile:** `flux-profile`
- **Known Issue:** Always clear xattrs (`xattr -cr Flux.app`) before signing to avoid "resource fork/detritus" errors.

## File Structure
- `Sources/Flux/`: Swift source files and Info.plist.
- `Releases/`: Versioned release notes and notarized ZIP distributions.
- `Package.swift`: SwiftPM configuration.
- `AppIcon.icns`: Application icon assets.
- `Flux.app/`: The local application bundle.

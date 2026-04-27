# Flux

Flux is a professional, high performance battery and system monitor for macOS that lives entirely in your menu bar. It provides real time insights into your Mac's energy consumption, system load, and per-process impact with a beautiful, data driven interface.

## Features

- **Dynamic Menu Bar Icon:** The Flux icon changes color in real-time to reflect your system state (Green for charging, Yellow for Low Power Mode, and Orange for high energy drain).
- **Process Overview:** See which applications are pulling the most weight. Flux maps background helpers and renderers back to their parent GUI apps for a clear picture of what's using your power.
- **Real-Time Streaming:** Unlike traditional monitors that poll periodically, Flux uses a persistent background stream to deliver instant updates with minimal system overhead.
- **In-Depth Metrics:**
    - **CPU History:** 60 second rolling sparklines for every active process.
    - **RAM Tracking:** Accurate resident memory usage shown in MB or GB.
    - **Drain Heat Levels:** Intelligent categorization of energy impact (Low, Moderate, High, Extreme).
- **System-Wide Dashboard:** Aggregate CPU and RAM metrics (Used/Total) available at a glance.

## How it Works

Flux monitors system activity using the `top` utility in a non-blocking, asynchronous stream. It parses energy impact and resource utilization in the background, updating the UI only when necessary to ensure the monitor itself doesn't become a source of battery drain.

## Requirements

- macOS 13.0 or later (Ventura+)
- Xcode 14.1+ (for building from source)

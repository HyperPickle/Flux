# Flux

Flux is a professional, high performance battery and system monitor for macOS that lives entirely in your menu bar. It provides real time insights into your Mac's energy consumption, system load, and per-process impact with a beautiful, data driven interface.

## Features

- **Process Overview:** See which applications are pulling the most weight. Flux maps background helpers and renderers back to their parent GUI apps for a clear picture of what's using your power.
- **Real-Time Streaming:** Unlike traditional monitors that poll periodically, Flux uses a persistent stream to deliver instant updates with minimal overhead.
- **In Depth Metrics:**
    - **CPU History:** 60 second rolling sparklines for every active process.
    - **RAM Tracking:** Accurate resident memory usage shown in MB or GB.
    - **Drain Heat Levels:** Categorises energy impact (Low, Moderate, High, Extreme).
- **System Wide Dashboard:** Aggregate CPU and RAM metrics (Used/Total) available at a glance.
- **Interactive Graph Tooltip:** Floating indicator that tracks your cursor across a 12 hour timeline to display exact battery percentage and time.

## How it Works

Flux monitors system activity using the `top` utility in a non blocking, asynchronous stream. It parses energy impact and resource utilisation in the background, updating the UI only when necessary to ensure the monitor itself doesn't become a source of battery drain.

## Requirements

- macOS 13.0 or later (Ventura+)
- Xcode 14.1+ (for building from source)

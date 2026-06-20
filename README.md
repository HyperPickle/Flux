# Flux

Flux is a menu bar battery and system monitor for macOS. It shows battery status, estimated time remaining, power draw, CPU temperature, memory pressure, and the apps currently driving the most system load.

## Features

- Multiple menu bar display modes: icon only, battery, time remaining, or battery + time.
- Compact display options for percentage-only and time-only labels.
- Live battery status with charge state, time remaining or time to full, and wattage input/drain.
- Interactive battery history chart with persisted history and zoom levels from 1 to 24 hours.
- System health indicators for kernel CPU load, drain level, memory pressure, and CPU temperature when available.
- Process overview with top apps by energy impact, CPU, and RAM, including per-app history sparklines.
- Settings for window opacity, default chart zoom, and launch at login.

## How it works

Flux pulls battery and power-source data from macOS system APIs, reads charge and drain wattage from the IORegistry, and samples process activity with `top`. CPU temperature is read from available SMC sensors. Battery history is saved locally in Application Support and kept to the most recent 24 hours.

## How to download

Grab the latest build from the Releases section on the right side of the GitHub page.

## Requirements

- macOS 26.0 or later
- Swift 6.2

## Notes

- CPU temperature depends on available SMC sensors and may be unavailable on some machines.
- Process metrics appear while the Flux popover is open.

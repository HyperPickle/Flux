import sys
from monitor import BatteryMonitor
from ui import TrayApp

def main():
    print("Starting Flux Monitor...")
    monitor = BatteryMonitor()
    app = TrayApp(monitor)
    app.run()

if __name__ == "__main__":
    main()

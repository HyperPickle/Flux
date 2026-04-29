import psutil
import time
import os
import threading
from collections import defaultdict, deque

class AppMetricPoint:
    def __init__(self, id_val, cpu, power):
        self.id = id_val
        self.cpu = cpu
        self.power = power

class AppEnergyUsage:
    def __init__(self, appName, energyImpact, cpuUsage, ramUsageMB, history, pid=None):
        self.appName = appName
        self.energyImpact = energyImpact
        self.cpuUsage = cpuUsage
        self.ramUsageMB = ramUsageMB
        self.history = history
        self.pid = pid

    @property
    def ramUsage(self):
        if self.ramUsageMB >= 1024:
            return f"{self.ramUsageMB/1024:.1f}GB"
        return f"{self.ramUsageMB}MB"

class BatteryMonitor:
    def __init__(self):
        self.batteryLevel = 100 # Default to 100 if no battery
        self.isCharging = True
        self.powerSource = "AC Power"
        self.timeRemaining = "Fully Charged"
        self.topEnergyApps = []
        self.totalEnergyImpact = 0.0

        self.systemCPU = "0%"
        self.systemCPUValue = 0.0
        self.systemRAM = "0/0GB"
        self.systemRAMPercent = 0.0

        self.batteryHistory = deque(maxlen=24*60*6) # Roughly 24 hours if polled every 10s
        self.appHistory = defaultdict(lambda: deque(maxlen=15))

        self.running = True
        self.core_count = psutil.cpu_count(logical=True)
        self.total_ram_bytes = psutil.virtual_memory().total

        self._lock = threading.Lock()

        self._start_monitoring()

    def _start_monitoring(self):
        self.update_battery_info()
        self.update_system_metrics()
        # Initialize psutil cpu percent
        psutil.cpu_percent()
        for p in psutil.process_iter(['name']):
            try:
                p.cpu_percent()
            except:
                pass

        self.monitor_thread = threading.Thread(target=self._monitor_loop, daemon=True)
        self.monitor_thread.start()

    def _monitor_loop(self):
        while self.running:
            try:
                self.update_battery_info()
                self.update_system_metrics()
                self.update_process_metrics()
            except Exception as e:
                print(f"Error in monitor loop: {e}")
            time.sleep(5) # 5 seconds interval, similar to top -s 5

    def update_battery_info(self):
        battery = psutil.sensors_battery()
        with self._lock:
            if battery:
                self.batteryLevel = int(battery.percent)
                self.isCharging = battery.power_plugged
                self.powerSource = "AC Power" if self.isCharging else "Battery"

                if self.isCharging:
                    self.timeRemaining = "Charging"
                else:
                    if battery.secsleft and battery.secsleft != psutil.POWER_TIME_UNKNOWN:
                        m, s = divmod(battery.secsleft, 60)
                        h, m = divmod(m, 60)
                        self.timeRemaining = f"{h}:{m:02d} remaining"
                    else:
                        self.timeRemaining = "On Battery"
            else:
                self.batteryLevel = 100
                self.isCharging = True
                self.powerSource = "AC Power"
                self.timeRemaining = "Fully Charged"

            # Append to history
            point_id = len(self.batteryHistory)
            self.batteryHistory.append({
                "id": point_id,
                "time": time.time(),
                "level": self.batteryLevel
            })

    def update_system_metrics(self):
        cpu_percent = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()

        with self._lock:
            self.systemCPUValue = cpu_percent
            self.systemCPU = f"{cpu_percent:.0f}%"

            used_mb = mem.used / (1024 * 1024)
            total_gb = self.total_ram_bytes / (1024 * 1024 * 1024)
            used_display = f"{used_mb/1024:.1f}GB" if used_mb >= 1024 else f"{int(used_mb)}MB"

            self.systemRAM = f"{used_display}/{int(total_gb)}GB"
            self.systemRAMPercent = mem.percent

    def update_process_metrics(self):
        apps = {}
        for p in psutil.process_iter(['pid', 'name']):
            try:
                info = p.info
                name = info['name']
                if not name: continue
                # The psutil cpu_percent for processes is >100% for multi-core, divide by core_count to match Activity Monitor/top -o cpu
                # But note: without interval, process cpu_percent might be non-blocking but relative to last call.
                cpu = p.cpu_percent(interval=None) / self.core_count
                mem_mb = p.memory_info().rss / (1024 * 1024)

                # Approximate energy impact (very rough heuristic: CPU is main driver)
                # Windows doesn't expose a direct 'energy impact' easily via psutil
                power = cpu * 1.5

                if name in apps:
                    apps[name]['cpu'] += cpu
                    apps[name]['mem'] += mem_mb
                    apps[name]['power'] += power
                else:
                    apps[name] = {'cpu': cpu, 'mem': mem_mb, 'power': power, 'pid': info['pid']}
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess, AttributeError):
                pass

        # Aggregate
        with self._lock:
            energy_apps = []
            for name, data in apps.items():
                cpu = data['cpu']
                power = data['power']

                # Filter out idle/system processes that don't make sense or have 0
                if name.lower() in ('idle', 'system idle process', 'system') or cpu < 0.1:
                    continue

                hist = self.appHistory[name]
                new_id = hist[-1].id + 1 if hist else 0
                hist.append(AppMetricPoint(new_id, cpu, power))

                energy_apps.append(AppEnergyUsage(
                    appName=name,
                    energyImpact=power,
                    cpuUsage=cpu,
                    ramUsageMB=int(data['mem']),
                    history=list(hist),
                    pid=data['pid']
                ))

            # Sort by energy impact desc, then cpu
            energy_apps.sort(key=lambda x: (x.energyImpact, x.cpuUsage), reverse=True)
            self.topEnergyApps = energy_apps[:5]
            self.totalEnergyImpact = sum(app.energyImpact for app in energy_apps)

    def get_state(self):
        with self._lock:
            return {
                "batteryLevel": self.batteryLevel,
                "isCharging": self.isCharging,
                "powerSource": self.powerSource,
                "timeRemaining": self.timeRemaining,
                "systemCPU": self.systemCPU,
                "systemCPUValue": self.systemCPUValue,
                "systemRAM": self.systemRAM,
                "systemRAMPercent": self.systemRAMPercent,
                "topEnergyApps": self.topEnergyApps,
                "totalEnergyImpact": self.totalEnergyImpact,
                "batteryHistory": list(self.batteryHistory)
            }

    def stop(self):
        self.running = False

from monitor import BatteryMonitor
import time
m = BatteryMonitor()
time.sleep(2) # Give it time to poll once
state = m.get_state()
print(f"Battery: {state['batteryLevel']}%")
print(f"CPU: {state['systemCPU']}")
print(f"RAM: {state['systemRAM']}")
print(f"Top App: {state['topEnergyApps'][0].appName if state['topEnergyApps'] else 'None'}")
m.stop()

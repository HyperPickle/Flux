import sys
import time
from PyQt6.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout,
                             QLabel, QSystemTrayIcon, QMenu, QFrame, QScrollArea,
                             QSizePolicy, QPushButton, QGraphicsDropShadowEffect)
from PyQt6.QtGui import QIcon, QPainter, QColor, QPen, QFont, QPolygonF, QBrush, QAction
from PyQt6.QtCore import Qt, QTimer, QPoint, QRect, QPointF
import pyqtgraph as pg

# Configure pyqtgraph for a clean look
pg.setConfigOption('background', 'w')
pg.setConfigOption('foreground', '#333')

def get_cpu_color(val):
    if val < 35: return QColor(34, 197, 94) # Green
    if val < 75: return QColor(234, 179, 8) # Yellow
    return QColor(239, 68, 68) # Red

def get_drain_level(impact):
    if impact < 20: return "Low Drain", QColor(34, 197, 94)
    if impact < 60: return "Moderate", QColor(234, 179, 8)
    if impact < 150: return "High Drain", QColor(249, 115, 22)
    return "Extreme", QColor(239, 68, 68)

def get_heat_level(power, cpu):
    if power > 0:
        if power < 5: return "Low", QColor(156, 163, 175)
        if power < 20: return "Medium", QColor(234, 179, 8)
        if power < 50: return "High", QColor(249, 115, 22)
        return "Critical", QColor(239, 68, 68)
    else:
        if cpu < 10: return "Low", QColor(156, 163, 175)
        if cpu < 30: return "Medium", QColor(234, 179, 8)
        if cpu < 70: return "High", QColor(249, 115, 22)
        return "Critical", QColor(239, 68, 68)

class MetricPill(QFrame):
    def __init__(self, label, value, color):
        super().__init__()
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {color.name()}14;
                border: 1px solid {color.name()}26;
                border-radius: 6px;
            }}
            QLabel {{ border: none; background: transparent; }}
        """)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(8, 4, 8, 4)
        layout.setSpacing(4)

        val_lbl = QLabel(value)
        val_lbl.setFont(QFont("Segoe UI", 9, QFont.Weight.Bold))
        val_lbl.setStyleSheet(f"color: {color.name()};")

        layout.addWidget(val_lbl)

class AppDetailWidget(QFrame):
    def __init__(self, app_data, heat_color):
        super().__init__()
        self.app_data = app_data
        self.heat_color = heat_color
        self.init_ui()

    def init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 5, 0, 0)
        layout.setSpacing(5)

        title = QLabel("CPU HISTORY (60S)")
        title.setFont(QFont("Segoe UI", 7, QFont.Weight.Bold))
        title.setStyleSheet("color: #6B7280;")
        layout.addWidget(title)

        content = QHBoxLayout()

        # Sparkline
        self.plot = pg.PlotWidget()
        self.plot.setFixedHeight(40)
        self.plot.hideAxis('left')
        self.plot.hideAxis('bottom')
        self.plot.setMouseEnabled(x=False, y=False)
        self.plot.setMenuEnabled(False)

        if len(self.app_data.history) > 1:
            x = [p.id for p in self.app_data.history]
            y = [p.cpu for p in self.app_data.history]
            pen = pg.mkPen(color=self.heat_color.name(), width=2)
            self.plot.plot(x, y, pen=pen, fillLevel=0, brush=(self.heat_color.red(), self.heat_color.green(), self.heat_color.blue(), 50))

        content.addWidget(self.plot, stretch=2)

        # Stats
        stats_layout = QVBoxLayout()

        cpu_lbl = QLabel(f"CPU\n{self.app_data.cpuUsage:.0f}%")
        cpu_lbl.setFont(QFont("Segoe UI", 8, QFont.Weight.Bold))
        cpu_lbl.setStyleSheet("background-color: #F3F4F6; border-radius: 4px; padding: 2px;")

        ram_lbl = QLabel(f"RAM\n{self.app_data.ramUsage}")
        ram_lbl.setFont(QFont("Segoe UI", 8, QFont.Weight.Bold))
        ram_lbl.setStyleSheet("background-color: #F3F4F6; border-radius: 4px; padding: 2px;")

        stats_layout.addWidget(cpu_lbl)
        stats_layout.addWidget(ram_lbl)

        content.addLayout(stats_layout, stretch=1)
        layout.addLayout(content)

class AppCard(QFrame):
    def __init__(self, app_data):
        super().__init__()
        self.app_data = app_data
        self.is_expanded = False
        self.heat_label, self.heat_color = get_heat_level(app_data.energyImpact, app_data.cpuUsage)

        self.setStyleSheet(f"""
            QFrame {{
                background-color: {self.heat_color.name()}0A;
                border: 1px solid {self.heat_color.name()}1F;
                border-radius: 8px;
            }}
            QLabel {{ border: none; background: transparent; }}
        """)

        self.main_layout = QVBoxLayout(self)
        self.main_layout.setContentsMargins(10, 10, 10, 10)
        self.main_layout.setSpacing(0)

        # Header
        self.header = QWidget()
        self.header.setStyleSheet("background: transparent; border: none;")
        h_layout = QHBoxLayout(self.header)
        h_layout.setContentsMargins(0,0,0,0)

        name_lbl = QLabel(app_data.appName)
        name_lbl.setFont(QFont("Segoe UI", 10, QFont.Weight.Medium))

        cpu_lbl = QLabel(f"{app_data.cpuUsage:.0f}%")
        cpu_lbl.setFont(QFont("Segoe UI", 9, QFont.Weight.Bold))
        cpu_lbl.setStyleSheet("color: #6B7280;")
        cpu_lbl.setFixedWidth(35)
        cpu_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)

        heat_lbl = QLabel(self.heat_label)
        heat_lbl.setFont(QFont("Segoe UI", 8, QFont.Weight.Bold))
        heat_lbl.setStyleSheet(f"color: {self.heat_color.name()};")
        heat_lbl.setFixedWidth(45)
        heat_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)

        h_layout.addWidget(name_lbl, stretch=1)
        h_layout.addWidget(cpu_lbl)
        h_layout.addWidget(heat_lbl)

        self.main_layout.addWidget(self.header)

        # Details
        self.details = AppDetailWidget(app_data, self.heat_color)
        self.details.setVisible(False)
        self.main_layout.addWidget(self.details)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.is_expanded = not self.is_expanded
            self.details.setVisible(self.is_expanded)

class BatteryChart(pg.PlotWidget):
    def __init__(self):
        super().__init__()
        self.setFixedHeight(60)
        self.hideAxis('left')
        self.hideAxis('bottom')
        self.setMouseEnabled(x=False, y=False)
        self.setMenuEnabled(False)

    def update_data(self, history, is_charging):
        self.clear()
        if not history: return

        times = [p['time'] for p in history]
        levels = [p['level'] for p in history]

        # Normalize times
        min_time = min(times)
        max_time = max(times)
        if min_time == max_time:
            x = [0]
        else:
            x = [(t - min_time) for t in times]

        color = QColor(34, 197, 94)
        if is_charging: color = QColor(59, 130, 246)
        elif levels[-1] <= 20: color = QColor(239, 68, 68)
        elif levels[-1] <= 40: color = QColor(249, 115, 22)

        pen = pg.mkPen(color=color.name(), width=2)
        self.plot(x, levels, pen=pen, fillLevel=0, brush=(color.red(), color.green(), color.blue(), 50))
        self.setYRange(0, 100)

class FluxWindow(QWidget):
    def __init__(self, monitor):
        super().__init__()
        self.monitor = monitor

        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.Popup | Qt.WindowType.WindowStaysOnTopHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setFixedSize(280, 500)

        self.init_ui()

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update_ui)
        self.timer.start(5000) # 5 seconds

    def init_ui(self):
        # Main background frame
        self.bg_frame = QFrame(self)
        self.bg_frame.setGeometry(0, 0, 280, 500)
        self.bg_frame.setStyleSheet("""
            QFrame {
                background-color: white;
                border-radius: 12px;
                border: 1px solid #E5E7EB;
            }
        """)

        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(20)
        shadow.setColor(QColor(0, 0, 0, 40))
        shadow.setOffset(0, 4)
        self.bg_frame.setGraphicsEffect(shadow)

        layout = QVBoxLayout(self.bg_frame)
        layout.setContentsMargins(16, 16, 16, 16)
        layout.setSpacing(10)

        # Header
        header_layout = QHBoxLayout()
        v_header = QVBoxLayout()
        v_header.setSpacing(2)

        self.battery_lbl = QLabel("100%")
        self.battery_lbl.setFont(QFont("Segoe UI", 32, QFont.Weight.Bold))
        self.battery_lbl.setStyleSheet("color: #22C55E; border: none;")

        self.status_lbl = QLabel("Fully Charged")
        self.status_lbl.setFont(QFont("Segoe UI", 10, QFont.Weight.Medium))
        self.status_lbl.setStyleSheet("color: #6B7280; border: none;")

        v_header.addWidget(self.battery_lbl)
        v_header.addWidget(self.status_lbl)

        header_layout.addLayout(v_header)
        header_layout.addStretch()

        self.close_btn = QPushButton("✕")
        self.close_btn.setFixedSize(24, 24)
        self.close_btn.setStyleSheet("border: none; color: #9CA3AF; font-weight: bold;")
        self.close_btn.clicked.connect(self.hide)
        header_layout.addWidget(self.close_btn, alignment=Qt.AlignmentFlag.AlignTop)

        layout.addLayout(header_layout)

        # System Metrics
        metrics_layout = QHBoxLayout()
        self.cpu_pill = MetricPill("CPU", "0%", QColor(34, 197, 94))
        self.drain_pill = MetricPill("DRAIN", "Low Drain", QColor(34, 197, 94))
        metrics_layout.addWidget(self.cpu_pill)
        metrics_layout.addWidget(self.drain_pill)
        metrics_layout.addStretch()
        layout.addLayout(metrics_layout)

        # Chart
        self.chart = BatteryChart()
        layout.addWidget(self.chart)

        # Separator
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        line.setStyleSheet("color: #E5E7EB; border: none; background-color: #E5E7EB;")
        line.setFixedHeight(1)
        layout.addWidget(line)

        proc_title = QLabel("PROCESS OVERVIEW")
        proc_title.setFont(QFont("Segoe UI", 8, QFont.Weight.Bold))
        proc_title.setStyleSheet("color: #9CA3AF; border: none;")
        layout.addWidget(proc_title)

        # Processes Area
        self.scroll_area = QScrollArea()
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setStyleSheet("QScrollArea { border: none; background: transparent; }")

        self.apps_container = QWidget()
        self.apps_container.setStyleSheet("background: transparent;")
        self.apps_layout = QVBoxLayout(self.apps_container)
        self.apps_layout.setContentsMargins(0, 0, 0, 0)
        self.apps_layout.setSpacing(6)
        self.apps_layout.addStretch()

        self.scroll_area.setWidget(self.apps_container)
        layout.addWidget(self.scroll_area)

        self.update_ui()

    def update_ui(self):
        state = self.monitor.get_state()

        # Update header
        self.battery_lbl.setText(f"{state['batteryLevel']}%")
        self.status_lbl.setText(state['timeRemaining'])

        color = QColor(34, 197, 94)
        if state['isCharging']: color = QColor(59, 130, 246)
        elif state['batteryLevel'] <= 20: color = QColor(239, 68, 68)
        elif state['batteryLevel'] <= 40: color = QColor(249, 115, 22)
        self.battery_lbl.setStyleSheet(f"color: {color.name()}; border: none;")

        # Metrics
        cpu_color = get_cpu_color(state['systemCPUValue'])
        self.cpu_pill.deleteLater()
        self.cpu_pill = MetricPill("CPU", state['systemCPU'], cpu_color)

        drain_lbl, drain_color = get_drain_level(state['totalEnergyImpact'])
        self.drain_pill.deleteLater()
        self.drain_pill = MetricPill("DRAIN", drain_lbl, drain_color)

        metrics_layout = self.bg_frame.layout().itemAt(1).layout()
        # insert before stretch
        metrics_layout.insertWidget(0, self.cpu_pill)
        metrics_layout.insertWidget(1, self.drain_pill)

        # Chart
        self.chart.update_data(state['batteryHistory'], state['isCharging'])

        # Apps
        # Clear existing
        while self.apps_layout.count() > 1: # Keep the stretch at the end
            item = self.apps_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        for app in state['topEnergyApps']:
            card = AppCard(app)
            self.apps_layout.insertWidget(self.apps_layout.count() - 1, card)

class TrayApp:
    def __init__(self, monitor):
        self.app = QApplication(sys.argv)
        self.app.setQuitOnLastWindowClosed(False)
        self.monitor = monitor

        self.window = FluxWindow(monitor)

        self.tray = QSystemTrayIcon()
        # Create a simple generic icon
        icon_pixmap = QIcon.fromTheme("battery").pixmap(32, 32)
        if icon_pixmap.isNull():
            # Fallback simple rect
            pixmap = QIcon().pixmap(32,32)
            pixmap.fill(Qt.GlobalColor.transparent)
            painter = QPainter(pixmap)
            painter.setBrush(QBrush(QColor("black")))
            painter.drawRect(8, 10, 16, 12)
            painter.drawRect(24, 13, 2, 6)
            painter.end()
            self.tray.setIcon(QIcon(pixmap))
        else:
            self.tray.setIcon(QIcon(icon_pixmap))

        self.tray.setVisible(True)

        self.menu = QMenu()
        quit_action = QAction("Quit Flux", self.menu)
        quit_action.triggered.connect(self.quit)
        self.menu.addAction(quit_action)

        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.tray_activated)

    def tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            if self.window.isVisible():
                self.window.hide()
            else:
                # Position near tray (bottom right typically on Windows)
                geom = self.tray.geometry()
                screen = QApplication.primaryScreen().availableGeometry()
                x = screen.width() - self.window.width() - 10
                y = screen.height() - self.window.height() - 10
                # In a real app we'd get taskbar pos, but this is a good approximation
                self.window.move(x, y)
                self.window.show()
                self.window.activateWindow()

    def run(self):
        sys.exit(self.app.exec())

    def quit(self):
        self.monitor.stop()
        self.app.quit()

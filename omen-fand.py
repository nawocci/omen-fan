#!/usr/bin/env python3

import os
import signal
import sys
import json
import logging
from time import sleep
from bisect import bisect_left
from collections import deque
from logging.handlers import RotatingFileHandler

ECIO_FILE = "/sys/kernel/debug/ec/ec0/io"
IPC_FILE = "/tmp/omen-fand.PID"
CONFIG_FILE = "/etc/omen-fan/config.json"
LOG_DIR = "/var/log/omen-fan"

FAN1_OFFSET = 52
FAN2_OFFSET = 53
BIOS_OFFSET = 98
TIMER_OFFSET = 99
CPU_TEMP_OFFSET = 87
GPU_TEMP_OFFSET = 183

FAN1_MAX = 55
FAN2_MAX = 57

DEFAULT_CONFIG = {
    "service": {
        "TEMP_CURVE": [50, 60, 70, 80, 87, 93],
        "SPEED_CURVE": [20, 40, 60, 70, 85, 100],
        "IDLE_SPEED": 0,
        "POLL_INTERVAL": 1.0,
        "TEMP_SMOOTHING": True,
        "HYSTERESIS": 2
    }
}

def setup_logging():
    os.makedirs(LOG_DIR, exist_ok=True)
    handler = RotatingFileHandler(
        f"{LOG_DIR}/omen-fand.log", 
        maxBytes=1024*1024, 
        backupCount=3
    )
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[handler]
    )

def load_config():
    try:
        with open(CONFIG_FILE, "r") as file:
            config = json.load(file)
            merged_config = DEFAULT_CONFIG.copy()
            if "service" in config:
                merged_config["service"].update(config["service"])
            return merged_config["service"]
    except (FileNotFoundError, json.JSONDecodeError) as e:
        logging.warning(f"Config load failed, using defaults: {e}")
        return DEFAULT_CONFIG["service"]

class TemperatureFilter:
    def __init__(self, window_size=5, hysteresis=2):
        self.window = deque(maxlen=window_size)
        self.hysteresis = hysteresis
        self.last_speed = 0
    
    def smooth_temp(self, temp):
        self.window.append(temp)
        return sum(self.window) / len(self.window)
    
    def apply_hysteresis(self, new_speed):
        if abs(new_speed - self.last_speed) < self.hysteresis:
            return self.last_speed
        self.last_speed = new_speed
        return new_speed

config = load_config()
TEMP_CURVE = config["TEMP_CURVE"]
SPEED_CURVE = config["SPEED_CURVE"]
IDLE_SPEED = config["IDLE_SPEED"]
POLL_INTERVAL = config["POLL_INTERVAL"]
TEMP_SMOOTHING = config["TEMP_SMOOTHING"]
HYSTERESIS = config["HYSTERESIS"]

temp_filter = TemperatureFilter(hysteresis=HYSTERESIS)

# Precalculate slopes to reduce compute time.
slope = []
for i in range(1, len(TEMP_CURVE)):
    speed_diff = SPEED_CURVE[i] - SPEED_CURVE[i - 1]
    temp_diff = TEMP_CURVE[i] - TEMP_CURVE[i - 1]
    slope_val = round(speed_diff / temp_diff, 2)
    slope.append(slope_val)


def is_root():
    if os.geteuid() != 0:
        print("  Root access is required for this service.")
        print("  Please run this service as root.")
        sys.exit(1)


def sig_handler(signum, frame):
    os.remove("/tmp/omen-fand.PID")
    bios_control(True)
    sys.exit()


def update_fan(speed1, speed2):
    with open(ECIO_FILE, "r+b") as ec:
        ec.seek(FAN1_OFFSET)
        ec.write(bytes([int(speed1)]))
        ec.seek(FAN2_OFFSET)
        ec.write(bytes([int(speed2)]))


def get_temp():
    with open(ECIO_FILE, "rb") as ec:
        ec.seek(CPU_TEMP_OFFSET)
        temp_c = int.from_bytes(ec.read(1), "big")
        ec.seek(GPU_TEMP_OFFSET)
        temp_g = int.from_bytes(ec.read(1), "big")
    return max(temp_c, temp_g)


def bios_control(enabled):
    if enabled is False:
        with open(ECIO_FILE, "r+b") as ec:
            ec.seek(BIOS_OFFSET)
            ec.write(bytes([6]))
            sleep(0.1)
            ec.seek(TIMER_OFFSET)
            ec.write(bytes([0]))
    elif enabled is True:
        with open(ECIO_FILE, "r+b") as ec:
            ec.seek(BIOS_OFFSET)
            ec.write(bytes([0]))
            ec.seek(FAN1_OFFSET)
            ec.write(bytes([0]))
            ec.seek(FAN2_OFFSET)
            ec.write(bytes([0]))


signal.signal(signal.SIGTERM, sig_handler)

setup_logging()
logging.info("omen-fand starting up")

with open(IPC_FILE, "w", encoding="utf-8") as ipc:
    ipc.write(str(os.getpid()))

speed_old = -1
is_root()

while True:
    try:
        temp = get_temp()
        
        if TEMP_SMOOTHING:
            temp = temp_filter.smooth_temp(temp)

        if temp <= TEMP_CURVE[0]:
            speed = IDLE_SPEED
        elif temp >= TEMP_CURVE[-1]:
            speed = SPEED_CURVE[-1]
        else:
            i = bisect_left(TEMP_CURVE, temp)
            y0 = SPEED_CURVE[i - 1]
            x0 = TEMP_CURVE[i - 1]
            speed = y0 + slope[i - 1] * (temp - x0)

        speed = temp_filter.apply_hysteresis(speed)

        if speed_old != speed:
            speed_old = speed
            fan1_speed = int(FAN1_MAX * speed / 100)
            fan2_speed = int(FAN2_MAX * speed / 100)
            update_fan(fan1_speed, fan2_speed)
            logging.debug(f"Temp: {temp:.1f}°C, Speed: {speed:.1f}%, Fan1: {fan1_speed}, Fan2: {fan2_speed}")

        bios_control(False)
        sleep(POLL_INTERVAL)
        
    except KeyboardInterrupt:
        logging.info("Received keyboard interrupt, shutting down")
        break
    except Exception as e:
        logging.error(f"Unexpected error in main loop: {e}")
        sleep(POLL_INTERVAL)

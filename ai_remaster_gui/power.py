from __future__ import annotations

import ctypes
import os
import shutil
import subprocess
import sys
import threading


ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
ES_AWAYMODE_REQUIRED = 0x00000040

_lock = threading.Lock()
_condition = threading.Condition(_lock)
_count = 0
_worker: threading.Thread | None = None
_REFRESH_SECONDS = 30.0
_caffeinate: subprocess.Popen | None = None


def _mac_keep_awake(active: bool) -> None:
    """On macOS, hold a `caffeinate -i` process open while ARP is busy so the Mac doesn't sleep."""
    global _caffeinate
    if active:
        if _caffeinate is None or _caffeinate.poll() is not None:
            exe = shutil.which("caffeinate")
            if exe:
                _caffeinate = subprocess.Popen([exe, "-i", "-w", str(os.getpid())])
    elif _caffeinate is not None:
        _caffeinate.terminate()
        _caffeinate = None


def _set_execution_state(flags: int) -> bool:
    if os.name != "nt":
        return True
    result = ctypes.windll.kernel32.SetThreadExecutionState(flags)
    return bool(result)


def _request_keep_awake() -> None:
    flags = ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED
    if not _set_execution_state(flags):
        _set_execution_state(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)


def _power_worker() -> None:
    active = False
    while True:
        with _condition:
            while _count <= 0:
                if active:
                    _set_execution_state(ES_CONTINUOUS)
                    active = False
                _condition.wait()

        _request_keep_awake()
        active = True

        with _condition:
            if _count > 0:
                _condition.wait(timeout=_REFRESH_SECONDS)


def _ensure_worker_locked() -> None:
    global _worker
    if os.name != "nt":
        return
    if _worker and _worker.is_alive():
        return
    _worker = threading.Thread(target=_power_worker, name="ARPKeepAwake", daemon=True)
    _worker.start()


def keep_awake(reason: str = "") -> None:
    """Prevent Windows system sleep while ARP has an active long-running process."""
    global _count
    if sys.platform == "darwin":
        with _lock:
            _count += 1
            _mac_keep_awake(True)
        return
    if os.name != "nt":
        return
    with _lock:
        _count += 1
        _ensure_worker_locked()
        _condition.notify_all()


def release_keep_awake() -> None:
    global _count
    if sys.platform == "darwin":
        with _lock:
            if _count > 0:
                _count -= 1
            if _count == 0:
                _mac_keep_awake(False)
        return
    if os.name != "nt":
        return
    with _lock:
        if _count > 0:
            _count -= 1
        if _count == 0:
            _condition.notify_all()

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Exercise the TUI through a real controlling pseudo-terminal."""

from __future__ import annotations

import fcntl
import os
import pty
import select
import signal
import subprocess
import sys
import termios
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TUI_ROOT = REPO_ROOT / "packages" / "beamtrace_tui"
READY_MARKER = b"q quit"
EXPECTED_OUTPUT = (b"BeamTrace", READY_MARKER)
EXPECTED_CLEANUP = (b"\x1b[?1049l", b"\x1b[?7h", b"\x1b[?25h")


def pump(master: int, output: bytearray, seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        timeout = min(0.1, max(0.0, deadline - time.monotonic()))
        if not select.select([master], [], [], timeout)[0]:
            continue
        try:
            output.extend(os.read(master, 65536))
        except BlockingIOError:
            continue
        except OSError:
            return


def wait_for_marker(
    process: subprocess.Popen[bytes],
    master: int,
    output: bytearray,
    marker: bytes,
    seconds: float,
) -> bool:
    deadline = time.monotonic() + seconds
    while marker not in output and process.poll() is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        pump(master, output, min(0.2, remaining))
    return marker in output


def terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def fail(message: str, output: bytearray) -> int:
    tail = bytes(output[-2000:]).decode("utf-8", errors="backslashreplace")
    print(message, file=sys.stderr)
    print(f"PTY output tail: {tail!r}", file=sys.stderr)
    return 1


def main() -> int:
    if os.name != "posix":
        print("TUI PTY acceptance requires a POSIX host.", file=sys.stderr)
        return 1

    master, slave = pty.openpty()
    os.set_blocking(master, False)
    output = bytearray()
    environment = os.environ.copy()
    if environment.get("TERM") in (None, "", "dumb"):
        environment["TERM"] = "xterm-256color"

    def own_terminal() -> None:
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        ["gleam", "run"],
        cwd=TUI_ROOT,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=own_terminal,
        env=environment,
    )

    try:
        if not wait_for_marker(process, master, output, READY_MARKER, 30):
            return fail("TUI did not become ready within 30 seconds.", output)

        os.write(master, b"q")
        deadline = time.monotonic() + 10
        while process.poll() is None and time.monotonic() < deadline:
            pump(master, output, 0.2)
        pump(master, output, 1)

        if process.poll() is None:
            return fail("TUI did not exit after the quit key.", output)
        if process.returncode != 0:
            return fail(f"TUI exited with status {process.returncode}.", output)

        missing_output = [value for value in EXPECTED_OUTPUT if value not in output]
        missing_cleanup = [value for value in EXPECTED_CLEANUP if value not in output]
        if missing_output:
            return fail(f"TUI output markers are missing: {missing_output!r}", output)
        if missing_cleanup:
            return fail(f"TUI cleanup sequences are missing: {missing_cleanup!r}", output)

        print("TUI controlling-PTY acceptance passed.")
        return 0
    finally:
        terminate(process)
        os.close(slave)
        os.close(master)


if __name__ == "__main__":
    raise SystemExit(main())

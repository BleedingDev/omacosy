#!/usr/bin/env python3
"""Explicit live unlink/rebind check; the server and desktop must survive."""
import argparse
import getpass
import json
from pathlib import Path
import socket
import struct
import subprocess
import time


def receive_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise ConnectionError("AeroSpace closed the existing connection")
        result.extend(chunk)
    return result


def connect(path):
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(3)
    try:
        connection.connect(str(path))
        connection.sendall(struct.pack("<I", 1))
        if receive_exact(connection, 4) != struct.pack("<I", 1):
            raise ValueError("Unexpected socket protocol version")
        return connection
    except BaseException:
        connection.close()
        raise


def command(connection, *args):
    request = json.dumps(dict(args=args, stdin="", windowId=None, workspace=None)).encode()
    connection.sendall(struct.pack("<I", len(request)) + request)
    length, = struct.unpack("<I", receive_exact(connection, 4))
    answer = json.loads(receive_exact(connection, length))
    if answer["exitCode"] != 0:
        raise RuntimeError(answer["stderr"])
    return answer["stdout"]


def membership(connection):
    return command(connection, "list-windows", "--all", "--format", "%{window-id}|%{workspace}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unlink-active-socket", action="store_true", required=True,
                        help="Temporarily remove the live endpoint to verify recovery")
    parser.parse_args()
    path = Path(f"/tmp/bobko.aerospace-{getpass.getuser()}.sock")
    server_pid = subprocess.check_output(["pgrep", "-x", "AeroSpace"], text=True).strip()
    if not server_pid or "\n" in server_pid:
        raise RuntimeError("Expected exactly one running AeroSpace")
    with connect(path) as held:
        before = membership(held)
        focused = command(held, "list-workspaces", "--focused")
        for round_number in range(1, 4):
            path.unlink()
            deadline = time.monotonic() + 5
            while True:
                try:
                    fresh = connect(path)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("AeroSpace did not restore its socket")
                    time.sleep(0.05)
            with fresh:
                assert membership(fresh) == before, "Workspace membership changed"
                assert command(fresh, "list-workspaces", "--focused") == focused, "Focused workspace changed"
            assert membership(held) == before, "Existing connection or desktop state was lost"
            assert subprocess.check_output(["pgrep", "-x", "AeroSpace"], text=True).strip() == server_pid, "Server restarted"
            print(f"PASS unlink/reconnect {round_number}: same PID, existing connection and workspaces preserved")


if __name__ == "__main__":
    main()

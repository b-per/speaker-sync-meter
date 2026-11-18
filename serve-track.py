#!/usr/bin/env python3
"""Serve the calibration WAV to Music Assistant on the local network."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
from pathlib import Path
import re
import subprocess
import time

TRACK = Path(__file__).resolve().parent / "build" / "Speaker Sync Calibration.wav"
TRACK_URL = "/speaker-sync.wav"
BYTE_RANGE = re.compile(r"bytes=(\d*)-(\d*)")


class TrackHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_track(include_body=True)

    def do_HEAD(self):
        self.send_track(include_body=False)

    def send_track(self, include_body):
        if self.path != TRACK_URL:
            self.send_error(404)
            return

        try:
            source = TRACK.open("rb")
        except OSError:
            self.send_error(503, "Calibration track could not be opened")
            return

        with source:
            length = source.seek(0, 2)
            start, end = 0, length - 1
            requested = self.headers.get("Range")
            if requested:
                match = BYTE_RANGE.fullmatch(requested)
                if match and any(match.groups()):
                    first, last = match.groups()
                    if first:
                        start = int(first)
                        end = min(end, int(last)) if last else end
                    else:
                        start = max(0, length - int(last))
                if not match or not any(match.groups()) or not 0 <= start <= end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{length}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return

            count = end - start + 1
            self.send_response(206 if requested else 200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(count))
            self.send_header("Accept-Ranges", "bytes")
            if requested:
                self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
            self.end_headers()

            if include_body:
                source.seek(start)
                try:
                    while count:
                        data = source.read(min(count, 65536))
                        if not data:
                            break
                        self.wfile.write(data)
                        count -= len(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", help="Mac's local IPv4 address (defaults to Wi-Fi en0)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--minutes", type=int, default=60)
    args = parser.parse_args()
    if not TRACK.is_file():
        parser.error("Run ./build.sh to create the calibration WAV first.")
    try:
        host = args.host or subprocess.check_output(
            ["/usr/sbin/ipconfig", "getifaddr", "en0"], text=True
        ).strip()
        address = ipaddress.IPv4Address(host)
    except (ValueError, subprocess.CalledProcessError):
        parser.error("Use --host with this Mac's local IPv4 address.")
    if address not in ipaddress.IPv4Network("10.0.0.0/8") and address not in ipaddress.IPv4Network(
        "172.16.0.0/12"
    ) and address not in ipaddress.IPv4Network("192.168.0.0/16") and not address.is_loopback:
        parser.error("Use a local IPv4 address.")
    if args.minutes <= 0:
        parser.error("--minutes must be positive.")

    with ThreadingHTTPServer((host, args.port), TrackHandler) as server:
        server.timeout = 1
        deadline = time.monotonic() + args.minutes * 60
        print(f"http://{host}:{server.server_port}{TRACK_URL}", flush=True)
        print(f"Serving the track for {args.minutes} minutes. Press Ctrl-C to stop.", flush=True)
        try:
            while time.monotonic() < deadline:
                server.handle_request()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()

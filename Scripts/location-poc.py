#!/usr/bin/env python3
"""
Majoor 2.0 Phase 0 — location proof of concept (PRD §5.8, decision D10).

Question this answers: can an iPhone Shortcuts automation push your location
to a Mac without you tapping anything? Run this receiver on the Mac, build
the Shortcut below, walk out of the house, and look at the log.

Run:
    python3 Scripts/location-poc.py                # listens on port 8787, prints a token
    python3 Scripts/location-poc.py --token abc    # reuse a token across restarts

Shortcut (iPhone → Shortcuts → Automation → "+"):
  Trigger A: "Arrive" or "Leave" a location, "Run Immediately", notify off.
  Trigger B: "Time of Day" (any time) — a repeatable manual test.
  Actions:
    1. Get Current Location            (Shortcuts will ask for location permission once)
    2. Get Contents of URL
         URL:     http://<this Mac's Tailscale or LAN IP>:8787/location
         Method:  POST
         Headers: X-Majoor-Token = <token printed below>
         Body:    JSON
           event     = "arrive" / "leave" / "manual"   (type it per automation)
           latitude  = Latitude of Current Location
           longitude = Longitude of Current Location
           accuracy  = Horizontal Accuracy of Current Location
           place     = the place name you typed in the trigger (optional)

Pass criteria for D10: the row appears in ~/.majoor/location-poc.jsonl within
a minute of the trigger while the phone is locked in your pocket. If iOS asks
you to confirm each run, or nothing arrives while the phone is locked, the
Shortcuts path fails and OwnTracks is the fallback.

Security: this is a proof of concept. It binds to all interfaces so the phone
can reach it over Tailscale or Wi-Fi, accepts only POST /location with the
right token, keeps nothing but the JSON lines file, and should be stopped when
the test is over.
"""

import argparse
import json
import os
import secrets
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = os.path.expanduser("~/.majoor/location-poc.jsonl")
MAX_BODY = 4096


def main() -> None:
    parser = argparse.ArgumentParser(description="Receive location posts from an iPhone Shortcut.")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--token", default=None, help="shared secret the Shortcut sends in X-Majoor-Token")
    args = parser.parse_args()
    token = args.token or secrets.token_urlsafe(16)

    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/location":
                self.send_error(404)
                return
            if not secrets.compare_digest(self.headers.get("X-Majoor-Token", ""), token):
                self.send_error(403)
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                self.send_error(413 if length > MAX_BODY else 400)
                return
            try:
                payload = json.loads(self.rfile.read(length))
                record = {
                    "received_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "event": str(payload.get("event", "manual"))[:32],
                    "latitude": float(payload["latitude"]),
                    "longitude": float(payload["longitude"]),
                    "accuracy_m": float(payload.get("accuracy", -1)),
                    "place": str(payload.get("place", ""))[:64],
                    "from": self.client_address[0],
                }
            except (ValueError, KeyError, TypeError):
                self.send_error(400, "expected JSON with latitude and longitude")
                return
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
            print(f"✅ {record['received_at']} {record['event']:<7} {record['latitude']:.5f},{record['longitude']:.5f} ±{record['accuracy_m']:.0f}m {record['place']}", flush=True)
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *a):  # quiet the default access log
            return

    server = HTTPServer(("0.0.0.0", args.port), Handler)
    print(f"Majoor location PoC listening on port {args.port}")
    print(f"Token for the Shortcut's X-Majoor-Token header: {token}")
    print(f"Appending fixes to {LOG_PATH}. Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
        sys.exit(0)


if __name__ == "__main__":
    main()

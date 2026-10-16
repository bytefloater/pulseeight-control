#!/usr/bin/env python3
"""Stand-in for a Pulse-Eight NeoMatrix, for developing PulseEightKit and the app without hardware.

Serves every endpoint PulseEightKit uses, with in-memory state:

    GET  /System/Details, /system/features
    GET  /Port/List
    GET  /Port/Details/{Input|Output}/{bay}
    GET  /Port/Set/{input}/{output}
    GET  /Port/EDID/Set/{profile}/{bay}                (admin)
    POST /Account/Login                                {"Password": ...}
    POST /Port/SetName/{Input|Output}/{bay}/           {"Name": ...} (admin)
    POST /System/BacklightLED/{off|low|high}           (admin)
    POST /System/StatusLED/{On|Off}                    (admin)

Payload shapes are synthetic (built from the field names in pulse_eight_matrix_client), not real
device captures. Stdlib only.

    python3 tools/fake_matrix.py --port 8080 --password secret
    p8ctl --host 127.0.0.1 --port 8080 ports
"""
import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BAYS = 8  # overridden by --bays
LATENCY = 0.0  # seconds added to every request, set by --latency
NAME_MAX = 13  # matches the device's own rename field


class Matrix:
    def __init__(self, password):
        self.lock = threading.Lock()
        self.password = password
        # The real device issues no session cookie, so "logged in" is just the last login result.
        self.logged_in = False
        self.backlight = "High"
        self.status_led = "On"
        self.inputs = [
            {"name": f"Input {i + 1}", "status": 0 if i % 3 != 2 else 3, "edid": 0} for i in range(BAYS)
        ]
        self.inputs[0]["name"] = "Sky"
        self.inputs[1]["name"] = "Apple TV"
        self.outputs = [
            {"name": f"Output {i + 1}", "status": 0, "source": i % BAYS, "fw": "1.0.0", "fw_available": i == 2}
            for i in range(BAYS)
        ]
        self.outputs[0]["name"] = "Lounge TV"
        self.outputs[1]["name"] = "Bedroom TV"

    # Each method returns a JSON-serialisable dict, or None for "unknown path".

    def details(self):
        return {
            "Result": True, "Model": "NeoMatrix (fake)", "Version": "1.2.3", "Serial": "FAKE0001",
            "MAC": "00:11:22:33:44:55", "VID": "1234", "BoardRev": 2,
            "Revision": {"Main": 1, "Top": 2, "Ir": 3}, "Locale": "en-GB",
            "StatusMessage": "OK", "Status": 0,
        }

    def features(self):
        return {
            "Result": True, "UpdInterval": 5, "CEC": 1, "CEC_Switching": False, "CEC_Logging": 0,
            "CEC_Usage": 1, "PDU": False, "Sky": True, "HDBaseT": True, "HdbtUpgrade": True,
            "MxRemote": False,
            "Video": {"Scrambling": True, "Input": {"Bays": BAYS}, "Output": {"Bays": BAYS}},
            "Audio": {"Routing": True, "Input": {"Bays": BAYS}, "Output": {"Bays": BAYS}},
            "BacklightLED": self.backlight, "StatusLED": self.status_led,
        }

    def port_list(self):
        ports = [
            {"Bay": i, "Mode": "Input", "Type": "HDMI IN", "Status": p["status"], "Name": p["name"]}
            for i, p in enumerate(self.inputs)
        ]
        ports += [
            {"Bay": i, "Mode": "Output", "Type": "HDBT OUT", "Status": p["status"], "Name": p["name"],
             "ReceiveFrom": p["source"]}
            for i, p in enumerate(self.outputs)
        ]
        return {"Result": True, "Ports": ports}

    def port_details(self, mode, bay):
        if mode == "Input":
            p = self.inputs[bay]
            return {
                "Result": True, "Bay": bay, "Mode": "Input", "Type": "HDMI IN", "Status": p["status"],
                "Name": p["name"], "StatusMessage": "OK" if p["status"] == 0 else "No HDMI Signal",
                "HPD": 1, "HasSignal": p["status"] == 0,
                "VideoSignal": "3840x2160@60" if p["status"] == 0 else "", "Signal": "HDMI",
                "HDCP": 1, "EdidProfile": p["edid"],
            }
        p = self.outputs[bay]
        return {
            "Result": True, "Bay": bay, "Mode": "Output", "Type": "HDBT OUT", "Status": p["status"],
            "Name": p["name"], "StatusMessage": "OK", "ReceiveFrom": p["source"], "POE": True,
            "FirmwareVersion": p["fw"], "FirmwareVersionAvailable": p["fw_available"],
            "OverrideEDID": {"Address": "0x50", "Setting": 3},
        }

    def set_route(self, inp, out):
        if not (0 <= inp < BAYS and 0 <= out < BAYS):
            return {"Result": False, "Message": "Invalid port"}
        self.outputs[out]["source"] = inp
        return {"Result": True, "Message": "Changed"}

    def login(self, body):
        if self.password is None or body.get("Password") == self.password:
            self.logged_in = True
            return {"Result": True}
        self.logged_in = False
        return {"Result": False, "Message": "Incorrect password"}

    def require_admin(self):
        if self.password is not None and not self.logged_in:
            return {"Result": False, "Message": "Login required"}
        return None


def route(matrix, method, path, body):
    """Dispatch one request. Returns a dict to send as JSON, or None for 404."""
    p = path.lower().rstrip("/")
    with matrix.lock:
        if method == "GET":
            if p == "/system/details":
                return matrix.details()
            if p == "/system/features":
                return matrix.features()
            if p == "/port/list":
                return matrix.port_list()
            if m := re.fullmatch(r"/port/details/(input|output)/(\d+)", p):
                bay = int(m.group(2))
                if bay >= BAYS:
                    return {"Result": False, "Message": "No such port"}
                return matrix.port_details(m.group(1).capitalize(), bay)
            if m := re.fullmatch(r"/port/set/(\d+)/(\d+)", p):
                return matrix.set_route(int(m.group(1)), int(m.group(2)))
            if m := re.fullmatch(r"/port/edid/set/(\d+)/(\d+)", p):
                if denied := matrix.require_admin():
                    return denied
                profile, bay = int(m.group(1)), int(m.group(2))
                if bay >= BAYS:
                    return {"Result": False, "Message": "No such port"}
                matrix.inputs[bay]["edid"] = profile
                return {"Result": True}
        elif method == "POST":
            if p == "/account/login":
                return matrix.login(body)
            if m := re.fullmatch(r"/port/setname/(input|output)/(\d+)", p):
                if denied := matrix.require_admin():
                    return denied
                bay = int(m.group(2))
                name = body.get("Name", "")
                if bay >= BAYS or len(name) > NAME_MAX:
                    return {"Result": False, "Message": "Invalid name or port"}
                (matrix.inputs if m.group(1) == "input" else matrix.outputs)[bay]["name"] = name
                return {"Result": True}
            if m := re.fullmatch(r"/system/backlightled/(off|low|high)", p):
                if denied := matrix.require_admin():
                    return denied
                matrix.backlight = m.group(1).capitalize()
                return {"Result": True}
            if m := re.fullmatch(r"/system/statusled/(on|off)", p):
                if denied := matrix.require_admin():
                    return denied
                matrix.status_led = m.group(1).capitalize()
                return {"Result": True}
    return None


def make_handler(matrix, quiet):
    class Handler(BaseHTTPRequestHandler):
        def _handle(self, method):
            body = {}
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                try:
                    body = json.loads(self.rfile.read(length))
                except ValueError:
                    body = {}
            if LATENCY:
                time.sleep(LATENCY)
            path = self.path.split("?", 1)[0]
            result = route(matrix, method, path, body)
            if result is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            payload = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

        def log_message(self, fmt, *args):
            if not quiet:
                super().log_message(fmt, *args)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--password", default=None, help="admin password; omit to allow admin calls without login")
    parser.add_argument("--bays", type=int, default=8, help="inputs and outputs per side (8 or 16 on real hardware)")
    parser.add_argument("--latency", type=float, default=0.0, help="seconds to delay every reply, to see pending states")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    global BAYS, LATENCY
    BAYS = args.bays
    LATENCY = args.latency

    server = ThreadingHTTPServer((args.host, args.port), make_handler(Matrix(args.password), args.quiet))
    print(f"Fake NeoMatrix on http://{args.host}:{args.port} "
          f"(admin password: {args.password if args.password is not None else 'none'})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

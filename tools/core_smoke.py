#!/usr/bin/env python3
"""End-to-end check of the C interface (libpulseeight_core) from outside Swift, the way the
Windows app uses it: ctypes here, P/Invoke there. Needs a fake matrix running.

    python3 tools/fake_matrix.py --port 8089 --password secret &
    swift build --package-path swift
    python3 tools/core_smoke.py swift/.build/debug/libpulseeight_core.dylib 8089 secret
"""
import ctypes
import json
import os
import sys
import tempfile
import time

lib_path, port, password = sys.argv[1], sys.argv[2], sys.argv[3]
os.environ["P8_CONFIG_DIR"] = tempfile.mkdtemp(prefix="p8core-")
os.environ["P8_SECRET_STORE"] = "file"

lib = ctypes.CDLL(lib_path)
lib.p8_abi_version.restype = ctypes.c_int32
lib.p8_create.restype = ctypes.c_void_p
lib.p8_destroy.argtypes = [ctypes.c_void_p]
lib.p8_snapshot.argtypes = [ctypes.c_void_p]
lib.p8_snapshot.restype = ctypes.c_void_p
lib.p8_call.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.p8_call.restype = ctypes.c_void_p
lib.p8_free_string.argtypes = [ctypes.c_void_p]
OBSERVER = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)
lib.p8_set_observer.argtypes = [ctypes.c_void_p, OBSERVER, ctypes.c_void_p]

def take(pointer):
    text = ctypes.string_at(pointer).decode()
    lib.p8_free_string(pointer)
    return text

def snapshot(h):
    return json.loads(take(lib.p8_snapshot(h)))

def call(h, **request):
    return json.loads(take(lib.p8_call(h, json.dumps(request).encode())))

def wait_for(h, predicate, what, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        s = snapshot(h)
        if predicate(s):
            return s
        time.sleep(0.1)
    raise SystemExit(f"FAIL: timed out waiting for {what}: {json.dumps(snapshot(h))[:400]}")

def check(condition, what):
    print(("ok   " if condition else "FAIL ") + what)
    if not condition:
        raise SystemExit(1)

print("ABI version", lib.p8_abi_version())
h = lib.p8_create()
updates = []
callback = OBSERVER(lambda ctx, text: updates.append(json.loads(text.decode())["phase"]))
lib.p8_set_observer(h, callback, None)

s = snapshot(h)
check(s["schema"] == 1 and s["phase"] == "notConfigured", "starts unconfigured")
check(call(h, cmd="saveSettings", host="", port="80")["ok"] is False, "empty host rejected")
check("1 to 65535" in call(h, cmd="saveSettings", host="127.0.0.1", port="99999")["error"], "bad port rejected with message")
check(call(h, cmd="saveSettings", host="127.0.0.1", port=port, timeout="3", pollInterval="2", detailPollInterval="5", adminPassword=password)["ok"], "saveSettings accepted")

s = wait_for(h, lambda s: s["phase"] == "connected", "connected")
check(len(s["inputs"]) == 8 and len(s["outputs"]) == 8, "8 inputs and 8 outputs")
check(s["adminConfigured"] and s["settings"]["port"] == int(port), "admin and settings reflected")
check(s["inputs"][0]["name"] == "Sky" and s["outputs"][0]["sourceName"] == "Sky", "names and routed source")
s = wait_for(h, lambda s: len(s["systemRows"]) > 0 and s["outputs"][2]["details"], "system and port details")
check(any(r["label"] == "Model" for r in s["systemRows"]), "system rows present")
check(any(u["name"] == "Output 3" for u in s["updates"]), "firmware update listed")
check(len(s["edidProfiles"]) >= 8, "EDID profiles listed")

check(call(h, cmd="route", input=4, output=0)["ok"], "route command")
wait_for(h, lambda s: s["outputs"][0]["receiveFrom"] == 4, "route reflected")
check(call(h, cmd="renamePort", mode="Input", bay=0, name="Cable Box")["ok"], "rename (admin login path)")
wait_for(h, lambda s: s["inputs"][0]["name"] == "Cable Box", "rename reflected")
r = call(h, cmd="renamePort", mode="Input", bay=0, name="This name is far too long")
check(not r["ok"] and "13" in r["error"], "over-long name rejected")
check(call(h, cmd="validatePortName", name="  Hi  ")["value"] == "Hi", "validatePortName trims")
check(call(h, cmd="setBacklight", level="off")["ok"], "backlight command")
wait_for(h, lambda s: s["frontPanel"]["backlight"] == "off", "backlight reflected")
check(call(h, cmd="setStatusLed", on=False)["ok"], "status LED command")
wait_for(h, lambda s: s["frontPanel"]["statusLed"] is False, "status LED reflected")
check(call(h, cmd="setHighlightGrid", on=False)["ok"], "view preference command")
check(snapshot(h)["settings"]["highlightGrid"] is False, "view preference reflected")
check(call(h, cmd="nonsense")["ok"] is False, "unknown command rejected")
check(call(h, cmd="removeAdminPassword")["ok"], "remove admin password")
wait_for(h, lambda s: s["adminConfigured"] is False, "admin removed")

check("connected" in updates, f"observer callback fired ({len(updates)} updates)")
lib.p8_destroy(h)
print("ALL OK")

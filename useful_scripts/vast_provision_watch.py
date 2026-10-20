#!/usr/bin/env python3
"""Watch a Vast.ai SD-Forge instance provision; relaunch on a new host if it is defective.

Reads provisioning output through `vastai logs` (the Vast base image streams
/var/log/portal/provisioning.log to container stdout), so no SSH is needed.

Classification per poll:
  COMPLETE  "Provisioning complete" seen -> verify downloads vs config YAML, exit 0
  STALL     provisioning lines unchanged for --stall-secs while not complete
  DEFECT    instance exited/errored, or stuck in `loading` > --boot-timeout
  TOKEN     INVALID ... TOKEN banner -> exit 3 (relaunching cannot fix this)
  URL-FAIL  a `Downloading:` block ended with curl error / tiny body / git fatal
            -> recorded, reported at the end; NOT a relaunch trigger

STALL and DEFECT: destroy -y, blacklist that machine_id, create a new instance
from the same template on the best remaining offer, continue. Max --max-relaunch.

State is written to --state-file as JSON after every poll so another process
(or a chat monitor) can read progress without parsing logs.

Usage:
  vast_provision_watch.py --instance 56867543 --template d896889f...
  vast_provision_watch.py --template d896889f...        # launches first
"""
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
NOISE = re.compile(r"^\[https?://localhost:\d+\]|cloudflared|trycloudflare|quic-go|receive buffer")
PROV_MARK = re.compile(
    r"Downloading( extension)?: |Downloading \d+ model|token valid|INVALID .* TOKEN|"
    r"Switching Forge|Provisioning complete|Cloning into|fatal:|curl: \(|error: pathspec|"
    r"^\s*100\s+[\d.]+[kMG]?\s+100|Installing File Browser|password is too short"
)
OFFER_QUERY = ("gpu_name=RTX_4090 rentable=true inet_down>2000 inet_up>2000 "
               "disk_space>100 dph<0.6 reliability>0.98")


def sh(args, timeout=120):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def vast_json(*args):
    rc, out, err = sh(["vastai", *args, "--raw"])
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def instance_state(iid):
    d = vast_json("show", "instance", str(iid))
    if isinstance(d, list):
        d = d[0] if d else {}
    return d or {}


def fetch_logs(iid, tail=6000):
    rc, out, err = sh(["vastai", "logs", str(iid), "--tail", str(tail)], timeout=180)
    text = ANSI.sub("", out + err).replace("\r", "\n")
    keep = []
    for line in text.splitlines():
        if NOISE.search(line):
            continue
        keep.append(line.rstrip())
    return keep


def prov_lines(lines):
    return [l for l in lines if PROV_MARK.search(l)]


def expected_items(cfg_url):
    """Count download/clone items the script will attempt (sections the generator handles)."""
    handled = {"extensions", "models", "loras", "esrgan", "vae", "unet", "controlnet", "adetailer"}
    try:
        with urllib.request.urlopen(cfg_url, timeout=30) as r:
            body = r.read().decode()
    except Exception:
        return None
    sec, items = "", {}
    for line in body.splitlines():
        m = re.match(r"^([A-Za-z0-9_]+):\s*$", line)
        if m:
            sec = m.group(1)
            continue
        m = re.match(r"^\s*-\s*(\S+)", line)
        if m and sec in handled:
            items.setdefault(sec, []).append(m.group(1))
    return items


def analyse_downloads(lines):
    """Walk `Downloading: <url>` blocks; a block succeeds if a `100 <size M/G>` line follows
    before the next block, fails on curl error / only tiny bodies (Civitai error JSON)."""
    results, cur, big = {}, None, False
    ext_ok, ext_fail = set(), set()
    for i, l in enumerate(lines):
        m = re.match(r"Downloading: (\S+)", l)
        if m:
            if cur:
                results[cur] = big
            cur, big = m.group(1), False
            continue
        m = re.match(r"Downloading extension: (\S+?)\.{3}", l)
        if m:
            if cur:
                results[cur] = big
                cur = None
            repo = m.group(1)
            nxt = " ".join(lines[i + 1:i + 6])
            (ext_fail if "fatal:" in nxt else ext_ok).add(repo)
            continue
        if cur:
            if re.match(r"\s*100\s+[\d.]+[MG]\s+100", l):
                big = True
            if l.startswith("curl: ("):
                big = False
                results[cur] = False
                cur = None
    if cur:
        results[cur] = big
    return results, ext_ok, ext_fail


def best_offer(blacklist):
    offers = vast_json("search", "offers", OFFER_QUERY) or []
    offers = [o for o in offers if o.get("machine_id") not in blacklist]
    if not offers:
        return None
    offers.sort(key=lambda o: -min(o.get("inet_down", 0), o.get("inet_up", 0)))
    return offers[0]


def launch(template, disk, blacklist, log):
    for attempt in range(3):
        o = best_offer(blacklist)
        if not o:
            log("no offer matches the query")
            return None
        log("launching offer %s  $%.3f/h  down=%.0f up=%.0f  %s  machine=%s" % (
            o["id"], o.get("dph_total", 0), o.get("inet_down", 0), o.get("inet_up", 0),
            o.get("geolocation", "?"), o.get("machine_id")))
        d = vast_json("create", "instance", str(o["id"]), "--template_hash", template,
                      "--disk", str(disk))
        if d and d.get("success"):
            return int(d["new_contract"])
        log("create failed: %s (offer probably taken) - retrying" % (d,))
        blacklist.add(o.get("machine_id"))
        time.sleep(5)
    return None


def destroy(iid, log):
    rc, out, err = sh(["vastai", "destroy", "instance", str(iid), "-y"])
    log("destroyed %s: %s%s" % (iid, out.strip(), err.strip()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--instance", type=int)
    ap.add_argument("--template", required=True)
    ap.add_argument("--disk", type=int, default=80)
    ap.add_argument("--poll", type=int, default=30)
    ap.add_argument("--stall-secs", type=int, default=240)
    ap.add_argument("--boot-timeout", type=int, default=900)
    ap.add_argument("--max-relaunch", type=int, default=3)
    ap.add_argument("--config-url", default="https://gist.githubusercontent.com/LYTzeng/"
                    "05d650a1c7d20a22d9c1dab12963d4d3/raw/forge_sync_config.yaml")
    ap.add_argument("--state-file", default="/tmp/vast_watch_state.json")
    a = ap.parse_args()

    state = {"instance": a.instance, "phase": "init", "relaunches": 0, "blacklist": [],
             "events": [], "last_lines": []}

    def log(msg):
        line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
        print(line, flush=True)
        state["events"].append(line)
        state["events"] = state["events"][-60:]

    def save():
        with open(a.state_file, "w") as f:
            json.dump(state, f, indent=1)

    blacklist = set()
    iid = a.instance
    if not iid:
        iid = launch(a.template, a.disk, blacklist, log)
        if not iid:
            state["phase"] = "launch-failed"; save(); return 2
    state["instance"] = iid

    expected = expected_items(a.config_url)
    exp_total = sum(len(v) for v in (expected or {}).values())
    log("watching instance %s (expected %s items from config)" % (iid, exp_total or "?"))

    last_fp, last_change, boot_start = None, time.time(), time.time()
    while True:
        st = instance_state(iid)
        actual = st.get("actual_status")
        msg = (st.get("status_msg") or "").strip()
        state.update({"instance": iid, "actual_status": actual, "status_msg": msg[:160],
                      "machine_id": st.get("machine_id"),
                      "ssh": "ssh -p %s root@%s" % (st.get("ssh_port"), st.get("ssh_host"))})

        defect = None
        if actual in ("exited", "error") or "error" in msg.lower() and actual != "running":
            defect = "instance %s: %s" % (actual, msg[:100])
        elif actual != "running" and time.time() - boot_start > a.boot_timeout:
            defect = "still '%s' after %ds" % (actual, a.boot_timeout)

        plines = []
        if actual == "running":
            lines = fetch_logs(iid)
            plines = prov_lines(lines)
            state["last_lines"] = plines[-12:]
            text = "\n".join(plines)

            if re.search(r"INVALID .* TOKEN", text):
                state["phase"] = "token-invalid"; log("token banner seen - fix template, not host"); save()
                return 3

            if "Provisioning complete" in text:
                results, ext_ok, ext_fail = analyse_downloads(lines)
                failed = sorted(u for u, ok in results.items() if not ok)
                state.update({"phase": "complete", "downloads_ok": sum(results.values()),
                              "downloads_failed": failed, "extensions_ok": len(ext_ok),
                              "extensions_failed": sorted(ext_fail),
                              "filebrowser_error": "password is too short" in text,
                              "expected_items": exp_total})
                log("COMPLETE: %d/%d downloads ok, %d failed; extensions %d ok, %d failed" % (
                    sum(results.values()), len(results), len(failed), len(ext_ok), len(ext_fail)))
                for u in failed:
                    log("  FAILED download: " + u)
                for r in sorted(ext_fail):
                    log("  FAILED extension: " + r)
                if state["filebrowser_error"]:
                    log("  File Browser user creation failed (password too short) - script bug")
                save()
                return 0 if not failed and not ext_fail else 1

            fp = hash(text)
            if fp != last_fp:
                last_fp, last_change = fp, time.time()
                state["phase"] = "provisioning"
            elif time.time() - last_change > a.stall_secs:
                defect = "no provisioning progress for %ds (last: %s)" % (
                    a.stall_secs, plines[-1][:80] if plines else "-")
        else:
            state["phase"] = "booting"

        if defect:
            log("DEFECT on %s (machine %s): %s" % (iid, st.get("machine_id"), defect))
            if state["relaunches"] >= a.max_relaunch:
                state["phase"] = "gave-up"; log("relaunch cap reached"); save()
                destroy(iid, log)
                return 4
            blacklist.add(st.get("machine_id"))
            state["blacklist"] = sorted(x for x in blacklist if x is not None)
            destroy(iid, log)
            state["relaunches"] += 1
            iid = launch(a.template, a.disk, blacklist, log)
            if not iid:
                state["phase"] = "launch-failed"; save(); return 2
            last_fp, last_change, boot_start = None, time.time(), time.time()
            log("relaunched as %s (relaunch %d/%d)" % (iid, state["relaunches"], a.max_relaunch))

        save()
        time.sleep(a.poll)


if __name__ == "__main__":
    sys.exit(main())

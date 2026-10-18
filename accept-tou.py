#!/usr/bin/env python3
"""
Accept LibreLinkUp's updated Terms of Use for the follower account.

Abbott periodically forces re-acceptance of Terms of Use. Until it's done, the
API login returns status 4 with a 'tou' step and no user id, so the poller
can't fetch - the feed goes dark. This clears it.

IMPORTANT: this accepts Terms of Use on a medical account. Read the new terms
in the LibreLinkUp app first (you'll be prompted there too). This script is the
convenience to clear the block once you know what you're agreeing to - not a
way to blind-accept on a schedule.

    ./accept-tou.py            # accept, if a TOU step is pending
    ./accept-tou.py --check    # just report whether one is pending, change nothing

Reads LINK_UP_* from .env alongside it.
"""
import json, sys, urllib.request, urllib.error
from pathlib import Path

HERE = Path(__file__).resolve().parent

def load_env():
    env = {}
    for line in (HERE / ".env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def main():
    check_only = "--check" in sys.argv
    env = load_env()
    region = (env.get("LINK_UP_REGION") or "EU").lower()
    host = f"api-{region}.libreview.io"
    H = {"product": "llu.android",
         "version": env.get("LINK_UP_VERSION") or "4.16.0",
         "Content-Type": "application/json", "Accept": "application/json",
         "User-Agent": "Mozilla/5.0"}

    def req(path, data, headers):
        r = urllib.request.Request("https://" + host + path,
                                   data=data, headers=headers, method="POST")
        with urllib.request.urlopen(r, timeout=25) as resp:
            return json.load(resp)

    body = json.dumps({"email": env["LINK_UP_USERNAME"],
                       "password": env["LINK_UP_PASSWORD"]}).encode()
    d = req("/llu/auth/login", body, H)
    status = d.get("status")
    data = d.get("data", {})
    step = data.get("step")

    if status == 0 and data.get("user", {}).get("id"):
        print("No Terms of Use step pending - login is already clean.")
        return
    if not (step and step.get("type") == "tou"):
        print(f"Unexpected login state (status {status}). Not a TOU step - "
              f"not touching it. Check the LibreLinkUp app.")
        sys.exit(1)

    print("LibreLinkUp is requiring Terms of Use re-acceptance.")
    if check_only:
        print("(--check) A TOU acceptance IS pending. Re-run without --check "
              "to accept, after reading the terms in the app.")
        sys.exit(2)

    tok = data["authTicket"]["token"]
    H2 = dict(H); H2["Authorization"] = "Bearer " + tok
    d2 = req("/auth/continue/tou", b"{}", H2)
    if d2.get("status") == 0 and d2.get("data", {}).get("user", {}).get("id"):
        print("Accepted. Login is clean now.")
        print("Restart the poller:  sudo systemctl restart libre-poll")
    else:
        print(f"Acceptance did not clear it (status {d2.get('status')}). "
              f"Accept in the LibreLinkUp app instead.")
        sys.exit(1)

if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:200]}")
    except Exception as e:
        sys.exit(f"error: {e}")

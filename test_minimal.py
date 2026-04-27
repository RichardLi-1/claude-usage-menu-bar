import sys, traceback, os

LOG = "/tmp/claude-menu-test.log"

def log(msg):
    with open(LOG, "a") as f:
        f.write(msg + "\n")
    print(msg, flush=True)

log(f"started, pid={os.getpid()}, python={sys.executable}")

try:
    import rumps
    log("rumps imported OK")
except Exception:
    log("FAILED to import rumps:\n" + traceback.format_exc())
    sys.exit(1)

try:
    app = rumps.App("$0.00")
    log("app created OK")
    log("calling app.run() ...")
    app.run()
    log("app.run() returned")
except Exception:
    log("EXCEPTION in app.run():\n" + traceback.format_exc())
    sys.exit(1)

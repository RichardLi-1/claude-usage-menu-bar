"""Minimal menu bar item using raw PyObjC — no rumps."""
import sys, os

LOG = "/tmp/claude-raw-test.log"
def log(m):
    with open(LOG, "a") as f: f.write(m + "\n")
    print(m, flush=True)

log(f"pid={os.getpid()}")

from AppKit import (
    NSApplication, NSStatusBar, NSVariableStatusItemLength,
    NSMenu, NSMenuItem,
)
from PyObjCTools import AppHelper

log("imports OK")

app = NSApplication.sharedApplication()
app.setActivationPolicy_(1)   # NSApplicationActivationPolicyAccessory (no Dock icon)
log(f"activation policy set: {app.activationPolicy()}")

bar   = NSStatusBar.systemStatusBar()
item  = bar.statusItemWithLength_(NSVariableStatusItemLength)
item.setTitle_("$0.00")
item.setHighlightMode_(True)
log(f"status item created: {item}")

menu = NSMenu.alloc().init()
menu.addItem_(NSMenuItem.alloc().initWithTitle_action_keyEquivalent_("Quit", "terminate:", "q"))
item.setMenu_(menu)
log("menu attached — running event loop")

AppHelper.runEventLoop()
log("event loop exited")

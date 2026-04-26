#!/usr/bin/env python3
"""Claude Code usage macOS menu bar app."""
import threading

import rumps

from usage_parser import PeriodStats, UsageSummary, fmt_cost, fmt_tokens, load_usage

REFRESH_INTERVAL = 300  # seconds


def _period_line(label: str, stats: PeriodStats) -> str:
    return f"{label:<12} {fmt_cost(stats.cost):>7}   {fmt_tokens(stats.total_tokens):>6} tok"


class ClaudeUsageApp(rumps.App):
    def __init__(self):
        super().__init__("claude", quit_button=None)

        # --- fixed menu items ---
        self._today_item = rumps.MenuItem("Today: loading…")
        self._week_item = rumps.MenuItem("Week:  loading…")
        self._month_item = rumps.MenuItem("Month: loading…")

        self._sep1 = rumps.MenuItem("─" * 32)  # visual separator (disabled)

        self._detail_input = rumps.MenuItem("  Input:       …")
        self._detail_output = rumps.MenuItem("  Output:      …")
        self._detail_cr = rumps.MenuItem("  Cache read:  …")
        self._detail_cw = rumps.MenuItem("  Cache write: …")

        self._sep2 = rumps.MenuItem("─" * 32)

        self._models_item = rumps.MenuItem("By model (month)")

        self._sep3 = rumps.MenuItem("─" * 32)

        self._updated_item = rumps.MenuItem("Updated: —")
        self._refresh_item = rumps.MenuItem("Refresh now", callback=self._on_refresh)
        self._quit_item = rumps.MenuItem("Quit", callback=rumps.quit_application)

        self.menu = [
            self._today_item,
            self._week_item,
            self._month_item,
            self._sep1,
            "Detail (month)",
            self._detail_input,
            self._detail_output,
            self._detail_cr,
            self._detail_cw,
            self._sep2,
            self._models_item,
            self._sep3,
            self._updated_item,
            self._refresh_item,
            None,
            self._quit_item,
        ]

        # Disable purely decorative items
        for item in (self._sep1, self._sep2, self._sep3):
            item.set_callback(None)

        # Initial load + periodic refresh
        self._fetch_in_bg()
        self._timer = rumps.Timer(lambda _: self._fetch_in_bg(), REFRESH_INTERVAL)
        self._timer.start()

    # ------------------------------------------------------------------
    def _on_refresh(self, _sender):
        self._refresh_item.title = "Refreshing…"
        self._fetch_in_bg()

    def _fetch_in_bg(self):
        threading.Thread(target=self._load_and_update, daemon=True).start()

    def _load_and_update(self):
        summary = load_usage()
        # Schedule UI update on main thread via a one-shot 0s timer
        rumps.Timer(lambda _: self._apply(summary), 0).start()

    # ------------------------------------------------------------------
    def _apply(self, s: UsageSummary):
        # Menu bar title: today's cost
        self.title = fmt_cost(s.today.cost)

        self._today_item.title = _period_line("Today", s.today)
        self._week_item.title = _period_line("This week", s.week)
        self._month_item.title = _period_line("This month", s.month)

        m = s.month
        self._detail_input.title = f"  Input:       {fmt_tokens(m.input_tokens)}"
        self._detail_output.title = f"  Output:      {fmt_tokens(m.output_tokens)}"
        self._detail_cr.title = f"  Cache read:  {fmt_tokens(m.cache_read_tokens)}"
        self._detail_cw.title = f"  Cache write: {fmt_tokens(m.cache_write_tokens)}"

        # Rebuild model submenu
        self._models_item.clear()
        models_sorted = sorted(
            m.by_model.items(), key=lambda kv: kv[1]["cost"], reverse=True
        )
        if models_sorted:
            for model, stats in models_sorted[:6]:
                short = model.replace("claude-", "")
                label = f"  {short:<26} {fmt_cost(stats['cost']):>7}"
                self._models_item.add(rumps.MenuItem(label))
        else:
            self._models_item.add(rumps.MenuItem("  (no data)"))

        self._updated_item.title = f"Updated: {s.refreshed_at.strftime('%H:%M:%S')}"
        self._refresh_item.title = "Refresh now"


if __name__ == "__main__":
    ClaudeUsageApp().run()

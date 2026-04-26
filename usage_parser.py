"""Parse Claude Code JSONL session files to aggregate token usage and cost."""
import glob
import json
import os
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

# $/MTok: (input, output, cache_write, cache_read)
_PRICING: dict[str, tuple[float, float, float, float]] = {
    "claude-opus": (15.0, 75.0, 18.75, 1.5),
    "claude-sonnet": (3.0, 15.0, 3.75, 0.3),
    "claude-haiku": (0.8, 4.0, 1.0, 0.08),
}


def _get_pricing(model: str) -> tuple[float, float, float, float]:
    m = (model or "").lower()
    for key, prices in _PRICING.items():
        if key in m:
            return prices
    return _PRICING["claude-sonnet"]


def _calc_cost(usage: dict, model: str) -> float:
    p = _get_pricing(model)
    return (
        usage.get("input_tokens", 0) * p[0]
        + usage.get("output_tokens", 0) * p[1]
        + usage.get("cache_creation_input_tokens", 0) * p[2]
        + usage.get("cache_read_input_tokens", 0) * p[3]
    ) / 1_000_000


@dataclass
class PeriodStats:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    cost: float = 0.0
    by_model: dict = field(default_factory=lambda: defaultdict(lambda: {"input": 0, "output": 0, "cost": 0.0}))

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens


@dataclass
class UsageSummary:
    today: PeriodStats
    week: PeriodStats
    month: PeriodStats
    refreshed_at: datetime


def load_usage() -> UsageSummary:
    today = date.today()
    week_start = today - timedelta(days=today.weekday())
    month_start = today.replace(day=1)

    day_stats = PeriodStats()
    week_stats = PeriodStats()
    month_stats = PeriodStats()
    seen_ids: set[str] = set()

    pattern = os.path.expanduser("~/.claude/projects/*/*.jsonl")
    for filepath in glob.glob(pattern):
        try:
            with open(filepath) as f:
                for line in f:
                    _process_line(line, today, week_start, month_start,
                                  day_stats, week_stats, month_stats, seen_ids)
        except OSError:
            continue

    return UsageSummary(
        today=day_stats,
        week=week_stats,
        month=month_stats,
        refreshed_at=datetime.now(),
    )


def _process_line(
    line: str,
    today: date,
    week_start: date,
    month_start: date,
    day_stats: PeriodStats,
    week_stats: PeriodStats,
    month_stats: PeriodStats,
    seen_ids: set[str],
) -> None:
    line = line.strip()
    if not line:
        return
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return

    if obj.get("type") != "assistant":
        return

    msg = obj.get("message", {})
    msg_id = msg.get("id")
    if msg_id:
        if msg_id in seen_ids:
            return
        seen_ids.add(msg_id)

    usage = msg.get("usage")
    if not usage:
        return

    ts = obj.get("timestamp", "")
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        entry_date = dt.date()
    except (ValueError, AttributeError):
        return

    model = msg.get("model", "")
    cost = _calc_cost(usage, model)
    inp = usage.get("input_tokens", 0)
    out = usage.get("output_tokens", 0)
    cw = usage.get("cache_creation_input_tokens", 0)
    cr = usage.get("cache_read_input_tokens", 0)

    for stats, since in [
        (day_stats, today),
        (week_stats, week_start),
        (month_stats, month_start),
    ]:
        if entry_date >= since:
            stats.input_tokens += inp
            stats.output_tokens += out
            stats.cache_write_tokens += cw
            stats.cache_read_tokens += cr
            stats.cost += cost
            m = stats.by_model[model or "unknown"]
            m["input"] += inp
            m["output"] += out
            m["cost"] += cost


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def fmt_cost(c: float) -> str:
    if c >= 10:
        return f"${c:.1f}"
    return f"${c:.2f}"

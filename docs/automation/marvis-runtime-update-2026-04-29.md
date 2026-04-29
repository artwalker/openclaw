---
summary: "Marvis VPS trading runtime update for Axiom and Polymarket"
read_when:
  - Resuming Axiom or Polymarket market-scan cron jobs
  - Auditing VPS trading skill hotfixes
  - Debugging Axiom market regime summaries
title: "Marvis Runtime Update 2026-04-29"
---

# Marvis runtime update - 2026-04-29

This note records the VPS trading-runtime state after the Axiom cleanup and manual market-scan debugging pass.

## Code management state

Axiom repository:

```text
/root/projects/axiom
branch: main
status: clean after commit
head: c546f0b5 chore: remove stale frontend artifacts
ahead: origin/main by 4 commits
```

The latest commit removed stale frontend build/deploy surfaces and tracked local runtime artifacts. It did not touch the Marvis execution path, Binance adapter, order sync, or risk logic.

Validation before the commit:

```bash
go test ./...
go build -o /tmp/axiom-cleanup-build
git diff --check
```

All passed.

## VPS cron state

The market-scan cron jobs are intentionally paused for manual debugging:

```text
11fdd602-f6be-4038-aa6b-a689eaf3a978 Axiom Market Scan       enabled=false
polymarket-market-scan                 Polymarket Market Scan enabled=false
```

Their session targets are preserved:

```text
Axiom:      session:axiom-trader
Polymarket: session:polymarket-trader
```

Other jobs, including Bird digests, memory promotion, and daily/weekly review jobs, were not disabled.

Use `ssh -4 vps` and `openclaw cron show <job-id> --json` to confirm before resuming.

## Manual Axiom debug result

Axiom service status:

```text
systemd unit: axiom
state: active/running
```

Helper checks:

```bash
cd /root/.openclaw/workspace/skills/axiom-trade
bash scripts/axiom.sh preflight
bash scripts/axiom.sh account
bash scripts/axiom.sh positions
bash scripts/axiom.sh market BTCUSDT
bash scripts/axiom.sh market ETHUSDT
bash scripts/axiom.sh screener 20
```

Observed state:

```text
preflight: ok
account: ok
positions: ok, empty
equity: about 69.52 USDT
BTC regime: MEAN_REVERSION
ETH regime: MEAN_REVERSION
```

No real order was submitted.

## Axiom skill hotfix

VPS files changed:

```text
/root/.openclaw/workspace/skills/axiom-trade/scripts/market-summary.mjs
/root/.openclaw/workspace/skills/axiom-trade/SKILL.md
```

Backups created before editing:

```text
/root/.openclaw/workspace/skills/axiom-trade/scripts/market-summary.mjs.bak-20260429-regime-align
/root/.openclaw/workspace/skills/axiom-trade/SKILL.md.bak-20260429-mixed-regime
```

Reason:

`market-summary.mjs` previously selected 4h as the reference timeframe when present, but the output reason said `4h/1h ADX > 20 and price above EMA50`. During manual debugging, ZBTUSDT and ZKJUSDT were reported as `TREND_UP` even though 1h price was below EMA50. That could encourage chase entries in a conflicted market.

Fix:

- When both 4h and 1h have ADX > 20, both frames must agree on price vs EMA50 to return `TREND_UP` or `TREND_DOWN`.
- If 4h and 1h disagree, return `MIXED`.
- `SKILL.md` now says `MIXED` is a no-chase warning and requires cleaner 5m/15m stabilization, a defined invalidation level, and higher confidence before any order.

Post-fix spot checks:

```text
ZBTUSDT: MIXED - 4h above EMA50, 1h below EMA50
ZKJUSDT: MIXED - 4h above EMA50, 1h below EMA50
DEXEUSDT: TREND_DOWN - 4h and 1h both below EMA50 with ADX > 20
BTCUSDT: MEAN_REVERSION
```

## Resume checklist

Before enabling market scans again:

1. Run Axiom helper checks again and confirm positions are still fresh.
2. Confirm `market-summary.mjs` still returns `MIXED` for conflicting 4h/1h trends.
3. Confirm Polymarket V2 helper still passes `preflight`, `balance`, `positions`, and `orders`.
4. Re-enable only the two market-scan jobs:

```bash
openclaw cron enable 11fdd602-f6be-4038-aa6b-a689eaf3a978
openclaw cron enable polymarket-market-scan
```

5. Verify list output:

```bash
openclaw cron show 11fdd602-f6be-4038-aa6b-a689eaf3a978 --json
openclaw cron show polymarket-market-scan --json
```

Expected after resume:

```text
Axiom Market Scan enabled=true, sessionTarget=session:axiom-trader
Polymarket Market Scan enabled=true, sessionTarget=session:polymarket-trader
```

Do not enable duplicate evening Polymarket scans.

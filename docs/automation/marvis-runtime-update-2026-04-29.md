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
status: clean after commits
head: 08d856c3 fix(api): classify risk-control trade blocks
ahead: origin/main by 6 commits
```

The latest commits removed stale frontend build/deploy surfaces, added `cmd/axiomctl`, and changed risk-control trade blocks from HTTP 500 runtime errors to structured HTTP 422 responses. They did not change Binance adapter, order sync, or order placement logic.

Validation before the commit:

```bash
go test ./...
go build -o /tmp/axiom-cleanup-build
git diff --check
```

All passed.

Additional validation for `cmd/axiomctl`:

```bash
go test ./cmd/axiomctl
go test ./cmd/axiomctl ./api/handlers ./trader
go build -o /tmp/axiomctl ./cmd/axiomctl
/tmp/axiomctl help
```

All passed.

## VPS cron state

The market-scan cron jobs were resumed after manual validation:

```text
11fdd602-f6be-4038-aa6b-a689eaf3a978 Axiom Market Scan       enabled=true
polymarket-market-scan                 Polymarket Market Scan enabled=true
```

Their session targets are preserved:

```text
Axiom:      session:axiom-trader
Polymarket: session:polymarket-trader
```

Delivery modes:

```text
Axiom:      announce -> telegram:8436785488; no-action runs are normalized to NO_REPLY and not delivered
Polymarket: none; the skill may call the message tool only for a real trade, material position risk, or operational blocker
```

Other jobs, including Bird digests, memory promotion, and daily/weekly review jobs, were not disabled.

Use `ssh -4 vps` and `openclaw cron show <job-id> --json` to confirm before editing.

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

Follow-up manual scan after prompt cleanup:

```text
model: xiaomi-coding/mimo-v2.5-pro
runtime summary: NO_REPLY
tool failures: 0
positions after scan: none
```

The first MiMo no-action retest wrote a skip summary plus `NO_REPLY`. The Axiom skill and cron prompt classify below-threshold candidates, watchlist-only decisions, normal market regime, healthy account state, and zero positions as no-action outcomes that must return exactly `NO_REPLY`. Because model adherence is not a sufficient runtime guarantee, OpenClaw cron delivery was also patched to normalize any final output containing the `NO_REPLY` sentinel into a fully silent result.

## OpenClaw cron silent-output fix

Local source changed:

```text
src/cron/isolated-agent/run.ts
src/cron/isolated-agent.skips-delivery-without-whatsapp-recipient-besteffortdeliver-true.e2e.test.ts
CHANGELOG.md
```

Behavior:

- If a cron final output contains `NO_REPLY`, the isolated-agent result now stores `summary=NO_REPLY` and `outputText=NO_REPLY`.
- Announce delivery is skipped for the normalized silent result.
- The regression test covers a final payload like `analysis + NO_REPLY + extra text` and asserts the stored result is exactly `NO_REPLY` with no delivery.

Local validation:

```bash
pnpm test src/cron/isolated-agent/run.skill-filter.test.ts
pnpm test:e2e src/cron/isolated-agent.skips-delivery-without-whatsapp-recipient-besteffortdeliver-true.e2e.test.ts
```

Both passed.

VPS package-installed OpenClaw hot patches:

```text
/usr/lib/node_modules/openclaw/dist/run-delivery.runtime-Bf3jOWmV.js
/usr/lib/node_modules/openclaw/dist/server.impl-CnVVyYzF.js
```

Backups:

```text
/usr/lib/node_modules/openclaw/dist/run-delivery.runtime-Bf3jOWmV.js.bak-mimo-no-reply-summary-20260429-083646
/usr/lib/node_modules/openclaw/dist/server.impl-CnVVyYzF.js.bak-cron-silent-summary-20260429-090754
```

VPS validation after restarting `marvis.service`:

```text
manual run 1777453801267: summary=NO_REPLY, delivered=false, deliveryStatus=not-requested, model=mimo-v2.5-pro
manual run 1777454333328: summary=NO_REPLY, delivered=false, deliveryStatus=not-requested, model=mimo-v2.5-pro
manual announce run 1777454729252: summary=NO_REPLY, delivered=false, deliveryStatus=not-delivered, model=mimo-v2.5-pro
scheduled announce run 1777455000017: summary=NO_REPLY, delivered=false, deliveryStatus=not-delivered, model=mimo-v2.5-pro
```

The model still may write internal analysis plus `NO_REPLY` into the persistent session transcript. The runtime-visible cron result and Telegram delivery path are the source of truth for user notification behavior.

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

## Axiomctl VPS adoption

`axiomctl` was built from Axiom commit `08d856c3` and installed on the VPS:

```text
/usr/local/bin/axiomctl
```

The Axiom service binary was also rebuilt from the same commit and installed at:

```text
/opt/axiom/axiom
```

Backup files:

```text
/opt/axiom/backups/axiom.bak-20260429-risk-response
/usr/local/bin/axiomctl.bak-20260429-risk-response
```

The VPS Axiom workspace helper now prefers `axiomctl` when it is present and executable, then falls back to the older shell/Node implementation if the binary is unavailable:

```text
/root/.openclaw/workspace/skills/axiom-trade/scripts/axiom.sh
```

Backup created before editing:

```text
/root/.openclaw/workspace/skills/axiom-trade/scripts/axiom.sh.bak-20260429-axiomctl
```

Smoke checks through the normal skill helper:

```bash
cd /root/.openclaw/workspace/skills/axiom-trade
bash scripts/axiom.sh preflight
bash scripts/axiom.sh regime ZBTUSDT
bash scripts/axiom.sh account
bash scripts/axiom.sh positions
bash scripts/axiom.sh execute ZBTUSDT open_long 3 12 0.1200 0.2000 79 "smoke test low confidence should be rejected before any exchange order"
```

Observed state:

```text
preflight: ok
account: ok
positions: ok
ZBTUSDT regime: MIXED - 4h above EMA50, 1h below EMA50
execute smoke: HTTP 422, status=blocked, code=risk_control, order_placed=false
positions after execute smoke: none
```

No real order was submitted.

## Future emergency resume checklist

If market scans are paused again for debugging, use this checklist before resuming:

1. Run Axiom helper checks again and confirm positions are still fresh.
2. Confirm `bash scripts/axiom.sh regime ZBTUSDT` still routes through `axiomctl` and returns `MIXED` for conflicting 4h/1h trends.
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

## Polymarket read-only check

After pausing market-scan cron, the Polymarket helper was checked with read-only commands:

```bash
cd /root/.openclaw/workspace/skills/polymarket
bash scripts/pm.sh preflight
bash scripts/pm.sh balance
bash scripts/pm.sh positions
bash scripts/pm.sh orders
```

Observed state:

```text
preflight: ok
clob_client: v2
collateral: pUSD
pUSD balance: 5.626627
legacy USDC.e: 0
open orders: none
open positions: 1
```

Current open position at check time:

```text
Market: Will the All India Trinamool Congress (AITC) win the most seats in the 2026 West Bengal Legislative Assembly election?
Outcome: Yes
Size: 7.0093
Average price: 0.4279
Current price: 0.4845
Current value: 3.396
Cash PnL: 0.396
Percent PnL: 13.2
End date: 2026-04-29
```

The helper reported `cli_version: polymarket 0.1.4` while also reporting `clob_client: v2`. Treat the package version string as the installed wrapper version, not proof of CLOB v1 usage.

## Polymarket isolation and manual scan result

The first manual Polymarket agent scan after the V2 helper upgrade produced a no-trade report contaminated by stale Axiom/global memory. It mentioned Axiom/BTC/USDC state even though the Polymarket helper state was healthy and unchanged.

Fixes applied:

```text
skills/polymarket/SKILL.md
/root/.openclaw/workspace/skills/polymarket/SKILL.md
polymarket-market-scan cron prompt
```

The skill and cron prompt now state that Polymarket scans must ignore global workspace memory, short-term recall, Axiom status, crypto futures positions, BTC/USDC trades, Binance balances, USDT/USDC futures equity, Axiom service health, and any non-Polymarket memory. Objective current state may only come from `pm.sh preflight`, `pm.sh balance`, `pm.sh positions`, `pm.sh orders`, `pm.sh portfolio`, and fresh Polymarket Gamma/CLOB API responses.

Follow-up Polymarket debugging found two more runtime-quality issues:

- `pm.sh markets` could return high-volume markets whose `endDate` was already in the past, because Gamma still marked some of them `closed=false`.
- The market-scan prompt was broad enough that the persistent trader session sometimes did a quick position/order check instead of a full market scan.

Fixes applied:

```text
skills/polymarket/scripts/pm.sh
skills/polymarket/SKILL.md
/root/.openclaw/workspace/skills/polymarket/scripts/pm.sh
/root/.openclaw/workspace/skills/polymarket/SKILL.md
polymarket-market-scan cron prompt
```

`pm.sh markets` now filters out past-end-date markets and includes `days_to_end`. `pm.sh inspect <slug_or_market_id>` now returns normalized market status, token IDs, CLOB executable buy/sell prices, liquidity, spread, and resolution text so the agent does not hand-write Gamma/CLOB parsing before deciding.

The Polymarket skill and cron prompt now explicitly say there are no category-level bans. Sports and NBA markets are allowed when the actual data supports a thesis. The model should reject markets because they fail real gates such as unclear resolution, expired trading window, missing token IDs, unavailable executable prices, insufficient liquidity, no edge, or safety limits, not because they are sports/NBA.

X/Bird is now required supporting research for every candidate trade judgment and material existing-position risk judgment. Candidate inspection should combine `pm.sh inspect` with targeted `bird search --json` context checks; open positions should also get targeted X context before hold/close/reduce judgments. X can surface sports injuries, lineup news, official statements, political developments, breaking-event confirmation, and sentiment shifts, but it must never be the sole reason to trade. If Bird/X credentials are unavailable, new entries are blocked; existing-position risk management may still close/reduce based on Polymarket evidence.

`scripts/pm.sh scan-context` now gives the autonomous trader one baseline command for preflight, balance, positions, orders, portfolio, active markets, and targeted Bird/X searches for open positions plus the top market candidates. The cron prompt requires this command every run so the persistent session cannot reuse a previous scan's X results as fresh evidence.

`scan-context` now scans up to 60 active markets and returns `candidate_markets`
as a mixed edge pool instead of only the highest-volume markets. The pool keeps
the top hot-volume markets for awareness, then adds balanced-price markets,
near-event non-extreme markets, liquid longer-horizon non-extreme markets, and
eventful non-extreme markets. This prevents the trader from spending every scan
only on nearly resolved 0.00/1.00 markets while still preserving high-volume
context.

`scan-context` also returns `candidate_inspections` for up to six
`candidate_markets`. This forces the inspect stage into the baseline scan:
normalized market status, token IDs, executable CLOB buy/sell prices, liquidity,
spread, and resolution text are available before the model decides whether a
candidate has a real edge.

Manual validation after the fix:

```text
model: xiaomi-coding/mimo-v2.5-pro
final output: NO_REPLY
message tool calls: none
tool failures: 0
open orders after scan: none
open positions after scan: unchanged, AITC YES 7.0093 shares
full scan: scan-context 60
candidate pool: 12 mixed markets
candidate inspections: 6/6 ok, executable CLOB prices present
fresh Bird/X context: 8/8 ok for the AITC open position and top market candidates
cron run: status=ok, summary=NO_REPLY, delivered=false
```

Final cron state after validation:

```text
Axiom Market Scan:
  enabled: true
  schedule: 0,30 * * * * UTC
  sessionTarget: session:axiom-trader
  delivery: announce -> telegram:8436785488
  model: xiaomi-coding/mimo-v2.5-pro
  last scheduled announce validation: summary=NO_REPLY, delivered=false

Polymarket Market Scan:
  enabled: true
  schedule: 15,45 * * * * UTC
  sessionTarget: session:polymarket-trader
  delivery: none
  model: xiaomi-coding/mimo-v2.5-pro
```

## Axiom Fresh X Context

The Axiom trader now follows the same fresh-context pattern used for Polymarket.
`skills/axiom-trade/scripts/axiom.sh scan-context 20` bundles Axiom preflight,
account, positions, screener, BTC/ETH regime anchors, top candidate market
summaries, and targeted `bird search --json` results. The Axiom cron prompt
requires this command as the first tool command for each autonomous scan so the
persistent trader session cannot reuse stale X findings as fresh evidence.

Bird/X is supporting evidence only. New entries still require an Axiom-native
thesis from market structure, liquidity, volatility, positioning, R/R, account
tier confidence, and service-side risk controls. If Bird/X is unavailable, new
entries are blocked; emergency close/reduce remains allowed when Axiom
position/price/risk evidence itself justifies action.

## Daily Review Cron Fix

On 2026-04-29 UTC, `Axiom Daily Review` and `Polymarket Daily Review` failed
after the MiMo migration with `Agent couldn't generate a response`. The root
cause was review-job-specific tool restrictions plus prompts that asked MiMo to
read files and run commands; MiMo emitted XML-style pseudo tool calls instead of
real OpenClaw tool calls.

VPS cron config was updated so both daily review jobs:

- use `xiaomi-coding/mimo-v2.5-pro`;
- remove the review-only `toolsAllow` restriction;
- require a single first real process command:
  - Axiom: `cd /root/.openclaw/workspace/skills/axiom-trade && bash scripts/axiom.sh scan-context 20`
  - Polymarket: `cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh scan-context 60`
- keep cron `announce -> telegram:8436785488` delivery;
- ban the message tool inside review jobs so meaningful review conclusions are
  delivered once by cron announce, while no-conclusion reviews still return
  exact `NO_REPLY`.

Manual validation after the fix:

```text
Axiom Daily Review: status=ok, meaningful Chinese review delivered
Polymarket Daily Review: status=ok, review completed without agent-generation error
Current cron list: both daily review jobs status=ok, delivery=announce, model=mimo-v2.5-pro
```

## Model policy

All agent cron jobs now use MiMo as the primary model:

```text
model: xiaomi-coding/mimo-v2.5-pro
fallbacks: none
```

This includes Axiom, Polymarket, Bird X digest, Bird AI/Agent/Design digest, and daily/weekly review jobs. The Memory Dreaming Promotion job is a system event and has no model. Do not switch the primary model or fallback back to NVIDIA for routine cron work; `nvidia/z-ai/glm-5.1` was too slow on the VPS and contributed to delayed/stale cron scheduling.

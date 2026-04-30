---
title: "Skill Integration Contract"
summary: "Agent-facing contract for integrating OpenClaw skills safely into external runtimes."
---

# Skill Integration Contract

Status: agent-facing contract.

This document is written for future agents, Codex sessions, and external runtimes that need to integrate the local OpenClaw skills without reading historical chats.

The goal is safe interoperability:

- discover skills from the workspace
- run helper scripts with the correct working directory
- keep secrets out of logs and prompts
- keep trading sessions isolated
- keep no-action scans silent
- let backend services enforce hard risk controls
- make every real trade, risk change, outage, and review conclusion auditable

This is not a trading strategy and not a replacement for each skill's `SKILL.md`. Treat it as the integration boundary around the skills.

## Runtime Shape

The current VPS runtime uses package-installed `openclaw`, not a source checkout.

Expected runtime layout:

```text
/root/.openclaw/workspace
/root/.openclaw/workspace/skills
/root/.openclaw/.env
/root/.openclaw/cron/jobs.json
/root/.openclaw/cron/jobs-state.json
```

Source repo layout for development:

```text
skills/axiom-trade
skills/polymarket
docs/automation
```

When deploying skill updates to the VPS, sync the relevant skill directory into:

```text
/root/.openclaw/workspace/skills/<skill-name>
```

Do not switch the live VPS back to source deployment unless the operator explicitly requests it.

## Skill Package Contract

Each skill package has this shape:

```text
skills/<name>/SKILL.md
skills/<name>/scripts/*
skills/<name>/references/*   optional
```

`SKILL.md` is the behavior contract. It tells the model how to decide, what sources are authoritative, when to act, and what to output.

`scripts/` is the tool contract. Scripts should be preferred over hand-written authenticated `curl` because they centralize quoting, environment loading, API keys, output shape, and provider migration details.

Scripts should:

- load `/root/.openclaw/.env` when needed
- avoid printing secrets
- return JSON or stable machine-readable text where feasible
- exit nonzero on usage errors or missing runtime dependencies
- keep read-only commands separate from mutating commands
- encode current API migrations, such as Polymarket CLOB v2

Future agents should not infer missing endpoints. If a command is not listed in a skill contract, treat it as unavailable until the skill is updated.

## Environment Contract

Never print secrets.

Scripts may source:

```bash
/root/.openclaw/.env
```

Agents may report whether required variables are present or missing, but must redact values.

Required env varies by skill:

```text
AXIOM_URL
AXIOM_TRADER_ID
AXIOM_API_KEY
PM_* variables used by the Polymarket scripts
Bird or X credentials used by the bird CLI
```

If a required credential is missing, stop the affected action and report only the operational configuration error when it is material. Do not retry with placeholders such as `ID`, `TRADER_ID`, `KEY`, or `default`.

Provider or model choice must not alter tool authority. A slower or faster model may change latency, not permission boundaries.

## Shared Decision Rules

For autonomous scans:

- use fresh data for the current run
- treat prior chat, prior cron output, and session memory as stale unless a helper command confirms it
- use X through `bird search --json` as supporting context when a candidate or open position requires judgment
- do not use X posts as the sole reason to trade
- do not call outbound messaging tools directly from cron runs
- let cron delivery handle Telegram delivery
- output exactly `NO_REPLY` when no reportable event occurred

Reportable events are:

- real trade submitted, accepted, rejected, resized, or risk-blocked
- close, reduce, add, cancel, or position-risk action
- material position risk change requiring operator attention
- service, auth, API, runtime, or dependency failure
- service recovery from a previously broken state
- daily or weekly review conclusion

Non-reportable events include:

- no candidate meets the threshold
- normal account health
- zero positions
- unchanged positions
- ordinary market commentary
- watchlist-only decisions
- X results that do not change trade or risk judgment

If the final result is no action, the final assistant message must be exactly:

```text
NO_REPLY
```

No markdown, explanation, prefix, suffix, or Telegram send is allowed.

## Session And Cron Contract

Axiom and Polymarket must keep separate sessions.

Recommended session targets:

```text
session:axiom-trader
session:polymarket-trader
session:axiom-review
session:polymarket-review
```

Market scans and reviews have different responsibilities:

- market scan: find and act on fresh trade opportunities or position risk
- daily review: summarize material activity, mistakes, risk state, and lessons
- weekly review: summarize higher-level performance and process issues

Current intended stagger:

```text
Axiom Market Scan:       0,30 * * * * @ UTC
Polymarket Market Scan:  15,45 * * * * @ UTC
```

Do not run multiple autonomous jobs against the same trading session unless the operator explicitly intends the overlap.

Use `delivery.mode = "none"` only for truly silent internal jobs. Use `announce` for jobs whose final response should be delivered when reportable. No-action jobs still rely on exact `NO_REPLY`.

See [Cron jobs](/automation/cron-jobs) for OpenClaw scheduler behavior.

## Axiom Skill Contract

Skill directory:

```text
/root/.openclaw/workspace/skills/axiom-trade
```

Source directory:

```text
skills/axiom-trade
```

Helper:

```bash
cd /root/.openclaw/workspace/skills/axiom-trade
bash scripts/axiom.sh <command>
```

Core commands:

```text
preflight
scan-context [limit]
symbols [limit]
screener [limit]
klines SYMBOL [INTERVAL] [LIMIT]
market SYMBOL
regime SYMBOL
account
positions
execute SYMBOL ACTION LEVERAGE SIZE_USD STOP_LOSS TAKE_PROFIT CONFIDENCE REASONING
close SYMBOL SIDE QUANTITY REASON
```

Read-only commands:

```text
preflight
scan-context
symbols
screener
klines
market
regime
account
positions
```

Mutating commands:

```text
execute
close
```

Integration flow:

1. `bash scripts/axiom.sh preflight`
2. `bash scripts/axiom.sh scan-context 20`
3. Inspect account, positions, screener, BTC and ETH anchor summaries, candidate summaries, and Bird/X results.
4. Run `market SYMBOL` and targeted `bird search --json -n 10 "<query>"` if a candidate needs deeper inspection.
5. Submit `execute` only when the thesis survives market structure, liquidity, R/R, confidence threshold, and service-side risk controls.
6. Submit `close` only for a real position action. `quantity=0` means full close by current exchange position, not an exchange order of zero size.
7. Report only the authoritative result returned by Axiom.

Axiom service-side risk controls are authoritative. The model chooses a bounded request; Axiom may accept, reject, resize, de-leverage, widen stop loss, or block the trade. Reports must prefer returned `actual_*`, `adjustments[]`, stop-loss status, and take-profit status over requested values.

If `account.ok=false` or `positions.ok=false`, do not open new positions. Do not describe stale positions as current.

## Polymarket Skill Contract

Skill directory:

```text
/root/.openclaw/workspace/skills/polymarket
```

Source directory:

```text
skills/polymarket
```

Helper:

```bash
cd /root/.openclaw/workspace/skills/polymarket
bash scripts/pm.sh <command>
```

Core commands:

```text
preflight
scan-context [limit]
markets [limit]
inspect <slug_or_market_id>
balance
approve-check
refresh-balance
positions
portfolio
orders
trades
geoblock
limit <token_id> <side> <price> <size>
market <token_id> <side> <amount>
close <token_id> [shares]
cancel <order_id>
```

Read-only commands:

```text
preflight
scan-context
markets
inspect
balance
approve-check
positions
portfolio
orders
trades
geoblock
```

Mutating commands:

```text
refresh-balance
limit
market
close
cancel
```

Polymarket uses CLOB v2 and pUSD collateral. Legacy V1 CLI or USDC.e output is not authoritative for new orders.

Integration flow:

1. `bash scripts/pm.sh preflight`
2. Stop new entries if V2 client is unavailable, wallet is missing, geoblock is true, pUSD is below floor, allowance is zero, or executable prices are unavailable.
3. `bash scripts/pm.sh scan-context 60`
4. Use `candidate_markets` and `candidate_inspections` as the mixed candidate pool.
5. Run extra `inspect` only when the candidate is not already inspected.
6. Run targeted `bird search --json -n 10 "<market keywords>"` before every candidate trade judgment and material existing-position risk judgment.
7. Trade only when there is clear resolution, executable price, meaningful liquidity, acceptable time to resolution, and a concrete edge thesis.
8. Report only real orders, position changes, risk changes, blockers, or review conclusions.

No market category is categorically banned. Sports, NBA, politics, crypto, macro, tech, entertainment, and long-tail markets are all allowed when the data supports the thesis. Reject on real risk/data gates, not broad category labels.

## Bird X Research Contract

The `bird` CLI is a read/search intelligence source for X.

Use:

```bash
bird search --json -n 10 "<query>"
```

Treat Bird/X as:

- useful for official statements, breaking developments, injuries, lineups, regulatory headlines, listings, incidents, and sentiment shifts
- supporting signal, not sole evidence
- stale between runs unless searched fresh

If Bird is unavailable:

- do not open new Axiom or Polymarket positions that require external context
- continue read-only scanning
- manage existing-position emergencies only when exchange or market data alone justifies action
- report the blocker only if it is new or materially changed

## Notification Contract

Cron owns delivery. Agent turns should not call a message tool to send routine cron results.

User-visible reports should be concise and Chinese when the operator is using Chinese. Axiom trade reports should follow the skill's three-section format. Polymarket reports should include market, side, price, liquidity, thesis, and risk.

Never send:

```text
NO_REPLY
```

through a messaging tool. `NO_REPLY` is the final assistant output sentinel for cron suppression, not a chat message.

## Safety Contract

Do not:

- print secrets
- invent trader ids, token ids, endpoint paths, or wallet state
- bypass helper scripts for authenticated writes
- migrate funds automatically
- change provider/model defaults from a skill run
- switch the VPS from package-installed OpenClaw to source runtime
- let Axiom and Polymarket share a trader session
- create Telegram spam for no-action scans
- claim a trade executed unless the helper/API response proves it
- claim a position is protected unless fresh position/order data proves it

Mutating trade commands must be auditable from:

```text
cron run history
agent session history
helper command output
backend exchange/API response
service logs when needed
```

## Agent Integration Checklist

An external agent integrating these skills should:

1. Read this contract.
2. Read the target skill's `SKILL.md`.
3. Resolve the runtime skill directory.
4. Run the skill preflight command.
5. Refuse to proceed on missing credentials or missing helper dependencies.
6. Run the canonical scan-context command for autonomous scans.
7. Use helper scripts for all listed operations.
8. Use Bird/X only as supporting context.
9. Let backend services enforce hard risk controls.
10. Emit exactly `NO_REPLY` for no-action scans.
11. Produce a user-visible report only for reportable events.
12. Never print secrets.

## Machine Readable Summary

```yaml
runtime:
  openclaw_mode: package-installed
  workspace: /root/.openclaw/workspace
  env_file: /root/.openclaw/.env
  source_repo: /root/projects/marvis
  secret_policy: redact

delivery:
  no_action_response: NO_REPLY
  no_action_delivery: suppress
  report_language: zh-CN when operator uses Chinese
  direct_message_tool_from_cron: forbidden

sessions:
  axiom_market_scan: session:axiom-trader
  polymarket_market_scan: session:polymarket-trader
  axiom_review: session:axiom-review
  polymarket_review: session:polymarket-review

skills:
  axiom-trade:
    runtime_cwd: /root/.openclaw/workspace/skills/axiom-trade
    source_cwd: skills/axiom-trade
    preflight: bash scripts/axiom.sh preflight
    scan_context: bash scripts/axiom.sh scan-context 20
    read_commands:
      - preflight
      - scan-context
      - symbols
      - screener
      - klines
      - market
      - regime
      - account
      - positions
    write_commands:
      - execute
      - close
    requires_x_research_for_new_entries: true
    hard_risk_authority: axiom_service

  polymarket:
    runtime_cwd: /root/.openclaw/workspace/skills/polymarket
    source_cwd: skills/polymarket
    preflight: bash scripts/pm.sh preflight
    scan_context: bash scripts/pm.sh scan-context 60
    clob_client: v2
    collateral: pUSD
    read_commands:
      - preflight
      - scan-context
      - markets
      - inspect
      - balance
      - approve-check
      - positions
      - portfolio
      - orders
      - trades
      - geoblock
    write_commands:
      - refresh-balance
      - limit
      - market
      - close
      - cancel
    requires_x_research_for_candidate_judgment: true
```

## Maintenance Notes

When a helper command changes, update this contract and the corresponding `SKILL.md` together.

When cron cadence, session target, delivery mode, model defaults, or VPS runtime path changes, update this contract after verifying the live VPS state.

When adding a new trading-sensitive skill, define:

- runtime directory
- source directory
- preflight command
- scan-context command if autonomous
- read commands
- write commands
- secret requirements
- no-action output
- notification policy
- audit sources

See [Skills](/tools/skills) for general OpenClaw skill behavior and [Cron jobs](/automation/cron-jobs) for scheduler delivery semantics.

# Marvis Runtime Handoff — 2026-04-25

This note is for the next Codex/OpenClaw session. It captures the current Marvis VPS runtime, local Git situation, and the trading-skill changes already deployed.

## Current Goal

Continue optimizing the user's Marvis runtime and trading skills without breaking the live VPS bot.

Primary runtime concerns:

- Axiom and Polymarket cron jobs should trade autonomously when there is a real edge.
- No-action scans must stay quiet and must not spam Telegram.
- Axiom, Polymarket, Bird, and review jobs must keep their own sessions.
- Tool calls should use helper scripts instead of hand-written credentialed curl commands.

## Repositories and Workdirs

The normal project path is:

```text
/root/projects/marvis
```

However, in the current Codex session this path has a sandbox mount problem:

```text
/root/projects                ro
/root/projects/marvis         rw
/root/projects/marvis/.git    ro
/root/projects/marvis/.agents ro
/root/projects/marvis/.codex  ro
```

Consequence:

- Ordinary files under `/root/projects/marvis` can be edited.
- Git metadata cannot be written, so `git add`, `git commit`, `git stash`, pull/rebase, and branch operations fail.
- Directory-level operations under `/root/projects` such as renaming `/root/projects/marvis` also fail.

Temporary writable Git clone:

```text
/tmp/marvis
```

This clone has writable `.git`, and it was used to commit and push the latest skill changes.

Latest pushed commit:

```text
c030aee80895ec8714fe0640bac7ffb6e0daa2ca chore: harden trading skill cron behavior
branch: marvis-custom-v2026.4.21
remote: origin git@github.com:artwalker/marvis.git
```

If the next session still sees `/root/projects/marvis/.git` as read-only, either:

- continue Git work in `/tmp/marvis`, or
- restart/reconfigure Codex so `/root/projects/marvis/.git` is writable, or
- from the host/outer WSL layer, recreate `/root/projects/marvis` from the pushed branch.

## VPS Access

Use:

```bash
ssh -4 vps
```

Do not print secrets.

The VPS uses package-installed OpenClaw for Marvis, not a source checkout.

OpenClaw workspace paths on VPS:

```text
/root/.openclaw/workspace/skills/axiom-trade
/root/.openclaw/workspace/skills/polymarket
/root/.openclaw/workspace/skills/bird-x-intel
/root/.openclaw/cron/jobs.json
/root/.openclaw/cron/jobs-state.json
/root/.openclaw/cron/runs/
/root/.openclaw/agents/main/sessions/
```

## Deployed Skill Changes

The following local files were changed and pushed in commit `c030aee808`:

```text
skills/axiom-trade/SKILL.md
skills/axiom-trade/scripts/axiom.sh
skills/polymarket/SKILL.md
```

High-level changes:

- Added Axiom helper commands:
  - `bash scripts/axiom.sh execute SYMBOL ACTION LEVERAGE SIZE_USD STOP_LOSS TAKE_PROFIT CONFIDENCE REASONING`
  - `bash scripts/axiom.sh close SYMBOL SIDE QUANTITY REASON`
- Updated Axiom skill to prefer helpers for execute/close/account/positions/symbols/screener.
- Removed examples that encouraged hand-written authenticated curl for execute/close/status.
- Added Axiom open-position silence rule:
  - slight PnL movement, SL/TP intact, no close/resize/add, no material risk change => exact `NO_REPLY`.
- Added Polymarket review and message-tool discipline:
  - daily/weekly reviews must not call `message` themselves.
  - never send `NO_REPLY` through message tool.
  - no-action status text must not be sent.

The changed Axiom and Polymarket skill docs were synced to the VPS:

```text
/root/.openclaw/workspace/skills/axiom-trade/SKILL.md
/root/.openclaw/workspace/skills/axiom-trade/axiom-trade/SKILL.md
/root/.openclaw/workspace/skills/polymarket/SKILL.md
```

Validation performed:

```bash
bash -n skills/axiom-trade/scripts/axiom.sh
bash -n skills/polymarket/scripts/pm.sh
git diff --check
```

All passed. Full `pnpm check` was not rerun in this final pass and previously had unrelated repository issues; do not claim full repo checks passed.

## VPS Cron State

Primary jobs observed:

```text
11fdd602-f6be-4038-aa6b-a689eaf3a978 Axiom Market Scan
b8086f04-30b3-4fb4-a333-54b6a4e96b0d Bird X Hourly Digest
polymarket-market-scan               Polymarket Market Scan
b6ae147c-627f-4c7b-8ff2-719eec896c37 Axiom Daily Review
3033d188-7b75-4b3e-ae94-bfa56757f9c9 Polymarket Daily Review
26e3deed-9376-4d8f-b4e4-b3951f6b9116 Axiom Weekly Review
f9cc0a35-85c5-460a-9623-ec29f4eb183a Polymarket Weekly Review
```

Current intended model configuration:

```text
primary:   nvidia/z-ai/glm-5.1
fallbacks: nvidia/minimaxai/minimax-m2.7, nvidia/deepseek-ai/deepseek-v4-pro
```

Axiom and Polymarket scans are offset:

- Axiom: `0,30 * * * * @ UTC`
- Polymarket: `15,45 * * * * @ UTC`

This stagger is intentional.

Runtime cron hardening applied later on 2026-04-25:

- Review jobs now have a tool allow-list that excludes the `message` tool:
  `group:runtime,group:fs,group:web,group:memory`.
- Jobs changed:
  - `b6ae147c-627f-4c7b-8ff2-719eec896c37` Axiom Daily Review
  - `3033d188-7b75-4b3e-ae94-bfa56757f9c9` Polymarket Daily Review
  - `26e3deed-9376-4d8f-b4e4-b3951f6b9116` Axiom Weekly Review
  - `f9cc0a35-85c5-460a-9623-ec29f4eb183a` Polymarket Weekly Review
- Backup before edit: `/root/.openclaw/cron/jobs.json.bak-20260425-tools`.
- Reason: Polymarket Daily Review previously produced `NO_REPLY` but also used
  the `message` tool, causing Telegram spam despite prompt bans. Reviews use
  `delivery.mode=announce`, so cron delivery can still notify when the final
  review report is meaningful.

Skill prompt hardening applied later on 2026-04-25:

- `axiom-trade`: added a final cron output gate, stricter stale-position
  handling during preflight/API outages, recovery reporting guidance, and a
  ghost-position-cleanup rule. A ghost cleanup is now explicitly treated as a
  reconciliation/data-consistency event, not proof of a second exchange close or
  authoritative PnL.
- `polymarket`: added a top-level final output gate and stricter exact
  `NO_REPLY` cleanup. X/Bird context or market notes that do not change a
  trade/risk decision must stay internal and must not be appended to `NO_REPLY`.
- `bird-x-intel`: tightened hourly digest criteria so repeated headlines,
  generic sentiment, low-signal rumors, and "watch this space" items should be
  suppressed. Useful digest items must be new and plausibly relevant to trading,
  Polymarket, operations, regulation, or product impact.
- Backups before edit:
  - `/root/.openclaw/workspace/skills/axiom-trade/SKILL.md.bak-20260425-2230-skill-opt`
  - `/root/.openclaw/workspace/skills/axiom-trade/axiom-trade/SKILL.md.bak-20260425-2230-skill-opt`
  - `/root/.openclaw/workspace/skills/polymarket/SKILL.md.bak-20260425-2230-skill-opt`
  - `/root/.openclaw/workspace/skills/bird-x-intel/SKILL.md.bak-20260425-2230-skill-opt`

Axiom Market Scan cron follow-up:

- Temporarily disabled `11fdd602-f6be-4038-aa6b-a689eaf3a978` for manual
  debugging, then re-enabled after Axiom helper checks showed service healthy
  and positions empty.
- `bash scripts/axiom.sh preflight` returned public market data, screener,
  account, and positions all ok; `bash scripts/axiom.sh positions` returned
  `positions:null`.
- The cron prompt was tightened again to forbid stale position reporting and
  close-reason inference. It now says not to infer TP/SL/drawdown from equity
  delta, mark price, or memory, and to treat ghost cleanup as a reconciliation
  event only.
- A manual correction was sent to Telegram because the previous recovery report
  inferred "likely TP 0.0660" incorrectly. DB evidence shows close trade
  `429950744`, `SELL 301 @ 0.06097`, realized PnL about `0.31003`; the ghost
  row was a pre-fix local sync/reconciliation artifact.
- NVIDIA `nvidia/z-ai/glm-5.1` runs are very slow in this runtime. Recent Axiom
  runs took 3-11 minutes, and some review/digest jobs can appear overdue while
  still running. Wait before assuming stuck; then check `openclaw tasks list`
  and `openclaw cron list --all`.

## Axiom Runtime State

Binance API problem:

- Earlier Axiom account/positions failed with Binance `-2015 Invalid API-key, IP, or permissions`.
- Request IP was added by the user to Binance whitelist.
- After whitelist, `bash scripts/axiom.sh preflight` showed `account.ok=true` and `positions.ok=true`.

Axiom placed a real trade:

```text
ENJUSDT open_long
entry around 0.05994
requested: 36 USDT notional @ 3x
actual: about 18 USDT notional @ 3x
reason for resize: atr_scaling:0.50x
quantity: about 301 ENJ
```

Earlier position check showed normal small movement:

```text
ENJUSDT long, mark around 0.05985-0.05999
unrealized PnL roughly -0.45% to +0.10%
SL/TP intact
no material risk change
```

Later on 2026-04-25, Axiom closed that ENJUSDT long via drawdown protection:

- Real Binance close synced as trade `429950744`, `SELL`, quantity `301`,
  close price about `0.060970`, realized PnL about `0.31`, fee about `0.009176`.
- A later "Ghost position cleanup" Telegram notice was not the real close. It
  came from a local DB/exchange reconciliation mismatch.
- Root cause found in the Axiom runtime code: a local filled order and the
  Binance open-trade sync could both mutate the same position, doubling the DB
  quantity. Synthetic local fill IDs also polluted max-trade-id detection, so
  incremental sync skipped the real close until the runtime fix.
- Axiom source was patched in `/root/projects/axiom` to ignore non-numeric
  trade IDs for max-trade-id, and to skip position mutation when a synced open
  trade matches a recent local filled order.
- Patched binary was installed to `/opt/axiom/axiom` after backing up
  `/opt/axiom/axiom` and `/opt/axiom/data/data.db`.
- Post-fix validation: `axiom.service` active, `flowvpn.service` active,
  Axiom preflight ok, account/positions ok, and positions returned `null`.

Important validation:

- A pre-fix Axiom run sent commentary plus `NO_REPLY` to Telegram. That was undesirable.
- After prompt hardening, the 11:00 UTC real cron run output exact `NO_REPLY` for ordinary ENJ position noise.
- This confirmed the no-action silence rule can work in the live session.
- On 2026-04-25, later Axiom scan runs also produced `NO_REPLY` with
  `delivered=false`, `deliveryStatus=not-delivered`, and no `messageToolSentTo`.
- If `openclaw cron list --all` briefly shows Axiom scan as `running` with
  `Next` in the past, first check recent run duration before assuming it is
  stuck. A later check showed the job returned to `ok`; the observed state was a
  normal long-running scan.
- On 2026-04-29, one Axiom scan task was marked `lost` with `backing session
  missing` after completion while the cron job still showed `running`. It was
  repaired with `openclaw cron disable 11fdd602-f6be-4038-aa6b-a689eaf3a978`
  followed by `openclaw cron enable 11fdd602-f6be-4038-aa6b-a689eaf3a978`; the
  job then showed `status: ok` with the next run scheduled.

Useful check commands:

```bash
ssh -4 vps 'tail -n 3 /root/.openclaw/cron/runs/11fdd602-f6be-4038-aa6b-a689eaf3a978.jsonl'
ssh -4 vps 'jq ".jobs[\"11fdd602-f6be-4038-aa6b-a689eaf3a978\"].state" /root/.openclaw/cron/jobs-state.json'
ssh -4 vps 'cd /root/.openclaw/workspace/skills/axiom-trade && bash scripts/axiom.sh preflight'
ssh -4 vps 'cd /root/.openclaw/workspace/skills/axiom-trade && bash scripts/axiom.sh positions'
```

## Polymarket Runtime State

Polymarket was migrated to the official CLOB V2 client path on 2026-04-28/29.
The old Rust `polymarket` CLI remains installed only for wallet display,
geoblock checks, and data helpers.

VPS changes applied:

- Added `skills/polymarket/package.json` with pinned
  `@polymarket/clob-client-v2` and `viem`.
- Added `skills/polymarket/scripts/pm-v2.mjs`, a Node wrapper around the
  official TypeScript V2 client.
- Updated `skills/polymarket/scripts/pm.sh` so order, balance, allowance,
  trades, and cancel commands use the V2 wrapper.
- Updated `skills/polymarket/SKILL.md` and
  `skills/polymarket/references/trading.md` to treat V1 SDK/CLI trading as
  deprecated and V2 `pUSD` as the authoritative collateral.

Attempted but rejected:

- `polymarket upgrade` installed an upstream Rust CLI binary that required
  newer GLIBC than the VPS has. The binary was restored from backup.
- Building `polymarket-cli v0.1.5` from source did not solve V2 trading; its
  source still targets legacy USDC.e flows. It was not installed.

Current VPS preflight showed:

```text
cli: true
cli_version: polymarket 0.1.4
clob_client: v2
collateral: pUSD
v2: true
wallet: true
geoblocked: false
pusd: 0
pusd_allowance: 0
usdc_legacy_deprecated: true
max_order: 3
max_exposure: 10
```

Important: no V2 approval transaction, funding transaction, or trade was
executed during this migration. New positions must not be opened while `pusd`
is 0 or `pusd_allowance` is 0.

Known current position:

```text
AITC YES
market: West Bengal Legislative Assembly Election winner
position size around 7.0093 shares
current value around 3.7
unrealized gain around 20-25%
```

Polymarket scan job has `delivery.mode=none` to avoid no-action spam. It should use the message tool only for:

- real trade
- close/reduce
- real operational blocker
- material position-risk report

No-action scans should not call `message` and should final-answer exact `NO_REPLY`.

Later validation on 2026-04-25:

- Polymarket market scan latest observed no-action run returned exact
  `NO_REPLY`, `delivered=false`, `deliveryStatus=not-requested`, and
  `messageToolSentTo=null`.
- A prior run still returned analysis text ending in `NO_REPLY`; it was not
  delivered because the scan job has `delivery.mode=none`, but the prompt should
  continue to be watched for exact-`NO_REPLY` discipline.

V2 validation on 2026-04-29:

- `bash scripts/pm.sh preflight` returns `v2:true`, `collateral:"pUSD"`, and
  zero pUSD balance/allowance.
- `bash scripts/pm.sh balance` returns V2 pUSD balance/allowance and V2
  exchange allowances.
- `bash scripts/pm.sh orders` returns an empty open-order list.
- `bash scripts/pm.sh positions` still sees the existing AITC position via the
  proxy wallet.
- A stale `runningAtMs` marker made `polymarket-market-scan` show `status:
  running` while its task ledger record was already `lost`. This was repaired
  via `openclaw cron disable polymarket-market-scan` followed by
  `openclaw cron enable polymarket-market-scan`; the job now shows `status: ok`
  with the next run scheduled.

Useful check commands:

```bash
ssh -4 vps 'tail -n 3 /root/.openclaw/cron/runs/polymarket-market-scan.jsonl'
ssh -4 vps 'cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh preflight'
ssh -4 vps 'cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh balance'
ssh -4 vps 'cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh positions'
ssh -4 vps 'openclaw cron show polymarket-market-scan'
```

## Bird Runtime State

Bird X Hourly Digest exists and has delivered Telegram reports.

Bird AI/Agent/Design Digest was added later:

- Job id: `dd0477ff-2668-4206-80a8-b8063fc349b4`
- Schedule: `30 9,14,21 * * * @ Asia/Shanghai`
- Session key: `bird-ai-agent-design-digest`
- Delivery: Telegram announce to the same operator chat.
- Scope: AI agents, agent infrastructure, MCP/tool use, computer use, agent
  wallets, memory/evals/autonomy, AI product design, agent UI, interaction
  design, information architecture, workflow ergonomics, and design/product
  thinking.
- It is separate from the crypto/trading X digest. If fewer than two genuinely
  useful and new items exist, it must return exact `NO_REPLY`.
- Watchlist memory:
  `/root/.openclaw/workspace/skills/bird-x-intel/memory/watchlist.md`
- Digest memory:
  `/root/.openclaw/workspace/skills/bird-x-intel/memory/ai-agent-design-digest.md`

Known issue to keep watching:

- Bird digest can produce useful reports, but if no useful finding exists, final answer must be exact `NO_REPLY`.
- It must not call `message` itself; cron delivery owns Telegram.

Useful check:

```bash
ssh -4 vps 'tail -n 3 /root/.openclaw/cron/runs/b8086f04-30b3-4fb4-a333-54b6a4e96b0d.jsonl'
ssh -4 vps 'openclaw cron show dd0477ff-2668-4206-80a8-b8063fc349b4'
```

## Session Isolation

Observed session keys:

```text
agent:main:axiom-trader
agent:main:polymarket-trader
agent:main:axiom-review
agent:main:polymarket-review
agent:main:cron:b8086f04-30b3-4fb4-a333-54b6a4e96b0d
```

This is the desired pattern:

- user chats are separate from trading jobs.
- Axiom trader has its own persistent session.
- Polymarket trader has its own persistent session.
- Reviews have their own review sessions.
- Bird hourly digest is isolated.

Do not clear or merge trader sessions unless explicitly asked.

## Next Recommended Work

1. In a new session, first verify whether `/root/projects/marvis/.git` is writable.
2. If writable, pull the pushed branch and make `/root/projects/marvis` the main working directory again.
3. If still read-only, use `/tmp/marvis` for Git commits and `/root/projects/marvis` only for local file context.
4. Continue live validation:
   - Axiom no-action scans stay exact `NO_REPLY` and not delivered.
   - Axiom trade/risk events are delivered once.
   - Polymarket no-action scans do not call message.
   - Daily/weekly reviews do not send `NO_REPLY` through Telegram.
5. Verify the next natural Polymarket Daily Review after the review-job
   tool allow-list change. It should either produce a meaningful Chinese review
   via cron delivery or exact `NO_REPLY` with no `messageToolSentTo`.
6. Avoid source-level OpenClaw changes unless prompt/skill hardening and cron
   tool policy are insufficient.

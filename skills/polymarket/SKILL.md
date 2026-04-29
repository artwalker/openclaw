---
name: polymarket
description: Scan Polymarket prediction markets for betting opportunities and execute trades via the official CLOB v2 client wrapper. Search markets, analyze probabilities, filter by strategy, recommend picks, and optionally place orders. Use when user asks about prediction markets, Polymarket, or wants to trade on Polymarket.
homepage: https://polymarket.com
metadata: { "openclaw": { "emoji": "🔮", "requires": { "bins": ["curl"] } } }
---

# Polymarket — Prediction Market Scanner & Trader

Scan Polymarket for betting opportunities. Search markets, analyze probabilities, recommend picks. Optionally execute trades via `scripts/pm.sh`, which wraps Polymarket's official CLOB v2 client.

This skill is trading-sensitive. Stay conservative. If external event context is needed, you may use `bird-x-intel` as an auxiliary signal only. Never treat X posts as a sufficient reason to trade by themselves.

Response language: follow user's language.

## Runtime Isolation

This skill is Polymarket-only. In autonomous scans, ignore global workspace memories,
short-term recall, or previous session notes about non-Polymarket systems.

Only these sources are authoritative for current objective state:

- `scripts/pm.sh preflight`
- `scripts/pm.sh balance`
- `scripts/pm.sh positions`
- `scripts/pm.sh orders`
- `scripts/pm.sh portfolio`
- Fresh Polymarket Gamma/CLOB API responses

Never report or reason from Axiom status, crypto futures positions, BTC/USDC trades,
Binance balances, USDT/USDC futures equity, Axiom service health, or any non-Polymarket
memory during a Polymarket scan. If such content appears in context, treat it as
irrelevant stale memory.

If the current scan executes no Polymarket trade, changes no Polymarket position,
hits no Polymarket operational blocker, and detects no material Polymarket position
risk, the final response must be exactly `NO_REPLY`.

## API Base URLs

```
GAMMA=https://gamma-api.polymarket.com
CLOB=https://clob.polymarket.com
```

All endpoints are **public, no auth needed**. These are **external internet APIs**, not localhost. Use `curl -s` for all calls.

## Core Workflows

### 1. Scan Hot Markets

```bash
curl -s "https://gamma-api.polymarket.com/markets?closed=false&order=volume24hr&ascending=false&limit=50"
```

Key fields: `question`, `outcomePrices` (JSON string `["0.65","0.35"]`), `volume24hr`, `liquidity`, `endDate`, `slug`, `clobTokenIds` (JSON string).

### 2. Search by Keyword

```bash
curl -s "https://gamma-api.polymarket.com/public-search?q=bitcoin&limit_per_type=10"
```

Returns `{events[], tags[], profiles[]}`. The `events[]` array contains nested `markets[]`.

### 3. Filter by Category

```bash
curl -s "https://gamma-api.polymarket.com/events?closed=false&tag=crypto&limit=20"
```

Tags: `crypto`, `politics`, `sports`, `tech`, `economics`, `pop-culture`.

### 4. Get Market Detail

```bash
curl -s "https://gamma-api.polymarket.com/markets/{market_id}"
curl -s "https://gamma-api.polymarket.com/markets?slug={slug}"
```

### 5. Real-Time Price

Parse `clobTokenIds` first — index 0 = YES, index 1 = NO.

```bash
curl -s "https://clob.polymarket.com/price?token_id=TOKEN_ID&side=BUY"
```

### 6. Price History

```bash
curl -s "https://clob.polymarket.com/prices-history?market=TOKEN_ID&interval=1w&fidelity=60"
```

### 7. Order Book

```bash
curl -s "https://clob.polymarket.com/book?token_id=TOKEN_ID"
```

## ID Hierarchy

```
Event (topic) → Market (question)
  ├── outcomePrices: ["0.65", "0.35"]  (YES, NO)
  └── clobTokenIds: ["yes_token", "no_token"]  (JSON string, must parse)
```

## Screening Strategies

### 🪙 High Certainty ("Coin Picking")

Price < $0.05 or > $0.95, volume > $10k. **Warning**: 95¢ flip = 95% loss.

### 🔍 Value Discovery

Price $0.35–$0.65, volume > $50k. Look for mispriced events vs recent news.

### ⏰ Near Expiry

`endDate` < 7 days, clear resolution criteria. Short holding risk.

## Risk Assessment

| Factor      | Red Flag                                    |
| ----------- | ------------------------------------------- |
| Liquidity   | volume24hr < $10k or liquidity < $5k → skip |
| Resolution  | Vague criteria → dispute risk               |
| Event Type  | Subjective judgment > objective fact        |
| Price Trend | Rapid reversal → unstable consensus         |
| Book Depth  | Thin book → bad fill                        |

## Output Format

```
🔮 Polymarket 机会 #1
事件：[question]
选择：Yes/No | 当前价格：$0.XX（= XX% 概率）
24h 交易量：$XXk | 流动性：$XXk | 到期：YYYY-MM-DD
类型：[捡硬币 / 价值发现 / 即将到期]
理由：[1-2 sentence WHY]
风险：[低/中/高] | 预期收益率：XX%
⚠️ [risk warnings]
```

Rank by confidence, top 5 unless user asks for more.

## Trading (requires official CLOB v2 client)

Trading is **optional**. Without the official `@polymarket/clob-client-v2` dependency, the skill works in read-only scan mode.

Polymarket's 2026-04-28 CLOB v2 migration is active. V1 SDK/CLI trading paths are deprecated. For authenticated trading, use `pm.sh`; it delegates order, balance, allowance, trades, and cancel operations to `scripts/pm-v2.mjs` and `@polymarket/clob-client-v2`.

V2 collateral is `pUSD`, not legacy USDC.e. Treat any legacy USDC.e balance or V1 approval output as non-authoritative for new orders.

### OpenClaw exec path rule

In OpenClaw tool calls, do not use `~` in command paths. Use the absolute skill directory:

```bash
cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh preflight
```

If a shell command needs the user home, use `/root` explicitly. The cron exec environment may not define `HOME`.

### Preflight

Before any trade, run with an absolute working directory:

```bash
cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh preflight
```

Do not call `cd ~/.openclaw/...`; OpenClaw cron exec may not expand `~`.

Returns JSON including `{clob_client:"v2", collateral:"pUSD", v2, wallet, address, proxy_address, geoblocked, pusd, pusd_allowance, max_order, max_exposure}`. If `v2:false`, `wallet:false`, `geoblocked:"true"`, `pusd` is below the safety floor, or `pusd_allowance` is `0`, do not open new positions.
Use `proxy_address` for Polymarket positions and portfolio state. The signer `address` can be empty of positions even when the proxy wallet has active positions.

### Decision tree

Manual/user-requested trading:

```
User asks to trade
  → pm.sh preflight
  → V2 client missing? → "Trading unavailable. I can still analyze markets."
  → Wallet missing? → "Wallet not configured. See references/trading.md"
  → pUSD balance or allowance insufficient? → Report balance/allowance, suggest V2 funding/approval
  → All good → present confirmation prompt
  → User confirms → execute via pm.sh
```

Autonomous/cron trading:

```
Scheduled scan / prompt says autonomous trading scan / session key is polymarket-trader
  → pm.sh preflight
  → V2 client missing or wallet missing? → report only if this is a new operational blocker, otherwise NO_REPLY
  → geoblocked == true? → do not place orders; report once if newly detected, otherwise NO_REPLY
  → pUSD balance or allowance below safety floor? → stop opening new positions and report if newly detected
  → Scan markets and current portfolio
  → Clear thesis inside safety net? → execute via pm.sh without user confirmation
  → No clear thesis / no meaningful position change? → NO_REPLY
```

### Order execution

```bash
cd /root/.openclaw/workspace/skills/polymarket
bash scripts/pm.sh limit <token_id> <side> <price> <size>   # Limit order
bash scripts/pm.sh market <token_id> buy <amount_pusd>       # Buy market order; amount is pUSD exposure
bash scripts/pm.sh market <token_id> sell <shares>           # Sell market order; amount is shares, not pUSD
bash scripts/pm.sh close <token_id> [shares]                 # Close/reduce an existing position by selling shares
bash scripts/pm.sh cancel <order_id>                          # Cancel
bash scripts/pm.sh orders                                     # View open orders
bash scripts/pm.sh trades                                     # View recent CLOB v2 trades
bash scripts/pm.sh positions                                  # View positions (proxy wallet preferred)
bash scripts/pm.sh portfolio                                  # View portfolio (proxy wallet preferred)
bash scripts/pm.sh balance                                    # Check pUSD balance/allowance
bash scripts/pm.sh approve-check                              # Same pUSD balance/allowance check; no on-chain tx
bash scripts/pm.sh refresh-balance                            # Refresh CLOB v2 balance/allowance cache
bash scripts/pm.sh geoblock                                   # Check Polymarket geoblock status
bash scripts/pm.sh markets 30                                 # Robust active market scan; do not hand-write Gamma jq math
```

### Market scan helper

For scheduled scans, prefer:

```bash
cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh markets 30
```

Do not hand-write Gamma API `jq` math inside the agent turn. Gamma often returns numeric fields as strings; `pm.sh markets` normalizes them with `tonumber?`.

### Closing positions

When exiting or reducing an existing position, prefer:

```bash
cd /root/.openclaw/workspace/skills/polymarket && bash scripts/pm.sh close <token_id>
```

Do not estimate remaining position value and pass that dollar value to `market ... sell`. For Polymarket CLOB v2 market sells, `amount` means shares/making amount, not pUSD. Closing reduces exposure, so `pm.sh close` does not apply the opening-order `PM_MAX_ORDER` limit.

### Confirmation (manual mode only)

```
⚠️ Trade Confirmation Required
市场: [question]
方向: YES/NO | 价格: $0.XX | 数量: X shares
总成本: $XX.XX | 最大亏损: $XX.XX
pUSD 余额: $XX.XX
Type 'confirm' to execute.
```

### Risk limits

- Default max single order: $3 (env `PM_MAX_ORDER`)
- Default max total exposure: $10 (env `PM_MAX_EXPOSURE`)
- Min liquidity: $5k (skip markets below)

These defaults are intentionally small. If the operator chooses to raise them, that is an explicit deployment decision, not something this skill should encourage.

For official CLOB v2 dependency installation, wallet setup, and command details, see [trading.md](references/trading.md).

### Execution mechanism

- **Limit orders** (`pm.sh limit`): Signed and posted through `@polymarket/clob-client-v2`.
- **Market orders** (`pm.sh market`): Signed and posted through `@polymarket/clob-client-v2`.
- CLOB raw order book (`clob book`) is usually thin — most liquidity lives in the AMM.
  **Do not judge liquidity from raw book bid/ask.** Use `clob price --side buy/sell` for aggregated executable prices.
- `--order-type FAK` (Fill-and-Kill): Fills what it can immediately, cancels the rest. No open orders left behind.

### Positions & balance

- Balance/allowance: `bash scripts/pm.sh balance` (V2 pUSD)
- Positions: `polymarket data positions <proxy_address>` (NOT the signer address). `pm.sh positions` already prefers the proxy wallet.
- Proxy address: found via `polymarket wallet show` → `proxy_address` field
- After placing an order, verify execution with `bash scripts/pm.sh trades`

## Autonomous Mode (Cron Trading)

When triggered by scheduled scan, when the prompt says "autonomous trading scan", or when the session key is `polymarket-trader`, autonomous mode is active.
You scan markets, make decisions, and execute trades WITHOUT user confirmation.

### Experiment Goal

$10 pUSD → $30. Do not rely on stale remembered balance or old day counts; read live balance, positions, orders, and portfolio state from `pm.sh preflight`, `pm.sh balance`, `pm.sh orders`, `pm.sh positions`, and `pm.sh portfolio`.
Token cost matters, but correctness and safety come first. Prefer targeted API calls over broad repeated scans.

### Safety Net (code-enforced by `pm.sh` defaults)

- Max single order: $3
- Max total exposure: $10
- If balance drops below $3: STOP trading, notify user

These limits are hard-coded — you cannot override them even if you wanted to.

### Your Autonomy

You define your own strategy. No preset rules on what markets to pick, when to enter/exit,
or how to size positions. You have full access to Polymarket data (hot markets, categories,
order books, news) — use your judgment.

The only constraints:

1. Stay within the safety net above
2. Every decision must have a clear, articulable thesis
3. Learn from your results — adapt your approach based on what works
4. If you consult X/Twitter via `bird-x-intel`, treat it as supporting evidence only. A trade thesis must still stand on market structure, price, liquidity, timing, and resolution mechanics.

### Cross-session memory

Runtime memory lives under `/root/.openclaw/workspace/skills/polymarket/memory/`.
Do not read `/root/.openclaw/workspace/MEMORY.md`, `/root/.openclaw/workspace/memory/*`,
or `.dreams` recall files for objective Polymarket state; those files may contain
Axiom or other unrelated operational memories.

At the start of each scheduled scan, read both files if present:

- `/root/.openclaw/workspace/skills/polymarket/memory/polymarket-positions.md`: last portfolio snapshot, executed trades, and realized operational notes.
- `/root/.openclaw/workspace/skills/polymarket/memory/polymarket-observations.md`: subjective market views, thesis tracking, and lessons learned.
- `/root/.openclaw/workspace/skills/polymarket/memory/polymarket-daily-review.md`: daily review conclusions.
- `/root/.openclaw/workspace/skills/polymarket/memory/polymarket-weekly-review.md`: weekly strategy conclusions.

Objective state (positions, balance, orders, portfolio) must still be refreshed from CLI every scan. Memory is context, not authority.

After any trade, meaningful position change, operational failure, or thesis update, append a concise entry to the appropriate absolute-path file above.

Memory writes are append-only:

- Do not overwrite a memory file with the `write` tool.
- Do not write Polymarket memory under `/root/.openclaw/workspace/memory/`.
- Use shell append (`cat <<'EOF' >> /root/.openclaw/workspace/skills/polymarket/memory/<file>.md`) or a tool mode that explicitly appends.

For portfolio/trade state, append to `/root/.openclaw/workspace/skills/polymarket/memory/polymarket-positions.md`:

```
2026-04-25 06:30 UTC | balance=8.25 pUSD | positions: OpenAI YES size=3.2313 value=0.38 | note: reduced position; remaining exposure small
```

For subjective observations, append to `/root/.openclaw/workspace/skills/polymarket/memory/polymarket-observations.md`:

```
2026-03-14 12:00 | BTC 75k March: NO=0.82, thesis intact, holding
2026-03-14 12:00 | Iran regime June: Yes=0.24, underpriced but thin liquidity, watch next scan
```

### Review Jobs

Daily and weekly reviews are learning loops, not new trade scans. They should consolidate what the persistent trader learned without forcing a Telegram message when nothing changed.

Review cron delivery owns Telegram delivery:

- Do not call the `message` tool yourself in daily or weekly review jobs.
- If there is no meaningful review, final output must be exactly `NO_REPLY`.
- Never send `NO_REPLY` through the `message` tool.
- If a review is meaningful, final output must be the Chinese review report and must not include `NO_REPLY`.

Before writing a review, refresh objective state:

```bash
cd /root/.openclaw/workspace/skills/polymarket
bash scripts/pm.sh preflight
bash scripts/pm.sh balance
bash scripts/pm.sh positions
bash scripts/pm.sh orders
```

For daily reviews:

- Read `memory/polymarket-positions.md` and `memory/polymarket-observations.md`.
- Append only meaningful conclusions to `memory/polymarket-daily-review.md`.
- If the last 24 hours contain no trade, no position/risk change, and no durable thesis update, final output must be exactly `NO_REPLY`.

For weekly reviews:

- Read daily reviews plus positions and observations.
- Append only strategy-level conclusions to `memory/polymarket-weekly-review.md`.
- Focus on repeatable market types, false positives, sizing behavior, and progress toward the `$10 -> $30` experiment.

### Reporting

After each cron scan, decide what to send:

- **Trade executed or position moved >10%**: Full report (actions, portfolio snapshot, P&L, reasoning). Language: Chinese.
- **No action taken**: Output EXACTLY `NO_REPLY` (8 characters, uppercase, with underscore). Nothing else.

Cron delivery normally owns Telegram delivery:

- If the cron job has `delivery.mode=none`, do not rely on cron delivery. In that mode, call the `message` tool exactly once only for a real trade, operational blocker, or material position-risk report.
- In `delivery.mode=none`, no-action scans must not call the `message` tool.
- For cron jobs with normal delivery enabled, do not call the `message` tool yourself.
- Never call the `message` tool with `NO_REPLY`, status-only monitoring text, or a no-action summary.
- If a trade was executed, the final assistant response must be the Chinese trade report, not `NO_REPLY`.
- If you already used a tool to send a message by mistake, the final response must still be the same Chinese trade report so cron history remains truthful.
- Only use `NO_REPLY` when no trade/reportable event happened.

**NO_REPLY rules (AUTHORITATIVE — single source of truth):**

1. Output the literal string `NO_REPLY` and nothing else — no quotes, no punctuation, no newline prefix.
2. No preamble ("I scanned...", "After reviewing..."), no analysis, no summary, no apology, no language wrapper.
3. No markdown, no code fences, no emoji.
4. If you have any analysis to share but took no action, the answer is still `NO_REPLY`. The daily summary cron covers portfolio reviews.
5. Trade executed OR existing position moved >10% since last scan → Full Chinese report instead of NO_REPLY.

Invalid: `"NO_REPLY"`, `no_reply`, `NO_REPLY.`, `分析完毕 NO_REPLY`, `NO_REPLY\n\nDetails: ...`
Valid: `NO_REPLY`

## Rules

1. **Read-only by default** — manual trading requires CLI + wallet + explicit user confirmation
2. **Manual mode: Never auto-execute trades** — every trade needs user typing "confirm".
   Exception: In autonomous/cron mode, trades execute automatically within safety net limits.
3. **If CLI not installed** — operate in read-only mode, do not suggest installing unless user asks about trading
4. **Do not use X posts as sole evidence** — social chatter can help with discovery and timing, but never replaces market, liquidity, and resolution analysis
5. **Not financial advice** — frame as analysis
6. **Volume threshold** — ignore < $10k 24h volume
7. **Tail risk warning** — always warn on "捡硬币". 95% probability ≠ certainty.
8. **Verify resolution criteria** — vague resolution = dispute risk
9. **clobTokenIds is a JSON string** — parse before using token IDs
10. **External API** — internet requests to polymarket.com, not localhost

## Error Handling

| Issue                 | Action                                                        |
| --------------------- | ------------------------------------------------------------- |
| Empty `[]`            | Try different search terms                                    |
| 400 Bad Request       | Invalid token ID or param                                     |
| 404 Not Found         | Market resolved/removed                                       |
| 429 Rate Limited      | Wait and retry                                                |
| 500 / timeout         | Retry once                                                    |
| V2 client not found   | Degrade to read-only, link references/trading.md              |
| Wallet not configured | Link references/trading.md for setup                          |
| Insufficient pUSD     | Report balance and required amount                            |
| pUSD allowance is 0   | Do not open new positions; report V2 approval/funding blocker |
| Order rejected        | Report CLOB error message                                     |

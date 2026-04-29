# Polymarket CLOB V2 Trading Reference

Polymarket migrated CLOB trading to V2 on 2026-04-28. V1 SDK/CLI trading paths are deprecated. This skill uses the official TypeScript package `@polymarket/clob-client-v2` through `scripts/pm-v2.mjs` and `scripts/pm.sh`.

## Installation

```bash
cd /root/.openclaw/workspace/skills/polymarket
npm install
```

The older Rust `polymarket` CLI can still be useful for wallet display, geoblock checks, and data commands, but it is not the authoritative V2 trading path.

## Wallet Setup

```bash
# Create new wallet
polymarket wallet create

# Or import existing private key
polymarket wallet import 0xYOUR_PRIVATE_KEY

# Check wallet
polymarket wallet show
```

Config stored at `~/.config/polymarket/config.json`:

```json
{ "private_key": "0x...", "chain_id": 137, "signature_type": "proxy" }
```

## Contract Approval / Allowance

V2 trading uses pUSD collateral. Check V2 balance and allowance:

```bash
cd /root/.openclaw/workspace/skills/polymarket
bash scripts/pm.sh preflight
bash scripts/pm.sh approve-check
```

If `pusd` is `0` or `pusd_allowance`/`allowance` is `0`, do not open new positions. Funding, wrapping, or approval must be handled deliberately by the operator. The skill must not send on-chain approval transactions unless explicitly requested.

## Order Commands

### Limit Order

```bash
bash scripts/pm.sh limit TOKEN_ID buy 0.45 20
```

- `--price`: 0.01 to 0.99 (probability / share price)
- `--size`: number of shares
- Total cost = price × size
- `--order-type`: GTC (default), FOK, GTD, FAK

### Market Order

```bash
bash scripts/pm.sh market TOKEN_ID buy 5
```

- Buy `amount`: pUSD amount to spend
- Sell `amount`: shares to sell

### Cancel Orders

```bash
bash scripts/pm.sh cancel ORDER_ID
```

## Portfolio

```bash
# Open orders
bash scripts/pm.sh orders

# Positions (need wallet address)
bash scripts/pm.sh positions

# Trade history
bash scripts/pm.sh trades

# Balance
bash scripts/pm.sh balance
```

## Token ID Resolution

Market data returns `clobTokenIds` as a **JSON string inside JSON**:

```json
{ "clobTokenIds": "[\"abc123\", \"def456\"]" }
```

- Index 0 = YES token
- Index 1 = NO token

Parse with: `echo $clobTokenIds | jq -r 'fromjson | .[0]'`

To buy YES: `--token <index 0> --side buy`
To buy NO: `--token <index 1> --side buy`
Or equivalently: `--token <index 0> --side sell` = buying NO

## Polygon Network

| Asset | Purpose                                                    |
| ----- | ---------------------------------------------------------- |
| pUSD  | V2 collateral for CLOB trades                              |
| USDC.e | Legacy collateral; wrap/migrate before V2 trading         |
| MATIC | Gas fees for approvals/on-chain ops                        |

Follow official Polymarket V2 migration instructions for wrapping/migrating USDC.e to pUSD. Do not assume a legacy USDC.e balance can be used for V2 orders.

## Signature Types

| Type              | Use Case                                  |
| ----------------- | ----------------------------------------- |
| `proxy` (default) | Polymarket's proxy wallet, simplest setup |
| `eoa`             | Direct private key signing                |
| `gnosis-safe`     | Multisig wallet                           |

Set in config or with `--signature-type` flag.

## Troubleshooting

| Issue            | Fix                                                                              |
| ---------------- | -------------------------------------------------------------------------------- |
| "geoblock" error | Check: `polymarket clob geoblock`. Some regions restricted.                      |
| Order rejected   | Check `pm.sh balance`, allowance, tick size, and CLOB error message              |
| Stale prices     | Use `polymarket clob price TOKEN --side buy` for real-time                       |
| API down         | Check: `polymarket clob ok`                                                      |

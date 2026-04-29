#!/usr/bin/env bash
set -euo pipefail
: "${HOME:=/root}"

# === Config (override via env) ===
PM_BIN="${PM_BIN:-$(command -v polymarket 2>/dev/null || true)}"
PM_MAX_ORDER="${PM_MAX_ORDER:-3}"
PM_MAX_EXPOSURE="${PM_MAX_EXPOSURE:-10}"
PM_CONFIG="${PM_CONFIG:-${HOME}/.config/polymarket/config.json}"
PM_WEB_WALLET="${PM_WEB_WALLET:-}"
PM_V2_SCRIPT="${PM_V2_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pm-v2.mjs}"
NODE="${NODE:-$(command -v node 2>/dev/null || true)}"
JQ="${JQ:-$(command -v jq 2>/dev/null || true)}"

ACTION="${1:-}"
shift || true

usage() {
  cat <<'USAGE'
usage: pm.sh <command> [args...]

Commands:
  preflight                          Check CLI, wallet, balance, approval
  limit  <token> <side> <price> <size>  Place limit order
  market <token> <side> <amount>     Place market order
  close <token> [shares]              Close a YES/NO token position by selling shares
  cancel <order_id>                  Cancel order
  orders                             List open orders
  positions                          List positions (CLI wallet)
  portfolio                          List positions (web wallet, read-only)
  balance                            Show V2 pUSD collateral balance/allowance
  approve-check                      Show V2 pUSD balance/allowance state
  refresh-balance                    Refresh V2 pUSD CLOB balance/allowance cache
  trades                             List recent V2 CLOB trades
  geoblock                           Check Polymarket geoblock status
  markets                            List active high-volume markets (Gamma API)
USAGE
  exit 1
}

# === Helpers ===

need_cli() {
  if [[ -z "${PM_BIN}" || ! -x "${PM_BIN}" ]]; then
    echo '{"error":"polymarket CLI not found","hint":"Install: curl -sSL https://raw.githubusercontent.com/Polymarket/polymarket-cli/main/install.sh | sh"}' >&2
    exit 2
  fi
}

need_jq() {
  if [[ -z "${JQ}" || ! -x "${JQ}" ]]; then
    echo '{"error":"jq not found","hint":"Install: apt install jq / brew install jq"}' >&2
    exit 2
  fi
}

need_v2() {
  if [[ -z "${NODE}" || ! -x "${NODE}" ]]; then
    echo '{"error":"node not found","hint":"Install Node.js for @polymarket/clob-client-v2"}' >&2
    exit 2
  fi
  if [[ ! -f "${PM_V2_SCRIPT}" ]]; then
    echo '{"error":"pm-v2.mjs not found","hint":"Sync the updated polymarket skill scripts"}' >&2
    exit 2
  fi
  local pkg_dir
  pkg_dir="$(cd "$(dirname "${PM_V2_SCRIPT}")/.." && pwd)"
  if [[ ! -d "${pkg_dir}/node_modules/@polymarket/clob-client-v2" ]]; then
    echo '{"error":"@polymarket/clob-client-v2 not installed","hint":"Run npm install in the polymarket skill directory"}' >&2
    exit 2
  fi
}

v2() {
  need_v2
  local proxy
  proxy=$(get_proxy_address)
  PM_PROXY_ADDRESS="${PM_PROXY_ADDRESS:-${proxy}}" "${NODE}" "${PM_V2_SCRIPT}" "$@"
}

get_wallet_address() {
  need_jq
  if [[ ! -f "${PM_CONFIG}" ]]; then
    echo ""
    return
  fi
  ${JQ} -r '.address // empty' "${PM_CONFIG}" 2>/dev/null || true
}

get_proxy_address() {
  need_cli
  ${PM_BIN} wallet show 2>/dev/null | awk -F':' '/Proxy wallet/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' || true
}

check_geoblock() {
  need_cli
  ${PM_BIN} clob geoblock 2>/dev/null || true
}

check_order_limit() {
  local amount="$1"
  need_jq
  local over
  over=$(echo "${amount} ${PM_MAX_ORDER}" | awk '{print ($1 > $2) ? "yes" : "no"}')
  if [[ "${over}" == "yes" ]]; then
    echo "{\"error\":\"order amount \$${amount} exceeds max \$${PM_MAX_ORDER}\",\"hint\":\"Set PM_MAX_ORDER env to increase limit\"}" >&2
    exit 3
  fi
  local warn
  warn=$(echo "${amount}" | awk '{print ($1 > 10) ? "yes" : "no"}')
  if [[ "${warn}" == "yes" ]]; then
    echo "{\"warning\":\"order amount \$${amount} is above \$10 review threshold\"}" >&2
  fi
}

# === Commands ===

cmd_preflight() {
  local cli_ok="false" cli_version="" wallet_ok="false" address="" proxy_address="" geoblocked="unknown"

  # CLI check
  if [[ -n "${PM_BIN}" && -x "${PM_BIN}" ]]; then
    cli_ok="true"
    cli_version=$(${PM_BIN} --version 2>/dev/null | head -1 || echo "unknown")
  fi

  # Wallet check
  if [[ -f "${PM_CONFIG}" ]]; then
    need_jq
    local key
    key=$(${JQ} -r '.private_key // empty' "${PM_CONFIG}" 2>/dev/null || true)
    if [[ -n "${key}" ]]; then
      wallet_ok="true"
      address=$(get_wallet_address)
    fi
  fi

  # V2 collateral check (only if Node V2 client + wallet available)
  local pusd_balance="0" pusd_allowance="0" legacy_usdce="0" v2_ok="false" v2_error=""
  if [[ "${cli_ok}" == "true" && "${wallet_ok}" == "true" ]]; then
    proxy_address=$(get_proxy_address)
    local geo_out
    geo_out=$(${PM_BIN} clob geoblock 2>/dev/null || true)
    geoblocked=$(echo "${geo_out}" | awk -F':' '/Blocked/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    if [[ -z "${geoblocked}" ]]; then
      geoblocked="unknown"
    fi
    if [[ -n "${NODE}" && -f "${PM_V2_SCRIPT}" ]]; then
      local bal_out
      bal_out=$(v2 balance 2>/dev/null || true)
      if echo "${bal_out}" | ${JQ} -e 'has("error") | not' >/dev/null 2>&1; then
        v2_ok="true"
        pusd_balance=$(echo "${bal_out}" | ${JQ} -r '
          (.balance // "0") as $raw
          | ($raw | tostring | tonumber? // 0) / 1000000
        ' 2>/dev/null || echo "0")
        pusd_allowance=$(echo "${bal_out}" | ${JQ} -r '
          if .allowance then
            .allowance
          elif .allowances and (.allowances | type == "object") then
            ([.allowances[] | tostring | select(. != "0")] | first) // "0"
          else
            "0"
          end
        ' 2>/dev/null || echo "0")
        local wallet_out
        wallet_out=$(v2 wallet-balances 2>/dev/null || true)
        if echo "${wallet_out}" | ${JQ} -e 'has("error") | not' >/dev/null 2>&1; then
          legacy_usdce=$(echo "${wallet_out}" | ${JQ} -r '.proxy.usdce // .signer.usdce // "0"' 2>/dev/null || echo "0")
        fi
      else
        v2_error=$(echo "${bal_out}" | ${JQ} -r '.error // empty' 2>/dev/null || true)
      fi
    else
      v2_error="node v2 client unavailable"
    fi
  fi
  v2_error=${v2_error//\\/\\\\}
  v2_error=${v2_error//\"/\\\"}

  cat <<EOF
{
  "cli": ${cli_ok},
  "cli_version": "${cli_version}",
  "clob_client": "v2",
  "collateral": "pUSD",
  "v2": ${v2_ok},
  "v2_error": "${v2_error}",
  "wallet": ${wallet_ok},
  "address": "${address}",
  "proxy_address": "${proxy_address}",
  "geoblocked": "${geoblocked}",
  "pusd": ${pusd_balance},
  "pusd_allowance": "${pusd_allowance}",
  "legacy_usdce": ${legacy_usdce},
  "usdc_legacy_deprecated": true,
  "max_order": ${PM_MAX_ORDER},
  "max_exposure": ${PM_MAX_EXPOSURE}
}
EOF
}

cmd_limit() {
  local token="${1:?token_id required}"
  local side="${2:?side required (buy/sell)}"
  local price="${3:?price required}"
  local size="${4:?size required}"

  need_cli

  # Calculate total cost
  local cost
  cost=$(echo "${price} ${size}" | awk '{printf "%.2f", $1 * $2}')
  check_order_limit "${cost}"

  v2 limit "${token}" "${side}" "${price}" "${size}"
}

cmd_market() {
  local token="${1:?token_id required}"
  local side="${2:?side required (buy/sell)}"
  local amount="${3:?amount required}"

  need_cli
  if [[ "${side}" == "buy" ]]; then
    check_order_limit "${amount}"
  fi

  v2 market "${token}" "${side}" "${amount}" FAK
}

cmd_close() {
  local token="${1:?token_id required}"
  local shares="${2:-}"
  need_cli
  need_jq

  if [[ -z "${shares}" ]]; then
    shares=$(cmd_positions | ${JQ} -r --arg token "${token}" '
      map(select((.asset // "") == $token)) | .[0].size // empty
    ')
  fi
  if [[ -z "${shares}" || "${shares}" == "null" ]]; then
    echo '{"error":"position not found for token"}' >&2
    exit 5
  fi

  # Closing reduces exposure. Do not apply PM_MAX_ORDER, which is for opening risk.
  v2 market "${token}" sell "${shares}" FAK
}

cmd_cancel() {
  local order_id="${1:?order_id required}"
  v2 cancel "${order_id}"
}

cmd_orders() {
  v2 orders
}

cmd_positions() {
  need_cli
  local addr
  addr=$(get_proxy_address)
  if [[ -z "${addr}" ]]; then
    addr=$(get_wallet_address)
  fi
  if [[ -z "${addr}" ]]; then
    echo '{"error":"wallet address not found"}' >&2
    exit 4
  fi
  ${PM_BIN} data positions "${addr}" -o json
}

cmd_balance() {
  v2 balance
}

cmd_refresh_balance() {
  v2 refresh-balance
}

cmd_trades() {
  v2 trades
}

cmd_markets() {
  local limit="${1:-30}"
  need_jq
  curl -fsS "https://gamma-api.polymarket.com/markets?closed=false&order=volume24hr&ascending=false&limit=${limit}" \
    | ${JQ} '[.[] | {
        question: (.question // ""),
        slug: (.slug // ""),
        end_date: ((.endDate // "") | tostring | .[0:10]),
        volume_24h: ((.volume24hr // .volume24h // 0) | tonumber? // 0),
        liquidity: ((.liquidity // 0) | tonumber? // 0),
        outcome_prices: ((.outcomePrices // "[]") | if type == "string" then (fromjson? // []) else . end),
        clob_token_ids: ((.clobTokenIds // "[]") | if type == "string" then (fromjson? // []) else . end),
        active: (.active // true),
        accepting_orders: (.acceptingOrders // null)
      }]'
}

cmd_portfolio() {
  local addr="${1:-}"
  if [[ -z "${addr}" ]]; then
    addr=$(get_proxy_address)
  fi
  if [[ -z "${addr}" ]]; then
    addr="${PM_WEB_WALLET}"
  fi
  if [[ -z "${addr}" ]]; then
    echo '{"error":"no web wallet address configured","hint":"Set PM_WEB_WALLET env"}' >&2
    exit 4
  fi
  curl -s "https://data-api.polymarket.com/positions?user=${addr}&sizeThreshold=0.1&limit=50"
}

# === Dispatch ===

case "${ACTION}" in
  preflight)  cmd_preflight ;;
  limit)      cmd_limit "$@" ;;
  market)     cmd_market "$@" ;;
  close)      cmd_close "$@" ;;
  cancel)     cmd_cancel "$@" ;;
  orders)     cmd_orders ;;
  trades)     cmd_trades ;;
  positions)  cmd_positions ;;
  portfolio)  cmd_portfolio "$@" ;;
  balance)    cmd_balance ;;
  approve-check) cmd_balance ;;
  refresh-balance) cmd_refresh_balance ;;
  geoblock)   check_geoblock ;;
  markets)    cmd_markets "$@" ;;
  "")         usage ;;
  *)          echo "{\"error\":\"unknown command: ${ACTION}\"}" >&2; exit 1 ;;
esac

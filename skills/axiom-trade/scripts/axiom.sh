#!/usr/bin/env bash
set -euo pipefail

: "${HOME:=/root}"

if [[ -f /root/.openclaw/.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /root/.openclaw/.env
  set +a
fi

AXIOM_URL="${AXIOM_URL:-http://localhost:8080}"
BINANCE_FUTURES_URL="${BINANCE_FUTURES_URL:-https://fapi.binance.com}"
AXIOMCTL="${AXIOMCTL:-$(command -v axiomctl 2>/dev/null || true)}"
JQ="${JQ:-$(command -v jq 2>/dev/null || true)}"
ACTION="${1:-}"
shift || true

if [[ -n "${AXIOMCTL}" && -x "${AXIOMCTL}" ]]; then
  case "${ACTION}" in
    preflight|symbols|klines|market|regime|account|positions|close)
      export AXIOM_URL
      exec "${AXIOMCTL}" "${ACTION}" "$@"
      ;;
  esac
fi

usage() {
  cat <<'USAGE'
usage: axiom.sh <command> [args...]

Commands:
  preflight              Check env, symbols, screener, account, and positions
  symbols [limit]        List available symbols
  screener [limit]       List screener candidates
  klines SYMBOL [INTERVAL] [LIMIT]
                         Fetch public OHLCV candles through Axiom
  market SYMBOL          Summarize public candles, indicators, and regime
  regime SYMBOL          Print only the computed market regime block
  scan-context [limit]   Full autonomous scan context plus targeted Bird/X searches
  account                Query trader account
  positions              Query trader positions
  execute SYMBOL ACTION LEVERAGE SIZE_USD STOP_LOSS TAKE_PROFIT CONFIDENCE REASONING
                          Submit a bounded open_long/open_short request
  close SYMBOL SIDE QUANTITY REASON
                          Close a position; quantity=0 means full close
USAGE
  exit 1
}

need_jq() {
  if [[ -z "${JQ}" || ! -x "${JQ}" ]]; then
    echo '{"error":"jq not found"}' >&2
    exit 2
  fi
}

need_auth() {
  if [[ -z "${AXIOM_TRADER_ID:-}" || -z "${AXIOM_API_KEY:-}" ]]; then
    echo '{"ok":false,"error":"missing AXIOM_TRADER_ID or AXIOM_API_KEY"}' >&2
    exit 4
  fi
}

curl_status() {
  local url="${1:?url required}"
  shift || true
  local body
  local code
  body=$(mktemp)
  code=$(curl -sS -o "${body}" -w '%{http_code}' "$@" "${url}" || true)
  printf '%s\n' "${code}"
  cat "${body}"
  rm -f "${body}"
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_symbol() {
  printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]'
}

fetch_exchange_info() {
  curl -fsS "${BINANCE_FUTURES_URL}/fapi/v1/exchangeInfo"
}

contract_type_for_symbol() {
  local symbol
  symbol="$(normalize_symbol "${1:-}")"
  if [[ -z "${symbol}" ]]; then
    return 1
  fi

  fetch_exchange_info \
    | ${JQ} -r --arg symbol "${symbol}" '.symbols[]? | select(.symbol == $symbol) | .contractType // empty' \
    | head -1
}

symbol_in_list() {
  local symbol list item
  symbol="$(normalize_symbol "${1:-}")"
  list="${2:-}"
  while IFS= read -r item; do
    if [[ "$(normalize_symbol "${item}")" == "${symbol}" ]]; then
      return 0
    fi
  done < <(printf '%s\n' "${list}" | tr ',;[:space:]' '\n')
  return 1
}

tradfi_open_allowed() {
  local symbol
  symbol="$(normalize_symbol "${1:-}")"
  truthy "${AXIOM_ALLOW_TRADFI_PERP:-0}" && symbol_in_list "${symbol}" "${AXIOM_TRADFI_PERP_ALLOWLIST:-}"
}

reject_json() {
  local symbol="${1:?symbol required}"
  local action="${2:?action required}"
  local error="${3:?error required}"
  local message="${4:?message required}"
  ${JQ} -n \
    --arg symbol "${symbol}" \
    --arg action "${action}" \
    --arg error "${error}" \
    --arg message "${message}" \
    '{ok: false, result: "rejected", symbol: $symbol, action: $action, error: $error, message: $message}'
}

enforce_tradfi_open_guard() {
  local symbol action contract_type
  symbol="$(normalize_symbol "${1:-}")"
  action="${2:-}"
  case "${action}" in
    open_long|open_short) ;;
    *) return 0 ;;
  esac

  contract_type="$(contract_type_for_symbol "${symbol}" 2>/dev/null || true)"
  if [[ -z "${contract_type}" ]]; then
    reject_json "${symbol}" "${action}" "symbol_classification_unavailable" "Refusing to open because Binance contractType could not be verified"
    return 1
  fi

  if [[ "${contract_type}" != "TRADIFI_PERPETUAL" ]]; then
    return 0
  fi

  if tradfi_open_allowed "${symbol}"; then
    return 0
  fi

  reject_json "${symbol}" "${action}" "tradfi_perpetual_disabled" "TRADIFI_PERPETUAL opens are disabled unless AXIOM_ALLOW_TRADFI_PERP=1 and the symbol is in AXIOM_TRADFI_PERP_ALLOWLIST"
  return 1
}

filter_tradfi_screener() {
  local screener_file="${1:?screener_file required}"
  local exchange_file="${2:?exchange_file required}"
  ${JQ} --slurpfile exchange "${exchange_file}" '
    ($exchange[0] // {}) as $info
    | (reduce (($info.symbols // [])[]?) as $s ({}; .[$s.symbol] = ($s.contractType // ""))) as $types
    | [ .[]? | select(($types[.symbol] // "") != "TRADIFI_PERPETUAL") ]
  ' "${screener_file}"
}

tradfi_exclusions() {
  local screener_file="${1:?screener_file required}"
  local exchange_file="${2:?exchange_file required}"
  ${JQ} --slurpfile exchange "${exchange_file}" '
    ($exchange[0] // {}) as $info
    | (reduce (($info.symbols // [])[]?) as $s ({}; .[$s.symbol] = ($s.contractType // ""))) as $types
    | [ .[]?
        | select(($types[.symbol] // "") == "TRADIFI_PERPETUAL")
        | {
            symbol,
            score,
            price_change_24h,
            contract_type: "TRADIFI_PERPETUAL",
            reason: "tradfi_perpetual_disabled"
          }
      ]
  ' "${screener_file}"
}

cmd_symbols() {
  local limit="${1:-30}"
  need_jq
  curl -fsS "${AXIOM_URL}/api/symbols" \
    | ${JQ} --argjson limit "${limit}" 'if type == "array" then .[:$limit] elif (.data | type) == "array" then .data[:$limit] else . end'
}

cmd_screener_raw() {
  local limit="${1:-20}"
  need_jq
  curl -fsS "${AXIOM_URL}/api/screener?limit=${limit}" \
    | ${JQ} 'if (.data | type) == "array" then .data else . end'
}

cmd_screener() {
  local limit="${1:-20}"
  need_jq
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN

  if ! cmd_screener_raw "${limit}" >"${tmpdir}/screener.json"; then
    return 1
  fi
  if ! fetch_exchange_info >"${tmpdir}/exchange-info.json"; then
    ${JQ} -n '[]'
    return 0
  fi

  filter_tradfi_screener "${tmpdir}/screener.json" "${tmpdir}/exchange-info.json"
}

cmd_klines() {
  local symbol="${1:-}"
  local interval="${2:-5m}"
  local limit="${3:-120}"
  need_jq
  if [[ -z "${symbol}" ]]; then
    echo '{"ok":false,"error":"usage: axiom.sh klines SYMBOL [INTERVAL] [LIMIT]"}' >&2
    exit 2
  fi
  curl -fsS "${AXIOM_URL}/api/klines?symbol=${symbol}&interval=${interval}&limit=${limit}" \
    | ${JQ} 'if (.data | type) == "array" then .data else . end'
}

cmd_market() {
  local symbol="${1:-}"
  if [[ -z "${symbol}" ]]; then
    echo '{"ok":false,"error":"usage: axiom.sh market SYMBOL"}' >&2
    exit 2
  fi
  node "$(dirname "${BASH_SOURCE[0]}")/market-summary.mjs" "${AXIOM_URL}" "${symbol}" market
}

cmd_regime() {
  local symbol="${1:-}"
  if [[ -z "${symbol}" ]]; then
    echo '{"ok":false,"error":"usage: axiom.sh regime SYMBOL"}' >&2
    exit 2
  fi
  node "$(dirname "${BASH_SOURCE[0]}")/market-summary.mjs" "${AXIOM_URL}" "${symbol}" regime
}

cmd_account() {
  need_auth
  curl -fsS "${AXIOM_URL}/api/v1/trade/account?trader_id=${AXIOM_TRADER_ID}" \
    -H "X-API-Key: ${AXIOM_API_KEY}"
}

cmd_positions() {
  need_auth
  curl -fsS "${AXIOM_URL}/api/v1/trade/positions?trader_id=${AXIOM_TRADER_ID}" \
    -H "X-API-Key: ${AXIOM_API_KEY}"
}

cmd_execute() {
  need_auth
  need_jq
  local symbol="${1:-}"
  local action="${2:-}"
  local leverage="${3:-}"
  local size_usd="${4:-}"
  local stop_loss="${5:-}"
  local take_profit="${6:-}"
  local confidence="${7:-}"
  local reasoning="${8:-}"

  if [[ -z "${symbol}" || -z "${action}" || -z "${leverage}" || -z "${size_usd}" || -z "${stop_loss}" || -z "${take_profit}" || -z "${confidence}" || -z "${reasoning}" ]]; then
    echo '{"ok":false,"error":"usage: axiom.sh execute SYMBOL ACTION LEVERAGE SIZE_USD STOP_LOSS TAKE_PROFIT CONFIDENCE REASONING"}' >&2
    exit 2
  fi

  if ! enforce_tradfi_open_guard "${symbol}" "${action}"; then
    return 0
  fi

  local payload
  payload=$(${JQ} -n \
    --arg trader_id "${AXIOM_TRADER_ID}" \
    --arg symbol "${symbol}" \
    --arg action "${action}" \
    --argjson leverage "${leverage}" \
    --argjson position_size_usd "${size_usd}" \
    --argjson stop_loss "${stop_loss}" \
    --argjson take_profit "${take_profit}" \
    --argjson confidence "${confidence}" \
    --arg reasoning "${reasoning}" \
    '{
      trader_id: $trader_id,
      symbol: $symbol,
      action: $action,
      leverage: $leverage,
      position_size_usd: $position_size_usd,
      stop_loss: $stop_loss,
      take_profit: $take_profit,
      confidence: $confidence,
      reasoning: $reasoning
    }')

  curl -sS -X POST "${AXIOM_URL}/api/v1/trade/execute" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${AXIOM_API_KEY}" \
    -d "${payload}"
}

cmd_close() {
  need_auth
  need_jq
  local symbol="${1:-}"
  local side="${2:-}"
  local quantity="${3:-0}"
  local reason="${4:-}"

  if [[ -z "${symbol}" || -z "${side}" || -z "${quantity}" || -z "${reason}" ]]; then
    echo '{"ok":false,"error":"usage: axiom.sh close SYMBOL SIDE QUANTITY REASON"}' >&2
    exit 2
  fi

  local payload
  payload=$(${JQ} -n \
    --arg trader_id "${AXIOM_TRADER_ID}" \
    --arg symbol "${symbol}" \
    --arg side "${side}" \
    --argjson quantity "${quantity}" \
    --arg reason "${reason}" \
    '{trader_id: $trader_id, symbol: $symbol, side: $side, quantity: $quantity, reason: $reason}')

  curl -sS -X POST "${AXIOM_URL}/api/v1/trade/close" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${AXIOM_API_KEY}" \
    -d "${payload}"
}

cmd_preflight() {
  need_jq
  local env_ok="true"
  if [[ -z "${AXIOM_TRADER_ID:-}" || -z "${AXIOM_API_KEY:-}" ]]; then
    env_ok="false"
  fi

  local symbols_code symbols_body screener_code screener_body account_code account_body positions_code positions_body

  {
    read -r symbols_code
    symbols_body=$(cat)
  } < <(curl_status "${AXIOM_URL}/api/symbols")

  {
    read -r screener_code
    screener_body=$(cat)
  } < <(curl_status "${AXIOM_URL}/api/screener?limit=20")

  if [[ "${env_ok}" == "true" ]]; then
    {
      read -r account_code
      account_body=$(cat)
    } < <(curl_status "${AXIOM_URL}/api/v1/trade/account?trader_id=${AXIOM_TRADER_ID}" -H "X-API-Key: ${AXIOM_API_KEY}")
    {
      read -r positions_code
      positions_body=$(cat)
    } < <(curl_status "${AXIOM_URL}/api/v1/trade/positions?trader_id=${AXIOM_TRADER_ID}" -H "X-API-Key: ${AXIOM_API_KEY}")
  else
    account_code="000"
    account_body='{"error":"missing auth env"}'
    positions_code="000"
    positions_body='{"error":"missing auth env"}'
  fi

  ${JQ} -n \
    --arg url "${AXIOM_URL}" \
    --argjson env_ok "${env_ok}" \
    --arg symbols_code "${symbols_code}" \
    --arg screener_code "${screener_code}" \
    --arg account_code "${account_code}" \
    --arg positions_code "${positions_code}" \
    --argjson symbols_body "$(printf '%s' "${symbols_body}" | ${JQ} -c 'try . catch {"parse_error":true}' 2>/dev/null || printf '{}')" \
    --argjson screener_body "$(printf '%s' "${screener_body}" | ${JQ} -c 'try . catch {"parse_error":true}' 2>/dev/null || printf '{}')" \
    '{
      ok: (($symbols_code == "200") and ($screener_code == "200") and ($account_code == "200") and ($positions_code == "200")),
      env_ok: $env_ok,
      url: $url,
      symbols: {
        ok: ($symbols_code == "200"),
        status: ($symbols_code | tonumber? // 0),
        count: (if ($symbols_body | type) == "array" then ($symbols_body | length) elif (($symbols_body.data? | type) == "array") then ($symbols_body.data | length) else 0 end),
        sample: (if ($symbols_body | type) == "array" then $symbols_body[:12] elif (($symbols_body.data? | type) == "array") then $symbols_body.data[:12] else [] end)
      },
      screener: {
        ok: ($screener_code == "200"),
        status: ($screener_code | tonumber? // 0),
        sample: (if (($screener_body.data? | type) == "array") then $screener_body.data[:5] elif ($screener_body | type) == "array" then $screener_body[:5] else [] end)
      },
      account: { ok: ($account_code == "200"), status: ($account_code | tonumber? // 0) },
      positions: { ok: ($positions_code == "200"), status: ($positions_code | tonumber? // 0) }
    }'
}

capture_json() {
  local out_file="${1:?out_file required}"
  local label="${2:?label required}"
  shift 2
  local err_file
  err_file=$(mktemp)
  if "$@" >"${out_file}" 2>"${err_file}" && ${JQ} -e . "${out_file}" >/dev/null 2>&1; then
    rm -f "${err_file}"
    return
  fi

  ${JQ} -n \
    --arg ok "false" \
    --arg label "${label}" \
    --arg error "$(cat "${err_file}" 2>/dev/null | head -c 1000)" \
    '{ok: false, source: $label, error: $error}' >"${out_file}"
  rm -f "${err_file}"
}

bird_query_json() {
  local query="$1"
  if ! command -v bird >/dev/null 2>&1; then
    ${JQ} -n --arg query "${query}" '{query: $query, ok: false, error: "bird CLI not found"}'
    return
  fi

  local raw
  raw=$(bird search --json -n 5 "${query}" 2>&1) || {
    ${JQ} -n --arg query "${query}" --arg error "${raw}" '{query: $query, ok: false, error: $error}'
    return
  }

  printf '%s' "${raw}" | ${JQ} --arg query "${query}" '
    {
      query: $query,
      ok: true,
      results: (if type == "array" then
        [.[:5][] | {
          text: ((.text // "") | tostring | .[0:500]),
          createdAt: (.createdAt // ""),
          author: (.author.username // .author.name // ""),
          likeCount: (.likeCount // 0),
          retweetCount: (.retweetCount // 0)
        }]
      else [] end)
    }' 2>/dev/null || ${JQ} -n --arg query "${query}" '{query: $query, ok: false, error: "bird returned non-json"}'
}

cmd_scan_context() {
  local limit="${1:-20}"
  need_jq

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN

  capture_json "${tmpdir}/preflight.json" preflight cmd_preflight
  capture_json "${tmpdir}/account.json" account cmd_account
  capture_json "${tmpdir}/positions.json" positions cmd_positions
  capture_json "${tmpdir}/raw-screener.json" screener cmd_screener_raw "${limit}"
  capture_json "${tmpdir}/exchange-info.json" exchange_info fetch_exchange_info

  if ${JQ} -e '.symbols | type == "array"' "${tmpdir}/exchange-info.json" >/dev/null 2>&1; then
    filter_tradfi_screener "${tmpdir}/raw-screener.json" "${tmpdir}/exchange-info.json" >"${tmpdir}/screener.json"
    tradfi_exclusions "${tmpdir}/raw-screener.json" "${tmpdir}/exchange-info.json" >"${tmpdir}/tradfi-exclusions.json"
    ${JQ} -n \
      --argjson excluded_count "$(${JQ} 'length' "${tmpdir}/tradfi-exclusions.json")" \
      --slurpfile excluded "${tmpdir}/tradfi-exclusions.json" \
      '{ok: true, policy: "disabled_by_default", excluded_count: $excluded_count, excluded: $excluded[0]}' >"${tmpdir}/tradfi-filter.json"
  else
    ${JQ} -n '[]' >"${tmpdir}/screener.json"
    ${JQ} -n '{ok: false, policy: "fail_closed", error: "exchangeInfo unavailable; screener candidates suppressed to avoid TRADIFI_PERPETUAL bypass"}' >"${tmpdir}/tradfi-filter.json"
  fi

  {
    printf '%s\n' BTCUSDT ETHUSDT
    ${JQ} -r '.[]? | .symbol // empty' "${tmpdir}/screener.json" 2>/dev/null | head -5
    ${JQ} -r '.. | objects | .symbol? // empty' "${tmpdir}/positions.json" 2>/dev/null
  } | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++' | head -8 >"${tmpdir}/symbols.txt"

  printf '[' >"${tmpdir}/markets.json"
  local first=1 symbol
  while IFS= read -r symbol; do
    local market_file="${tmpdir}/market-${symbol}.json"
    capture_json "${market_file}" "market:${symbol}" cmd_market "${symbol}"
    if [[ "${first}" -eq 0 ]]; then
      printf ',' >>"${tmpdir}/markets.json"
    fi
    first=0
    cat "${market_file}" >>"${tmpdir}/markets.json"
  done <"${tmpdir}/symbols.txt"
  printf ']' >>"${tmpdir}/markets.json"

  sed 's/USDT$//' "${tmpdir}/symbols.txt" \
    | awk '{print $0 " crypto token market news catalyst Binance futures"}' \
    | head -8 >"${tmpdir}/queries.txt"

  printf '[' >"${tmpdir}/bird.json"
  first=1
  local query
  while IFS= read -r query; do
    if [[ "${first}" -eq 0 ]]; then
      printf ',' >>"${tmpdir}/bird.json"
    fi
    first=0
    bird_query_json "${query}" >>"${tmpdir}/bird.json"
  done <"${tmpdir}/queries.txt"
  printf ']' >>"${tmpdir}/bird.json"

  ${JQ} -n \
    --slurpfile preflight "${tmpdir}/preflight.json" \
    --slurpfile account "${tmpdir}/account.json" \
    --slurpfile positions "${tmpdir}/positions.json" \
    --slurpfile screener "${tmpdir}/screener.json" \
    --slurpfile tradfi_filter "${tmpdir}/tradfi-filter.json" \
    --slurpfile markets "${tmpdir}/markets.json" \
    --slurpfile bird "${tmpdir}/bird.json" \
    '{
      preflight: $preflight[0],
      account: $account[0],
      positions: $positions[0],
      screener: $screener[0],
      tradfi_filter: $tradfi_filter[0],
      market_summaries: $markets[0],
      bird_queries: $bird[0]
    }'
}

case "${ACTION}" in
  preflight) cmd_preflight ;;
  symbols) cmd_symbols "$@" ;;
  screener) cmd_screener "$@" ;;
  klines) cmd_klines "$@" ;;
  market) cmd_market "$@" ;;
  regime) cmd_regime "$@" ;;
  scan-context) cmd_scan_context "$@" ;;
  account) cmd_account ;;
  positions) cmd_positions ;;
  execute) cmd_execute "$@" ;;
  close) cmd_close "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "{\"error\":\"unknown command: ${ACTION}\"}" >&2; exit 1 ;;
esac

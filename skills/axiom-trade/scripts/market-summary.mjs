#!/usr/bin/env node

const [baseUrlRaw, symbolRaw, modeRaw] = process.argv.slice(2);
const baseUrl = (baseUrlRaw || "http://localhost:8080").replace(/\/+$/, "");
const symbol = (symbolRaw || "").toUpperCase();
const mode = modeRaw || "market";

if (!symbol) {
  console.error(JSON.stringify({ ok: false, error: "symbol is required" }));
  process.exit(2);
}

const intervals = [
  ["5m", 120],
  ["15m", 120],
  ["1h", 120],
  ["4h", 180],
];

async function getJson(path) {
  const response = await fetch(`${baseUrl}${path}`);
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`non-json response from ${path}: ${text.slice(0, 160)}`);
  }
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} from ${path}: ${text.slice(0, 160)}`);
  }
  return Array.isArray(json?.data) ? json.data : json;
}

function number(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function round(value, digits = 6) {
  if (!Number.isFinite(value)) return 0;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function ema(values, period) {
  if (values.length < period) return null;
  const k = 2 / (period + 1);
  let current = values.slice(0, period).reduce((a, b) => a + b, 0) / period;
  for (let i = period; i < values.length; i += 1) {
    current = values[i] * k + current * (1 - k);
  }
  return current;
}

function rsi(values, period = 14) {
  if (values.length <= period) return null;
  let gain = 0;
  let loss = 0;
  for (let i = 1; i <= period; i += 1) {
    const delta = values[i] - values[i - 1];
    if (delta >= 0) gain += delta;
    else loss -= delta;
  }
  let avgGain = gain / period;
  let avgLoss = loss / period;
  for (let i = period + 1; i < values.length; i += 1) {
    const delta = values[i] - values[i - 1];
    avgGain = (avgGain * (period - 1) + Math.max(delta, 0)) / period;
    avgLoss = (avgLoss * (period - 1) + Math.max(-delta, 0)) / period;
  }
  if (avgLoss === 0) return 100;
  const rs = avgGain / avgLoss;
  return 100 - 100 / (1 + rs);
}

function atr(bars, period = 14) {
  if (bars.length <= period) return null;
  const trs = [];
  for (let i = 1; i < bars.length; i += 1) {
    const high = number(bars[i].high);
    const low = number(bars[i].low);
    const prevClose = number(bars[i - 1].close);
    trs.push(Math.max(high - low, Math.abs(high - prevClose), Math.abs(low - prevClose)));
  }
  let current = trs.slice(0, period).reduce((a, b) => a + b, 0) / period;
  for (let i = period; i < trs.length; i += 1) {
    current = (current * (period - 1) + trs[i]) / period;
  }
  return current;
}

function adx(bars, period = 14) {
  if (bars.length <= period * 2) return null;
  const trs = [];
  const plusDM = [];
  const minusDM = [];
  for (let i = 1; i < bars.length; i += 1) {
    const high = number(bars[i].high);
    const low = number(bars[i].low);
    const prevHigh = number(bars[i - 1].high);
    const prevLow = number(bars[i - 1].low);
    const prevClose = number(bars[i - 1].close);
    const upMove = high - prevHigh;
    const downMove = prevLow - low;
    trs.push(Math.max(high - low, Math.abs(high - prevClose), Math.abs(low - prevClose)));
    plusDM.push(upMove > downMove && upMove > 0 ? upMove : 0);
    minusDM.push(downMove > upMove && downMove > 0 ? downMove : 0);
  }

  let tr = trs.slice(0, period).reduce((a, b) => a + b, 0);
  let plus = plusDM.slice(0, period).reduce((a, b) => a + b, 0);
  let minus = minusDM.slice(0, period).reduce((a, b) => a + b, 0);
  const dxValues = [];
  for (let i = period; i < trs.length; i += 1) {
    tr = tr - tr / period + trs[i];
    plus = plus - plus / period + plusDM[i];
    minus = minus - minus / period + minusDM[i];
    const plusDI = tr === 0 ? 0 : (100 * plus) / tr;
    const minusDI = tr === 0 ? 0 : (100 * minus) / tr;
    const dx = plusDI + minusDI === 0 ? 0 : (100 * Math.abs(plusDI - minusDI)) / (plusDI + minusDI);
    dxValues.push(dx);
  }
  if (dxValues.length < period) return null;
  let current = dxValues.slice(0, period).reduce((a, b) => a + b, 0) / period;
  for (let i = period; i < dxValues.length; i += 1) {
    current = (current * (period - 1) + dxValues[i]) / period;
  }
  return current;
}

function boll(values, period = 20, mult = 2) {
  if (values.length < period) return null;
  const slice = values.slice(-period);
  const middle = slice.reduce((a, b) => a + b, 0) / period;
  const variance = slice.reduce((sum, v) => sum + (v - middle) ** 2, 0) / period;
  const stdev = Math.sqrt(variance);
  return { upper: middle + mult * stdev, middle, lower: middle - mult * stdev };
}

function changeFrom(values, barsBack) {
  if (values.length <= barsBack) return null;
  const current = values.at(-1);
  const previous = values[values.length - 1 - barsBack];
  return previous > 0 ? ((current - previous) / previous) * 100 : null;
}

function summarizeBars(rawBars, interval) {
  const bars = rawBars.map((bar) => ({
    openTime: number(bar.openTime),
    open: number(bar.open),
    high: number(bar.high),
    low: number(bar.low),
    close: number(bar.close),
    volume: number(bar.volume),
    quoteVolume: number(bar.quoteVolume),
    trades: number(bar.trades),
    takerBuyBaseVolume: number(bar.takerBuyBaseVolume),
    takerBuyQuoteVolume: number(bar.takerBuyQuoteVolume),
  }));
  const closes = bars.map((b) => b.close);
  const latest = bars.at(-1);
  const recent = bars.slice(-20);
  const recentQuoteVolume = recent.reduce((sum, b) => sum + b.quoteVolume, 0);
  const recentTakerBuyQuote = recent.reduce((sum, b) => sum + b.takerBuyQuoteVolume, 0);
  const high20 = Math.max(...recent.map((b) => b.high));
  const low20 = Math.min(...recent.map((b) => b.low));
  const band = boll(closes);
  const atr14 = atr(bars);
  const currentAdx = adx(bars);
  const intervalMinutes = { "1m": 1, "3m": 3, "5m": 5, "15m": 15, "30m": 30, "1h": 60, "4h": 240 }[
    interval
  ];
  const changePct = (minutes) => {
    if (!intervalMinutes || minutes < intervalMinutes || minutes % intervalMinutes !== 0)
      return null;
    return changeFrom(closes, minutes / intervalMinutes);
  };
  return {
    interval,
    candles: bars.length,
    latest_close: round(latest?.close ?? 0),
    change_pct_1h: changePct(60) == null ? null : round(changePct(60), 3),
    change_pct_4h: changePct(240) == null ? null : round(changePct(240), 3),
    ema20: round(ema(closes, 20) ?? 0),
    ema50: round(ema(closes, 50) ?? 0),
    rsi14: round(rsi(closes, 14) ?? 0, 2),
    atr14: round(atr14 ?? 0),
    atr14_pct: round(atr14 && latest?.close ? (atr14 / latest.close) * 100 : 0, 3),
    adx14: round(currentAdx ?? 0, 2),
    boll: band
      ? {
          upper: round(band.upper),
          middle: round(band.middle),
          lower: round(band.lower),
          position: round(
            (latest.close - band.lower) / Math.max(band.upper - band.lower, Number.EPSILON),
            3,
          ),
        }
      : null,
    high_20: round(high20),
    low_20: round(low20),
    range_position_20: round((latest.close - low20) / Math.max(high20 - low20, Number.EPSILON), 3),
    recent_quote_volume: round(recentQuoteVolume, 2),
    taker_buy_quote_ratio_20: round(
      recentQuoteVolume > 0 ? recentTakerBuyQuote / recentQuoteVolume : 0,
      3,
    ),
    latest: latest
      ? {
          open_time: latest.openTime,
          open: round(latest.open),
          high: round(latest.high),
          low: round(latest.low),
          close: round(latest.close),
          quote_volume: round(latest.quoteVolume, 2),
          trades: latest.trades,
          taker_buy_quote_ratio: round(
            latest.quoteVolume > 0 ? latest.takerBuyQuoteVolume / latest.quoteVolume : 0,
            3,
          ),
        }
      : null,
  };
}

function classifyRegime(summary) {
  const h4 = summary.timeframes["4h"];
  const h1 = summary.timeframes["1h"];
  const ref = h4 || h1;
  if (!ref) return { regime: "UNKNOWN", reason: "missing reference timeframe" };
  const sideOfEma50 = (frame) => {
    if (!frame || !frame.latest_close || !frame.ema50) return "unknown";
    if (frame.latest_close > frame.ema50) return "above";
    if (frame.latest_close < frame.ema50) return "below";
    return "at";
  };
  const h4Side = sideOfEma50(h4);
  const h1Side = sideOfEma50(h1);
  const h4Trending = h4 && h4.adx14 > 20;
  const h1Trending = h1 && h1.adx14 > 20;
  if (h4Trending && h1Trending) {
    if (h4Side === "above" && h1Side === "above") {
      return {
        regime: "TREND_UP",
        reason: "4h and 1h ADX > 20 with price above EMA50 on both frames",
      };
    }
    if (h4Side === "below" && h1Side === "below") {
      return {
        regime: "TREND_DOWN",
        reason: "4h and 1h ADX > 20 with price below EMA50 on both frames",
      };
    }
    return {
      regime: "MIXED",
      reason: `4h/1h trend conflict: 4h price ${h4Side} EMA50, 1h price ${h1Side} EMA50`,
    };
  }
  const price = ref.latest_close;
  if (ref.adx14 > 20) {
    if (price > ref.ema50) {
      return { regime: "TREND_UP", reason: `${ref.interval} ADX > 20 and price above EMA50` };
    }
    return { regime: "TREND_DOWN", reason: `${ref.interval} ADX > 20 and price below EMA50` };
  }
  if (ref.range_position_20 >= 0.99) {
    return { regime: "TREND_UP", reason: "price near recent range high" };
  }
  if (ref.range_position_20 <= 0.01) {
    return { regime: "TREND_DOWN", reason: "price near recent range low" };
  }
  if (ref.adx14 >= 15) {
    if (price > ref.ema20 && ref.ema20 > ref.ema50) {
      return { regime: "TREND_UP", reason: "weak ADX with bullish EMA alignment" };
    }
    if (price < ref.ema20 && ref.ema20 < ref.ema50) {
      return { regime: "TREND_DOWN", reason: "weak ADX with bearish EMA alignment" };
    }
  }
  return { regime: "MEAN_REVERSION", reason: "trend confirmation absent" };
}

try {
  const [screener, ...timeframeResults] = await Promise.all([
    getJson(`/api/screener?limit=30`),
    ...intervals.map(([interval, limit]) =>
      getJson(
        `/api/klines?symbol=${encodeURIComponent(symbol)}&interval=${interval}&limit=${limit}`,
      ),
    ),
  ]);

  const timeframes = {};
  intervals.forEach(([interval], index) => {
    timeframes[interval] = summarizeBars(timeframeResults[index], interval);
  });

  const screenerItem = Array.isArray(screener)
    ? screener.find((item) => String(item.symbol || "").toUpperCase() === symbol) || null
    : null;
  const summary = {
    ok: true,
    symbol,
    source: "axiom_public_api",
    generated_at: new Date().toISOString(),
    screener: screenerItem,
    timeframes,
  };
  summary.regime = classifyRegime(summary);

  if (mode === "regime") {
    console.log(
      JSON.stringify(
        {
          ok: true,
          symbol,
          regime: summary.regime,
          reference: summary.timeframes["4h"] || summary.timeframes["1h"],
        },
        null,
        2,
      ),
    );
  } else {
    console.log(JSON.stringify(summary, null, 2));
  }
} catch (error) {
  console.error(JSON.stringify({ ok: false, symbol, error: error.message }, null, 2));
  process.exit(1);
}

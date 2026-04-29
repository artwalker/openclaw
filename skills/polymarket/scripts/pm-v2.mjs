#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { ApiError, AssetType, Chain, ClobClient, OrderType, Side, SignatureTypeV2 } from "@polymarket/clob-client-v2";
import { createPublicClient, createWalletClient, formatUnits, http, parseAbi } from "viem";
import { polygon } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const host = process.env.PM_CLOB_HOST || "https://clob.polymarket.com";
const rpcUrl = process.env.POLYGON_RPC_URL || process.env.PM_POLYGON_RPC_URL || "https://polygon-rpc.com";
const readRpcUrls = (process.env.PM_POLYGON_READ_RPC_URLS || process.env.POLYGON_READ_RPC_URLS || [
  rpcUrl,
  "https://polygon-bor-rpc.publicnode.com",
  "https://polygon.llamarpc.com",
  "https://rpc.ankr.com/polygon",
].join(",")).split(",").map((value) => value.trim()).filter(Boolean);
const configPath = process.env.PM_CONFIG || `${process.env.HOME || "/root"}/.config/polymarket/config.json`;
const command = process.argv[2] || "";
const args = process.argv.slice(3);
const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const tokens = {
  usdce: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
  pusd: "0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB",
};

function print(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function fail(message, extra = {}, code = 1) {
  print({ error: message, ...extra });
  process.exit(code);
}

function loadConfig() {
  try {
    return JSON.parse(readFileSync(configPath, "utf8"));
  } catch {
    return {};
  }
}

function normalizePrivateKey(value) {
  if (!value || typeof value !== "string") return "";
  return value.startsWith("0x") ? value : `0x${value}`;
}

function signatureType(value) {
  const normalized = String(value || "proxy").toLowerCase();
  if (normalized === "eoa") return SignatureTypeV2.EOA;
  if (normalized === "gnosis-safe" || normalized === "gnosis_safe") return SignatureTypeV2.POLY_GNOSIS_SAFE;
  if (normalized === "1271" || normalized === "poly_1271") return SignatureTypeV2.POLY_1271;
  return SignatureTypeV2.POLY_PROXY;
}

function side(value) {
  const normalized = String(value || "").toLowerCase();
  if (normalized === "buy") return Side.BUY;
  if (normalized === "sell") return Side.SELL;
  fail("side must be buy or sell", { side: value }, 2);
}

async function client({ auth = false } = {}) {
  const config = loadConfig();
  const privateKey = normalizePrivateKey(process.env.PM_PRIVATE_KEY || config.private_key);
  if (!privateKey) {
    if (auth) fail("wallet private key not configured", { config_path: configPath }, 4);
    return new ClobClient({ host, chain: Chain.POLYGON, throwOnError: true });
  }

  const account = privateKeyToAccount(privateKey);
  const walletClient = createWalletClient({ account, transport: http(rpcUrl) });
  const funderAddress = process.env.PM_FUNDER || process.env.PM_PROXY_ADDRESS || config.proxy_address || undefined;
  const base = {
    host,
    chain: Chain.POLYGON,
    signer: walletClient,
    signatureType: signatureType(process.env.PM_SIGNATURE_TYPE || config.signature_type),
    funderAddress,
    throwOnError: true,
  };

  if (!auth) return new ClobClient(base);
  const l1 = new ClobClient(base);
  // The production account already has an API key. Deriving avoids a failing
  // create request and prevents noisy SDK error logging in cron output.
  const creds = await l1.deriveApiKey();
  return new ClobClient({ ...base, creds });
}

async function readTokenBalances(addresses) {
  let lastError;
  for (const url of readRpcUrls) {
    try {
      const publicClient = createPublicClient({ chain: polygon, transport: http(url) });
      const result = {};
      for (const [label, address] of Object.entries(addresses)) {
        if (!address) continue;
        result[label] = {};
        for (const [symbol, token] of Object.entries(tokens)) {
          const balance = await publicClient.readContract({
            address: token,
            abi: erc20Abi,
            functionName: "balanceOf",
            args: [address],
          });
          result[label][symbol] = formatUnits(balance, 6);
        }
      }
      return result;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

async function main() {
  try {
    if (command === "ok") {
      print(await (await client()).getOk());
      return;
    }
    if (command === "time") {
      print({ timestamp: await (await client()).getServerTime() });
      return;
    }
    if (command === "balance" || command === "allowance") {
      print(await (await client({ auth: true })).getBalanceAllowance({ asset_type: AssetType.COLLATERAL }));
      return;
    }
    if (command === "wallet-balances") {
      const config = loadConfig();
      const privateKey = normalizePrivateKey(process.env.PM_PRIVATE_KEY || config.private_key);
      const signer = privateKey ? privateKeyToAccount(privateKey).address : config.address;
      const funder = process.env.PM_FUNDER || process.env.PM_PROXY_ADDRESS || config.proxy_address || undefined;
      print(await readTokenBalances({ signer, proxy: funder }));
      return;
    }
    if (command === "refresh-balance") {
      await (await client({ auth: true })).updateBalanceAllowance({ asset_type: AssetType.COLLATERAL });
      print({ success: true });
      return;
    }
    if (command === "orders") {
      print(await (await client({ auth: true })).getOpenOrders());
      return;
    }
    if (command === "trades") {
      print(await (await client({ auth: true })).getTrades({}, true));
      return;
    }
    if (command === "market") {
      const [tokenID, rawSide, rawAmount, rawOrderType = "FOK"] = args;
      if (!tokenID || !rawSide || !rawAmount) fail("usage: pm-v2.mjs market <token> <buy|sell> <amount> [FOK|FAK]", {}, 2);
      const orderType = String(rawOrderType).toUpperCase() === "FAK" ? OrderType.FAK : OrderType.FOK;
      const amount = Number(rawAmount);
      if (!Number.isFinite(amount) || amount <= 0) fail("amount must be a positive number", { amount: rawAmount }, 2);
      print(await (await client({ auth: true })).createAndPostMarketOrder(
        { tokenID, side: side(rawSide), amount, orderType },
        {},
        orderType,
      ));
      return;
    }
    if (command === "limit") {
      const [tokenID, rawSide, rawPrice, rawSize, rawOrderType = "GTC"] = args;
      if (!tokenID || !rawSide || !rawPrice || !rawSize) fail("usage: pm-v2.mjs limit <token> <buy|sell> <price> <size> [GTC|GTD]", {}, 2);
      const price = Number(rawPrice);
      const size = Number(rawSize);
      if (!Number.isFinite(price) || price <= 0 || price >= 1) fail("price must be between 0 and 1", { price: rawPrice }, 2);
      if (!Number.isFinite(size) || size <= 0) fail("size must be a positive number", { size: rawSize }, 2);
      const orderType = String(rawOrderType).toUpperCase() === "GTD" ? OrderType.GTD : OrderType.GTC;
      print(await (await client({ auth: true })).createAndPostOrder(
        { tokenID, side: side(rawSide), price, size },
        {},
        orderType,
      ));
      return;
    }
    if (command === "cancel") {
      const [orderID] = args;
      if (!orderID) fail("usage: pm-v2.mjs cancel <order_id>", {}, 2);
      print(await (await client({ auth: true })).cancelOrder({ orderID }));
      return;
    }
    fail(`unknown command: ${command}`, {
      commands: ["ok", "time", "balance", "allowance", "wallet-balances", "refresh-balance", "orders", "trades", "market", "limit", "cancel"],
    }, 2);
  } catch (error) {
    if (error instanceof ApiError) {
      fail(error.message, { status: error.status, data: error.data }, 1);
    }
    fail(error?.message || String(error), {}, 1);
  }
}

await main();

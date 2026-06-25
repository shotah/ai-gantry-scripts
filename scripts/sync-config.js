#!/usr/bin/env node
'use strict';

/**
 * Merge selected .env values into data/openclaw.json.
 * Runs on the host (reads .env from repo root) or inside the container (env from compose).
 */

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const hostConfig = path.join(repoRoot, 'data', 'openclaw.json');
const hostEnv = path.join(repoRoot, '.env');
const containerConfig = path.join('/home/node/.openclaw', 'openclaw.json');

function loadDotEnv(envPath) {
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = val;
  }
}

function resolveConfigPath() {
  if (fs.existsSync(hostConfig)) {
    loadDotEnv(hostEnv);
    return hostConfig;
  }
  if (fs.existsSync(containerConfig)) return containerConfig;
  return hostConfig;
}

function parseList(value) {
  if (!value || !String(value).trim()) return null;
  return String(value)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function ensurePath(obj, keys) {
  let cur = obj;
  for (let i = 0; i < keys.length - 1; i++) {
    if (cur[keys[i]] === undefined || typeof cur[keys[i]] !== 'object') {
      cur[keys[i]] = {};
    }
    cur = cur[keys[i]];
  }
  return cur;
}

function setPath(obj, keys, value) {
  const parent = ensurePath(obj, keys);
  parent[keys[keys.length - 1]] = value;
}

function main() {
  const configPath = resolveConfigPath();

  if (!fs.existsSync(configPath)) {
    console.error(`Missing ${configPath}`);
    console.error('Run: make onboard');
    process.exit(1);
  }

  const raw = fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '');
  const config = JSON.parse(raw);
  const updates = [];

  const allowFrom = parseList(process.env.WHATSAPP_ALLOW_FROM);
  if (allowFrom?.length) {
    setPath(config, ['channels', 'whatsapp', 'allowFrom'], allowFrom);
    updates.push(`channels.whatsapp.allowFrom = [${allowFrom.join(', ')}]`);
  }

  const whatsappEnabled = process.env.WHATSAPP_ENABLED?.trim().toLowerCase();
  if (whatsappEnabled === 'false' || whatsappEnabled === '0') {
    setPath(config, ['channels', 'whatsapp', 'enabled'], false);
    updates.push('channels.whatsapp.enabled = false');
  } else if (whatsappEnabled === 'true' || whatsappEnabled === '1') {
    setPath(config, ['channels', 'whatsapp', 'enabled'], true);
    updates.push('channels.whatsapp.enabled = true');
  }

  const model = process.env.OPENCLAW_MODEL?.trim();
  if (model) {
    setPath(config, ['agents', 'defaults', 'model', 'primary'], model);
    updates.push(`agents.defaults.model.primary = ${model}`);
  }

  const tz = process.env.TZ?.trim();
  if (tz) {
    if (!config.agents) config.agents = {};
    if (!config.agents.defaults) config.agents.defaults = {};
    config.agents.defaults.timezone = tz;
    updates.push(`agents.defaults.timezone = ${tz}`);
  }

  if (updates.length === 0) {
    console.log('No .env values to sync (set WHATSAPP_ALLOW_FROM, OPENCLAW_MODEL, or TZ)');
    return;
  }

  fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
  console.log(`Synced ${configPath}:`);
  for (const line of updates) console.log(`  ${line}`);
}

main();

#!/usr/bin/env node
/**
 * Validate every MCP tool-name mention in plugin content against the tool manifest.
 *
 * Skills, rules, agents, and commands are read by models connected to the Control Plane
 * MCP on ANY toolset profile (core ⊂ mk8s ⊂ full, core is the default), so:
 *
 *   1. A mentioned tool must EXIST in the registry — a stale name (a tool that was removed
 *      or renamed) sends the model into a guaranteed-failing call.
 *   2. A tool beyond the core tier must be marked on the line with how to reach it
 *      (`?toolsets=full` / `?toolsets=mk8s`) or the file must carry a "**Tool availability:**"
 *      note, so a core-profile reader knows to ask the user to reconnect instead of improvising.
 *      A `name_*` wildcard mentions its whole family and takes the family's highest tier.
 *   3. `cpln_api_request` is registered only when its kill switch is on, so every mention
 *      needs an availability hedge ("disabled by default", "only when advertised", …).
 *
 * Deliberate "this tool does not exist" prose is fine: lines matching the negation
 * patterns (e.g. "There is no `create_user`") are exempt from the existence check.
 *
 * The `readonly` profile sits outside this tier ladder — it withholds every write tool, so
 * markers would have to sit on nearly every mention. Content covers it in prose instead: the
 * guardrails define it, and availability notes name the tools that survive on it.
 *
 * The manifest is generated from the MCP server's tool registry — regenerate it there after tool changes.
 *
 * Usage: node scripts/check-tool-mentions.mjs   (exit 1 on any violation)
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const PLUGIN = path.join(ROOT, 'plugins', 'cpln');

const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'scripts', 'tools-manifest.json'), 'utf8')).tools;
const TIER = { core: 1, mk8s: 2, full: 3, conditional: 4 };

const TOKEN_RE = /\b(?:mcp__cpln__)?([a-z][a-z0-9]*(?:_[a-z0-9]+)+)(?:(_\*)|\b)/g;
const VERB_PREFIXES = new Set([
  'list', 'get', 'create', 'update', 'delete', 'query', 'reveal', 'export', 'convert', 'install', 'build', 'write',
  'uninstall', 'upgrade', 'rollback', 'browse', 'mount', 'configure', 'search', 'preview', 'set',
  'add', 'remove', 'patch', 'stop', 'restart', 'scale', 'clone', 'deploy', 'run',
  'apply', 'validate', 'describe', 'fetch', 'grant', 'revoke', 'attach', 'detach',
]);
// Snake_case non-tool tokens that share a verb prefix (Prometheus endpoints, spec fields, …).
const NOT_TOOLS = new Set(['query_range', 'start_period']);

const FULL_MARKER_RE = /toolsets=full/;
const MK8S_MARKER_RE = /toolsets=(?:mk8s|full)/;
const API_REQUEST_HEDGE_RE = /disabled by default|only when advertised|if advertised|when advertised|kill switch|if enabled|when enabled/i;
const NEGATION_RE = /no `|there is no |no create- or update-/i;
const FILE_NOTE_RE = /\*\*Tool availability:\*\*/;

const offenders = [];

// The tiers a mention names: the tool itself, or every tool in a `name_*` family.
function tiersNamedBy(token, isWildcard) {
  if (!isWildcard) return manifest[token] ? [manifest[token]] : [];
  return Object.keys(manifest).filter((name) => name.startsWith(`${token}_`)).map((name) => manifest[name]);
}

function checkFile(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const fileHasNote = FILE_NOTE_RE.test(text);
  const rel = path.relative(ROOT, filePath);

  text.split('\n').forEach((line, index) => {
    const where = `${rel}:${index + 1}`;

    for (const match of line.matchAll(TOKEN_RE)) {
      const token = match[1];
      if (NOT_TOOLS.has(token)) continue;

      const tiers = tiersNamedBy(token, match[2] !== undefined);

      if (tiers.length === 0) {
        const looksLikeTool = match[0].startsWith('mcp__cpln__') || VERB_PREFIXES.has(token.split('_')[0]);
        if (looksLikeTool && !NEGATION_RE.test(line)) {
          offenders.push(`${where}: unknown tool "${match[0]}" — ${line.trim().slice(0, 120)}`);
        }
        continue;
      }

      const tier = tiers.reduce((highest, candidate) => (TIER[candidate] > TIER[highest] ? candidate : highest));

      if (tier === 'conditional') {
        if (!API_REQUEST_HEDGE_RE.test(line)) {
          offenders.push(`${where}: "${token}" is registered only when its kill switch is on — add an availability hedge — ${line.trim().slice(0, 120)}`);
        }
        continue;
      }

      if (TIER[tier] <= TIER.core || fileHasNote) continue;

      const marker = tier === 'full' ? FULL_MARKER_RE : MK8S_MARKER_RE;
      if (!marker.test(line)) {
        offenders.push(`${where}: "${token}" (${tier} profile) mentioned without a ?toolsets= marker or a file-level "**Tool availability:**" note — ${line.trim().slice(0, 120)}`);
      }
    }
  });
}

function* walk(dir, exts) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full, exts);
    else if (exts.some((ext) => entry.name.endsWith(ext))) yield full;
  }
}

// Source content lives under plugins/cpln/. Scan skills, rules, agents, and
// commands for MCP tool mentions.
for (const dir of ['skills', 'rules', 'agents', 'commands']) {
  const full = path.join(PLUGIN, dir);
  if (fs.existsSync(full)) for (const file of walk(full, ['.md'])) checkFile(file);
}

// knowledge-map toolSkills keys are injected into tool descriptions ("recommended reading")
// by the MCP server — a stale key is dead steering, and an unknown skill value points at a
// runbook that get_cpln_skill cannot serve.
const knowledgeMap = JSON.parse(fs.readFileSync(path.join(PLUGIN, 'knowledge-map.json'), 'utf8'));
const knownSkills = new Set(Object.keys(knowledgeMap.skills ?? {}));
for (const [key, skill] of Object.entries(knowledgeMap.toolSkills ?? {})) {
  if (!manifest[key]) {
    offenders.push(`plugins/cpln/knowledge-map.json: toolSkills key "${key}" is not a registered MCP tool`);
  }

  if (!knownSkills.has(skill)) {
    offenders.push(`plugins/cpln/knowledge-map.json: toolSkills["${key}"] points at unknown skill "${skill}"`);
  }
}

if (offenders.length > 0) {
  console.error(`✗ ${offenders.length} tool-mention violation(s):\n`);
  for (const offender of offenders) console.error(`  ${offender}`);
  console.error('\nFix the mention, add a ?toolsets= marker / "**Tool availability:**" note, or regenerate scripts/tools-manifest.json if the registry changed.');
  process.exit(1);
}

console.log('✓ all tool mentions exist and respect toolset-profile visibility');

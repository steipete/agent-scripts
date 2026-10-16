#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { adminMembership } from "./admin-membership.mjs";

function fail(message) {
  process.stderr.write(`fleet-profile: ${message}\n`);
  process.exit(2);
}

function run(command, args = [], options = {}) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    }).trim();
  } catch {
    return "";
  }
}

function lines(value) {
  return value.split(/\r?\n/).map((entry) => entry.trim()).filter(Boolean);
}

function uniqueSorted(values) {
  return [...new Set(values.filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

function packageKeys(values) {
  const keys = new Set();
  for (const value of values) {
    keys.add(value);
    keys.add(value.split("/").at(-1));
  }
  return keys;
}

function findExecutable(names) {
  for (const name of names) {
    if (name.includes("/") && fs.existsSync(name)) return name;
    const located = run("/usr/bin/which", [name]);
    if (located) return located;
  }
  return null;
}

function jsonCommand(command, args, fallback, options = {}) {
  const output = run(command, args, options);
  if (!output) return fallback;
  try {
    return JSON.parse(output);
  } catch {
    return fallback;
  }
}

function plistValue(plist, key) {
  return run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist]);
}

function collectApps() {
  const roots = ["/Applications", path.join(os.homedir(), "Applications")];
  const apps = [];

  function walk(directory, depth) {
    if (depth < 0 || !fs.existsSync(directory)) return;
    let entries = [];
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const candidate = path.join(directory, entry.name);
      if (entry.name.endsWith(".app")) {
        const plist = path.join(candidate, "Contents", "Info.plist");
        apps.push({
          name: entry.name.replace(/\.app$/, ""),
          bundle_id: fs.existsSync(plist) ? plistValue(plist, "CFBundleIdentifier") || null : null,
          version: fs.existsSync(plist)
            ? plistValue(plist, "CFBundleShortVersionString") || plistValue(plist, "CFBundleVersion") || null
            : null,
          path: candidate,
        });
        continue;
      }
      walk(candidate, depth - 1);
    }
  }

  for (const root of roots) walk(root, 2);
  const seen = new Set();
  return apps
    .sort((a, b) => a.name.localeCompare(b.name))
    .filter((app) => {
      const key = app.bundle_id || app.path;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function collectAccounts() {
  const raw = lines(run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"]));
  const accounts = [];
  const fileVaultResult = spawnSync("/usr/bin/fdesetup", ["list"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const fileVaultListReadable = fileVaultResult.status === 0;
  const fileVaultUsers = new Set(
    lines(fileVaultResult.stdout || "")
      .map((entry) => entry.split(",", 1)[0])
      .filter(Boolean),
  );
  for (const row of raw) {
    const match = row.match(/^(.*?)\s+(\d+)$/);
    if (!match || Number(match[2]) < 500) continue;
    const username = match[1];
    const adminResult = spawnSync("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", username, "admin"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const admin = adminMembership(adminResult);
    const tokenResult = spawnSync("/usr/sbin/sysadminctl", ["-secureTokenStatus", username], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const tokenCheck = `${tokenResult.stdout || ""}\n${tokenResult.stderr || ""}`;
    accounts.push({
      username,
      uid: Number(match[2]),
      admin,
      filevault_unlock: fileVaultListReadable ? fileVaultUsers.has(username) : null,
      secure_token: /enabled/i.test(tokenCheck) ? "enabled" : /disabled/i.test(tokenCheck) ? "disabled" : "unknown",
    });
  }
  return accounts.sort((a, b) => a.uid - b.uid);
}

function collectHomebrew() {
  const brew = findExecutable(["brew", "/opt/homebrew/bin/brew", "/usr/local/bin/brew"]);
  if (!brew) return { present: false };
  const env = { ...process.env, HOMEBREW_NO_AUTO_UPDATE: "1" };
  const outdated = jsonCommand(brew, ["outdated", "--json=v2"], { formulae: [], casks: [] }, { env });
  const services = jsonCommand(brew, ["services", "list", "--json"], [], { env });
  return {
    present: true,
    executable: brew,
    prefix: run(brew, ["--prefix"], { env }),
    version: lines(run(brew, ["--version"], { env }))[0] || null,
    taps: uniqueSorted(lines(run(brew, ["tap"], { env }))),
    formulae: uniqueSorted(lines(run(brew, ["list", "--formula"], { env }))),
    formulae_top_level: uniqueSorted(lines(run(brew, ["leaves"], { env }))),
    casks: uniqueSorted(lines(run(brew, ["list", "--cask"], { env }))),
    outdated_formulae: uniqueSorted((outdated.formulae || []).map((item) => item.name)),
    outdated_casks: uniqueSorted((outdated.casks || []).map((item) => item.name)),
    services,
  };
}

function collectMas() {
  const mas = findExecutable(["mas", "/opt/homebrew/bin/mas", "/usr/local/bin/mas"]);
  if (!mas) return { present: false, apps: [], outdated: [] };
  const parse = (text) => lines(text).map((row) => {
    const match = row.match(/^(\d+)\s+(.+?)\s+\(([^)]+)\)$/);
    return match ? { id: Number(match[1]), name: match[2].trim(), version: match[3] } : null;
  }).filter(Boolean);
  return {
    present: true,
    apps: parse(run(mas, ["list"])),
    outdated: parse(run(mas, ["outdated"])),
  };
}

function collectNpm() {
  const npm = findExecutable(["npm"]);
  if (!npm) return { present: false, packages: [] };
  const listing = jsonCommand(npm, ["ls", "-g", "--depth=0", "--json"], {});
  const packages = Object.entries(listing.dependencies || {}).map(([name, metadata]) => ({
    name,
    version: metadata.version || null,
  })).sort((a, b) => a.name.localeCompare(b.name));
  return { present: true, executable: npm, packages };
}

function collectTools() {
  const names = [
    "birdclaw",
    "camsnap",
    "claude",
    "codex",
    "discrawl",
    "gh",
    "git",
    "gitcrawl",
    "graincrawl",
    "node",
    "notcrawl",
    "openclaw",
    "op",
    "peekaboo",
    "pnpm",
    "slacrawl",
    "telecrawl",
    "tmux",
    "wacrawl",
  ];
  return names.map((name) => {
    const executable = findExecutable([
      name,
      path.join(os.homedir(), "bin", name),
      path.join("/opt/homebrew/bin", name),
      path.join("/usr/local/bin", name),
    ]);
    const tool = { name, executable };
    if (name === "camsnap" && executable) {
      tool.version = lines(run(executable, ["--version"]))[0] || null;
      tool.sha256 = run("/usr/bin/shasum", ["-a", "256", executable]).split(/\s+/)[0] || null;
    }
    return tool;
  });
}

function collectClaudeAttribution() {
  const settingsFile = path.join(os.homedir(), ".claude", "settings.json");
  if (!fs.existsSync(settingsFile)) {
    return { configured: false, state: "missing" };
  }
  try {
    const settings = JSON.parse(fs.readFileSync(settingsFile, "utf8"));
    const attribution = settings?.attribution;
    const commitDisabled = attribution?.commit === "";
    const prDisabled = attribution?.pr === "";
    const sessionUrlDisabled = attribution?.sessionUrl === false;
    return {
      configured: commitDisabled && prDisabled && sessionUrlDisabled,
      state: "valid",
      commit: commitDisabled ? "disabled" : "enabled",
      pr: prDisabled ? "disabled" : "enabled",
      session_url: sessionUrlDisabled ? "disabled" : "enabled",
    };
  } catch {
    return { configured: false, state: "invalid" };
  }
}

function collect() {
  const hardware = run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]);
  const uuid = hardware.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/)?.[1] || null;
  const localHostName = run("/usr/sbin/scutil", ["--get", "LocalHostName"]);
  const productVersion = run("/usr/bin/sw_vers", ["-productVersion"]);
  const buildVersion = run("/usr/bin/sw_vers", ["-buildVersion"]);
  const fileVaultStatus = run("/usr/bin/fdesetup", ["status"]);
  const gitSigningFormat = run("/usr/bin/git", ["config", "--global", "gpg.format"]);
  const gitSigningKey = run("/usr/bin/git", ["config", "--global", "user.signingkey"]);
  const gitCommitSigning = run("/usr/bin/git", ["config", "--global", "commit.gpgsign"]);
  return {
    schema_version: 1,
    collected_at: new Date().toISOString(),
    host: {
      hostname: os.hostname(),
      local_host_name: localHostName || null,
      hardware_uuid: uuid,
      architecture: os.arch(),
      macos_version: productVersion || null,
      macos_build: buildVersion || null,
    },
    accounts: collectAccounts(),
    homebrew: collectHomebrew(),
    mas: collectMas(),
    npm: collectNpm(),
    tools: collectTools(),
    security: {
      filevault: /is on/i.test(fileVaultStatus) ? "on" : /is off/i.test(fileVaultStatus) ? "off" : "unknown",
    },
    configuration: {
      claude_attribution: collectClaudeAttribution(),
      git_signing: {
        configured: gitSigningFormat === "ssh" && Boolean(gitSigningKey) && /^(true|yes|on|1)$/i.test(gitCommitSigning),
        format: gitSigningFormat || null,
        commit_signing: /^(true|yes|on|1)$/i.test(gitCommitSigning),
        signing_key_configured: Boolean(gitSigningKey),
      },
    },
    apps: collectApps(),
  };
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`cannot read JSON ${file}: ${error.message}`);
  }
}

function option(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1] || fallback;
}

function markdownList(title, values) {
  process.stdout.write(`\n## ${title} (${values.length})\n\n`);
  if (!values.length) {
    process.stdout.write("None.\n");
    return;
  }
  for (const value of values) process.stdout.write(`- ${value}\n`);
}

function diffSnapshots(source, target) {
  const missing = (sourceValues, targetValues, normalizePackages = false) => {
    const targetSet = normalizePackages ? packageKeys(targetValues) : new Set(targetValues);
    return uniqueSorted(sourceValues.filter((value) => {
      if (targetSet.has(value)) return false;
      return normalizePackages ? !targetSet.has(value.split("/").at(-1)) : true;
    }));
  };
  const sourceMas = new Map((source.mas?.apps || []).map((app) => [String(app.id), app]));
  const targetMas = new Set((target.mas?.apps || []).map((app) => String(app.id)));
  const sourceApps = new Map((source.apps || []).map((app) => [app.bundle_id || `name:${app.name}`, app]));
  const targetApps = new Set((target.apps || []).map((app) => app.bundle_id || `name:${app.name}`));
  const sourceNpm = (source.npm?.packages || []).map((pkg) => pkg.name).filter((name) => name !== "npm");
  const targetNpm = (target.npm?.packages || []).map((pkg) => pkg.name);

  return {
    brew_formulae: missing(source.homebrew?.formulae_top_level || [], target.homebrew?.formulae || [], true),
    brew_casks: missing(source.homebrew?.casks || [], target.homebrew?.casks || []),
    mas: [...sourceMas.entries()].filter(([id]) => !targetMas.has(id)).map(([, app]) => `${app.name} (${app.id})`),
    npm: missing(sourceNpm, targetNpm),
    apps: [...sourceApps.entries()]
      .filter(([key]) => !targetApps.has(key))
      .map(([, app]) => `${app.name}${app.bundle_id ? ` (${app.bundle_id})` : ""}`)
      .sort(),
    target_outdated: uniqueSorted([
      ...(target.homebrew?.outdated_formulae || []).map((name) => `brew: ${name}`),
      ...(target.homebrew?.outdated_casks || []).map((name) => `cask: ${name}`),
      ...(target.mas?.outdated || []).map((app) => `mas: ${app.name} (${app.id})`),
    ]),
  };
}

function resolveProfile(inventory, hostId) {
  const host = inventory.hosts?.[hostId];
  if (!host) fail(`unknown host id: ${hostId}`);
  const profile = inventory.profiles?.[host.profile];
  if (!profile) fail(`host ${hostId} references unknown profile ${host.profile}`);
  return { host, profile };
}

function planProfile(inventory, hostId, snapshot) {
  const { profile } = resolveProfile(inventory, hostId);
  const managed = profile.managed || {};
  const brew = managed.homebrew || {};
  const installedFormulae = packageKeys(snapshot.homebrew?.formulae || []);
  const installedCasks = new Set(snapshot.homebrew?.casks || []);
  const installedTaps = new Set(snapshot.homebrew?.taps || []);
  const installedMas = new Set((snapshot.mas?.apps || []).map((app) => String(app.id)));
  const installedNpm = new Set((snapshot.npm?.packages || []).map((pkg) => pkg.name));
  const installedApps = new Set((snapshot.apps || []).map((app) => app.bundle_id || `name:${app.name}`));
  const installedTools = new Set((snapshot.tools || []).filter((tool) => tool.executable).map((tool) => tool.name));
  const requirements = profile.requirements || {};
  const configurationIssues = [];
  if (requirements.filevault && snapshot.security?.filevault !== requirements.filevault) {
    configurationIssues.push(`FileVault expected ${requirements.filevault}; observed ${snapshot.security?.filevault || "unknown"}`);
  }
  if (requirements.git_signing === true && snapshot.configuration?.git_signing?.configured !== true) {
    configurationIssues.push("Git SSH commit signing is not fully configured");
  }
  if (requirements.claude_attribution === "none" && snapshot.configuration?.claude_attribution?.configured !== true) {
    configurationIssues.push("Claude commit, pull-request, or session attribution is enabled");
  }
  return {
    profile: inventory.hosts[hostId].profile,
    missing_taps: (brew.taps || []).filter((name) => !installedTaps.has(name)),
    missing_formulae: (brew.formulae || []).filter((name) => !installedFormulae.has(name) && !installedFormulae.has(name.split("/").at(-1))),
    missing_casks: (brew.casks || []).filter((name) => !installedCasks.has(name)),
    missing_mas: (managed.mas || []).filter((app) => !installedMas.has(String(app.id))).map((app) => `${app.name} (${app.id})`),
    missing_npm: (managed.npm || []).filter((name) => !installedNpm.has(name)),
    missing_apps: (managed.apps || []).filter((app) => !installedApps.has(app.bundle_id || `name:${app.name}`)).map((app) => app.name),
    missing_tools: (managed.tools || []).filter((name) => !installedTools.has(name)),
    configuration_issues: configurationIssues,
    outdated: uniqueSorted([
      ...(snapshot.homebrew?.outdated_formulae || []).map((name) => `brew: ${name}`),
      ...(snapshot.homebrew?.outdated_casks || []).map((name) => `cask: ${name}`),
      ...(snapshot.mas?.outdated || []).map((app) => `mas: ${app.name} (${app.id})`),
    ]),
  };
}

function rubyString(value) {
  return `"${String(value).replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

function renderBrewfile(inventory, hostId) {
  const { profile } = resolveProfile(inventory, hostId);
  const managed = profile.managed || {};
  const brew = managed.homebrew || {};
  const output = [
    "# Generated by fleet-profile.mjs. Edit manager/fleet/inventory.json, not this file.",
    `# host: ${hostId}; profile: ${inventory.hosts[hostId].profile}`,
    "",
  ];
  for (const name of brew.taps || []) output.push(`tap ${rubyString(name)}`);
  if ((brew.taps || []).length) output.push("");
  for (const name of brew.formulae || []) output.push(`brew ${rubyString(name)}`);
  if ((brew.formulae || []).length) output.push("");
  for (const name of brew.casks || []) output.push(`cask ${rubyString(name)}`);
  if ((brew.casks || []).length) output.push("");
  for (const app of managed.mas || []) output.push(`mas ${rubyString(app.name)}, id: ${app.id}`);
  if ((managed.mas || []).length) output.push("");
  for (const name of managed.npm || []) output.push(`npm ${rubyString(name)}`);
  return `${output.join("\n")}\n`;
}

function validateInventory(inventory) {
  const errors = [];
  const warnings = [];
  const profileNames = Object.keys(inventory.profiles || {}).sort();
  if (JSON.stringify(profileNames) !== JSON.stringify(["full", "worker"])) {
    errors.push(`profiles must be exactly full and worker; found: ${profileNames.join(", ") || "none"}`);
  }
  for (const profileName of profileNames) {
    const attributionPolicy = inventory.profiles?.[profileName]?.requirements?.claude_attribution;
    if (attributionPolicy !== "none") {
      errors.push(`${profileName}: claude_attribution must be none`);
    }
    const agentCliPolicy = inventory.profiles?.[profileName]?.requirements?.agent_clis;
    if (agentCliPolicy !== "authenticated") {
      errors.push(`${profileName}: agent_clis must be authenticated`);
    }
    const githubCachePolicy = inventory.profiles?.[profileName]?.requirements?.github_cache;
    if (githubCachePolicy !== "octopool") {
      errors.push(`${profileName}: github_cache must be octopool`);
    }
    const windowTitleIconsPolicy = inventory.profiles?.[profileName]?.requirements?.window_title_icons;
    if (windowTitleIconsPolicy !== true) {
      errors.push(`${profileName}: window_title_icons must be true`);
    }
    const simulatorPolicy = inventory.profiles?.[profileName]?.requirements?.xcode_simulator_hygiene;
    if (simulatorPolicy !== "no-outdated") {
      errors.push(`${profileName}: xcode_simulator_hygiene must be no-outdated`);
    }
  }
  for (const [hostId, host] of Object.entries(inventory.hosts || {})) {
    if (!inventory.profiles?.[host.profile]) errors.push(`${hostId}: unknown profile ${host.profile}`);
    for (const account of host.accounts || []) {
      if (!account.username) errors.push(`${hostId}: account missing username`);
      if (account.onepassword_item_id == null) warnings.push(`${hostId}/${account.username}: 1Password item pending`);
      if (account.onepassword_item_id && /^op:\/\//.test(account.onepassword_item_id)) {
        errors.push(`${hostId}/${account.username}: store an opaque item ID, not an op:// reference`);
      }
    }
  }
  return { valid: errors.length === 0, errors, warnings };
}

const command = process.argv[2];
if (command === "collect") {
  process.stdout.write(`${JSON.stringify(collect(), null, 2)}\n`);
} else if (command === "diff") {
  const sourceFile = option("--source");
  const targetFile = option("--target");
  if (!sourceFile || !targetFile) fail("diff requires --source FILE --target FILE");
  const result = diffSnapshots(readJson(sourceFile), readJson(targetFile));
  if (process.argv.includes("--json")) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    markdownList("MacBook-only Homebrew formulae", result.brew_formulae);
    markdownList("MacBook-only Homebrew casks", result.brew_casks);
    markdownList("MacBook-only App Store apps", result.mas);
    markdownList("MacBook-only global npm packages", result.npm);
    markdownList("MacBook-only application bundles", result.apps);
    markdownList("Target updates available", result.target_outdated);
  }
} else if (command === "plan") {
  const fleetFile = option("--fleet");
  const hostId = option("--host");
  const snapshotFile = option("--snapshot");
  if (!fleetFile || !hostId || !snapshotFile) fail("plan requires --fleet FILE --host ID --snapshot FILE");
  const result = planProfile(readJson(fleetFile), hostId, readJson(snapshotFile));
  if (process.argv.includes("--json")) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`# Fleet plan: ${hostId} (${result.profile})\n`);
    markdownList("Missing taps", result.missing_taps);
    markdownList("Missing Homebrew formulae", result.missing_formulae);
    markdownList("Missing Homebrew casks", result.missing_casks);
    markdownList("Missing App Store apps", result.missing_mas);
    markdownList("Missing global npm packages", result.missing_npm);
    markdownList("Missing manual apps", result.missing_apps);
    markdownList("Missing required tools", result.missing_tools);
    markdownList("Configuration issues", result.configuration_issues);
    markdownList("Updates available", result.outdated);
  }
} else if (command === "brewfile") {
  const fleetFile = option("--fleet");
  const hostId = option("--host");
  if (!fleetFile || !hostId) fail("brewfile requires --fleet FILE --host ID");
  process.stdout.write(renderBrewfile(readJson(fleetFile), hostId));
} else if (command === "validate") {
  const fleetFile = option("--fleet");
  if (!fleetFile) fail("validate requires --fleet FILE");
  const result = validateInventory(readJson(fleetFile));
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.valid) process.exitCode = 1;
} else {
  fail("usage: fleet-profile.mjs collect | diff --source FILE --target FILE | plan --fleet FILE --host ID --snapshot FILE | brewfile --fleet FILE --host ID | validate --fleet FILE");
}

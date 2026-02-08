# OpenClaw Integration Proposal: Concrete Changes

**Purpose:** Concrete code changes to implement openclaw-defender gates inside the OpenClaw repo. Use with [openclaw-integration-map.md](./openclaw-integration-map.md) (where) and [runtime-integration.md](./runtime-integration.md) (what to call).

**Assumptions:**
- Defender workspace is at `OPENCLAW_WORKSPACE` or `~/.openclaw/workspace`.
- Defender scripts live at `$OPENCLAW_WORKSPACE/scripts/` or a configurable path (e.g. `openclaw config get security.defender.scriptsPath`).
- All paths below are relative to **OpenClaw repo root** (`GIT/openclaw/`).

---

## 1. Kill switch (tool dispatch)

**File:** `src/gateway/tools-invoke-http.ts`

**Location:** At the start of `handleToolsInvokeHttpRequest`, immediately after auth and before resolving the tool (e.g. before `const toolName = ...` or right after `const body = ...`).

**Logic:** If defender is enabled, run kill-switch check. If active, return 503 and do not invoke any tool.

**Proposed addition:**

```ts
// After: const body = (bodyUnknown ?? {}) as ToolsInvokeBody;
// Add optional kill-switch check (when defender is enabled)

const defenderScriptsPath = cfg.security?.defender?.scriptsPath ?? resolveDefenderScriptsPath();
if (defenderScriptsPath) {
  const killSwitchScript = path.join(defenderScriptsPath, "runtime-monitor.sh");
  if (await fs.access(killSwitchScript).then(() => true).catch(() => false)) {
    const { execFile } = await import("node:child_process");
    const { promisify } = await import("node:util");
    const execFileAsync = promisify(execFile);
    try {
      await execFileAsync("bash", [killSwitchScript, "kill-switch", "check"], {
        env: { ...process.env, OPENCLAW_WORKSPACE: cfg.workspace?.dir ?? process.env.OPENCLAW_WORKSPACE },
        timeout: 5_000,
      });
    } catch {
      sendJson(res, 503, {
        ok: false,
        error: {
          type: "service_unavailable",
          message: "KILL_SWITCH_ACTIVE: All tool operations are disabled. Remove workspace .kill-switch to resume.",
        },
      });
      return true;
    }
  }
}
```

**Alternative (simpler, no config):** Only check for the file; no script path config:

```ts
const workspaceDir = cfg.workspace?.dir ?? process.env.OPENCLAW_WORKSPACE ?? path.join(os.homedir(), ".openclaw", "workspace");
const killSwitchPath = path.join(workspaceDir, ".kill-switch");
if (await fs.access(killSwitchPath).then(() => true).catch(() => false)) {
  sendJson(res, 503, {
    ok: false,
    error: {
      type: "service_unavailable",
      message: "KILL_SWITCH_ACTIVE: All tool operations are disabled. Remove workspace .kill-switch to resume.",
    },
  });
  return true;
}
```

Use the file-only check if you want zero dependency on defender script location; use the script check if you want to run the full `check_kill_switch` (logging, etc.).

**Imports to add:** `path`, `fs` (from `node:fs/promises`), and optionally `os` if using the file-only check.

---

## 2. Skill install (audit gate)

**File:** `src/agents/skills-install.ts`

**Location:** In the code path that installs a skill (e.g. before copying to `workspace/skills/<name>/` or before running npm/uv install). After `scanDirectoryWithSummary` (or in parallel), add a defender audit step.

**Logic:** If defender is enabled, run `audit-skills.sh` (or equivalent) on the skill directory. If exit code !== 0, abort install and return an error.

**Proposed addition:**

- Resolve defender workspace and `scripts/audit-skills.sh`.
- Before completing install (e.g. before `runCommandWithTimeout` for `npm install` in the skill dir), run:
  - `audit-skills.sh <skillDir>` (or pass the temp dir if installing from a bundle).
- If audit exits non-zero, return `{ ok: false, message: "Skill failed security audit (blocklist or patterns). Install aborted.", ... }` and do not write to `workspace/skills/`.

**Concrete spot:** In `installSkill`, after `collectSkillInstallScanWarnings` and before proceeding to run package manager (e.g. before the block that runs `runCommandWithTimeout` for npm/uv). Add:

```ts
// Optional: run openclaw-defender audit; abort install if it fails
const defenderWorkspace = config?.workspace?.dir ?? process.env.OPENCLAW_WORKSPACE ?? path.join(await import("node:os").then((o) => o.default.homedir()), ".openclaw", "workspace");
const auditScript = path.join(defenderWorkspace, "scripts", "audit-skills.sh");
const scriptExists = await fs.access(auditScript).then(() => true).catch(() => false);
if (scriptExists) {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);
  try {
    await execFileAsync("bash", [auditScript, skillDir], {
      env: { ...process.env, OPENCLAW_WORKSPACE: defenderWorkspace },
      timeout: 30_000,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return withWarnings(
      { ok: false, message: `Skill failed security audit. Install aborted. ${msg}`, stdout: "", stderr: msg, code: 1 },
      warnings,
    );
  }
}
```

Ensure `skillDir` at that point is the directory that will become (or already is) the skill root (the one containing `SKILL.md`). If install writes to a temp dir first, run audit on that temp dir and only then copy to `workspace/skills/<name>/`.

---

## 3. Exec / command execution (pre-exec gate)

**File:** `src/node-host/runner.ts`

**Location:** Immediately before `const result = await runCommand(execArgv, ...)` (around line 1163). After all existing allowlist/approval checks and before spawning the process.

**Logic:** If defender runtime monitor is available, run `runtime-monitor.sh check-command "<rawCommand>" "<skillName>"`. If exit code !== 0, send `exec.denied` and return without calling `runCommand`.

**Proposed addition:**

```ts
// Resolve defender workspace and runtime-monitor.sh
const defenderWorkspace = process.env.OPENCLAW_WORKSPACE ?? path.join((await import("node:os")).default.homedir(), ".openclaw", "workspace");
const monitorScript = path.join(defenderWorkspace, "scripts", "runtime-monitor.sh");
const scriptExists = await fsPromises.access(monitorScript).then(() => true).catch(() => false);
if (scriptExists) {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);
  const skillName = ""; // optional: pass current skill name if available from context
  try {
    await execFileAsync("bash", [monitorScript, "check-command", cmdText, skillName], {
      env: { ...process.env, OPENCLAW_WORKSPACE: defenderWorkspace },
      timeout: 5_000,
    });
  } catch {
    await sendNodeEvent(client, "exec.denied", buildExecEventPayload({
      sessionKey, runId, host: "node", command: cmdText, reason: "defender-command-blocked",
    }));
    await sendInvokeResult(client, frame, {
      ok: false,
      error: { code: "UNAVAILABLE", message: "SYSTEM_RUN_DENIED: Command blocked by security policy (defender)." },
    });
    return;
  }
}

const result = await runCommand(execArgv, ...);
```

Use `cmdText` (the raw command string) for the check. If the runner has access to a “current skill” name (e.g. from the session or tool context), pass it as the second argument for better logging.

---

## 4. Network (pre-fetch gate)

**File:** `src/agents/tools/web-fetch.ts`

**Location:** Inside the `execute` callback of the web_fetch tool, before calling `runWebFetch` (around line 662).

**Logic:** If defender is enabled, run `runtime-monitor.sh check-network "<url>" "<skillName>"`. If exit code !== 0, return an error and do not fetch.

**Proposed addition:**

```ts
// Before: const result = await runWebFetch({ url, ... });
const defenderWorkspace = process.env.OPENCLAW_WORKSPACE ?? path.join(await import("node:os").then((o) => o.default.homedir()), ".openclaw", "workspace");
const monitorScript = path.join(defenderWorkspace, "scripts", "runtime-monitor.sh");
const scriptExists = await fs.access(monitorScript).then(() => true).catch(() => false);
if (scriptExists) {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);
  try {
    await execFileAsync("bash", [monitorScript, "check-network", url, ""], {
      env: { ...process.env, OPENCLAW_WORKSPACE: defenderWorkspace },
      timeout: 5_000,
    });
  } catch {
    return jsonResult({ ok: false, error: "URL blocked by security policy (defender)." });
  }
}
const result = await runWebFetch({ url, ... });
```

Apply the same pattern in **`src/agents/tools/web-search.ts`** for any URL that is actually fetched (e.g. search API base URL or result links, depending on how the tool works). If the tool only calls an external search API, gate the API base URL with the same check.

---

## 5. File access (pre-write/delete gate)

**Relevant paths:** OpenClaw may not expose a dedicated “write_file”/“read_file” tool in core; file changes may happen only via exec. If there is a dedicated file tool (e.g. in an extension), add before the actual fs operation:

- Call `runtime-monitor.sh check-file "<path>" "<read|write|delete>" "<skillName>"`.
- If exit code !== 0, return an error and do not perform the operation.

**Search for:** Any handler that performs `fs.writeFile`, `fs.unlink`, or similar on paths that can be influenced by the agent. If found, add the defender check there; otherwise the exec gate (check-command) is the main file-related gate for agent-driven writes.

---

## 6. Skill execution start/end (logging only)

**Where:** In the code path that runs a skill (e.g. slash command or skill tool execution). Before running the skill logic, call `runtime-monitor.sh start <skillName>`. After the skill finishes (success or failure), call `runtime-monitor.sh end <skillName> <exitCode>`.

**Likely location:** Same area as skill install or the agent’s skill/slash-command dispatcher (e.g. in `src/plugins/commands.ts` around `executePluginCommand`, or wherever a skill runner is invoked). This is optional for the first iteration; it enables collusion detection and analytics but does not block.

---

## 7. Optional: shared defender helper in OpenClaw

To avoid duplicating “resolve workspace, find script, execFile, timeout” in every call site, add a small helper in OpenClaw, e.g.:

**File:** `src/security/defender-client.ts` (new)

```ts
import fs from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import os from "node:os";

const execFileAsync = promisify(execFile);

export function resolveDefenderWorkspace(override?: string): string {
  return override ?? process.env.OPENCLAW_WORKSPACE ?? path.join(os.homedir(), ".openclaw", "workspace");
}

export async function isKillSwitchActive(workspaceDir: string): Promise<boolean> {
  const p = path.join(workspaceDir, ".kill-switch");
  return fs.access(p).then(() => true).catch(() => false);
}

export async function runDefenderScript(
  workspaceDir: string,
  command: string,
  args: string[],
  timeoutMs = 5_000,
): Promise<{ ok: boolean; stderr?: string }> {
  const script = path.join(workspaceDir, "scripts", "runtime-monitor.sh");
  try {
    await fs.access(script);
  } catch {
    return { ok: true }; // no script => skip check
  }
  try {
    await execFileAsync("bash", [script, command, ...args], {
      env: { ...process.env, OPENCLAW_WORKSPACE: workspaceDir },
      timeout: timeoutMs,
    });
    return { ok: true };
  } catch (err) {
    const stderr = err instanceof Error ? err.message : String(err);
    return { ok: false, stderr };
  }
}
```

Then in `tools-invoke-http.ts` use `isKillSwitchActive(workspaceDir)` or `runDefenderScript(workspaceDir, "kill-switch", ["check"])`; in `runner.ts` use `runDefenderScript(workspaceDir, "check-command", [cmdText, skillName])`; in `web-fetch.ts` use `runDefenderScript(workspaceDir, "check-network", [url, ""])`; and in `skills-install.ts` call a similar helper for `audit-skills.sh` (separate function or same `runDefenderScript` with a different script path).

---

## Summary table

| # | Gate            | OpenClaw file                      | Insert point                          | Defender call                              |
|---|-----------------|-------------------------------------|---------------------------------------|--------------------------------------------|
| 1 | Kill switch     | `src/gateway/tools-invoke-http.ts`  | Start of handler, after auth           | File `.kill-switch` or `runtime-monitor.sh kill-switch check` |
| 2 | Skill install   | `src/agents/skills-install.ts`       | Before package install / copy to workspace | `audit-skills.sh <skillDir>`               |
| 3 | Exec            | `src/node-host/runner.ts`           | Before `runCommand(execArgv, ...)`     | `runtime-monitor.sh check-command "<cmd>" "<skill>"` |
| 4 | Network         | `src/agents/tools/web-fetch.ts` (and web-search if applicable) | Before `runWebFetch` / fetch            | `runtime-monitor.sh check-network "<url>" "<skill>"` |
| 5 | File            | Any dedicated file tool handler      | Before fs write/delete                 | `runtime-monitor.sh check-file "<path>" "<op>" "<skill>"` |
| 6 | Skill start/end | Skill/slash dispatcher              | Around skill run                       | `runtime-monitor.sh start/end <skill> <code>` (optional) |

Implementing 1–4 gives you kill switch, install audit, exec gate, and network gate with minimal changes. Use the optional helper (7) to keep the code DRY and consistent.

# Two-Layer Defender: Core Gates + Guardrail Plugin

**Purpose:** Use defender checks at **two layers** for defense in depth: keep existing **core gates** (hard enforcement in the execution path) and add an **optional guardrail plugin** (same checks in the guardrail hook layer). Different checks can run at different layers; together they give best of both worlds.

**Audience:** OpenClaw maintainers and openclaw-defender contributors. Requires OpenClaw with defender core integration and (once merged) the guardrails API from PR #6095.

---

## 1. Why two layers?

| Layer | Role | Bypass risk | Use case |
|-------|------|-------------|----------|
| **Core** | Hard gates in the code path that runs tools (gateway, runner, web-fetch, skills-install). | Cannot be bypassed by the model; no tool runs if the gate fails. | Kill switch, exec `check-command`, network `check-network`, skill audit, start/end logging. |
| **Guardrail** | Plugin hooks (`before_tool_call`, etc.) that run before/after the agent loop steps. | Runs in plugin order; can block or modify. | Same checks as a second line of defense; consistent violation messaging; future checks that only need hook context (e.g. prompt/response). |

**Best of both:** Core ensures enforcement even if plugins misbehave or are disabled. Guardrail layer allows defender to participate in the same pipeline as other guardrails (command-safety-guard, GPT-OSS-Safeguard, etc.), with configurable priority and block/monitor mode.

---

## 2. What runs where (recommended split)

- **Kill switch**  
  - **Core only.** Already in `tools-invoke-http`: if `.kill-switch` exists, return 503 and do not run tools. No need to duplicate in guardrail (would be redundant and kill switch is global).

- **Exec (check-command)**  
  - **Core:** `node-host/runner.ts` — before `runCommand()`, call `runDefenderRuntimeMonitor(workspace, "check-command", [cmdText, agentId])`; on failure send `exec.denied` and do not spawn.  
  - **Guardrail:** `before_tool_call` for tool `exec`: call same `runDefenderRuntimeMonitor(..., "check-command", [cmd, ""])`. Use for defense in depth and consistent “blocked by defender” messaging in the agent flow.

- **Network (check-network)**  
  - **Core:** `agents/tools/web-fetch.ts` — before `runWebFetch`, call `runDefenderRuntimeMonitor(..., "check-network", [url, ""])`; on failure return blocked error.  
  - **Guardrail:** `before_tool_call` for tool `web_fetch`: call same `runDefenderRuntimeMonitor(..., "check-network", [url, ""])`. Same script, second check.

- **Skill install audit**  
  - **Core only.** In `skills-install.ts` (`installDownloadSpec`), after extract run `runDefenderAudit(workspaceDir, targetDir)`; on failure abort install. Guardrail does not see “install” as a single tool call in the same way, so keep audit in core.

- **Skill start/end**  
  - **Core only.** In `plugins/commands.ts`, fire-and-forget `runDefenderRuntimeMonitor(..., "start"|"end", ...)`. Logging/orchestration, not a gate; no guardrail needed.

- **Future (e.g. prompt/response)**  
  - **Guardrail only.** If you add `before_request` or `after_response` checks (e.g. prompt injection patterns, response sanitization), implement those only in the guardrail plugin; core does not need to know.

---

## 3. Implementation: guardrail plugin

Add a **guardrail extension** that calls the same defender scripts from the **guardrail layer**. Two options:

### Option A: Extension inside OpenClaw repo (recommended)

- **Path:** `extensions/openclaw-defender-guardrail/` (new).
- **Depends on:** OpenClaw’s `src/security/defender-client.ts` (same as core). No duplicate script-calling logic.
- **Behavior:** When the openclaw-defender skill is installed, scripts exist and the guardrail runs; when the skill is absent, `runDefenderRuntimeMonitor` returns `{ ok: true }` and the guardrail allows through.

**Steps:**

1. In OpenClaw (on a branch that has both defender core and guardrails API, e.g. after merging defender and guardrails PRs):
   - Create `extensions/openclaw-defender-guardrail/` with:
     - `package.json` (name e.g. `@openclaw/extension-openclaw-defender-guardrail`, dependency on `openclaw` or workspace packages as per other extensions).
     - `openclaw.plugin.json`: plugin id `openclaw-defender-guardrail`, name “OpenClaw Defender (guardrail)”, config schema with `stages.beforeToolCall`, `failOpen`, `guardrailPriority`.
     - `index.ts`: use `createGuardrailPlugin<DefenderGuardrailConfig>({ ... })` from `openclaw/plugin-sdk`.
2. In the plugin’s `evaluate()` for `before_tool_call`:
   - If `ctx.metadata.toolName === "exec"`: get command string from `ctx.metadata.toolParams` (e.g. `params.command` — if it’s an array, join or serialize the same way `runner.ts` builds `cmdText`). Call `resolveDefenderWorkspace()` then `runDefenderRuntimeMonitor(workspace, "check-command", [cmd, ""], 5_000)`. If `!result.ok`, return `{ safe: false, reason: result.stderr ?? "Command blocked by defender" }`.
   - If `ctx.metadata.toolName === "web_fetch"`: get `url` from `ctx.metadata.toolParams`. Call `runDefenderRuntimeMonitor(workspace, "check-network", [url, ""], 5_000)`. If `!result.ok`, return `{ safe: false, reason: result.stderr ?? "URL blocked by defender" }`.
   - Otherwise return `{ safe: true }`.
3. Use `formatViolationMessage(evaluation, location)` to return a clear message (e.g. “Defender blocked at tool call: …”).
4. Wire the extension into the OpenClaw build and plugin loading like other guardrail extensions (e.g. command-safety-guard).

Result: same defender scripts and policy, checked once in core and again in the guardrail layer for exec and web_fetch.

### Option B: Guardrail in openclaw-defender repo

- **Path:** e.g. `openclaw-defender/guardrail/` or a separate package that ships with the skill.
- **Challenge:** The plugin cannot import `defender-client` from OpenClaw (different package). It would have to spawn `runtime-monitor.sh` itself (duplicate logic) or depend on a shared npm package that exposes the same API. Possible but more moving parts; Option A is simpler.

---

## 4. Config and priority

- **failOpen:** Default `true` for the defender guardrail so that if the script is missing or times out, the guardrail does not block (core still enforces when the script is present).
- **guardrailPriority:** e.g. 60 so defender guardrail runs **before** command-safety-guard (50), giving defender first say when both are enabled; or 40 to run after. Tune so defender and command-safety-guard complement each other (e.g. defender = policy/blocklist, command-safety = pattern rules).
- **stages:** Enable only `before_tool_call` for exec/network; optionally add `before_request` later if you want a guardrail-level “kill switch” check (e.g. block request when `.kill-switch` exists) for consistent UX.

---

## 5. Summary

- **Core layer (existing):** Kill switch, exec check-command, network check-network, skill audit, start/end. Keep as-is; no change required.
- **Guardrail layer (new):** Add `openclaw-defender-guardrail` extension that in `before_tool_call` calls the same defender scripts for `exec` and `web_fetch`. Same scripts, same policy, two layers.
- **Different checks on different layers:** Core = hard gates in execution path. Guardrail = same gates for defense in depth + future prompt/response checks only in the plugin.

This gives you best of both worlds: guaranteed enforcement in core and a single, pluggable defender guardrail that fits the guardrails API and can be tuned (priority, failOpen, block/monitor) alongside other extensions.

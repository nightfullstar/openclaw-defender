# OpenClaw Integration Map: Where to Hard-Rule Defender Checks

**Purpose:** Lower-level implementation guide for **OpenClaw core** ([github.com/openclaw/openclaw](https://github.com/openclaw/openclaw)). These are the code paths where defender checks must run so the LLM cannot bypass policy.

**Audience:** Implementers working on OpenClaw (main repo or a branch). This doc describes what to build *in OpenClaw*, not changes to the openclaw-defender skill itself. The skill stays as-is; the map is the roadmap to deepen it into OpenClaw.

**Use with:** [runtime-integration.md](./runtime-integration.md) (what to call); this doc (where to call it). **Concrete patches:** [openclaw-integration-proposal.md](./openclaw-integration-proposal.md) (exact file paths and code snippets for OpenClaw).

---

## Repo Context (from OpenClaw README / structure)

- **Repo:** `openclaw/openclaw` — TypeScript, Node ≥22, Gateway + Pi agent.
- **Key dirs:** `packages/` (clawdbot, moltbot), `apps/`, `skills/`, `.pi/` (agent runtime).
- **Gateway** = control plane (WS); **Pi agent** = RPC, tool streaming.
- **Tools:** exec (bash), browser, skills (install + UI), cron, nodes, etc.
- **Security:** `agents.defaults.sandbox.mode`, tool allowlist/denylist; exec runs on gateway host (or in Docker for non-main).
- **Workspace:** `~/.openclaw/workspace`; skills under `workspace/skills/<name>/`.

---

## 1. Kill switch (global gate)

**Rule:** Before any tool dispatch or agent turn, if `.kill-switch` exists in workspace, refuse all tool invocations and return an error to the agent.

**Where to implement:**
- **Tool-dispatch layer** — The place that receives a tool call from the agent (e.g. `exec`, `browser_navigate`, `skill_invoke`) and runs the actual implementation. Add a single check at the very start: read `workspace/.kill-switch` (or call `runtime-monitor.sh kill-switch check`); if active, return error and do not run any tool.
- **Likely location:** Gateway or Pi agent package, in the RPC/handler that processes tool requests (e.g. “run tool X with params Y”). One central gate so every tool is blocked when kill switch is on.

---

## 2. Skill install (pre-write gate)

**Rule:** Before writing any skill into `workspace/skills/<name>/`, run the defender audit (blocklist + patterns). If audit fails, refuse install; do not write files.

**Where to implement:**
- **Skill install path** — Where ClawHub install or “add skill to workspace” happens (e.g. download/copy into `workspace/skills/<slug>/`). Before writing:
  1. Write to a temp dir if needed.
  2. Run `audit-skills.sh <temp-dir>` (or a Node/TS equivalent that uses `references/blocklist.conf` and the same pattern checks).
  3. If exit code ≠ 0 (fail or warn), abort install and return error; do not copy to `workspace/skills/`.
  4. If pass, then copy to `workspace/skills/<name>/` and optionally run `generate-baseline.sh` for the new SKILL.md.
- **Likely location:** Package or module that handles “install skill” / ClawHub sync (e.g. `clawhub install <slug>`). The README mentions “install gating + UI” — that gating is the place to add the defender audit as a hard prerequisite.

---

## 3. Exec / command execution (pre-exec gate)

**Rule:** Before running any shell command (bash, exec tool), run command validation. If blocked, do not spawn the process; return error to the agent.

**Where to implement:**
- **Exec tool implementation** — The code that takes a command string and runs it (e.g. `child_process.spawn` or similar). Before spawning:
  1. Call `runtime-monitor.sh check-command "<command>" "<skillName>"` (or inline the same blocklist/safe-command logic in TS).
  2. If exit code ≠ 0, return error to agent and do not execute.
  3. If pass, run the command as today.
- **Likely location:** Package that implements the “exec” or “bash” tool (gateway or agent package). Same path that sandboxing uses (allowlist/denylist); add defender check before the actual exec.

---

## 4. File access (pre-read/write/delete gate)

**Rule:** Before any read/write/delete of a file path that the agent can influence, check path and operation. If the path is a protected path (credentials, SOUL.md, MEMORY.md, .integrity, .defender-*, etc.) and operation is write/delete, refuse.

**Where to implement:**
- **File tool or exec’s file operations** — Wherever the agent can read/write/delete files (e.g. a dedicated file tool, or exec that runs `cat`/`echo`/scripts that write files). Before the actual fs operation:
  1. Call `runtime-monitor.sh check-file "<path>" "<read|write|delete>" "<skillName>"` (or inline the same critical-path logic in TS).
  2. If exit code ≠ 0, return error and do not perform the operation.
  3. If pass, proceed.
- **Likely location:** Same exec tool path (if it’s the one that can write files), or a dedicated “file”/“read_file”/“write_file” tool handler. If the agent only touches files via exec, gating exec is enough for commands that write; for a dedicated file API, gate that API.

---

## 5. Network requests (pre-fetch gate)

**Rule:** Before any outbound HTTP request (fetch, browser URL, web_search, etc.), check the URL. If blocklisted or not whitelisted (when you enforce whitelist), refuse the request.

**Where to implement:**
- **HTTP/fetch layer** — The code that performs `fetch(url)` or equivalent for agent-driven requests (e.g. web_search, web_fetch, or browser navigation to a URL). Before sending the request:
  1. Call `runtime-monitor.sh check-network "<url>" "<skillName>"` (or inline the same whitelist/blocklist logic in TS).
  2. If exit code ≠ 0, return error and do not send the request.
  3. If pass, proceed.
- **Likely location:** Package that implements web_search, browser, or any “fetch URL” tool used by the agent. One central place for “agent requested URL” is enough.

---

## 6. Skill execution start/end (logging only)

**Rule:** When the agent invokes a skill (slash command or skill tool), call `runtime-monitor.sh start <skillName>` before running the skill and `runtime-monitor.sh end <skillName> <exitCode>` after. This enables collusion detection and analytics; it does not by itself block anything.

**Where to implement:**
- **Skill invocation path** — Where a “run skill X” is executed (e.g. slash command handler or skill dispatcher). Before running the skill logic: call `start`; after (success or failure): call `end`.
- **Likely location:** Same area as “skill install” or the agent’s skill/slash-command handler.

---

## 7. RAG / embedding operations (if ever added)

**Rule:** If OpenClaw adds RAG (embedding, vector store, retrieve), before calling that operation run `runtime-monitor.sh check-rag "<operation>" "<skillName>"`. If blocked, refuse the operation (EchoLeak/GeminiJack mitigation).

**Where to implement:** In the code path that performs embedding/retrieve/vector-store calls, before the actual call.

---

## Implementation options

1. **Shell out to scripts** — Call `runtime-monitor.sh` and `audit-skills.sh` from Node/TS. Pros: single source of truth (defender scripts), no duplication. Cons: process spawn overhead, need to resolve workspace path.
2. **Inline logic in TypeScript** — Port blocklist, safe-command list, critical paths, and network rules into a small TS module; call it from the same code paths. Pros: no subprocess, faster. Cons: must keep blocklist/rules in sync with defender repo (or read `blocklist.conf` and workspace `.defender-*` at runtime).
3. **Hybrid** — Kill switch + audit (install) shell out; exec/file/network checks can be inlined for speed if the gateway reads `blocklist.conf` and workspace config.

---

## Order of operations (hard-rules)

1. **Every request/tool dispatch:** Check kill switch → if active, refuse all.
2. **Skill install:** Run audit → if fail, do not write to `workspace/skills/`.
3. **Exec:** Check command → if blocked, do not spawn.
4. **File read/write/delete:** Check path + operation → if blocked, do not perform.
5. **Network:** Check URL → if blocked, do not send request.
6. **Skill start/end:** Call start/end for logging (no block).

This gives a lower-level implementation map: same rules as the defender advisories, but enforced in code at the points where OpenClaw performs the action, so the model cannot bypass them.

---

## Deepening integration

Ways to go beyond “call scripts at these points” and make the defender a first-class part of OpenClaw:

### 1. Config-driven gating

**Idea:** In `openclaw.json`, add a `security.defender` section (e.g. `enabled`, `workspacePath`, `auditBeforeInstall`, `runtimeChecks`). The gateway reads this and only runs defender checks when enabled; users can turn policy on/off and point to the defender workspace without code changes.

**Deepens:** Defender becomes an optional but supported “security mode” instead of an undocumented hook.

### 2. Defender as a formal hook / middleware

**Idea:** Define a small hook interface (e.g. `beforeToolDispatch(tool, params) => allow | deny`, `beforeSkillInstall(slug, source) => allow | deny`) and have the gateway call it at the points in §1–7. The defender skill (or a thin OpenClaw package) implements that interface by calling the scripts or inlined logic. Other plugins could implement the same interface later.

**Deepens:** One contract for “policy layer”; defender is one implementation. Easier to test and to add more policy sources later.

### 3. Single source of truth in-process

**Idea:** When the defender skill is present, the gateway loads `blocklist.conf` and workspace `.defender-*` at startup (or on first tool call) and uses them for in-process checks (exec, file, network) instead of shelling out every time. Scripts remain the authority for install (audit) and for generating/updating the blocklist; the gateway only reads.

**Deepens:** No subprocess per check; same blocklist for scripts and gateway; one place to update (defender repo + workspace).

### 4. Human-in-the-loop for highest risk

**Idea:** For a small set of actions (e.g. install from ClawHub, disable kill switch, first write to SOUL/MEMORY after a violation), the gateway does not auto-allow even if the check passes; it emits “needs_approval” and waits for an explicit user approval (CLI `openclaw approval allow <id>` or UI). Defender (or config) defines which actions require approval.

**Deepens:** Highest-impact operations cannot be fully automated by the model; a human must explicitly approve.

### 5. Defender health at startup

**Idea:** If `security.defender.enabled` is true, the gateway at startup checks: defender skill present, baseline exists (or warn), kill switch off. If “secure” mode is required, refuse to start until defender is correctly set up; otherwise log a warning.

**Deepens:** Misconfiguration is visible at boot instead of failing silently at first install or first tool run.

### 6. Structured protocol instead of only scripts

**Idea:** Defender exposes a small JSON protocol (stdio or local HTTP): request `{ "type": "check", "check": "command", "payload": { "command": "...", "skill": "..." } }`, response `{ "allowed": false, "reason": "..." }`. OpenClaw calls this instead of (or in addition to) shell scripts. Scripts can implement the same protocol (e.g. a wrapper that parses JSON and calls runtime-monitor.sh).

**Deepens:** Stable, testable contract; other languages or a long-running defender process can implement it; easier to add new check types without changing OpenClaw CLI surface.

### 7. Align with sandbox allowlist/denylist

**Idea:** OpenClaw already has `agents.defaults.sandbox` with tool allowlist/denylist. When defender is enabled, merge defender blocklist (e.g. dangerous commands, blocked URLs) into the effective denylist or into a “defender policy” layer that the sandbox respects. One policy surface for “what the agent must not do.”

**Deepens:** Defender rules and sandbox rules are consistent; no gap between “sandbox allows X” and “defender blocks X.”

### 8. CI / contribution checks

**Idea:** In the OpenClaw repo (or in defender repo), add a CI job that runs `audit-skills.sh` (or the inlined audit) on any changed skill or on a curated list of skills. PRs that add or modify skills get checked by defender logic before merge.

**Deepens:** Defender is part of the development pipeline; malicious or risky contributions are caught at review time.

---

**Summary:** Deepening = make defender config-driven, hook-based, in-process where it helps, and approval-aware for the highest risk, with a clear contract (config + optional protocol) and alignment with sandbox and CI.

---
name: sandbox
description: "Sandboxes on Control Plane: isolated sessions that run code with an identity's access, and dev sandboxes (cloud IDEs). Use when the user asks to run or test code, use a sandbox or session, or set up a dev box or cloud IDE."
---

# Sandboxes: Sessions and Dev Boxes

> **Tool availability:** `run_session` and `deploy_sandbox` are core.

A sandbox is a workload in the org's **sandbox GVC**, which runs in one location. New orgs use their `default` GVC; an older org gets one named `sandboxes` with its first sandbox. There are two types:

| Type | What it is | Tool |
|:---|:---|:---|
| **worker** | Holds **sessions**: isolated workspaces that run commands. The server creates and scales workers per identity on its own. | `mcp__cpln__run_session` |
| **dev** | A cloud IDE (browser IDE and terminal) with a persistent home volume the user works in. | `mcp__cpln__deploy_sandbox` |

## The identity is the access

Code in a session runs with the access of the **identity** it was started with: its cloud access (AWS, GCP, Azure through Universal Cloud Identity) and its outbound rules apply, and nothing else does. That is what makes it safe to run code the AI wrote.

- The identity must exist **in the sandbox GVC**: create it there with `create_identity`, then give it cloud access with `grant_cloud_access`. An identity in another GVC cannot be used.
- Use only an identity the user named. Never pick one: the identity decides what the code can reach.
- No identity means no cloud access.
- Code in a session cannot read Control Plane secrets: the platform removes the workload token from every session process. Never put a secret value in a command.

## Running code

1. `run_session` with `command` (and `identity` when the user named one) starts a session and runs the command. The answer names the session, its GVC, and the identity it ran as.
2. Pass the returned `session` to keep working there: its files and processes stay. A reused session keeps the identity, worker, outbound rules, image, and keep time it started with; a different one needs a new session. A session that has ended is replaced with the same setup, and limited outbound rules must be passed again to replace it.
3. Commands are non-interactive. Start servers and long jobs in the background with output to a file (`nohup CMD > out.log 2>&1 &`), then read the file in a later call. A command still running after `waitSeconds` keeps running.
4. `previewPort` returns a link to a server in the session. Whoever has the link can open it once, within about a minute; call again for a fresh one. For a lasting public URL, deploy the app instead.
5. A session ends `keepMinutes` (default 60, up to 7 days) after the last call. `list_resources` and `delete_resource` with kind `session` list and end sessions.

`allowOutbound` limits where the code can connect: hostnames (wildcards like `*.github.com` work) and CIDRs. `[]` allows nothing but the org registry; leaving it out leaves outbound open. `image` runs the session on another image (`//image/NAME:TAG` from `build_image`, or an exact public reference); with outbound limited, the public image's registry must be in `allowOutbound`.

## Workers

Sessions of one identity spread over that identity's workers. By default a worker holds 20 sessions, an identity grows to 10 workers, and an added worker that stays empty for an hour is deleted. Every worker the server adds copies the first one a user made for that identity.

- `deploy_sandbox` with `type: worker` makes a worker for an identity or changes one: its size, its outbound rules, and how the identity's workers scale (`maxSessions`, `minWorkers`, `maxWorkers`, `idleDeleteDelay`).
- `run_session` with `worker` sends a session to a worker the user named; that worker fixes the identity and the outbound rules.
- Workers never need starting: they sleep when idle and wake on the next session.

## Dev sandboxes

`deploy_sandbox` with `type: dev` creates one, and the same tool changes, starts, or stops it (`stop: true`; the home volume is kept). The answer links to the IDE (`/_ide/`) and the terminal (`/_term/`). Opening a link signs in with the Control Plane account in that browser and needs `connect` on the sandbox; it wakes a sleeping sandbox.

- `image` makes the IDE run on the user's image (for a toolchain): the IDE layer is built onto it once, as a sandbox image, and reused by every dev sandbox on the same image. The first call returns while it builds; call again with the same inputs.
- `env` takes `cpln://secret/NAME.KEY` once `grant_workload_secret_access` grants the secret to the sandbox.
- The AI cannot run commands inside a dev sandbox. Inside it, the user works in the IDE terminal, where an AI agent with the MCP can run.
- `delete_resource` (kind `workload`) deletes a dev sandbox together with its home volume: say so before deleting.
- `update_workload` refuses sandboxes: change them only with `deploy_sandbox`.

## Permissions

| Action | Needs |
|:---|:---|
| Start a session | `connect` on the worker, and `use` on the identity when the server adds a worker for it |
| Create a sandbox | `create` on workloads in the sandbox GVC, and `use` on its identity |
| Open a dev sandbox | `connect` on it |
| Run on an org image | `pull` on that image |

## Limits

- No Control Plane secrets inside a session (above).
- Files move through commands as text; for binary or large files, the user runs the `cpln sandbox` session copy command on their machine (check `cpln sandbox --help`).
- An answer keeps the last 8,000 characters of each output stream; filter long output with `tail` or `grep`.
- Sessions and sandboxes run in the sandbox GVC's one location.
- Desktop IDEs (VS Code, Cursor, SSH) connect through the CLI: `cpln sandbox --help` lists the connect command and its `--ide` choices.

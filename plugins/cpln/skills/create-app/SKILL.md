---
name: create-app
description: "Writes, builds, and deploys an app the user asks for in the chat (they say what it should do; there is no repository and no image yet). With a filesystem and a working cpln CLI the files go into a directory on the machine and the CLI builds them; otherwise the files are stored on Control Plane and built there. Use when the user asks to create, generate, write, vibe-code, prototype, or scaffold an app, API, site, bot, game, or service and run it on Control Plane, or to change an app that was created this way."
---

# Create an App from the User's Request

> **Tool availability:** every MCP tool named here is on the default `core` profile (the reads also on `readonly`). The stored way needs no `cpln` CLI, git repository, Docker daemon, or file on the user's machine.

The user asks for an app that does not exist yet ("create me a todo app and deploy it"). You write its files, Control Plane builds them into an image, and the image runs as a workload with a public URL. There are two ways to get there, and choosing one is the first decision: **local** (the files go into a directory on the user's machine and the `cpln` CLI builds them) or **stored** (the files are stored on Control Plane with `mcp__cpln__write_app_files` and built with `mcp__cpln__build_image`). Everything after the build is the same either way.

## Where the files go: decide by your environment

| Your environment | Which way | Where the app's files live | How the image is built |
|---|---|---|---|
| You can write files and run commands, and the `cpln` CLI is installed and logged in (Claude Code, Codex, Cursor, Antigravity, Amp, OpenCode, any CLI agent) | **Local** | A directory on the user's machine (`./NAME`) that you create and fill with your own file tools; it is theirs to keep, version, and edit | `cpln image build --remote --dir ./NAME --name NAME:v1 --org ORG` (builds on Control Plane, no Docker; verify flags with the `cpln` skill) |
| You cannot write files or run commands (ChatGPT, Claude web, Claude desktop, any hosted chat), or you have a filesystem but no working `cpln` CLI | **Stored** | Control Plane, through `mcp__cpln__write_app_files`; they stay there between calls and sessions and the user can download them | `mcp__cpln__build_image` with no `repoUrl` |

- **With a filesystem and a working CLI, local is the default.** The user expects the code where they can see it. Stored is fine when they ask for it, or when there is no `cpln` CLI to build with; either way, say which way you are taking.
- **Never hand a user without a filesystem a CLI command** for an app you can store and build yourself.
- With a filesystem but no `cpln` CLI installed or logged in, go stored; mention that installing the CLI would keep the code local next time.
- Everything after the build (GVC and location, workload, verification, URL) is the same both ways and uses the MCP tools.

## Decide the path first

| The user has | Path | Skill |
|---|---|---|
| A request for an app that does not exist yet (they say what it should do) | Local: files in `./NAME` → `cpln image build --remote --dir ./NAME` → `mcp__cpln__create_workload`. Stored: `mcp__cpln__write_app_files` → `mcp__cpln__build_image` → `mcp__cpln__create_workload` | this skill |
| An existing container image (`nginx:latest`, `//image/api:v1`, an ECR/GCR path) | `mcp__cpln__create_workload` directly | `workload` |
| A GitHub or GitLab repository URL | `mcp__cpln__build_image` with `repoUrl` → `mcp__cpln__create_workload` | `image`, `workload` |
| A folder on their own machine | `cpln image build --remote --dir PATH` (CLI; this server cannot read their disk) | `image`, `cpln` |
| A database, cache, queue, broker, search engine, or gateway ("I need Postgres") | `mcp__cpln__browse_templates` → `mcp__cpln__install_template` | `template-catalog` |

An app that also needs a database is both: this skill for the app, `template-catalog` for the database, then wire the connection through env and secrets. Never build a database, cache, or queue from source, and never fake an app by inlining code into a generic base image.

## The journey, in order

Do every step yourself. Ask the user only where a step says to ask.

1. **Target and name.** Confirm the org (never guess it). Choose the app's name: short kebab-case, letters, digits and hyphens, at most 40 characters (`todo-app`). This one name is used everywhere: `name` for `mcp__cpln__write_app_files` and `mcp__cpln__get_app_files`, the image NAME that `mcp__cpln__build_image` produces (`//image/NAME:TAG`), and the workload name. Keep it stable for the app's whole life; a different name is a different app.
2. **Write a small, deployable app.** Bind `0.0.0.0`, listen on a fixed port taken from the `PORT` env var with a default of `8080`, and serve a `GET /healthz` that returns 200. Read configuration from env. Put no credentials, tokens, or `.env` files with values in the code (the tool refuses them); reference secrets from the workload instead (`setup-secret` skill). Write a `Dockerfile` at the root that uses `linux/amd64` base images (`node:20-slim`, `python:3.12-slim`, `golang:1.23`), installs dependencies, exposes the port, and starts the app. Auto-detection without a Dockerfile works for common stacks, but an explicit Dockerfile gives a readable log when something fails. Leave out `node_modules`, build output, and lockfiles you did not generate. **Files the user provides** (a logo, photos, a font, a PDF, a dataset): you write what you author; anything the user has as a file goes through `mcp__cpln__create_app_files_upload_link` with the exact app paths, and you reference those paths in the code right away (`<img src="/public/logo.png">`). Call it in the same turn you write the app; never wait for the files to write the code. Files attached to the chat, or sitting in a code sandbox, cannot be forwarded to Control Plane, so do not ask for attachments: hand over the link and say why. A binary never goes inline, whatever its size.
3. **Write the files.** Local: create `./NAME` and write the files there with your own tools; files the user provides go into that folder by hand. Stored: `mcp__cpln__write_app_files` with `org`, `name`, and `files` (path plus whole content), (text only; a big generated file goes in parts, `files` for the first part and `appends` for the rest), plus `mcp__cpln__create_app_files_upload_link` for anything the user must upload; send a larger app across several calls with the same `name`. The tool reports how many files the app now has and that no image is built yet. When you asked for uploads, give the user the link exactly as returned and, after they confirm, call `mcp__cpln__get_app_files` to check every expected path shows before you build.
4. **Build the image.** Local: `cpln image build --remote --dir ./NAME --name NAME:v1 --org ORG`; it uploads the folder, builds on Control Plane, pushes `//image/NAME:v1`, and streams the log (`cpln image get NAME:v1 --org ORG` confirms the push). Stored: `mcp__cpln__build_image` with the same `name`, tag `v1`, and **no `repoUrl`**; it builds the stored files and returns a `buildId` that keeps running. Do not poll in a tight loop: do step 5 while it builds, then read `mcp__cpln__get_image_build`. A build takes about 1 to 5 minutes. On failure the cause is in the log (a wrong dependency, a bad Dockerfile line, a syntax error): fix the file (on disk, or with `mcp__cpln__write_app_files` `edits`), then build again with the next tag (`v2`). Never rebuild unchanged files.
5. **Deployment target.** If the user named a GVC, use it. Otherwise `mcp__cpln__list_resources` (kind="gvc"): if GVCs exist, ask which one to use or whether to create a new one; if none exists or a new one is wanted, `mcp__cpln__list_resources` (kind="location") and **ask the user which location(s)** the app should run in, then `mcp__cpln__create_gvc` with those locations. Never pick a region for them and never create a GVC without locations.
6. **Deploy** once the build reports `pushed`: `mcp__cpln__create_workload` in that GVC, named after the app, with `containers[0].image` = `//image/NAME:TAG`, `containers[0].ports` = the port the app listens on (the build reports the port it detected; it must match the code), `public: true` (the user asked for an app they can open, so it is meant to be reachable), a readiness probe on `/healthz`, and CPU/memory sized to the runtime (typically `250m` and `512Mi`; `100m` and `128Mi` for a static site). A freshly generated app is a prototype: `minScale: 1`, `maxScale: 2`, no scale-to-zero. When the user says it serves real users, apply the production defaults from `get_cpln_rules` instead. Type `standard` (the default) fits almost every generated app.
7. **Verify, automatically:** poll `mcp__cpln__list_deployments` until every location is ready. Not ready after a few reads: `mcp__cpln__get_workload_events`, then `mcp__cpln__get_workload_logs`. A crash or port mismatch is a code fix: edit the source, build the next tag, `mcp__cpln__update_workload` the container image to it, verify again. Never re-apply an unchanged spec.
8. **Report and hand over the code.** Give the user the canonical URL from `mcp__cpln__list_deployments` (never a constructed one; follow the reachability rule in `get_cpln_rules`) and the image that runs (`//image/NAME:TAG`). Local: the code is already in `./NAME` on their machine; say so. Stored: add a download link for the app's files: `mcp__cpln__get_app_files` with `download: true`, shown exactly as returned (it needs no login and expires after about an hour; do not post it anywhere shared). Then invite changes: "tell me what to change and I will update the running app".

## Changing an app that already exists

- **Find it, in any session.** This is for changes to the app's code. A change to its workload settings (scaling, env, exposure, probes) is `mcp__cpln__update_workload` and needs none of this. Nothing about the app is remembered between chats; the platform is. Take NAME from the workload's container image `//image/NAME:TAG` and call `mcp__cpln__get_app_files` with that `name` (it returns files and the app's images, never an image itself). Its answer decides what you do:

| `get_app_files` says | What it means | What to do |
|---|---|---|
| Files stored, written through `write_app_files` | Control Plane's copy is the source of truth, even if you now have a filesystem | Read the file you need (`path`), edit with `mcp__cpln__write_app_files`, build the next tag, `mcp__cpln__update_workload`. If the user wants the app on their machine from now on: download the archive, unpack it into a folder, and continue the local way |
| Files stored, uploaded by the cpln CLI from a folder | The user's folder is the source of truth | With a filesystem: ask which folder, edit there, `cpln image build --remote --dir` the next tag, `mcp__cpln__update_workload`. Without: tell the user what to change in their folder and to rebuild with the CLI; `write_app_files` refuses without `adopt: true` |
| No files; images built from a repository | The code lives in that repository | Change it there, then `mcp__cpln__build_image` with `repoUrl` and `mcp__cpln__update_workload` |
| No files; images pushed outside a Control Plane build | The code is not on Control Plane | Ask the user where it lives; do not rewrite it |
| No files, no images | A new app | Start the journey above |

  `adopt: true` on `write_app_files` makes Control Plane's copy the source of truth from then on, or starts a new app under a name that was used before. Use it only when the user asks for exactly that, and say what it means. An edit needs the exact current text, so read the file first.
- **Small change:** `mcp__cpln__write_app_files` with `edits` (`find` must match exactly once, or set `replaceAll`), then `mcp__cpln__build_image` with the **next** tag, then `mcp__cpln__update_workload` with the new image, then `mcp__cpln__list_deployments`. Building the same tag again only reaches a workload that has `supportDynamicTags`; otherwise the running app keeps the old image.
- **Bigger change:** send whole files; remove files that no longer belong with `deletePaths`.
- **Needs a database or cache:** install it from the catalog (`template-catalog` skill), pass the connection details through env, and put any password in a secret with `mcp__cpln__grant_workload_secret_access` (`setup-secret` skill).
- **Wants a custom domain:** `domain` skill, after the app is up.

## Limits and traps

- Limits follow GitHub's: 100 MB per file, 1 GB per app, 20,000 files per app; 200 files and 100 MB per call (far more than one reply can hold). A file of any size is read in slices with `offset` and `length` on `mcp__cpln__get_app_files` (or downloaded whole in the archive). Generated and vendored files stay out; dependencies are installed by the build.
- Paths are relative with forward slashes (`src/index.js`); `..`, absolute paths, `node_modules/`, and `.git/` are refused.
- Inline content is text, up to 1 MB per file per call; a bigger generated file goes in parts (`files` for the first, `appends` for the rest). Every photo, font, PDF, archive, or file the user has goes through `mcp__cpln__create_app_files_upload_link`. Edits and appends apply to text files only.
- The files belong to the org and the app name. Deleting the image record does not delete the files; writing files to a name that already has some merges into them.
- A `.env` file with values, an API key, a private key, or a cloud access key in a file is refused: use secrets.
- The app must listen on `0.0.0.0` and the declared port. A wrong port or a bind to `127.0.0.1` shows up as a readiness failure, not a build failure.
- A build service that has not been updated for app files refuses `mcp__cpln__write_app_files` with an explicit message; the fallback then is a repository (`repoUrl`) or the local way.

## Quick reference

| Tool | Purpose |
|---|---|
| `cpln image build --remote --dir ./NAME --name NAME:TAG --org ORG` (CLI, local) | Build a folder on the machine into `//image/NAME:TAG` on Control Plane. |
| `mcp__cpln__write_app_files` (stored) | Write or change the app's stored files (whole files, exact-text edits, deletions), kept per org and app name. |
| `mcp__cpln__build_image` (no `repoUrl`) | Build the stored files into `//image/NAME:TAG`. |
| `mcp__cpln__get_image_build` | Build status, detected port and runtime, and the log on failure. |
| `mcp__cpln__create_app_files_upload_link` | An upload link for files the user has (pictures, fonts, PDFs, data); files attached to the chat cannot be forwarded. |
| `mcp__cpln__get_app_files` | List the files, read one (in slices for a large file), or get a download link (`download: true`). |
| `mcp__cpln__list_resources` (kind="gvc" / "location") | Existing GVCs, and the locations the user can choose from. |
| `mcp__cpln__create_gvc` | Create the deployment target with the user's chosen location(s). |
| `mcp__cpln__create_workload` / `mcp__cpln__update_workload` | Run the image, or move a running app to the next tag. |
| `mcp__cpln__list_deployments` | Readiness per location and the canonical public URL to report. |
| `mcp__cpln__get_workload_events` / `mcp__cpln__get_workload_logs` | Why a deployment is not ready. |

## Documentation

- [AI usage examples](https://docs.controlplane.com/ai/examples.md) and the [tool reference](https://docs.controlplane.com/ai/tools.md)
- [Workload reference](https://docs.controlplane.com/reference/workload/general.md) and [image reference](https://docs.controlplane.com/reference/image.md)

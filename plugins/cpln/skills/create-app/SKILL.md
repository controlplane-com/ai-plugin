---
name: create-app
description: "Writes, builds, and deploys an app the user asks for in the chat, with no repository and no image yet. Use when the user asks to create, generate, write, vibe-code, prototype, or scaffold an app, API, site, bot, game, or service and run it on Control Plane, or to change an app made this way."
---

# Create an App from the User's Request

You write the app's files, Control Plane builds them into an image, and `mcp__cpln__deploy_app` runs the image as a workload and waits for it. The first decision is where the files live.

## Local or stored

| Your environment | Files live | Build |
|---|---|---|
| You can write files and run commands, and the `cpln` CLI is installed and logged in | **Local:** a folder `./NAME` on the user's machine, theirs to keep and version | `cpln image build --remote --dir ./NAME --name NAME:v1 --org ORG`, then `deploy_app` with `image: //image/NAME:v1` |
| No filesystem or commands (ChatGPT, Claude web and desktop), or no working CLI | **Stored:** on Control Plane through `mcp__cpln__write_app_files`, kept across sessions | `deploy_app` with the same `name` builds the stored files |

With a filesystem and a working CLI, local is the default; stored is fine when the user asks for it. Never hand a CLI command to a user without a filesystem. Say which way you are taking.

Other starting points: an existing image or a git repository goes straight to `deploy_app` (`image` or `repoUrl`); a folder the user already has is built with the CLI. A database or Redis the app needs comes from `mcp__cpln__add_database`, whose result lists the env values to pass to `deploy_app`; other infrastructure comes from the Template Catalog (`template-catalog` skill). Never build a database from source or inline an app into a base image.

## The journey

1. **Name.** Short kebab-case, at most 40 characters (`todo-app`). The same name is the app files name, the image NAME, and the workload name, for the app's whole life; a different name is a different app.
2. **Write a deployable app.** Bind `0.0.0.0`, listen on the port from the `PORT` env var with a default of 8080, and serve `GET /healthz` with 200. Read configuration from env, and secrets through `cpln://secret/NAME.KEY` references; no credentials or `.env` values in files, which the tool refuses. Add a `Dockerfile` on `linux/amd64` bases (`node:20-slim`, `python:3.12-slim`, `golang:1.23`); auto-detection works for common stacks, but a Dockerfile gives a readable build log. Leave out `node_modules`, build output, and lockfiles you did not generate.
3. **Files the user has** (a logo, photos, fonts, a PDF, a dataset) never go inline and cannot be forwarded from the chat. In the same turn you write the code, call `mcp__cpln__create_app_files_upload_link` with the exact paths the code references, give the user the link as returned, and once they say it is done, check with `mcp__cpln__get_app_files` that every path is stored. Locally, those files go into the folder by hand.
4. **Write the files.** Stored: `write_app_files` with `files` (path and whole content, text only); a large generated file goes in parts, `files` for the first and `appends` for the rest; a big app spans several calls with the same `name`.
5. **Target.** Use the GVC the user named. Otherwise list GVCs and ask which to use; for a new GVC, list locations and ask which the app runs in.
6. **Deploy.** Pass `port`, `public: true` for an app the user will open, `healthPath: "/healthz"`, CPU and memory for the runtime (typically `250m` and `512Mi`; `100m` and `128Mi` for a static site), and env. A fresh app is a prototype: `minScale: 1`, `maxScale: 2`. Once the user says it serves real users, leave both out so the production defaults apply. Files that must survive restarts (SQLite, uploads) need `storage` on the first deploy: per-replica storage cannot be added to an existing workload without recreating it.
7. **Let it finish.** While the build runs, call `deploy_app` again with the same arguments plus the returned `buildId`; once it is deploying, make the call its result names. A `failed` build with a log is a code fix: correct the file (`write_app_files` `edits`, or on disk), then deploy again without `buildId`. Never rebuild unchanged files or re-apply an unchanged spec. Not ready after a good build: `diagnose_workload`; a crash or port mismatch is also a code fix.
8. **Hand over.** Give the canonical URL and the image. Stored: add a download link, `get_app_files` with `download: true`, shown as returned (no login, about an hour, not for shared places). Then offer to make changes.

## Changing an existing app

A change to the workload's settings (scaling, env, exposure, probes) is `update_workload` and needs none of this. For the code, take NAME from the workload image `//image/NAME:TAG` and call `get_app_files`:

| `get_app_files` says | Source of truth | What to do |
|---|---|---|
| Files written through `write_app_files` | Control Plane's copy | Read the file, edit with `write_app_files` (`edits` need the exact current text), then `deploy_app`. To move the app local: download the archive and continue there |
| Files uploaded by the CLI from a folder | The user's folder | With a filesystem: edit there, rebuild with `cpln image build --remote --dir`, then `deploy_app` with the new `image`. Without: tell the user what to change; `write_app_files` refuses without `adopt: true` |
| No files; images built from a repository | The repository | Change it there, then `deploy_app` with `repoUrl` |
| No files; images pushed outside a build | Unknown | Ask the user where the code lives; never rewrite it |
| No files, no images | A new app | Start the journey |

`adopt: true` makes Control Plane's copy the source of truth from then on, or reuses a name for a new app; use it only when the user asks. Remove files that no longer belong with `deletePaths`. A custom domain after the app is up: `domain` skill.

## Limits

- 100 MB per file, 1 GB and 20,000 files per app; 200 files and 100 MB per call. Inline content is text, up to 1 MB per file per call; `get_app_files` reads any file in slices with `offset` and `length`.
- Paths are relative with forward slashes; `..`, absolute paths, `node_modules/`, and `.git/` are refused. Writing to a name that already has files merges into them, and deleting the image record keeps the files.
- A wrong port or a bind to `127.0.0.1` shows up as a readiness failure, not a build failure.
- A build service not yet updated for app files refuses `write_app_files` with an explicit message; then use a repository or the local way.

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

With a filesystem and a working CLI, local is the default; stored is fine when the user asks for it. The CLI only builds: `ORG` is the org the tools use, and the deploy, every read, and every secret go through the tools. Never hand a CLI command to a user without a filesystem. Say which way you are taking.

Other starting points: an existing image or a git repository goes straight to `deploy_app` (`image` or `repoUrl`); a folder the user already has is built with the CLI. A database or Redis the app needs comes from `mcp__cpln__add_database`, whose result lists the env values to pass to `deploy_app`; other infrastructure comes from the Template Catalog (`template-catalog` skill). An app the user asks for, for example a blog, a wiki, or a shop, is one you write; install a template instead only when they name one. Never build a database from source or inline an app into a base image.

## Decide before you build

A stateless app, one that keeps nothing (for example a game, a calculator, or a landing page), has nothing to decide: build it on the `deploy_app` defaults with no storage, and say so. An app that keeps anything (content, records, files, or sign-ins; for example a portfolio, a blog, a wiki, a shop, or a ledger) gets what a production app of its kind has, even where the user did not spell it out: content the owner adds or changes after launch (menu items, products, posts, and their photos) is managed from the app itself and kept on its file storage, never built into the image, and the owner adds what they already have from the app once it runs.

Call `mcp__cpln__plan_app` first. It returns how Control Plane keeps files, records, secrets, and replicas, and the tools that do each. Plan as a senior engineer would for a real business: put to the user in one message the decisions that shape the build and that the request does not settle (for example how the owner and staff sign in), each with the option you recommend as production and industry practice, why, and the alternatives, and build nothing until they answer; a user who says "your call" gets your recommendations. Never ask for content the owner will add from the app, or to confirm what they already said or what `plan_app` settles. Build what they chose, production ready from the first deploy: what it keeps survives restarts and deploys, and a deploy never takes it offline. Choose what fits this user, not the most elaborate build. Give prices only when the user asks.

## The journey

1. **Name.** Short kebab-case, at most 40 characters (`todo-app`). The same name is the app files name, the image NAME, and the workload name, for the app's whole life; a different name is a different app.
2. **Write a deployable app.** Bind `0.0.0.0`, listen on the port from the `PORT` env var with a default of 8080, and serve `GET /healthz` with 200. Read configuration from env, and secrets through `cpln://secret/NAME.KEY` references; no credentials or `.env` values in files, which the tool refuses. Mail (contact forms, bookings, password resets) needs a provider key the user pastes in the Console after `create_secret` with values "user", never in the chat. Add a `Dockerfile` on `linux/amd64` bases (`node:20-slim`, `python:3.12-slim`, `golang:1.23`); auto-detection works for common stacks, but a Dockerfile gives a readable build log. Leave out `node_modules`, build output, and lockfiles you did not generate. Never put the user's name, email, or other personal details on a public page they did not ask for: use clear placeholders and ask.
3. **Files the user has** (a logo, photos, fonts, a PDF, a dataset) never go inline and cannot be forwarded from the chat. Content the owner adds or changes after launch (menu items, products, posts, and their photos) never goes through an upload link, not even as a first batch: once the app runs, the owner adds it from the app, including the files they already have, and the app keeps it on its file storage (`plan_app`). An upload link is only for files that stay as they are until the next build. In the same turn you write the code, call `mcp__cpln__create_app_files_upload_link` with a `label` the user understands on each entry: `files` for each file the code uses in one specific place (the logo, the hero image), and `folders` for a set the code does not tell apart (photos the user says will not change), which takes up to 100 files (`max`, up to 200) the user never matches to paths; add `caption` ("Where it was taken") when the code needs each one named. Have the code read a folder's files from a data file (`src/photos.json`), since their names and count are known only after the upload. Give the user the link as returned. Once they say it is done, call `mcp__cpln__get_app_files`, fill the data file from the uploaded paths and captions, and use each named file's stored path: another format keeps its own extension (`logo.svg` for `logo.png`). `write_app_files` `moves` renames a file without a new upload. Locally, those files go into the folder by hand.
4. **Write the files.** Stored: `write_app_files` with `files` (path and whole content, text only); a large generated file goes in parts, `files` for the first and `appends` for the rest; a big app spans several calls with the same `name`.
5. **Target.** Use the GVC the user named; a name that does not exist yet is created in `location`. Otherwise `deploy_app` uses the GVC a job made for apps and asks before using any other. When the org has none, it creates one once you pass `location`: recommend the location nearest most of the users from the list it returns, say why, and let the user choose; when they leave it to you, pass the one you recommended and say which.
6. **Deploy.** Pass `port`, `public: true` for an app the user will open, `healthPath: "/healthz"`, CPU and memory for the runtime (typically `250m` and `512Mi`; `100m` and `128Mi` for a static site), env, `storage` with `shared: true` when the app keeps files on Control Plane, and `timeoutSeconds` when a request may take longer than 5 seconds. The app runs two replicas and deploys without downtime, so nothing it keeps lives on one replica: records in a database, files on shared storage or in a bucket. SQLite needs `storage` without `shared`: one stateful replica on a disk of its own, offline briefly on each deploy. Files that must survive restarts (SQLite, uploads) need storage on the first deploy: per-replica storage cannot be added to an existing workload without recreating it.
7. **Let it finish.** While the build runs, call `deploy_app` again with the same arguments plus the returned `buildId`; once it is deploying, make the call its result names. A `failed` build with a log is a code fix: correct the file (`write_app_files` `edits`, or on disk), then deploy again without `buildId`. Never rebuild unchanged files or re-apply an unchanged spec. Not ready after a good build: `diagnose_workload`; a crash or port mismatch is also a code fix.
8. **Hand over.** Give the canonical URL and the image. When the owner adds content from the app, say where they sign in and add it, including the files they mentioned. Stored: add a download link, `get_app_files` with `download: true`, shown as returned (no login, about an hour, not for shared places). Then offer to make changes.

## Changing an existing app

A change to the workload's settings (scaling, env, exposure, probes) is `update_workload` and needs none of this. A change of plan (a database, file storage, backups) follows `plan_app` the same way, then the tools it names. For the code, take NAME from the workload image `//image/NAME:TAG` and call `get_app_files`:

| `get_app_files` says | Source of truth | What to do |
|---|---|---|
| Files written through `write_app_files` | Control Plane's copy | Read the file, edit with `write_app_files` (`edits` need the exact current text), then `deploy_app`. To move the app local: download the archive and continue there |
| Files uploaded by the CLI from a folder | The user's folder | With a filesystem: edit there, rebuild with `cpln image build --remote --dir PATH --name NAME:TAG --org ORG`, then `deploy_app` with the new `image`. Without: tell the user what to change; `write_app_files` refuses without `adopt: true` |
| No files; images built from a repository | The repository | Change it there, then `deploy_app` with `repoUrl` |
| No files; images pushed outside a build | Unknown | Ask the user where the code lives; never rewrite it |
| No files, no images | A new app | Start the journey |

`adopt: true` makes Control Plane's copy the source of truth from then on, or reuses a name for a new app; use it only when the user asks. Remove files that no longer belong with `deletePaths`. A custom domain after the app is up: `domain` skill.

## Limits

- 100 MB per file, 1 GB and 20,000 files per app; 200 files and 8 MB per call. An upload link takes 50 named files and 10 folders of up to 200 files each, for an hour. Inline content is text, up to 1 MB per file per call; `get_app_files` reads any file in slices with `offset` and `length`.
- Paths are relative with forward slashes; `..`, absolute paths, `node_modules/`, and `.git/` are refused. Writing to a name that already has files merges into them, and deleting the image record keeps the files.
- A wrong port or a bind to `127.0.0.1` shows up as a readiness failure, not a build failure.
- A build service not yet updated for app files refuses `write_app_files` with an explicit message; then use a repository or the local way.

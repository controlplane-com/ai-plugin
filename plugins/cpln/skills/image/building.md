# Building Images on Control Plane

Companion to `skills/image/SKILL.md`. Read this when actually building an image — choosing between `cpln image build` and direct Docker, configuring buildpacks per language, or hitting platform-mismatch errors.

## Choosing Between `cpln image build` and Docker

| Path | When to use |
|:---|:---|
| `cpln image build` | Default. Handles Dockerfile + buildpack workflows, authenticates to the org's private registry automatically, pushes in one step. |
| Direct `docker buildx build` | When you need Buildx-only features (multi-platform manifests, advanced cache backends) or your build pipeline is already Docker-native. |

Always verify command details against `cpln image build --help` before authoring new examples — flags and defaults change.

## Option A: `cpln image build` (recommended)

**Required flag:** `--name IMAGE-NAME:IMAGE-TAG`.

**Common flags:**
- `--push` — push to your org's private registry after build.
- `--dockerfile PATH` — path to Dockerfile (default: `./Dockerfile`). If set, buildpacks are not used.
- `--dir PATH` — directory containing the application (default: `.`).
- `--no-cache` — build without using cached layers.
- `--platform linux/amd64` — target platform (default: `linux/amd64`).
- `--builder` / `-B` — buildpack builder image (default: `heroku/builder:24_linux-amd64`).
- `--buildpack` / `-b` — specific buildpack (repeatable).
- `--env KEY=VALUE` / `-e` — build-time env var (repeatable, NOT available at runtime).
- `--env-file PATH` — file with build-time env vars.

**Context flags:** `--org`, `--profile`.

**Dockerfile example:**

```bash
cpln image build --name my-app:v1.0 --push --org my-org
```

**Buildpack example (no Dockerfile, auto-detected):**

```bash
cpln image build --name my-app:v1.0 --push --org my-org
```

## Option B: Docker CLI directly

Use this path when you need `docker buildx` features or your pipeline is already Docker-native.

**Prerequisites:** Verify Buildx is available:

```bash
docker buildx version
```

If Buildx is missing, either install the [Docker Buildx plugin](https://docs.docker.com/build/install-buildx/) or substitute `docker build` (single-platform only).

**Steps:**

```bash
# 1. Authenticate Docker to your org's registry
cpln image docker-login --org my-org

# 2. Build targeting linux/amd64
docker buildx build --platform=linux/amd64 \
  -t my-org.registry.cpln.io/my-app:v1.0 .

# 3. Push
docker push my-org.registry.cpln.io/my-app:v1.0
```

## Platform Requirement: `linux/amd64`

All Control Plane managed locations run `linux/amd64`. Wrong platform causes `exec format error` at runtime.

- The default platform for `cpln image build` is `linux/amd64` — safe on any host including Apple Silicon.
- For direct `docker buildx build`, always pass `--platform=linux/amd64`.
- Verify after building: `cpln image get my-app:v1.0 --org my-org -o json`.

## Buildpacks (no Dockerfile)

Cloud Native Buildpacks automatically detect your application language and produce an optimized image — no Dockerfile required. Good for standard frameworks; use a Dockerfile when you need custom system packages or build steps.

**Default builder:** `heroku/builder:24_linux-amd64`. Override with `-B`/`--builder` for Paketo, Google Cloud Buildpacks, or community builders.

**Build-time vs runtime env vars:** Variables set with `--env`/`--env-file` are available only during the build. They are NOT available at container runtime — use workload env vars for that.

**Procfile format** — single-line file in the project root:

```
web: <start-command>
```

Required for some languages (see per-language notes below).

### Node.js

- **Detection:** `package.json` plus a lockfile (`package-lock.json`, `yarn.lock`, or `pnpm-lock.yaml`)
- **Start command:** auto-detected from `index.js`, `server.js`, `scripts.start` in `package.json`, or `Procfile`
- **Version pinning:** set `engines.node` in `package.json`
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`
- **Pitfall:** missing lockfile → buildpack won't detect Node

### Python

- **Detection:** one of:
  - `requirements.txt` (pip)
  - `uv.lock` (uv) — also requires `.python-version`
  - `poetry.lock` (Poetry)
- **Start command:** **Procfile is REQUIRED.** Python buildpacks do not auto-detect web servers.
- **Runtime:** the server must bind to `0.0.0.0` and listen on `$PORT`
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`
- **Poetry note:** non-packaged apps need `package-mode = false` in `pyproject.toml`
- **Pitfall:** no Procfile → container builds but starts and immediately exits

### Go

- **Detection:** `go.mod` in the project root
- **Structure:** the `main` package must be in the project root
- **Start command:** auto-detected — the compiled binary is used automatically
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`

### Java (Maven)

- **Detection:** `pom.xml`
- **Build:** runs `mvn package`
- **Start command:** auto-detected for Spring Boot apps; other frameworks need a `Procfile`
- **Runtime:** bind to `0.0.0.0`, listen on `$PORT`
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`

### Java (Gradle)

- **Detection:** `build.gradle` or `build.gradle.kts`, plus the `gradlew` wrapper
- **Build:** runs `./gradlew build`
- **Start command:** auto-detected for Spring Boot apps; other frameworks need a `Procfile`
- **Runtime:** bind to `0.0.0.0`, listen on `$PORT`
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`

### Ruby

- **Detection:** `Gemfile` plus `Gemfile.lock`
- **Start command:** Rails apps are auto-detected, but a `Procfile` is recommended; non-Rails apps require a `Procfile`
- **Runtime:** must listen on `$PORT`
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`

### PHP

- **Detection:** `composer.json` plus `composer.lock`
- **Start command:** **Procfile is REQUIRED**
- **Command:** `cpln image build --name my-app:v1.0 --push --org my-org`

### Rust

- **NOT supported by the default `heroku/builder:24_linux-amd64` builder.**
- **Detection:** `Cargo.toml`, `Cargo.lock`, and a binary target
- **Build:** `cargo build --release`
- **Runtime:** must listen on `$PORT`
- **Command:**

  ```bash
  cpln image build --name my-app:v1.0 --push --org my-org \
    -b docker.io/paketocommunity/rust
  ```

### C# / .NET

- **NOT supported by the default `heroku/builder:24_linux-amd64` builder.**
- **Detection:** `.csproj`, `.fsproj`, or `.sln`
- **Build:** runs `dotnet publish` (Release configuration)
- **Runtime:** bind to `0.0.0.0` and set `ASPNETCORE_URLS=http://0.0.0.0:$PORT`
- **Command:**

  ```bash
  cpln image build --name my-app:v1.0 --push --org my-org \
    -B paketobuildpacks/builder-jammy-base
  ```

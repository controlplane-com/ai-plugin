#!/usr/bin/env python3
"""Export a complete public upload without modifying the local plugin or publishing it."""
import argparse
import hashlib
from io import BytesIO
import json
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import unicodedata
from urllib.parse import urlsplit
from urllib.request import urlopen
import zipfile

import jsonschema
from PIL import Image
import yaml

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugins/cpln"
REVIEW = ROOT / "openai-review.json"
SCHEMAS = Path(__file__).resolve().parent / "schemas"
NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
NUMBER = r"(?:0|[1-9]\d*)"
PRERELEASE = rf"(?:{NUMBER}|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION = re.compile(rf"{NUMBER}\.{NUMBER}\.{NUMBER}(?:-{PRERELEASE}(?:\.{PRERELEASE})*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")
MANIFESTS = ("plugin.json", ".codex-plugin/plugin.json")
URL_FIELDS = ("websiteURL", "supportURL", "privacyPolicyURL", "termsOfServiceURL")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def https_url(value, label):
    require(isinstance(value, str) and len(value) <= 1024, f"{label}: missing or invalid URL")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password,
            f"{label}: use HTTPS without credentials")
    return parsed


def json_bytes(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def source_file(path):
    for part in (path, *path.parents):
        require(not part.is_symlink(), f"Symlinks cannot be uploaded: {part}")
        if part == ROOT:
            break
    require(path.is_file(), f"Missing packaged file: {path}")
    return path.read_bytes()


def interface_of(manifest):
    return manifest.get("extensions", {}).get("com.openai", {}).get("interface", manifest.get("interface", {}))


def validate_files(files):
    """Validate the actual archive inventory and bytes, including compatibility files."""
    normalized = set()
    for name, body in files.items():
        path = PurePosixPath(name)
        require(not path.is_absolute() and ".." not in path.parts and "\\" not in name,
                f"Unsafe archive path: {name}")
        require(str(path) == name, f"Non-canonical archive path: {name}")
        folded = unicodedata.normalize("NFC", name).casefold()
        require(folded not in normalized, f"Conflicting archive path: {name}")
        normalized.add(folded)
        require("hooks" not in path.parts and name != ".app.json", f"Unsupported public component: {name}")
        require(not any(p in {"node_modules", ".git", "__pycache__", ".DS_Store"} for p in path.parts),
                f"Unrelated generated file: {name}")
        require(not path.name.startswith(".env") and path.suffix not in {".pem", ".key", ".p12", ".pfx"},
                f"Secret-bearing file must stay outside the ZIP: {name}")
        require(not re.search(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}", body),
                f"Credential-like content detected in {name}; inspect it locally")

    root = json.loads(files["plugin.json"])
    config = json.loads(files["mcp.json"])
    for filename, value in (("plugin", root), ("mcp", config)):
        schema = json.loads((SCHEMAS / f"{filename}.schema.json").read_text())
        jsonschema.Draft202012Validator(schema).validate(value)
    require(NAME.fullmatch(root["name"]) and len(root["name"]) <= 64, "Invalid public plugin name")
    require(isinstance(root.get("version"), str) and VERSION.fullmatch(root["version"]), "Use an explicit semantic version")

    for name in MANIFESTS:
        if name not in files:
            continue
        manifest = json.loads(files[name])
        extension = manifest.get("extensions", {}).get("com.openai", {})
        for obj in (manifest, extension):
            require(obj.get("apps") is None and obj.get("hooks") is None, f"{name}: apps/hooks are not public-uploadable")
        require(manifest["name"] == root["name"] and manifest["version"] == root["version"], f"{name}: identity/version mismatch")
        interface = interface_of(manifest)
        for field, limit in (("displayName", 30), ("shortDescription", 30), ("longDescription", 4000), ("developerName", 80)):
            value = interface.get(field)
            require(isinstance(value, str) and value.strip() and len(value) <= limit, f"{name}: invalid {field} (max {limit})")
        for field in URL_FIELDS:
            https_url(interface.get(field), f"{name}:{field}")
        prompts = interface.get("defaultPrompt", [])
        prompts = [prompts] if isinstance(prompts, str) else prompts
        require(isinstance(prompts, list) and 1 <= len(prompts) <= 3, f"{name}: supply one to three prompts")
        require(all(isinstance(p, str) and p.strip() and len(p) <= 128 and "\n" not in p and "\r" not in p and "@" not in p
                    for p in prompts), f"{name}: invalid default prompt")
        require(len({" ".join(p.split()) for p in prompts}) == len(prompts), f"{name}: duplicate prompts")
        for field, minimum in (("logo", 256), ("composerIcon", 48), ("logoDark", 256), ("composerIconDark", 48)):
            if field not in interface and field.endswith("Dark"):
                continue
            relative = interface.get(field, "")
            require(relative.startswith("./"), f"{name}:{field}: use a contained relative path")
            asset = relative[2:]
            require(asset in files, f"Missing icon: {asset}")
            data = files[asset]
            require(data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24, f"{asset}: a PNG is required for submission")
            with Image.open(BytesIO(data)) as icon:
                width, height = icon.size
                require(icon.format == "PNG" and width == height and minimum <= width <= 4096 and len(data) <= 5 * 1024 * 1024,
                        f"{asset}: invalid icon dimensions/size")
                icon.verify()

    servers = config["mcpServers"]
    require(len(servers) == 1, "This public package requires exactly one MCP server")
    server = next(iter(servers.values()))
    require(server["type"] == "streamable-http" and not server.get("headers"), "Use remote HTTP with host-managed OAuth, no inline credentials")
    https_url(server["url"], "MCP URL")
    if ".mcp.json" in files:
        legacy = json.loads(files[".mcp.json"])["mcpServers"]
        require(set(legacy) == set(servers), "Compatibility MCP identity mismatch")
        require(all(legacy[key]["url"] == value["url"] for key, value in servers.items()), "Compatibility MCP URL mismatch")

    skills = []
    for name, body in files.items():
        if not re.fullmatch(r"skills/[^/]+/SKILL\.md", name):
            continue
        require(len(body) <= 256 * 1024, f"Skill is too large: {name}")
        match = re.match(r"^---\r?\n(.*?)\r?\n---(?:\r?\n|$)", body.decode("utf-8"), re.S)
        require(match is not None, f"Missing skill frontmatter: {name}")
        front = yaml.safe_load(match[1])
        expected = PurePosixPath(name).parent.name
        require(isinstance(front, dict) and front.get("name") == expected and NAME.fullmatch(expected), f"Skill name mismatch: {name}")
        description = front.get("description")
        require(isinstance(description, str) and description.strip() and len(description) <= 1024, f"Invalid skill description: {name}")
        skills.append(expected)
    require(skills, "No skills packaged")

    extension = root["extensions"]["com.openai"]
    review = extension.get("review", {})
    cases = review.get("test_cases", {})
    tools = json.loads((ROOT / "scripts/tools-manifest.json").read_text())["tools"]
    for kind, minimum in (("positive", 5), ("negative", 3)):
        rows = cases.get(kind, [])
        require(isinstance(rows, list) and len(rows) >= minimum, f"Supply {minimum} {kind} review cases")
        for row in rows:
            for field in ("description", "prompt", "tools_triggered", "expected_behavior") if kind == "positive" else ("description", "prompt"):
                require(isinstance(row.get(field), str) and row[field].strip(), f"{kind} case: invalid {field}")
            if kind == "positive":
                names = [n.strip() for n in row["tools_triggered"].split(",")]
                require(all(n in tools and tools[n] == "core" for n in names), f"Case uses an unavailable core tool: {names}")
    require(extension.get("publication", {}).get("release_notes", "").strip(), "Missing release notes")
    if "commerce" in review:
        require(type(review["commerce"]) is bool, "review.commerce must be a boolean")
        require(not review["commerce"] or review.get("commerce_description", "").strip(), "Describe the commerce behavior")
    if review.get("demo_recording_url"):
        https_url(review["demo_recording_url"], "Demo recording URL")
    gaps = []
    if not review.get("demo_recording_url"):
        gaps.append("Verify an existing walkthrough covers this release, or record and host a new demo; then add review.demo_recording_url.")
    if "commerce" not in review:
        gaps.append("Confirm whether the plugin offers purchases or payment actions before declaring review.commerce.")
    return {"name": root["name"], "version": root["version"], "skills": sorted(skills),
            "mcp_url": server["url"], "metadata_gaps": gaps,
            "portal_checks": ["Verify the existing plugin identity, registered MCP URL, publisher, and preserved country availability.",
                              "Deploy the compatible MCP and build service, then verify the actual tools and scans in the portal.",
                              "Run the five positive and three negative cases with the dedicated reviewer account; drafted cases are not test results.",
                              "Verify demo playback and reviewer access; enter credentials only in secure portal fields.",
                              "The authorized publisher completes policy attestations, submits for review, and publishes the approved version."]}


def validate_archive(path):
    with zipfile.ZipFile(path) as archive:
        files = {}
        roots = set()
        for entry in archive.infolist():
            require(not stat.S_ISLNK(entry.external_attr >> 16), f"Archive contains a symlink: {entry.filename}")
            require(not entry.is_dir(), "Export should contain files only")
            parts = entry.filename.split("/", 1)
            require(len(parts) == 2, "ZIP must contain one plugin directory")
            roots.add(parts[0])
            require(parts[1] not in files, f"Duplicate archive entry: {entry.filename}")
            files[parts[1]] = archive.read(entry)
        require(len(roots) == 1, "ZIP must contain exactly one plugin")
        report = validate_files(files)
        require(roots == {report["name"]}, "ZIP directory must match plugin name")
        report["files"] = sorted(files)
        report["sha256"] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        return report


def export_files(version, mcp_url, review_path=REVIEW):
    root = json.loads(source_file(PLUGIN / "plugin.json"))
    root["version"] = version
    extension = root["extensions"]["com.openai"]
    require("review" not in extension, "plugins/cpln/plugin.json must not carry review materials; they live in openai-review.json, outside version control")
    require(review_path.is_file(), f"Missing review materials: {review_path} holds the test cases and the demo recording URL, and is never committed")
    extension["review"] = json.loads(source_file(review_path))
    files = {"plugin.json": json_bytes(root)}
    overlay = json.loads(source_file(PLUGIN / ".codex-plugin/plugin.json"))
    overlay["version"] = version
    files[".codex-plugin/plugin.json"] = json_bytes(overlay)
    config = json.loads(source_file(PLUGIN / "mcp.json"))
    next(iter(config["mcpServers"].values()))["url"] = mcp_url
    files["mcp.json"] = json_bytes(config)
    files[".mcp.json"] = json_bytes({"mcpServers": {key: {"url": value["url"]} for key, value in config["mcpServers"].items()}})
    for directory in ("skills", "rules"):
        for path in sorted((PLUGIN / directory).rglob("*")):
            if any(part in {".DS_Store", ".git", "node_modules", "__pycache__"} for part in path.relative_to(PLUGIN).parts):
                continue
            require(not path.is_symlink(), f"Symlinks cannot be uploaded: {path}")
            if path.is_file():
                files[path.relative_to(PLUGIN).as_posix()] = source_file(path)
    for manifest in (root, overlay):
        for field in ("logo", "composerIcon", "logoDark", "composerIconDark"):
            relative = interface_of(manifest).get(field)
            if relative:
                require(relative.startswith("./") and not PurePosixPath(relative[2:]).is_absolute()
                        and ".." not in PurePosixPath(relative).parts and "\\" not in relative, f"Unsafe asset path: {relative}")
                files[relative[2:]] = source_file(PLUGIN / relative[2:])
    files["knowledge-map.json"] = source_file(PLUGIN / "knowledge-map.json")
    files["LICENSE"] = source_file(ROOT / "LICENSE")
    validate_files(files)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", help="Public package version; independent of local marketplace release tags")
    parser.add_argument("--mcp-url", help="The exact URL already registered for the published plugin; do not migrate it in an update")
    parser.add_argument("--review", type=Path, default=REVIEW, help="Review cases and demo recording URL, kept out of version control")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--draft", action="store_true", help="Allow missing review materials; mark the archive as an incomplete draft")
    parser.add_argument("--validate", type=Path, help="Validate an existing export instead of creating one")
    parser.add_argument("--check-live", action="store_true", help="Compare public /about inventory with current source; not an authenticated tools/list check")
    args = parser.parse_args()
    if args.validate:
        report = validate_archive(args.validate)
    else:
        require(args.version and args.mcp_url, "Export requires --version and --mcp-url")
        files = export_files(args.version, args.mcp_url, args.review)
        preliminary = validate_files(files)
        require(args.draft or not preliminary["metadata_gaps"], "Review materials incomplete; use --draft only for preparation: " + "; ".join(preliminary["metadata_gaps"]))
        args.output.mkdir(parents=True, exist_ok=True)
        suffix = "-draft" if args.draft else ""
        target = args.output / f"{preliminary['name']}-{args.version}{suffix}.zip"
        require(not target.exists(), f"Export already exists: {target}; use a fresh output directory")
        with tempfile.TemporaryDirectory() as temp:
            staged = Path(temp) / target.name
            with zipfile.ZipFile(staged, "w", zipfile.ZIP_DEFLATED) as archive:
                for name, body in sorted(files.items()):
                    info = zipfile.ZipInfo(f"{preliminary['name']}/{name}", date_time=(2026, 1, 1, 0, 0, 0))
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = (stat.S_IFREG | 0o644) << 16
                    archive.writestr(info, body)
            report = validate_archive(staged)
            target.write_bytes(staged.read_bytes())
        report["archive"] = str(target.resolve())
    if args.check_live:
        url = https_url(report["mcp_url"], "MCP URL")
        with urlopen(f"{url.scheme}://{url.netloc}/about", timeout=25) as response:
            live = json.load(response)
        local = set(json.loads((ROOT / "scripts/tools-manifest.json").read_text())["tools"]) - {"cpln_api_request"}
        report["live_inventory"] = {"build": live.get("version"), "timestamp": live.get("timestamp"),
                                    "missing_tools": sorted(local - set(live["tools"])),
                                    "obsolete_tools": sorted(set(live["tools"]) - local)}
    incomplete = args.draft or report["metadata_gaps"] or report.get("live_inventory", {}).get("missing_tools")
    report["status"] = "draft; not ready to submit" if incomplete else "package metadata validated; portal checks remain"
    print(json.dumps(report, indent=2))
    if "archive" in report:
        Path(report["archive"]).with_suffix(".report.json").write_bytes(json_bytes(report))
    require(args.draft or not report["metadata_gaps"], "Review materials are incomplete")
    if args.check_live:
        require(not report["live_inventory"]["missing_tools"], "Hosted server is missing tools required by this release; deploy it before submission")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, jsonschema.ValidationError, yaml.YAMLError) as error:
        raise SystemExit(str(error))

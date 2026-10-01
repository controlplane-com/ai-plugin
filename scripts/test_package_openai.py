"""Regression checks for public exports and unsafe or incomplete archives."""
import copy
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("package_openai", Path(__file__).with_name("package-openai.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

REVIEW_FIXTURE = Path(__file__).with_name("fixtures") / "openai-review.json"


class PublicPackageTests(unittest.TestCase):
    def setUp(self):
        config = json.loads((package.PLUGIN / "mcp.json").read_text())
        self.url = config["mcpServers"]["cpln"]["url"]
        self.files = package.export_files("1.1.0", self.url, REVIEW_FIXTURE)

    def mutate_manifest(self, path, mutate):
        value = json.loads(self.files[path])
        mutate(value)
        self.files[path] = package.json_bytes(value)

    def test_export_preserves_source_and_excludes_local_hooks(self):
        manifest = (package.PLUGIN / "plugin.json").read_bytes()
        original_hooks = (package.PLUGIN / "hooks/hooks.json").read_bytes()
        report = package.validate_files(self.files)
        self.assertEqual(report["version"], "1.1.0")
        self.assertIn("create-app", report["skills"])
        self.assertFalse(any("hooks" in Path(name).parts for name in self.files))
        self.assertEqual((package.PLUGIN / "plugin.json").read_bytes(), manifest)
        self.assertEqual((package.PLUGIN / "hooks/hooks.json").read_bytes(), original_hooks)
        self.assertTrue(report["metadata_gaps"])

    def test_review_materials_come_only_from_the_local_file(self):
        exported = json.loads(self.files["plugin.json"])["extensions"]["com.openai"]["review"]
        self.assertEqual(exported, json.loads(REVIEW_FIXTURE.read_text()))
        with self.assertRaises(ValueError):
            package.export_files("1.1.0", self.url, REVIEW_FIXTURE.with_name("missing.json"))

    def test_rejects_apps_and_hook_declarations_in_both_manifests(self):
        original = copy.deepcopy(self.files)
        for filename in package.MANIFESTS:
            for field in ("apps", "hooks"):
                for location in ("root", "extension"):
                    with self.subTest(filename=filename, field=field, location=location):
                        self.files = copy.deepcopy(original)
                        def change(manifest):
                            target = manifest if location == "root" else manifest.setdefault("extensions", {}).setdefault("com.openai", {})
                            target[field] = []
                        self.mutate_manifest(filename, change)
                        with self.assertRaises((ValueError, package.jsonschema.ValidationError)):
                            package.validate_files(self.files)

    def test_rejects_unsafe_and_private_files(self):
        for name in ("../outside", "skills/./hidden", "hooks/hooks.json", ".app.json", ".env", "assets/key.pem"):
            with self.subTest(name=name):
                files = {**self.files, name: b"{}"}
                with self.assertRaises(ValueError):
                    package.validate_files(files)

    def test_rejects_missing_asset_and_non_square_icon(self):
        icon = "assets/icon-square.png"
        for value in (None, (package.PLUGIN / "assets/icon.png").read_bytes()):
            files = {**self.files}
            if value is None:
                del files[icon]
            else:
                files[icon] = value
            with self.assertRaises(ValueError):
                package.validate_files(files)

    def test_rejects_invalid_frontmatter_and_version(self):
        for content in (b"No frontmatter", b"---\nname: wrong\ndescription: example\n---\nBody"):
            with self.assertRaises(ValueError):
                package.validate_files({**self.files, "skills/create-app/SKILL.md": content})
        for version in ("1.01.0", "1.1.0-01", "1.1.0-", "1.1.0+."):
            with self.subTest(version=version):
                files = copy.deepcopy(self.files)
                manifest = json.loads(files["plugin.json"])
                manifest["version"] = version
                files["plugin.json"] = package.json_bytes(manifest)
                with self.assertRaises(ValueError):
                    package.validate_files(files)

    def test_rejects_case_and_unicode_path_collisions(self):
        for a, b in (("assets/Test.txt", "assets/test.txt"), ("assets/caf\u00e9.txt", "assets/cafe\u0301.txt")):
            with self.assertRaises(ValueError):
                package.validate_files({**self.files, a: b"a", b: b"b"})

    def test_rejects_unknown_review_tool_and_invalid_subtitle(self):
        original = copy.deepcopy(self.files)
        self.mutate_manifest("plugin.json", lambda m: m["extensions"]["com.openai"]["review"]["test_cases"]["positive"][0].update(tools_triggered="removed_tool"))
        with self.assertRaises(ValueError):
            package.validate_files(self.files)
        self.files = original
        self.mutate_manifest("plugin.json", lambda m: m["extensions"]["com.openai"]["interface"].update(shortDescription="x" * 31))
        with self.assertRaises(ValueError):
            package.validate_files(self.files)

    def test_archive_is_checked_after_packaging_and_symlinks_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "plugin.zip"
            with zipfile.ZipFile(path, "w") as archive:
                for name, body in self.files.items():
                    archive.writestr("cpln/" + name, body)
            self.assertIn("create-app", package.validate_archive(path)["skills"])
            with zipfile.ZipFile(path, "a") as archive:
                entry = zipfile.ZipInfo("cpln/assets/link")
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, "outside")
            with self.assertRaises(ValueError):
                package.validate_archive(path)


if __name__ == "__main__":
    unittest.main()

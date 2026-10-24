"""Behavioral source-memory tests; every mutation uses an isolated temporary project."""
import concurrent.futures
import copy
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "src/skills/basix-source-memory/scripts/source_memory.py"
SPEC = importlib.util.spec_from_file_location("source_memory", SCRIPT)
sm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sm)
TODAY = datetime.date.today().isoformat()


class SourceMemoryTests(unittest.TestCase):
    """Exercise catalog boundaries and real subprocess persistence."""

    def setUp(self):
        """Create an isolated project for this test instance.

        Args:
            self: Current isolated test fixture.
        """
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)

    def observation(self, **changes):
        """Return a valid observation overridden by keyword changes.

        Args:
            self: Current isolated test fixture.
            changes: Keyword overrides for the generated observation or review.
        """
        value = {"source": "Example.org", "scope": "General cooking instruction", "source_type": "guide",
                 "find": "Search the recipe index", "contains": "Cooking methods and recipes", "categories": ["food", "guides"]}
        value.update(changes)
        return value

    def review(self, evidence_quality="strong", accountability="unknown", **changes):
        """Return a justified review using evidence_quality, accountability, and keyword changes.

        Args:
            self: Current isolated test fixture.
            evidence_quality: Evidence-quality axis for the generated assessment.
            accountability: Accountability axis for the generated assessment.
            changes: Keyword overrides for the generated observation or review.
        """
        value = {"date": TODAY, "scope": "General cooking instruction", "reason": "Representative methods independently checked",
                 "evidence": ["https://independent.example/check?v=2"], "evidence_quality": evidence_quality,
                 "accountability": accountability, "trustability": sm.MATRIX[evidence_quality][accountability]}
        value.update(changes)
        return value

    def write(self, observation):
        """Persist observation in this isolated project.

        Args:
            self: Current isolated test fixture.
            observation: Proposed source-observation object, or None when unused.
        """
        return sm.mutate(self.project, "record", observation)

    def load(self):
        """Return validated catalogs from this isolated project.

        Args:
            self: Current isolated test fixture.
        """
        return sm.load(self.project / ".basix/sources")

    def cli(self, *arguments, observation=None):
        """Run CLI arguments with optional observation JSON on standard input.

        Args:
            self: Current isolated test fixture.
            observation: Proposed source-observation object, or None when unused.
            arguments: CLI subcommand and option arguments.
        """
        result = subprocess.run([sys.executable, str(SCRIPT), "--project", str(self.project), *arguments],
                                input=json.dumps(observation) if observation is not None else None,
                                text=True, capture_output=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        return result.returncode, json.loads(result.stdout)

    def test_seed_and_domain_independent_facets(self):
        """Seed exactly 37 valid facets and allow cooking guides without computing.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation())
        cats, sources = self.load()
        self.assertEqual(37, len(cats["categories"]))
        self.assertEqual(["food", "guides"], sources["sources"][0]["categories"])
        self.assertIn("any subject", next(c["description"] for c in cats["categories"] if c["id"] == "best-practices"))

    def test_lazy_reads_and_invalid_record(self):
        """Read commands and invalid input leave no catalog directory or lock.

        Args:
            self: Current isolated test fixture.
        """
        for arguments in [("list",), ("show", "example.org"), ("validate",)]:
            self.assertEqual(0, self.cli(*arguments)[0])
        self.assertFalse((self.project / ".basix").exists())
        self.assertEqual(2, self.cli("record", "--input", "-", observation=self.observation(find="x " * 33))[0])
        self.assertFalse((self.project / ".basix").exists())

    def test_bounds_and_types(self):
        """Enforce word counts, tag limits, integer types, and unknown-key rejection.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation(find="word " * 32))
        for change in [{"find": "word " * 33}, {"contains": "word " * 33}, {"categories": ["food"] * 2},
                       {"categories": ["food", "guides", "arts", "health", "history", "business"]},
                       {"helpful": 1}, {"assessment": self.review(trustability=True)},
                       {"expected_revision": True}, {"unexpected": "x"}]:
            with self.subTest(change=change), self.assertRaises(sm.CatalogError):
                self.write(self.observation(**change))
        for value in [{"id": "a" * 17, "description": "Test"}, {"id": "test", "description": "word " * 17}]:
            with self.assertRaises(sm.CatalogError):
                sm.category(value)

    def test_neutral_assessed_and_all_matrix_cells(self):
        """Unknown starts neutral; independently evidenced pseudonymous sources can be trusted.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation())
        self.assertEqual("unassessed", self.load()[1]["sources"][0]["assessment_status"])
        for quality in sm.MATRIX:
            for accountability in sm.MATRIX[quality]:
                source = quality + "-" + accountability + ".example.org"
                self.write(self.observation(source=source, assessment=self.review(quality, accountability)))
        records = self.load()[1]["sources"]
        self.assertEqual(1, next(s["trustability"] for s in records if s["source"] == "strong-unknown.example.org"))
        neutral = next(s for s in records if s["source"] == "open-unknown.example.org")
        self.assertEqual((0, "assessed"), (neutral["trustability"], neutral["assessment_status"]))

    def test_history_recheck_and_scope_changes(self):
        """Preserve justified changes while unchanged reviews avoid history bloat.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation(assessment=self.review()))
        self.write({"source": "example.org", "assessment": self.review(reason="Rechecked representative instructions")})
        self.assertEqual(1, len(self.load()[1]["sources"][0]["history"]))
        with self.assertRaises(sm.CatalogError):
            self.write({"source": "example.org", "assessment": self.review("unreliable", reason="Rechecked representative instructions")})
        self.write({"source": "example.org", "assessment": self.review("unreliable", reason="Material uncorrected falsehood independently demonstrated", evidence=["https://review.example/correction"])})
        item = self.load()[1]["sources"][0]
        self.assertEqual([1, -1], [h["trustability"] for h in item["history"]])
        with self.assertRaises(sm.CatalogError):
            self.write({"source": "example.org", "scope": "Different subject"})
        self.write({"source": "example.org", "scope": "Different subject", "reset": self.review("open", scope="Different subject", reason="Scope changed and requires new evaluation", evidence=["https://example.org/new-scope"])})
        self.assertEqual("unassessed", self.load()[1]["sources"][0]["assessment_status"])

    def test_rating_changes_at_same_url_and_historical_assessment(self):
        """Changed content at one URL supports reassessment without backdating entry creation.

        Args:
            self: Current isolated test fixture.
        """
        historical = "2000-01-01"
        original = self.review(date=historical)
        self.write(self.observation(assessment=original))
        item = self.load()[1]["sources"][0]
        self.assertEqual(TODAY, item["created"])
        self.assertEqual(historical, item["last_reviewed"])
        downgrade = self.review("unreliable", reason="The same review now documents material uncorrected falsehood")
        self.write({"source": "example.org", "assessment": downgrade})
        upgrade = self.review(reason="The same page now verifies corrected representative instructions independently")
        self.write({"source": "example.org", "assessment": upgrade})
        item = self.load()[1]["sources"][0]
        self.assertEqual([1, -1, 1], [event["trustability"] for event in item["history"]])
        self.assertTrue(all(event["evidence"] == original["evidence"] for event in item["history"]))
        self.assertEqual(TODAY, item["created"])
        with self.assertRaises(sm.CatalogError):
            self.write({"source": "example.org", "assessment": self.review("unreliable", reason=upgrade["reason"])})
        with self.assertRaises(sm.CatalogError):
            self.write({"source": "example.org", "assessment": self.review(date=historical)})

    def test_canonical_scopes_and_lookup(self):
        """Canonicalization preserves tenants and path case; parent lookup discloses scope mismatch.

        Args:
            self: Current isolated test fixture.
        """
        self.assertEqual("xn--bcher-kva.example/Manual", sm.canonical("https://Bücher.example/Manual/"))
        for bad in ["localhost", "127.0.0.1", "example.org:80", "example.org:", "example.org?", "example.org#", "https://user:pass@example.org", "https://@example.org", "https://:@example.org", "example.org/a/../b", "example.org/a//b", "example.org/%2F", "example.org/%252f", "example.org/a?x=1", "example.org/#x"]:
            with self.subTest(bad=bad), self.assertRaises(sm.CatalogError):
                sm.canonical(bad)
        with self.assertRaises(sm.CatalogError):
            self.write(self.observation(source="example.org/manual", scope=""))
        self.write(self.observation(source="example.org/manual", assessment=self.review()))
        _, result = self.cli("show", "example.org/manual/topic", "--lookup")
        self.assertEqual("example.org/manual", result["matched_key"])
        self.assertFalse(result["trust_applies_to_requested"])
        self.assertNotIn("history", result["source"])
        self.assertNotIn("usage_events", result["source"])
        self.assertIsNone(self.cli("show", "example.org/manual-other", "--lookup")[1]["source"])
        self.assertIsNone(self.cli("show", "tenant.example.org/manual", "--lookup")[1]["source"])

    def test_categories_fixed_and_seed_preserves_local_meaning(self):
        """Fixed definitions cannot be redefined; initialization respects first creator semantics.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation())
        with self.assertRaises(sm.CatalogError):
            sm.mutate(self.project, "add-category", category_value={"id": "food", "description": "Different meaning"})
        sm.mutate(self.project, "add-category", category_value={"id": "geology", "description": "Earth materials and processes."})
        sm.mutate(self.project, "add-category", category_value={"id": "geology", "description": "Earth materials and processes."})
        with self.assertRaises(sm.CatalogError):
            sm.mutate(self.project, "add-category", category_value={"id": "rocks", "description": "EARTH materials and processes!"})
        cats = {"version": 1, "revision": 0, "categories": [{"id": "guides", "description": "Local first creator meaning."}]}
        sm.seed(cats)
        self.assertEqual("Local first creator meaning.", cats["categories"][0]["description"])

    def test_usage_retry_and_stale_revision(self):
        """Stable task/source hashes survive retries; stale writes cannot clobber a catalog.

        Args:
            self: Current isolated test fixture.
        """
        for _ in range(3):
            self.write(self.observation(helpful=True, use_role="lead", use_note="Identify cooking instructions for later verification", task_id="logical-task-one"))
        self.write(self.observation(helpful=True, use_role="lead", use_note="Identify cooking instructions for later verification", task_id="logical-task-two"))
        item = self.load()[1]["sources"][0]
        self.assertEqual(2, item["usefulness"])
        self.assertEqual(2, len(item["usage_events"]))
        self.assertNotIn("logical-task-one", (self.project / ".basix/sources/sources.toml").read_text())
        before = (self.project / ".basix/sources/sources.toml").read_bytes()
        with self.assertRaises(sm.CatalogError):
            self.write(self.observation(expected_revision=0))
        self.assertEqual(before, (self.project / ".basix/sources/sources.toml").read_bytes())

    def test_concurrent_writes(self):
        """Concurrent CLI writers retain all independent helpful observations.

        Args:
            self: Current isolated test fixture.
        """
        def run(index):
            """Persist one isolated task identified by index.

            Args:
                index: Distinct logical task index for the concurrent write.
            """
            return self.cli("record", "--input", "-", observation=self.observation(helpful=True, use_role="lead", use_note="Identify cooking instructions for later verification", task_id="task-" + str(index)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(run, range(12)))
        self.assertTrue(all(status == 0 for status, _ in results), results)
        self.assertEqual(12, self.load()[1]["sources"][0]["usefulness"])

    def test_unicode_roundtrip_and_malformed_no_clobber(self):
        """Unicode and quotes roundtrip; malformed state is never repaired by guessing.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation(contains="Crème brûlée, 日本語 and quoted \"recipes\""))
        self.assertIn("日本語", self.load()[1]["sources"][0]["contains"])
        value = {"a": "\b\f\n\t\u0000😀"}
        self.assertEqual(value, tomllib.loads(sm.serialize(value)))
        path = self.project / ".basix/sources/sources.toml"
        path.write_text("broken = [")
        with self.assertRaises(sm.CatalogError):
            self.write(self.observation())
        self.assertEqual("broken = [", path.read_text())

    def test_interrupted_pair_write_safe_recovery(self):
        """Failure after categories replacement leaves valid unused categories and no dangling refs.

        Args:
            self: Current isolated test fixture.
        """
        original = sm.atomic_write
        def fail_sources(path, content):
            """Write content at path except the simulated failing sources replacement.

            Args:
                path: Filesystem path to read or atomically replace.
                content: Complete validated UTF-8 TOML content to persist.
            """
            if path.name == "sources.toml":
                raise OSError("simulated interruption")
            original(path, content)
        with patch.object(sm, "atomic_write", fail_sources), self.assertRaises(sm.CatalogError):
            self.write(self.observation(new_categories=[{"id": "geology", "description": "Earth materials and geological processes."}]))
        cats, sources = self.load()
        self.assertEqual([], sources["sources"])
        self.assertIn("geology", [c["id"] for c in cats["categories"]])
        self.write(self.observation())
        self.assertEqual(1, len(self.load()[1]["sources"]))

    def test_symlinks_and_secret_urls(self):
        """Unsafe filesystem paths and credential-bearing URLs fail without exposing credentials.

        Args:
            self: Current isolated test fixture.
        """
        with tempfile.TemporaryDirectory() as outside:
            (self.project / ".basix").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(sm.CatalogError):
                self.write(self.observation())
            (self.project / ".basix").unlink()
        self.write(self.observation())
        path = self.project / ".basix/sources/sources.toml"
        backup = self.project / "backup"
        path.rename(backup)
        path.symlink_to(backup)
        self.assertEqual(2, self.cli("validate")[0])
        path.unlink()
        backup.rename(path)
        for url in ["https://u:secret@example.org/x", "https://@example.org/x", "https://:@example.org/x", "https://example.org/#", "https://example.org?access_token=TOPSECRET", "https://example.org?api-key=TOPSECRET", "https://example.org/x#fragment"]:
            status, result = self.cli("record", "--input", "-", observation=self.observation(assessment=self.review(evidence=[url])))
            self.assertEqual(2, status)
            self.assertNotIn("TOPSECRET", json.dumps(result))

    def test_safe_evidence_queries_remain_exact(self):
        """Retain harmless evidence query parameters exactly, including empty queries.

        Args:
            self: Current isolated test fixture.
        """
        urls = ["https://example.org/check?version=2&lang=en", "https://example.org/check?"]
        self.write(self.observation(assessment=self.review(evidence=urls)))
        self.assertEqual(urls, self.load()[1]["sources"][0]["assessment"]["evidence"])

    def test_use_roles_retry_history_and_unreliable_objects(self):
        """Usage roles describe purpose independently of current source trust.

        Args:
            self: Current isolated test fixture.
        """
        bad = self.observation(assessment=self.review("unreliable"), helpful=True,
                              task_id="analysis-one", use_role="object", use_note="Analyze the mechanism of misleading cooking claims")
        self.write(bad)
        self.write(dict(bad, use_role="position", use_note="Document the publisher position"))
        item = self.load()[1]["sources"][0]
        self.assertEqual((-1, 1), (item["trustability"], item["usefulness"]))
        self.assertEqual(["object", "position"], item["usage_events"][0]["roles"])
        self.assertEqual(bad["use_note"], item["usage_events"][0]["use_note"])
        before = (self.project / ".basix/sources/sources.toml").read_bytes()
        with self.assertRaises(sm.CatalogError):
            self.write(dict(bad, use_role="support"))
        self.assertEqual(before, (self.project / ".basix/sources/sources.toml").read_bytes())
        self.write(self.observation(source="reliable.example.org", assessment=self.review(), helpful=True,
                                    task_id="past-support", use_role="support", use_note="Support the specific cooking temperature claim"))
        downgrade = self.review("unreliable", reason="Later independent checking found misleading temperature evidence")
        self.write({"source": "reliable.example.org", "assessment": downgrade})
        # Identical historical support is idempotent, not a renewed endorsement.
        self.write({"source": "reliable.example.org", "helpful": True, "task_id": "past-support",
                    "use_role": "support", "use_note": "Ignored retry note"})
        with self.assertRaises(sm.CatalogError):
            self.write({"source": "reliable.example.org", "helpful": True, "task_id": "new-support",
                        "use_role": "support", "use_note": "New factual support"})
        self.assertEqual(2, len(self.cli("list")[1]["sources"]))
        self.assertEqual(1, len(self.cli("list", "--role", "object")[1]["sources"]))
        self.assertEqual(1, len(self.cli("list", "--role", "support")[1]["sources"]))
        shown = self.cli("show", "reliable.example.org", "--usage")[1]["source"]
        self.assertEqual(["support"], shown["use_roles"])
        self.assertIn("ratings can change", shown["usage_notice"])
        self.assertNotIn("id", shown["usage_events"][0])

    def test_usage_requires_role_and_specific_bounded_purpose(self):
        """Missing/invalid role and purpose fail before catalog initialization.

        Args:
            self: Current isolated test fixture.
        """
        base = self.observation(helpful=True, task_id="task", use_role="lead", use_note="Locate cooking evidence")
        for field in ("use_role", "use_note", "task_id"):
            broken = dict(base)
            del broken[field]
            with self.assertRaises(sm.CatalogError):
                self.write(broken)
        for changes in ({"use_role": "endorse"}, {"use_note": ""}, {"use_note": "word " * 33}):
            with self.assertRaises(sm.CatalogError):
                self.write(dict(base, **changes))
        self.assertFalse((self.project / ".basix").exists())
        self.write(dict(base, use_note="word " * 32))
        cats, sources = self.load()
        for roles in (["support", "support"], ["unknown"], [], ["support", "object"]):
            broken = copy.deepcopy(sources)
            broken["sources"][0]["usage_events"][0]["roles"] = roles
            with self.assertRaises(sm.CatalogError):
                sm.validate_sources(broken, cats)
        broken = copy.deepcopy(sources)
        broken["sources"][0]["usage_events"].append(copy.deepcopy(broken["sources"][0]["usage_events"][0]))
        broken["sources"][0]["usefulness"] = 2
        with self.assertRaises(sm.CatalogError):
            sm.validate_sources(broken, cats)

    def test_catalog_history_and_type_corruption(self):
        """Validation detects counter/history/revision tampering and dangling references.

        Args:
            self: Current isolated test fixture.
        """
        self.write(self.observation(assessment=self.review()))
        cats, sources = self.load()
        for field, value in [("usefulness", True), ("trustability", True), ("categories", ["missing"]), ("updated", "2000-01-01")]:
            broken = copy.deepcopy(sources)
            broken["sources"][0][field] = value
            with self.assertRaises(sm.CatalogError):
                sm.validate_sources(broken, cats)
        broken = copy.deepcopy(sources)
        broken["sources"][0]["history"][0]["old"] = 1
        with self.assertRaises(sm.CatalogError):
            sm.validate_sources(broken, cats)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Deterministic tests for safe Codex Scrapling registration shapes."""

from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "codex_scan", ROOT / "src/setup/scrapling-tor/codex_scan.py"
)
assert SPEC and SPEC.loader
codex_scan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(codex_scan)
ENDPOINT = "http://127.0.0.1:8002/mcp"


def registration() -> dict[str, object]:
    """Return a canonical current Codex registration fixture."""
    return {
        "name": "scrapling",
        "enabled": True,
        "disabled_reason": None,
        "transport": {
            "type": "streamable_http",
            "url": ENDPOINT,
            "bearer_token_env_var": None,
            "http_headers": None,
            "env_http_headers": None,
            "http_headers_helper": None,
        },
        "startup_timeout_sec": None,
        "tool_timeout_sec": None,
        "auth_status": "unknown",
    }


class CodexScanTests(unittest.TestCase):
    """Exercise the fail-closed registration allowlist."""

    def test_current_safe_shape_is_expected(self) -> None:
        self.assertTrue(codex_scan.expected(registration(), ENDPOINT))

    def test_non_null_header_helper_is_rejected(self) -> None:
        entry = registration()
        transport = copy.deepcopy(entry["transport"])
        assert isinstance(transport, dict)
        transport["http_headers_helper"] = "credential-helper"
        entry["transport"] = transport
        self.assertFalse(codex_scan.expected(entry, ENDPOINT))

    def test_credentials_are_rejected(self) -> None:
        for field, value in (
            ("bearer_token_env_var", "TOKEN"),
            ("http_headers", {"Authorization": "secret"}),
            ("env_http_headers", {"Authorization": "TOKEN"}),
        ):
            with self.subTest(field=field):
                entry = registration()
                transport = copy.deepcopy(entry["transport"])
                assert isinstance(transport, dict)
                transport[field] = value
                entry["transport"] = transport
                self.assertFalse(codex_scan.expected(entry, ENDPOINT))

    def test_unknown_fields_are_rejected(self) -> None:
        entry = registration()
        entry["future_field"] = None
        self.assertFalse(codex_scan.expected(entry, ENDPOINT))

    def test_enabled_disabled_and_type_require_declared_types(self) -> None:
        invalid_values = (None, "true", 1, [], {})
        for field in ("enabled", "disabled"):
            for value in invalid_values:
                with self.subTest(field=field, value=value):
                    entry = registration()
                    entry[field] = value
                    self.assertFalse(codex_scan.expected(entry, ENDPOINT))
        for value in invalid_values:
            with self.subTest(field="transport.type", value=value):
                entry = registration()
                transport = copy.deepcopy(entry["transport"])
                assert isinstance(transport, dict)
                transport["type"] = value
                entry["transport"] = transport
                self.assertFalse(codex_scan.expected(entry, ENDPOINT))


if __name__ == "__main__":
    unittest.main()

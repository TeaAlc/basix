#!/usr/bin/env python3
"""Atomically manage Basix developer instructions and native-agent config."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import tomllib

START = "<!-- basix:developer-instructions:start -->"
END = "<!-- basix:developer-instructions:end -->"
AGENT_START = "# basix:agent-config:start"
AGENT_END = "# basix:agent-config:end"
KEY_RE = re.compile(r"^[ \t]*(?:developer_instructions|['\"]developer_instructions['\"])[ \t]*=")
TABLE_RE = re.compile(r"^[ \t]*\[")
AGENT_TABLE_RE = re.compile(
    r"^[ \t]*\[agents\.([A-Za-z0-9_-]+)\][ \t]*(?:#.*)?(?:\r?\n)?$"
)

PLAYWRIGHT_DEFAULT_START = "# basix:playwright-default:start"
PLAYWRIGHT_DEFAULT_END = "# basix:playwright-default:end"
PLAYWRIGHT_FEATURE_START = "# basix:playwright-network-proxy:start"
PLAYWRIGHT_FEATURE_END = "# basix:playwright-network-proxy:end"
PLAYWRIGHT_PERMISSIONS_START = "# basix:playwright-permissions:start"
PLAYWRIGHT_PERMISSIONS_END = "# basix:playwright-permissions:end"
PLAYWRIGHT_SEPARATOR_MARKER = "# basix:playwright-separator:owned"
NO_FINAL_ASSIGNMENT_SEPARATOR = "<!-- basix:developer-instructions:separator-owned -->"

PLAYWRIGHT_DEFAULT_BLOCK = (
    f"{PLAYWRIGHT_DEFAULT_START}\n"
    'default_permissions = "playwright"\n'
    f"{PLAYWRIGHT_DEFAULT_END}\n"
)
PLAYWRIGHT_FEATURE_ASSIGNMENT_BLOCK = (
    f"{PLAYWRIGHT_FEATURE_START}\n"
    "network_proxy = true\n"
    f"{PLAYWRIGHT_FEATURE_END}\n"
)
PLAYWRIGHT_FEATURE_DOTTED_BLOCK = (
    f"{PLAYWRIGHT_FEATURE_START}\n"
    "features.network_proxy = true\n"
    f"{PLAYWRIGHT_FEATURE_END}\n"
)
PLAYWRIGHT_FEATURE_TABLE_BLOCK = (
    f"{PLAYWRIGHT_FEATURE_START}\n"
    "features.network_proxy = true\n"
    f"{PLAYWRIGHT_FEATURE_END}\n"
)
PLAYWRIGHT_PERMISSIONS_BLOCK = (
    f"{PLAYWRIGHT_PERMISSIONS_START}\n"
    "[permissions.playwright]\n"
    'extends = ":workspace"\n'
    "\n"
    "[permissions.playwright.network]\n"
    "enabled = true\n"
    'mode = "limited"\n'
    "allow_local_binding = true\n"
    "\n"
    "[permissions.playwright.network.domains]\n"
    '"localhost" = "allow"\n'
    '"127.0.0.1" = "allow"\n'
    '"::1" = "allow"\n'
    f"{PLAYWRIGHT_PERMISSIONS_END}\n"
)


class ConfigError(ValueError):
    pass


def raw_marker_span(text: str, start: str, end: str) -> tuple[int, int] | None:
    starts = [match.start() for match in re.finditer(re.escape(start), text)]
    ends = [match.end() for match in re.finditer(re.escape(end), text)]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ConfigError(f"configuration contains damaged or duplicate {start} markers")
    block_end = ends[0]
    if block_end < len(text) and text[block_end] == "\n":
        block_end += 1
    return starts[0], block_end


def playwright_marker_span(
    text: str, start: str, end: str, expected: str | tuple[str, ...] | None = None
) -> tuple[int, int] | None:
    """Locate one complete Playwright marker pair.

    Args:
        text: Full configuration text.
        start: Opening marker line.
        end: Closing marker line.
        expected: Exact owned block(s), when validating ownership.
    """
    occurrences = text.count(start) + text.count(end)
    if not occurrences:
        return None
    starts = [m for m in re.finditer(rf"(?m)^[ \t]*{re.escape(start)}[ \t]*\r?$", text)]
    ends = [m for m in re.finditer(rf"(?m)^[ \t]*{re.escape(end)}[ \t]*\r?$", text)]
    if len(starts) != 1 or len(ends) != 1 or starts[0].start() >= ends[0].start():
        raise ConfigError("configuration contains damaged or duplicate Playwright markers")
    raw_start = starts[0].start()
    block_end = ends[0].end()
    if text.startswith("\r\n", block_end):
        block_end += 2
    elif block_end < len(text) and text[block_end] == "\n":
        block_end += 1
    actual = text[raw_start:block_end].replace("\r\n", "\n")
    expected_values = (expected,) if isinstance(expected, str) else expected
    if expected_values is not None and actual not in expected_values:
        raise ConfigError("configuration contains a modified Playwright-managed block")
    span_start = raw_start
    if PLAYWRIGHT_SEPARATOR_MARKER in actual:
        if text.startswith("\r\n", raw_start - 2):
            span_start -= 2
        elif raw_start > 0 and text[raw_start - 1] == "\n":
            span_start -= 1
        else:
            raise ConfigError("Playwright separator marker is missing its owned newline")
    return span_start, block_end


def append_managed_block(text: str, block: str) -> str:
    """Append one owned TOML block without rewriting existing bytes.

    Args:
        text: Existing configuration text.
        block: Complete marker-delimited block ending in a newline.
    """
    newline = "\r\n" if "\r\n" in text else "\n"
    block = block.replace("\r\n", "\n").replace("\n", newline)
    separator = "" if not text or text.endswith(newline) else newline
    if separator and block.startswith("# basix:playwright-"):
        block = mark_playwright_separator(block, newline)
    return text + separator + block


def append_top_level_block(text: str, block: str) -> str:
    """Insert a managed block before the first TOML table.

    Args:
        text: Existing configuration text.
        block: Complete marker-delimited block ending in a newline.
    """
    offset = 0
    for line in text.splitlines(keepends=True):
        if re.match(r"^[ \t]*\[\[?[^\]]+\]\]?[ \t]*(?:#.*)?(?:\r?\n)?$", line):
            previous_start = text.rfind("\n", 0, offset - 1) + 1 if offset else 0
            previous = text[previous_start:offset].strip()
            if re.match(r"^#[^\n]*:start$", previous):
                offset = previous_start
            prefix, suffix = text[:offset], text[offset:]
            newline = "\r\n" if "\r\n" in text else "\n"
            block = block.replace("\r\n", "\n").replace("\n", newline)
            before = "" if not prefix or prefix.endswith(newline) else newline
            if before and block.startswith("# basix:playwright-"):
                block = mark_playwright_separator(block, newline)
            after = ""
            return prefix + before + block + after + suffix
        offset += len(line)
    return append_managed_block(text, block)


def mark_playwright_separator(block: str, newline: str) -> str:
    """Mark a Playwright block whose preceding separator is Basix-owned.

    Args:
        block: Complete marker-delimited Playwright block using LF endings.
        newline: Newline sequence used by the surrounding configuration.
    """
    first, rest = block.split(newline, 1)
    return f"{first}{newline}{PLAYWRIGHT_SEPARATOR_MARKER}{newline}{rest}"


def table_region(text: str, name: str) -> tuple[int, int] | None:
    """Return byte offsets for a normal TOML table.

    Args:
        text: Full configuration text.
        name: Dotted table name without brackets.
    """
    lines = text.splitlines(keepends=True)
    offset = 0
    found: tuple[int, int] | None = None
    for line in lines:
        match = re.match(r"^[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?(?:\r?\n)?$", line)
        array = re.match(r"^[ \t]*\[\[([^\[\]]+)\]\]", line)
        if match and match.group(1).strip() == name:
            if found is not None:
                raise ConfigError(f"configuration contains duplicate [{name}] tables")
            found = (offset, len(text))
        elif array and array.group(1).strip() == name:
            raise ConfigError(f"configuration contains an array table for [{name}]")
        elif found is not None and (match or array):
            found = (found[0], offset)
            break
        offset += len(line)
    return found


def has_dotted_assignment(text: str, prefix: str) -> bool:
    """Check for an existing top-level dotted TOML assignment.

    Args:
        text: Full configuration text.
        prefix: Dotted key prefix, including its trailing dot.
    """
    return bool(re.search(rf"(?m)^[ \t]*{re.escape(prefix)}[A-Za-z0-9_-]+[ \t]*=", text))


def remove_span(text: str, span: tuple[int, int]) -> str:
    """Remove one exact managed span.

    Args:
        text: Full configuration text.
        span: Start and exclusive end offsets.
    """
    return text[: span[0]] + text[span[1] :]


def playwright_profile_is_required(profile: object) -> bool:
    """Return whether a parsed profile has exactly the managed values.

    Args:
        profile: Parsed ``permissions.playwright`` TOML value.
    """
    return profile == {
        "extends": ":workspace",
        "network": {
            "enabled": True,
            "mode": "limited",
            "allow_local_binding": True,
            "domains": {"localhost": "allow", "127.0.0.1": "allow", "::1": "allow"},
        },
    }


def playwright_parse(text: str) -> dict:
    """Parse TOML and return its top-level mapping.

    Args:
        text: Full configuration text.
    """
    try:
        return tomllib.loads(text) if text.strip() else {}
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML: {exc}") from exc


def playwright_owned_spans(text: str) -> dict[str, tuple[int, int] | None]:
    """Validate and locate every Playwright-managed marker pair.

    Args:
        text: Full configuration text.
    """
    spans = {
        "default": playwright_marker_span(
            text,
            PLAYWRIGHT_DEFAULT_START,
            PLAYWRIGHT_DEFAULT_END,
            (PLAYWRIGHT_DEFAULT_BLOCK, mark_playwright_separator(PLAYWRIGHT_DEFAULT_BLOCK, "\n")),
        ),
        "feature": playwright_marker_span(
            text,
            PLAYWRIGHT_FEATURE_START,
            PLAYWRIGHT_FEATURE_END,
            tuple(
                block
                for base in (
                    PLAYWRIGHT_FEATURE_ASSIGNMENT_BLOCK,
                    PLAYWRIGHT_FEATURE_DOTTED_BLOCK,
                    PLAYWRIGHT_FEATURE_TABLE_BLOCK,
                )
                for block in (base, mark_playwright_separator(base, "\n"))
            ),
        ),
        "permissions": playwright_marker_span(
            text, PLAYWRIGHT_PERMISSIONS_START, PLAYWRIGHT_PERMISSIONS_END,
            (PLAYWRIGHT_PERMISSIONS_BLOCK, mark_playwright_separator(PLAYWRIGHT_PERMISSIONS_BLOCK, "\n")),
        ),
    }
    feature = spans["feature"]
    feature_block = text[feature[0] : feature[1]].replace("\r\n", "\n") if feature is not None else None
    if feature_block and feature_block.startswith("\n"):
        feature_block = feature_block[1:]
    if feature is not None and feature_block not in {
        PLAYWRIGHT_FEATURE_ASSIGNMENT_BLOCK,
        PLAYWRIGHT_FEATURE_DOTTED_BLOCK,
        PLAYWRIGHT_FEATURE_TABLE_BLOCK,
        mark_playwright_separator(PLAYWRIGHT_FEATURE_ASSIGNMENT_BLOCK, "\n"),
        mark_playwright_separator(PLAYWRIGHT_FEATURE_DOTTED_BLOCK, "\n"),
        mark_playwright_separator(PLAYWRIGHT_FEATURE_TABLE_BLOCK, "\n"),
    }:
        raise ConfigError("configuration contains a modified Playwright-managed block")
    marker_presence = [span is not None for span in spans.values()]
    if any(marker_presence) and not all(marker_presence):
        raise ConfigError("configuration contains incomplete Playwright-managed markers")
    return spans


def playwright_validate_foreign(text: str, parsed: dict, spans: dict[str, tuple[int, int] | None]) -> None:
    """Reject unmanaged values that overlap the Playwright ownership boundary.

    Args:
        text: Full configuration text.
        parsed: Parsed TOML mapping.
        spans: Validated owned marker spans.
    """
    managed = all(span is not None for span in spans.values())
    if managed:
        if parsed.get("default_permissions") != "playwright":
            raise ConfigError("Playwright default marker is not a top-level default_permissions setting")
        features = parsed.get("features")
        if not isinstance(features, dict) or features.get("network_proxy") is not True:
            raise ConfigError("Playwright network-proxy marker is not an effective features.network_proxy setting")
        permissions = parsed.get("permissions")
        profile = permissions.get("playwright") if isinstance(permissions, dict) else None
        if not playwright_profile_is_required(profile):
            raise ConfigError("Playwright permission marker is not an effective permissions.playwright profile")
    if "default_permissions" in parsed:
        if not managed or parsed["default_permissions"] != "playwright":
            raise ConfigError("foreign default_permissions conflicts with Basix Playwright settings")
    features = parsed.get("features")
    if features is not None:
        if not isinstance(features, dict):
            raise ConfigError("top-level features must be a table")
        if "network_proxy" in features and (not managed or features["network_proxy"] is not True):
            raise ConfigError("foreign features.network_proxy conflicts with Basix Playwright settings")
    permissions = parsed.get("permissions")
    if permissions is not None and not isinstance(permissions, dict):
        raise ConfigError("top-level permissions must be a table")
    profile = (permissions or {}).get("playwright") if isinstance(permissions, dict) else None
    if profile is not None and (not managed or not playwright_profile_is_required(profile)):
        raise ConfigError("foreign permissions.playwright conflicts with Basix Playwright settings")
    if not managed:
        if has_dotted_assignment(text, "features.") and "features" not in parsed:
            raise ConfigError("foreign dotted features configuration conflicts with Basix Playwright settings")
        if re.search(r"(?m)^[ \t]*permissions[ \t]*=", text) and "permissions" not in parsed:
            raise ConfigError("foreign permissions configuration conflicts with Basix Playwright settings")


def playwright_feature_insert(text: str, parsed: dict) -> tuple[str, str]:
    """Insert the managed network-proxy assignment in the safest TOML location.

    Args:
        text: Full configuration text.
        parsed: Parsed TOML mapping.
    """
    region = table_region(text, "features")
    if region is not None:
        start, end = region
        insertion = text[start:end]
        newline = "\r\n" if "\r\n" in text else "\n"
        separator = "" if not insertion or insertion.endswith(newline) else newline
        block = PLAYWRIGHT_FEATURE_ASSIGNMENT_BLOCK.replace("\r\n", "\n").replace("\n", newline)
        if separator:
            block = mark_playwright_separator(block, newline)
        return text[:end] + separator + block + text[end:], "existing"
    if has_dotted_assignment(text, "features."):
        return append_top_level_block(text, PLAYWRIGHT_FEATURE_DOTTED_BLOCK), "dotted"
    if "features" in parsed:
        raise ConfigError("cannot safely extend foreign inline features configuration")
    return append_top_level_block(text, PLAYWRIGHT_FEATURE_TABLE_BLOCK), "created"


def playwright_add_text(text: str) -> tuple[str, str]:
    """Validate and add or update all managed Playwright settings.

    Args:
        text: Existing configuration text.
    """
    parsed = playwright_parse(text)
    spans = playwright_owned_spans(text)
    playwright_validate_foreign(text, parsed, spans)
    if all(span is not None for span in spans.values()):
        return text, "unchanged"

    result = text
    if spans["default"] is None:
        result = append_top_level_block(result, PLAYWRIGHT_DEFAULT_BLOCK)
    if spans["feature"] is None:
        result, _ = playwright_feature_insert(result, playwright_parse(result))
    if spans["permissions"] is None:
        result = append_managed_block(result, PLAYWRIGHT_PERMISSIONS_BLOCK)
    playwright_parse(result)
    return result, "changed"


def playwright_remove_text(text: str) -> tuple[str, str]:
    """Validate and remove only Basix-owned Playwright settings.

    Args:
        text: Existing configuration text.
    """
    parsed = playwright_parse(text)
    spans = playwright_owned_spans(text)
    playwright_validate_foreign(text, parsed, spans)
    if not any(span is not None for span in spans.values()):
        return text, "unchanged"
    result = text
    for current in sorted(
        (span for span in spans.values() if span is not None), reverse=True
    ):
        result = remove_span(result, current)
    playwright_parse(result)
    return result, "changed"


def playwright_check_text(text: str, mode: str) -> str:
    """Validate a requested Playwright transition without writing.

    Args:
        text: Existing configuration text.
        mode: ``enable`` or ``disable``.
    """
    if mode == "enable":
        _, status = playwright_add_text(text)
        return status
    if mode == "disable":
        _, status = playwright_remove_text(text)
        return status
    raise ConfigError(f"unsupported Playwright check mode: {mode}")


# The legacy Playwright implementation above remains available only to validate
# and migrate configurations written by released Basix versions. New installs
# use the purpose-oriented capability names below.
CAPABILITY_DEFAULT_START = "# basix:local-access-default:start"
CAPABILITY_DEFAULT_END = "# basix:local-access-default:end"
CAPABILITY_FEATURE_START = "# basix:local-network-feature:start"
CAPABILITY_FEATURE_END = "# basix:local-network-feature:end"
CAPABILITY_PROFILE_START = "# basix:local-access-profile:start"
CAPABILITY_PROFILE_END = "# basix:local-access-profile:end"
CAPABILITY_SEPARATOR_MARKER = "# basix:local-access-separator:owned"

LOCAL_NETWORK_PROFILE = "local-network"
TEST_SOCKET_PROFILE = "test-socket"
COMBINED_PROFILE = "local-network-test-socket"


def capability_profile_name(local_network: bool, test_socket: bool) -> str | None:
    """Return the one effective profile for the requested capabilities.

    Args:
        local_network: Whether loopback network permissions are requested.
        test_socket: Whether the repository-local test socket is requested.
    """
    if local_network and test_socket:
        return COMBINED_PROFILE
    if local_network:
        return LOCAL_NETWORK_PROFILE
    if test_socket:
        return TEST_SOCKET_PROFILE
    return None


def project_socket_path(project_root: Path) -> str:
    """Return the canonical absolute test socket path for a project root.

    Args:
        project_root: Project root, which may not exist yet.
    """
    root = Path(os.path.realpath(os.fspath(project_root)))
    if not root.is_absolute():
        raise ConfigError("project root must be absolute")
    return os.fspath(root / "test" / "test.sock")


def capability_default_block(profile: str) -> str:
    """Render the managed default permission assignment.

    Args:
        profile: Effective Basix permission profile name.
    """
    return (
        f"{CAPABILITY_DEFAULT_START}\n"
        f"default_permissions = {json.dumps(profile)}\n"
        f"{CAPABILITY_DEFAULT_END}\n"
    )


def capability_feature_block() -> str:
    """Render the managed local network proxy feature assignment."""
    return (
        f"{CAPABILITY_FEATURE_START}\n"
        "network_proxy = true\n"
        f"{CAPABILITY_FEATURE_END}\n"
    )


def capability_feature_dotted_block() -> str:
    """Render the managed dotted local network proxy assignment."""
    return (
        f"{CAPABILITY_FEATURE_START}\n"
        "features.network_proxy = true\n"
        f"{CAPABILITY_FEATURE_END}\n"
    )


def capability_feature_table_block() -> str:
    """Render the managed local network proxy table."""
    return (
        f"{CAPABILITY_FEATURE_START}\n"
        "[features]\n"
        "network_proxy = true\n"
        f"{CAPABILITY_FEATURE_END}\n"
    )


def capability_profile_block(
    local_network: bool, test_socket: bool, socket_path: str
) -> str:
    """Render one complete managed permission profile.

    Args:
        local_network: Whether to include loopback network permissions.
        test_socket: Whether to include the exact Unix test socket permission.
        socket_path: Absolute canonical repository test socket path.
    """
    profile = capability_profile_name(local_network, test_socket)
    if profile is None:
        raise ConfigError("at least one local access capability is required")
    lines = [CAPABILITY_PROFILE_START, f"[permissions.{profile}]", 'extends = ":workspace"', ""]
    if local_network:
        lines.extend(
            [
                f"[permissions.{profile}.network]",
                "enabled = true",
                'mode = "limited"',
                "allow_local_binding = true",
                "",
                f"[permissions.{profile}.network.domains]",
                '"localhost" = "allow"',
                '"127.0.0.1" = "allow"',
                '"::1" = "allow"',
            ]
        )
    if test_socket:
        if local_network:
            lines.append("")
        lines.extend(
            [
                f"[permissions.{profile}.network.unix_sockets]",
                f"{json.dumps(socket_path)} = \"allow\"",
            ]
        )
    lines.extend([CAPABILITY_PROFILE_END, ""])
    return "\n".join(lines)


def capability_mark_block(
    block: str, newline: str, marker: str = CAPABILITY_SEPARATOR_MARKER
) -> str:
    """Mark a capability block whose preceding separator is Basix-owned.

    Args:
        block: Complete marker-delimited block using ``newline`` endings.
        newline: Physical line ending used by the surrounding configuration.
        marker: Ownership marker inserted after the first line.
    """
    first, rest = block.split(newline, 1)
    return f"{first}{newline}{marker}{newline}{rest}"


def capability_marker_span(
    text: str,
    start: str,
    end: str,
    expected: str | tuple[str, ...] | None = None,
) -> tuple[int, int] | None:
    """Locate and validate one capability-owned marker pair.

    Args:
        text: Full TOML configuration text.
        start: Opening marker line.
        end: Closing marker line.
        expected: Exact allowed rendered block(s), when available.
    """
    occurrences = text.count(start) + text.count(end)
    if not occurrences:
        return None
    starts = [m for m in re.finditer(rf"(?m)^[ \t]*{re.escape(start)}[ \t]*\r?$", text)]
    ends = [m for m in re.finditer(rf"(?m)^[ \t]*{re.escape(end)}[ \t]*\r?$", text)]
    if len(starts) != 1 or len(ends) != 1 or starts[0].start() >= ends[0].start():
        raise ConfigError("configuration contains damaged or duplicate local-access markers")
    raw_start = starts[0].start()
    block_end = ends[0].end()
    if text.startswith("\r\n", block_end):
        block_end += 2
    elif block_end < len(text) and text[block_end] == "\n":
        block_end += 1
    actual = text[raw_start:block_end].replace("\r\n", "\n")
    expected_values = (expected,) if isinstance(expected, str) else expected
    if expected_values is not None and actual not in expected_values:
        raise ConfigError("configuration contains a modified local-access block")
    span_start = raw_start
    if CAPABILITY_SEPARATOR_MARKER in actual:
        if text.startswith("\r\n", raw_start - 2):
            span_start -= 2
        elif raw_start > 0 and text[raw_start - 1] == "\n":
            span_start -= 1
        else:
            raise ConfigError("local-access separator marker is missing its owned newline")
    return span_start, block_end


def capability_append_block(text: str, block: str) -> str:
    """Append a managed capability block without rewriting foreign bytes.

    Args:
        text: Existing configuration text.
        block: Complete marker-delimited block ending in a newline.
    """
    newline = "\r\n" if "\r\n" in text else "\n"
    rendered = block.replace("\r\n", "\n").replace("\n", newline)
    separator = "" if not text or text.endswith(newline) else newline
    if separator and rendered.startswith("# basix:"):
        rendered = capability_mark_block(rendered, newline)
    return text + separator + rendered


def capability_append_top_level(text: str, block: str) -> str:
    """Insert a managed block before the first TOML table.

    Args:
        text: Existing configuration text.
        block: Complete marker-delimited block ending in a newline.
    """
    offset = 0
    for line in text.splitlines(keepends=True):
        if re.match(r"^[ \t]*\[\[?[^\]]+\]\]?[ \t]*(?:#.*)?(?:\r?\n)?$", line):
            prefix, suffix = text[:offset], text[offset:]
            newline = "\r\n" if "\r\n" in text else "\n"
            rendered = block.replace("\r\n", "\n").replace("\n", newline)
            separator = "" if not prefix or prefix.endswith(newline) else newline
            if separator and rendered.startswith("# basix:"):
                rendered = capability_mark_block(rendered, newline)
            return prefix + separator + rendered + suffix
        offset += len(line)
    return capability_append_block(text, block)


def capability_feature_insert(text: str, parsed: dict) -> str:
    """Insert the managed proxy feature in a TOML-safe location.

    Args:
        text: Existing configuration text.
        parsed: Parsed top-level TOML mapping.
    """
    region = table_region(text, "features")
    if region is not None:
        start, end = region
        insertion = text[start:end]
        newline = "\r\n" if "\r\n" in text else "\n"
        separator = "" if not insertion or insertion.endswith(newline) else newline
        block = capability_feature_block().replace("\n", newline)
        if separator:
            block = capability_mark_block(block, newline)
        return text[:end] + separator + block + text[end:]
    if has_dotted_assignment(text, "features."):
        return capability_append_top_level(text, capability_feature_dotted_block())
    if "features" in parsed:
        raise ConfigError("cannot safely extend foreign inline features configuration")
    return capability_append_top_level(text, capability_feature_table_block())


def capability_expected_spans(text: str, socket_path: str) -> dict[str, tuple[int, int] | None]:
    """Validate and locate all new managed capability marker pairs.

    Args:
        text: Full configuration text.
        socket_path: Absolute canonical repository test socket path.
    """
    defaults = tuple(capability_default_block(profile) for profile in (
        LOCAL_NETWORK_PROFILE, TEST_SOCKET_PROFILE, COMBINED_PROFILE
    ))
    profiles = tuple(
        capability_profile_block(local, socket, socket_path)
        for local, socket in ((True, False), (False, True), (True, True))
    )
    spans = {
        "default": capability_marker_span(
            text, CAPABILITY_DEFAULT_START, CAPABILITY_DEFAULT_END,
            tuple(block for base in defaults for block in (base, capability_mark_block(base, "\n"))),
        ),
        "feature": capability_marker_span(
            text, CAPABILITY_FEATURE_START, CAPABILITY_FEATURE_END,
            tuple(
                block
                for base in (
                    capability_feature_block(),
                    capability_feature_dotted_block(),
                    capability_feature_table_block(),
                )
                for block in (base, capability_mark_block(base, "\n"))
            ),
        ),
        "profile": capability_marker_span(
            text, CAPABILITY_PROFILE_START, CAPABILITY_PROFILE_END,
            tuple(block for base in profiles for block in (base, capability_mark_block(base, "\n"))),
        ),
    }
    present = [span is not None for span in spans.values()]
    if any(present) and spans["default"] is None or any(present) and spans["profile"] is None:
        raise ConfigError("configuration contains incomplete local-access markers")
    if spans["feature"] is not None:
        feature_block = text[spans["feature"][0] : spans["feature"][1]].replace("\r\n", "\n")
        if feature_block.startswith("\n"):
            feature_block = feature_block[1:]
        allowed = tuple(
            block
            for base in (
                capability_feature_block(),
                capability_feature_dotted_block(),
                capability_feature_table_block(),
            )
            for block in (base, capability_mark_block(base, "\n"))
        )
        if feature_block not in allowed:
            raise ConfigError("configuration contains a modified local-network feature block")
    return spans


def capability_profile_is_required(
    profile: object, local_network: bool, test_socket: bool, socket_path: str
) -> bool:
    """Return whether a parsed profile exactly matches a requested combination.

    Args:
        profile: Parsed ``permissions.<profile>`` mapping.
        local_network: Whether loopback network permissions are expected.
        test_socket: Whether the exact Unix test socket is expected.
        socket_path: Absolute canonical repository test socket path.
    """
    expected = tomllib.loads(
        capability_profile_block(local_network, test_socket, socket_path)
        .split(CAPABILITY_PROFILE_START + "\n", 1)[1]
        .rsplit(CAPABILITY_PROFILE_END, 1)[0]
    )["permissions"][capability_profile_name(local_network, test_socket)]
    return profile == expected


def capability_current_modes(parsed: dict, socket_path: str) -> tuple[bool, bool] | None:
    """Return the modes represented by a managed effective profile.

    Args:
        parsed: Parsed TOML mapping.
        socket_path: Absolute canonical repository test socket path.
    """
    default = parsed.get("default_permissions")
    modes = {
        LOCAL_NETWORK_PROFILE: (True, False),
        TEST_SOCKET_PROFILE: (False, True),
        COMBINED_PROFILE: (True, True),
    }
    if default not in modes:
        return None
    permissions = parsed.get("permissions")
    profile = permissions.get(default) if isinstance(permissions, dict) else None
    local_network, test_socket = modes[default]
    if not capability_profile_is_required(profile, local_network, test_socket, socket_path):
        raise ConfigError("local-access profile marker is not an effective managed profile")
    features = parsed.get("features")
    has_feature = isinstance(features, dict) and features.get("network_proxy") is True
    if has_feature != local_network:
        raise ConfigError("local-network feature marker does not match the effective profile")
    return local_network, test_socket


def capability_validate_foreign(
    text: str,
    parsed: dict,
    spans: dict[str, tuple[int, int] | None],
    local_network: bool,
    test_socket: bool,
    socket_path: str,
) -> tuple[bool, bool] | None:
    """Reject unmanaged values that overlap the requested capability boundary.

    Args:
        text: Full configuration text.
        parsed: Parsed TOML mapping.
        spans: New managed marker spans.
        local_network: Requested loopback network mode.
        test_socket: Requested Unix test socket mode.
        socket_path: Absolute canonical repository test socket path.
    """
    managed = spans["default"] is not None or spans["profile"] is not None
    if managed:
        current = capability_current_modes(parsed, socket_path)
        if current is None or spans["default"] is None or spans["profile"] is None:
            raise ConfigError("local-access markers do not describe a managed profile")
        if current[0] != (spans["feature"] is not None):
            raise ConfigError("local-network markers are incomplete")
        return current
    if spans["feature"] is not None:
        raise ConfigError("local-network feature marker is incomplete")
    if "default_permissions" in parsed:
        raise ConfigError("foreign default_permissions conflicts with Basix local-access settings")
    features = parsed.get("features")
    if features is not None and not isinstance(features, dict):
        raise ConfigError("top-level features must be a table")
    if isinstance(features, dict) and "network_proxy" in features:
        raise ConfigError("foreign features.network_proxy conflicts with Basix local-access settings")
    permissions = parsed.get("permissions")
    if permissions is not None and not isinstance(permissions, dict):
        raise ConfigError("top-level permissions must be a table")
    names = {LOCAL_NETWORK_PROFILE, TEST_SOCKET_PROFILE, COMBINED_PROFILE}
    conflicts = sorted(name for name in names if isinstance(permissions, dict) and name in permissions)
    if conflicts:
        raise ConfigError("foreign permissions profile conflicts with Basix: " + ", ".join(conflicts))
    if re.search(r"(?m)^[ \t]*features\.network_proxy[ \t]*=", text):
        raise ConfigError("foreign dotted features.network_proxy conflicts with Basix local-access settings")
    if not (local_network or test_socket):
        return None
    return None


def capability_add_text(
    text: str, project_root: Path, local_network: bool, test_socket: bool
) -> tuple[str, str]:
    """Add, update, migrate, or remove the requested local-access settings.

    Args:
        text: Existing configuration text.
        project_root: Canonical project root, which may not exist yet.
        local_network: Whether loopback network permissions are requested.
        test_socket: Whether the exact Unix test socket is requested.
    """
    socket_path = project_socket_path(project_root)
    parsed = playwright_parse(text)
    spans = capability_expected_spans(text, socket_path)
    legacy = playwright_owned_spans(text)
    if any(span is not None for span in spans.values()) and any(span is not None for span in legacy.values()):
        raise ConfigError("configuration contains both legacy Playwright and local-access markers")
    legacy_managed = all(span is not None for span in legacy.values()) and any(
        span is not None for span in legacy.values()
    )
    if any(span is not None for span in legacy.values()) and not legacy_managed:
        raise ConfigError("configuration contains incomplete legacy Playwright markers")
    if legacy_managed:
        playwright_validate_foreign(text, parsed, legacy)
        current = None
    else:
        current = capability_validate_foreign(
            text, parsed, spans, local_network, test_socket, socket_path
        )
    desired = (local_network, test_socket)
    if current == desired and not legacy_managed:
        return text, "unchanged"
    if not local_network and not test_socket:
        removals = [span for span in (*spans.values(), *legacy.values()) if span is not None]
        result = text
        for span in sorted(removals, reverse=True):
            result = remove_span(result, span)
        playwright_parse(result)
        return result, "changed" if result != text else "unchanged"
    result = text
    removals = [span for span in (*spans.values(), *legacy.values()) if span is not None]
    for span in sorted(removals, reverse=True):
        result = remove_span(result, span)
    profile = capability_profile_name(local_network, test_socket)
    result = capability_append_top_level(result, capability_default_block(profile))
    if local_network:
        result = capability_feature_insert(result, playwright_parse(result))
    result = capability_append_block(
        result, capability_profile_block(local_network, test_socket, socket_path)
    )
    playwright_parse(result)
    return result, "changed"


def capability_remove_text(text: str, project_root: Path) -> tuple[str, str]:
    """Remove only Basix-owned local-access or legacy Playwright settings.

    Args:
        text: Existing configuration text.
        project_root: Canonical project root used to validate socket ownership.
    """
    return capability_add_text(text, project_root, False, False)


def load_agents(source: Path, installed: Path) -> list[tuple[str, Path]]:
    agents: list[tuple[str, Path]] = []
    if not source.is_dir():
        raise ConfigError(f"agent source directory not found: {source}")
    for path in sorted(source.glob("*.toml")):
        try:
            value = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise ConfigError(f"invalid agent TOML {path}: {exc}") from exc
        name = value.get("name")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise ConfigError(f"agent TOML has no valid name: {path}")
        agents.append((name, (installed / path.name).absolute()))
    if not agents:
        raise ConfigError(f"no agent TOMLs found in: {source}")
    names = [name for name, _ in agents]
    if len(names) != len(set(names)):
        raise ConfigError("agent TOMLs contain duplicate names")
    return agents


def render_agent_block(agents: list[tuple[str, Path]]) -> str:
    lines = [AGENT_START]
    for name, path in agents:
        lines.extend((f"[agents.{name}]", f"config_file = {json.dumps(str(path))}", ""))
    lines.append(AGENT_END)
    return "\n".join(lines) + "\n"


def strip_managed_agent_content(
    text: str, names: set[str]
) -> tuple[str, bool]:
    """Remove marker lines and known Basix agent tables, preserving all other bytes."""
    span = raw_marker_span(text, AGENT_START, AGENT_END)
    if span is None:
        return text, False

    block = text[span[0] : span[1]]
    kept: list[str] = []
    pending_comments: list[str] = []
    in_managed_table = False
    for line in block.splitlines(keepends=True):
        if AGENT_START in line or AGENT_END in line:
            pending_comments.clear()
            in_managed_table = False
            continue
        table = AGENT_TABLE_RE.match(line)
        if TABLE_RE.match(line):
            next_is_managed = bool(table and table.group(1) in names)
            if in_managed_table and not next_is_managed:
                kept.extend(pending_comments)
            pending_comments.clear()
            in_managed_table = next_is_managed
            if in_managed_table:
                continue
        if in_managed_table:
            if not line.strip() or line.lstrip().startswith("#"):
                pending_comments.append(line)
            else:
                pending_comments.clear()
        else:
            kept.append(line)

    return text[: span[0]] + "".join(kept) + text[span[1] :], True


def agent_update_text(
    text: str, agents: list[tuple[str, Path]], action: str
) -> tuple[str, str]:
    span = raw_marker_span(text, AGENT_START, AGENT_END)
    expected = render_agent_block(agents)
    if action == "agent-add" and span is not None and text[span[0] : span[1]] == expected:
        return text, "unchanged"

    names = {name for name, _ in agents}
    outside, had_marker = strip_managed_agent_content(text, names)
    try:
        parsed = tomllib.loads(outside) if outside.strip() else {}
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML outside managed agent block: {exc}") from exc
    foreign_agents = parsed.get("agents", {})
    if foreign_agents is not None and not isinstance(foreign_agents, dict):
        raise ConfigError("top-level agents must be a table")
    conflicts = sorted(name for name, _ in agents if name in (foreign_agents or {}))
    if conflicts:
        raise ConfigError(
            "foreign agent definition conflicts with Basix: " + ", ".join(conflicts)
        )

    if action == "agent-check":
        return text, "unchanged"
    if action == "agent-add":
        separator = "" if not outside or outside.endswith("\n") else "\n"
        result = outside + separator + expected
        tomllib.loads(result)
        return result, "changed"
    if not had_marker:
        return text, "unchanged"
    result = outside
    tomllib.loads(result) if result.strip() else None
    return result, "changed"


def marker_span(value: str) -> tuple[int, int] | None:
    starts = [m.start() for m in re.finditer(re.escape(START), value)]
    ends = [m.end() for m in re.finditer(re.escape(END), value)]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ConfigError("developer_instructions contains damaged or duplicate Basix markers")
    return starts[0], ends[0]


def locate_assignment(text: str) -> tuple[int, int] | None:
    lines = text.splitlines(keepends=True)
    offset = 0
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if TABLE_RE.match(line) and not stripped.startswith("[["):
            break
        if TABLE_RE.match(line):
            break
        if KEY_RE.match(line):
            start = offset
            candidate = ""
            for part in lines[index:]:
                candidate += part
                try:
                    parsed = tomllib.loads(candidate)
                except tomllib.TOMLDecodeError:
                    continue
                if set(parsed) == {"developer_instructions"}:
                    return start, start + len(candidate)
            raise ConfigError("could not determine developer_instructions assignment")
        offset += len(line)
    return None


def clean_joined_value(value: str) -> str:
    return value.strip("\n")


def render_assignment(value: str, newline: str = "\n", final_newline: bool = True) -> str:
    """Render a top-level developer-instructions assignment.

    Args:
        value: Developer-instructions string value.
        newline: Physical line ending for the assignment.
        final_newline: Whether the rendered assignment ends with ``newline``.
    """
    rendered = f"developer_instructions = {json.dumps(value, ensure_ascii=False)}"
    return rendered + (newline if final_newline else "")


def assignment_newline(assignment: str, fallback: str = "\n") -> str:
    """Return the physical line ending used by an assignment.

    Args:
        assignment: Original assignment text, possibly including its line ending.
        fallback: Line ending to use when the assignment has none.
    """
    match = re.search(r"\r\n|\n", assignment)
    return match.group(0) if match else fallback


def assignment_comment_suffix(assignment: str) -> str:
    """Return an inline TOML comment and its exact surrounding whitespace."""
    quote: str | None = None
    triple = False
    index = 0
    while index < len(assignment):
        if quote is not None:
            delimiter = quote * (3 if triple else 1)
            if assignment.startswith(delimiter, index):
                index += len(delimiter)
                quote = None
                triple = False
                continue
            if quote == '"' and assignment[index] == "\\":
                index += 2
                continue
            index += 1
            continue
        if assignment.startswith("'''", index) or assignment.startswith('"""', index):
            quote = assignment[index]
            triple = True
            index += 3
            continue
        if assignment[index] in "'\"":
            quote = assignment[index]
            index += 1
            continue
        if assignment[index] == "#":
            start = index
            line_start = assignment.rfind("\n", 0, index) + 1
            while start > line_start and assignment[start - 1] in " \t":
                start -= 1
            return assignment[start:]
        index += 1
    return ""


def update_text(text: str, block: str, action: str) -> tuple[str, bool]:
    try:
        parsed = tomllib.loads(text) if text.strip() else {}
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML: {exc}") from exc

    current = parsed.get("developer_instructions")
    if current is not None and not isinstance(current, str):
        raise ConfigError("top-level developer_instructions must be a string")
    assignment = locate_assignment(text)
    if (current is None) != (assignment is None):
        raise ConfigError("could not safely locate top-level developer_instructions")

    value = current or ""
    span = marker_span(value)
    separator_owned = False
    if action == "add":
        if span:
            value = value[: span[0]] + block + value[span[1] :]
        else:
            has_table = any(TABLE_RE.match(line) for line in text.splitlines())
            separator_owned = (
                assignment is None
                and bool(text)
                and not text.endswith(("\n", "\r"))
                and not has_table
            )
            if separator_owned:
                block = block.replace(
                    START,
                    f"{START}\n{NO_FINAL_ASSIGNMENT_SEPARATOR}",
                    1,
                )
            separator = "" if not value else ("" if value.endswith("\n\n") else "\n" if value.endswith("\n") else "\n\n")
            value = value + separator + block
    else:
        if not span:
            return text, False
        separator_owned = NO_FINAL_ASSIGNMENT_SEPARATOR in value
        start, end = span
        if start >= 2 and value[start - 2 : start] == "\n\n":
            start -= 2
        elif start >= 1 and value[start - 1 : start] == "\n":
            start -= 1
        value = value[:start] + value[end:]

    if assignment:
        before, after = text[: assignment[0]], text[assignment[1] :]
        assignment_text = text[assignment[0] : assignment[1]]
        newline = assignment_newline(
            assignment_text,
            "\r\n" if "\r\n" in text else "\n",
        )
        final_newline = assignment_text.endswith(("\n", "\r"))
        if separator_owned and not value and before.endswith(newline):
            before = before[: -len(newline)]
        suffix = assignment_comment_suffix(assignment_text)
        if value:
            rendered = render_assignment(value, newline, final_newline)
            if suffix:
                base = rendered[:-len(newline)] if final_newline else rendered
                replacement = base + suffix
            else:
                replacement = rendered
        else:
            replacement = suffix
        result = before + replacement + after
    elif value:
        newline = "\r\n" if "\r\n" in text else "\n"
        result = append_top_level_block(text, render_assignment(value, newline))
    else:
        result = text

    tomllib.loads(result) if result.strip() else None
    return result, result != text


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=(
            "add",
            "remove",
            "agent-check",
            "agent-add",
            "agent-remove",
            "permissions-check",
            "permissions-add",
            "permissions-remove",
        ),
    )
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--instructions", type=Path)
    parser.add_argument("--agents-source", type=Path)
    parser.add_argument("--agents-dir", type=Path)
    parser.add_argument("--project-root", type=Path)
    parser.add_argument("--local-network-mode", choices=("enable", "disable"))
    parser.add_argument("--test-socket-mode", choices=("enable", "disable"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--remove-empty-file", action="store_true")
    parser.add_argument("--status-json", action="store_true")
    args = parser.parse_args()

    if args.action == "add" and not args.instructions:
        parser.error("add requires --instructions")
    if args.action.startswith("agent-") and (not args.agents_source or not args.agents_dir):
        parser.error(f"{args.action} requires --agents-source and --agents-dir")
    if args.config.exists():
        with args.config.open("r", encoding="utf-8", newline="") as handle:
            original = handle.read()
    else:
        original = ""
    if args.action.startswith("permissions-"):
        if not args.project_root:
            parser.error(f"{args.action} requires --project-root")
        if args.action != "permissions-remove" and (
            not args.local_network_mode or not args.test_socket_mode
        ):
            parser.error(
                f"{args.action} requires --local-network-mode and --test-socket-mode"
            )
        if args.action == "permissions-remove":
            if args.local_network_mode or args.test_socket_mode:
                parser.error("permissions-remove does not accept capability modes")
            updated, status = capability_remove_text(original, args.project_root)
        else:
            local_network = args.local_network_mode == "enable"
            test_socket = args.test_socket_mode == "enable"
            updated, status = capability_add_text(
                original, args.project_root, local_network, test_socket
            )
        if args.action == "permissions-check":
            result = {"status": status, "action": args.action, "dry_run": True}
            if args.status_json:
                print(json.dumps(result))
            else:
                print(f"Local access configuration check: {status}")
            return 0
        if status == "changed" and not args.dry_run:
            if args.action == "permissions-remove" and args.remove_empty_file and not updated.strip():
                args.config.unlink(missing_ok=True)
            else:
                atomic_write(args.config, updated)
        elif (
            status == "unchanged"
            and args.action == "permissions-remove"
            and args.remove_empty_file
            and not original.strip()
            and not args.dry_run
        ):
            args.config.unlink(missing_ok=True)
            status = "changed"
        result = {"status": status, "action": args.action, "dry_run": args.dry_run}
        if args.status_json:
            print(json.dumps(result))
        elif status == "changed":
            verb = "Would update" if args.dry_run else "Updated"
            print(f"{verb} Basix local access configuration: {args.config}")
        else:
            print(f"Basix local access configuration already current: {args.config}")
        return 0
    if args.action.startswith("agent-"):
        agents = load_agents(args.agents_source, args.agents_dir)
        updated, status = agent_update_text(original, agents, args.action)
        changed = status == "changed"
        if changed and not args.dry_run:
            if args.action == "agent-remove" and args.remove_empty_file and not updated.strip():
                args.config.unlink(missing_ok=True)
            else:
                atomic_write(args.config, updated)
        result = {"status": status, "action": args.action, "dry_run": args.dry_run}
        if args.status_json:
            print(json.dumps(result))
        elif status == "preserved":
            print(f"Preserved locally changed Basix agent configuration: {args.config}")
        elif changed:
            verb = "Would update" if args.dry_run else "Updated"
            print(f"{verb} Basix agent configuration: {args.config}")
        else:
            print(f"Basix agent configuration already current: {args.config}")
        return 0
    block = args.instructions.read_text(encoding="utf-8").strip() if args.instructions else ""
    if args.action == "add":
        if block.count(START) != 1 or block.count(END) != 1 or block.index(START) >= block.index(END):
            raise ConfigError("instruction source must contain exactly one ordered marker pair")
    updated, changed = update_text(original, block, args.action)
    current = tomllib.loads(original).get("developer_instructions", "") if original.strip() else ""
    existing_span = marker_span(current)
    if not changed:
        if args.status_json:
            print(json.dumps({"status": "unchanged", "action": args.action}))
            return 0
        if args.action == "add":
            print(f"Basix developer instructions already current: {args.config}")
        else:
            print(f"Basix developer instructions not present: {args.config}")
        return 0
    if args.dry_run:
        if args.status_json:
            print(json.dumps({"status": "changed", "action": args.action, "dry_run": True}))
            return 0
        if args.action == "add":
            verb = "update" if existing_span else "add"
            print(f"Would {verb} Basix developer instructions: {args.config}")
        else:
            print(f"Would remove Basix developer instructions: {args.config}")
            if args.remove_empty_file and not updated.strip():
                print(f"Would remove empty configuration file: {args.config}")
        return 0
    if args.action == "remove" and args.remove_empty_file and not updated.strip():
        args.config.unlink(missing_ok=True)
        if not args.status_json:
            print(f"Removed Basix developer instructions: {args.config}")
            print(f"Removed empty configuration file: {args.config}")
    else:
        atomic_write(args.config, updated)
        if args.action == "add" and not args.status_json:
            verb = "Updated" if existing_span else "Added"
            print(f"{verb} Basix developer instructions: {args.config}")
        elif not args.status_json:
            print(f"Removed Basix developer instructions: {args.config}")
    if args.status_json:
        # The human-readable branch above is retained for direct use; installers
        # request JSON and consume only the final record.
        print(json.dumps({"status": "changed", "action": args.action, "dry_run": False}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ConfigError, OSError) as exc:
        print(f"error: {exc}", file=__import__("sys").stderr)
        raise SystemExit(1)

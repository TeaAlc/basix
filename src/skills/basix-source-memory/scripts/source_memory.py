#!/usr/bin/env python3
"""Offline, project-owned source catalogs (Python 3.11+, POSIX flock)."""
import argparse
import copy
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib
from urllib.parse import parse_qsl, unquote, urlsplit


class CatalogError(ValueError):
    """A controlled validation or stale-write error."""


def require(condition, message):
    """Raise a controlled error unless condition is true; message contains no input secrets.

    Args:
        condition: Boolean condition required to hold.
        message: Controlled error text without input secrets.
    """
    if not condition:
        raise CatalogError(message)


def keys(value, allowed, required=()):
    """Validate a mapping value against allowed and required key collections.

    Args:
        value: Value to validate or transform as described above.
        allowed: Collection of permitted object keys.
        required: Collection of mandatory object keys.
    """
    require(type(value) is dict, "expected an object")
    require(not (set(value) - set(allowed)), "unknown field")
    require(set(required) <= set(value), "missing required field")


def integer(value, minimum=0):
    """Validate value as an actual integer at least minimum, excluding booleans.

    Args:
        value: Value to validate or transform as described above.
        minimum: Smallest accepted integer.
    """
    require(type(value) is int and value >= minimum, "invalid integer")


def plain(value, limit=None, empty=False):
    """Validate plaintext value, optionally limited to limit whitespace words; empty permits blanks.

    Args:
        value: Value to validate or transform as described above.
        limit: Maximum whitespace-delimited words, or None for no word limit.
        empty: Whether empty plaintext is permitted.
    """
    require(type(value) is str and (empty or bool(value.strip())), "expected nonempty plaintext")
    require(not any(ord(c) < 32 or ord(c) == 127 for c in value), "control character in plaintext")
    require(not re.search(r"[<>`]|\[[^]]*\]\(|\*\*|__", value), "markup is not plaintext")
    require(limit is None or len(value.split()) <= limit, "plaintext word limit exceeded")


def date(value):
    """Validate value as a canonical ISO calendar date, no later than today.

    Args:
        value: Value to validate or transform as described above.
    """
    require(type(value) is str, "invalid date")
    try:
        parsed = dt.date.fromisoformat(value)
    except ValueError:
        raise CatalogError("invalid date") from None
    require(parsed.isoformat() == value and parsed <= dt.date.today(), "invalid or future date")


def canonical(value):
    """Canonicalize source value to an IDNA host and conservative case-sensitive stable path.

    Args:
        value: Value to validate or transform as described above.
    """
    require(type(value) is str and value and not re.search(r"[\s\\\x00-\x1f\x7f]", value), "invalid source")
    try:
        parts = urlsplit(value if "://" in value else "https://" + value)
        require(parts.scheme in ("http", "https") and parts.hostname and parts.username is None and parts.password is None,
                "invalid source authority")
        require(parts.port is None and ":" not in parts.netloc and "?" not in value and "#" not in value, "source keys cannot contain port, query, or fragment")
        host = parts.hostname.encode("idna").decode("ascii").lower()
    except (ValueError, UnicodeError):
        raise CatalogError("invalid source authority") from None
    require(not host.endswith(".") and "." in host and len(host) <= 253, "source must be a public domain name")
    require(all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in host.split(".")), "invalid hostname")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise CatalogError("IP source keys are unsupported")
    path = parts.path
    require(not re.search(r"%(?:2f|5c|2e|25|0[0-9a-f]|1[0-9a-f]|7f)", path, re.I), "ambiguous encoded source path")
    require(not re.search(r"%(?![0-9a-fA-F]{2})", path), "invalid path encoding")
    require(not any(segment in (".", "..", "") for segment in path.split("/")[1:-1]), "ambiguous source path")
    require(not any(segment in (".", "..") for segment in path.split("/")), "dot source path")
    return host + path.rstrip("/")


def evidence_url(value):
    """Validate exact HTTP(S) evidence value, rejecting credentials and known secret query names.

    Args:
        value: Value to validate or transform as described above.
    """
    require(type(value) is str and not re.search(r"[\s\\\x00-\x1f\x7f]", value), "invalid evidence URL")
    try:
        parts = urlsplit(value)
        require(parts.scheme in ("http", "https") and parts.hostname and parts.username is None and parts.password is None
                and "#" not in value, "invalid evidence URL")
        parts.port
        for name, _ in parse_qsl(parts.query, keep_blank_values=True):
            normalized = re.sub(r"[^a-z0-9]", "", unquote(name).lower())
            require(normalized not in {"token", "accesstoken", "apikey", "password", "passwd", "secret", "authorization", "credential", "signature", "key"}, "secret query parameter in evidence URL")
    except ValueError:
        raise CatalogError("invalid evidence URL") from None


def category(value):
    """Validate category value with fixed short ID and plaintext description.

    Args:
        value: Value to validate or transform as described above.
    """
    keys(value, {"id", "description"}, {"id", "description"})
    require(type(value["id"]) is str and re.fullmatch(r"[a-z][a-z0-9-]{0,15}", value["id"]), "invalid category ID")
    plain(value["description"], 16)


def normalized(value):
    """Return normalized description value for mechanical duplicate detection.

    Args:
        value: Value to validate or transform as described above.
    """
    return " ".join(re.findall(r"\w+", value.casefold()))


def add_category(catalog, value):
    """Add category value to catalog or accept its identical existing definition.

    Args:
        catalog: Mutable category catalog receiving the definition.
        value: Value to validate or transform as described above.
    """
    category(value)
    for existing in catalog["categories"]:
        if existing["id"] == value["id"]:
            require(existing == value, "category meaning is immutable")
            return False
        require(normalized(existing["description"]) != normalized(value["description"]), "duplicate category description")
    catalog["categories"].append(copy.deepcopy(value))
    return True


MATRIX = {"strong": {"traceable": 1, "unknown": 1, "deceptive": -1},
          "open": {"traceable": 0, "unknown": 0, "deceptive": -1},
          "unreliable": {"traceable": -1, "unknown": -1, "deceptive": -1}}
ASSESSMENT = {"date", "reason", "evidence", "evidence_quality", "accountability", "scope", "trustability"}


def assessment(value):
    """Validate complete assessment value and its evidence/accountability matrix result.

    Args:
        value: Value to validate or transform as described above.
    """
    keys(value, ASSESSMENT, ASSESSMENT)
    date(value["date"])
    plain(value["reason"])
    plain(value["scope"])
    require(type(value["evidence"]) is list and bool(value["evidence"]), "assessment requires evidence URLs")
    require(len(set(value["evidence"])) == len(value["evidence"]), "duplicate evidence URL")
    for url in value["evidence"]:
        evidence_url(url)
    require(value["evidence_quality"] in MATRIX and value["accountability"] in MATRIX["open"], "invalid assessment axes")
    require(type(value["trustability"]) is int and value["trustability"] == MATRIX[value["evidence_quality"]][value["accountability"]], "trustability does not match matrix")


USE_ROLES = {"support", "object", "lead", "position"}

SOURCE_FIELDS = {"source", "scope", "source_type", "find", "contains", "categories", "usefulness", "usage_events",
                 "trustability", "assessment_status", "created", "updated", "last_reviewed", "assessment", "history"}


def validate_sources(sources, categories):
    """Validate sources catalog and cross-references to categories catalog, including full history.

    Args:
        sources: Source catalog being validated or merged.
        categories: Category catalog supplying valid tag definitions.
    """
    keys(sources, {"version", "revision", "sources"}, {"version", "revision", "sources"})
    require(type(sources["version"]) is int and sources["version"] == 1, "unsupported sources version")
    integer(sources["revision"])
    require(type(sources["sources"]) is list, "sources must be an array")
    ids = {c["id"] for c in categories["categories"]}
    seen = set()
    for item in sources["sources"]:
        keys(item, SOURCE_FIELDS, SOURCE_FIELDS - {"assessment", "last_reviewed"})
        require(item["source"] == canonical(item["source"]) and item["source"] not in seen, "duplicate or noncanonical source")
        seen.add(item["source"])
        plain(item["scope"], empty="/" not in item["source"])
        plain(item["source_type"])
        for field in ("find", "contains"):
            plain(item[field], 32)
        tags = item["categories"]
        require(type(tags) is list and 1 <= len(tags) <= 5 and all(type(t) is str for t in tags), "invalid category tags")
        require(len(set(tags)) == len(tags) and set(tags) <= ids, "duplicate or missing category tag")
        integer(item["usefulness"])
        events = item["usage_events"]
        require(type(events) is list, "invalid usage events")
        event_ids = []
        for event in events:
            keys(event, {"id", "roles", "use_note"}, {"id", "roles", "use_note"})
            require(type(event["id"]) is str and re.fullmatch(r"[0-9a-f]{64}", event["id"]), "invalid usage event ID")
            roles = event["roles"]
            require(type(roles) is list and bool(roles) and all(type(role) is str and role in USE_ROLES for role in roles), "invalid usage roles")
            require(roles == sorted(set(roles)), "usage roles must be distinct and sorted")
            plain(event["use_note"], 32)
            event_ids.append(event["id"])
        require(len(set(event_ids)) == len(event_ids) == item["usefulness"], "usefulness/event count mismatch")
        require(type(item["trustability"]) is int and item["trustability"] in (-1, 0, 1), "invalid trustability")
        date(item["created"])
        date(item["updated"])
        require(item["created"] <= item["updated"], "inconsistent source dates")
        require(type(item["history"]) is list, "invalid history")
        previous = 0
        previous_date = "0001-01-01"
        for event in item["history"]:
            keys(event, ASSESSMENT | {"old", "source_type", "reset"}, ASSESSMENT | {"old", "source_type", "reset"})
            require(type(event["old"]) is int and event["old"] == previous and type(event["reset"]) is bool, "invalid history chain")
            details = {k: event[k] for k in ASSESSMENT}
            assessment(details)
            plain(event["source_type"])
            require(previous_date <= event["date"] <= item["updated"], "inconsistent history dates")
            require(not event["reset"] or event["trustability"] == 0, "invalid reset")
            previous = event["trustability"]
            previous_date = event["date"]
        if item["assessment_status"] == "assessed":
            require("assessment" in item and "last_reviewed" in item and bool(item["history"]), "missing current assessment")
            assessment(item["assessment"])
            require(item["assessment"]["scope"] == item["scope"] and item["assessment"]["trustability"] == item["trustability"] == previous, "current assessment mismatch")
            date(item["last_reviewed"])
            require(item["last_reviewed"] == item["assessment"]["date"] and previous_date <= item["last_reviewed"] <= item["updated"], "inconsistent review dates")
            require(not item["history"][-1]["reset"], "assessed source ends in reset")
            require(item["history"][-1]["scope"] == item["scope"] and item["history"][-1]["source_type"] == item["source_type"], "assessed metadata differs from history")
        else:
            require(item["assessment_status"] == "unassessed" and item["trustability"] == 0 and "assessment" not in item and "last_reviewed" not in item, "invalid unassessed source")
            require(not item["history"] or item["history"][-1]["reset"], "unassessed history lacks reset")


def validate_categories(catalog):
    """Validate categories catalog, including unique fixed facets and revision.

    Args:
        catalog: Mutable category catalog receiving the definition.
    """
    keys(catalog, {"version", "revision", "categories"}, {"version", "revision", "categories"})
    require(type(catalog["version"]) is int and catalog["version"] == 1, "unsupported categories version")
    integer(catalog["revision"])
    require(type(catalog["categories"]) is list, "categories must be an array")
    probe = {"categories": []}
    for item in catalog["categories"]:
        require(add_category(probe, item), "duplicate category ID")


def toml_value(value):
    """Serialize supported value to deterministic TOML inline notation.

    Args:
        value: Value to validate or transform as described above.
    """
    if type(value) is str:
        # JSON short control escapes except backspace/formfeed also belong to TOML.
        return json.dumps(value, ensure_ascii=False)
    if type(value) is bool:
        return "true" if value else "false"
    if type(value) is int:
        return str(value)
    if type(value) is list:
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    if type(value) is dict:
        return "{ " + ", ".join(json.dumps(k) + " = " + toml_value(v) for k, v in value.items()) + " }"
    raise CatalogError("unsupported TOML value")


def serialize(value):
    """Serialize complete catalog value and verify its TOML round trip before writing.

    Args:
        value: Value to validate or transform as described above.
    """
    output = "".join(k + " = " + toml_value(v) + "\n" for k, v in value.items())
    require(tomllib.loads(output) == value, "TOML round trip failed")
    return output


def safe_path(project):
    """Return catalog directory under existing project, rejecting symlinked ancestors or data paths.

    Args:
        project: Existing project directory containing project-owned catalogs.
    """
    project = Path(os.path.abspath(project))
    require(project.is_dir(), "project directory does not exist")
    for ancestor in [project, *project.parents]:
        require(not ancestor.is_symlink(), "symlinked project ancestor")
    target = project / ".basix" / "sources"
    for path in (project / ".basix", target):
        require(not path.is_symlink() and (not path.exists() or path.is_dir()), "unsafe catalog directory")
    for name in ("sources.toml", "categories.toml", ".lock"):
        path = target / name
        require(not path.is_symlink() and (not path.exists() or path.is_file()), "unsafe catalog file")
        require(not path.exists() or path.stat().st_nlink == 1, "hardlinked catalog file")
    return target


def read_catalog(path, kind):
    """Read catalog at path for kind, or return an empty in-memory catalog without writes.

    Args:
        path: Filesystem path to read or atomically replace.
        kind: Catalog array key, sources or categories.
    """
    if not path.exists():
        return {"version": 1, "revision": 0, kind: []}
    try:
        with path.open("rb") as stream:
            return tomllib.load(stream)
    except (tomllib.TOMLDecodeError, UnicodeError):
        raise CatalogError("malformed catalog TOML") from None


def load(directory):
    """Load and validate both catalogs from directory; tolerate unused category-only recovery state.

    Args:
        directory: Project-owned catalog directory.
    """
    require(not (directory / "sources.toml").exists() or (directory / "categories.toml").exists(), "missing categories catalog")
    cats = read_catalog(directory / "categories.toml", "categories")
    sources = read_catalog(directory / "sources.toml", "sources")
    validate_categories(cats)
    validate_sources(sources, cats)
    return cats, sources


def atomic_write(path, content):
    """Atomically replace path with content, fsyncing the new file and parent directory.

    Args:
        path: Filesystem path to read or atomically replace.
        content: Complete validated UTF-8 TOML content to persist.
    """
    descriptor, temporary = tempfile.mkstemp(prefix=".source-memory-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def seed(cats):
    """Add missing seed IDs to cats without redefining preexisting category meanings.

    Args:
        cats: Mutable category catalog used by this operation.
    """
    asset = Path(__file__).resolve().parents[1] / "assets" / "categories.toml"
    initial = read_catalog(asset, "categories")
    validate_categories(initial)
    present = {item["id"] for item in cats["categories"]}
    for item in initial["categories"]:
        if item["id"] not in present:
            add_category(cats, item)


def record(cats, sources, observation):
    """Merge observation into in-memory cats and sources, validating before any persistence.

    Args:
        cats: Mutable category catalog used by this operation.
        sources: Source catalog being validated or merged.
        observation: Proposed source-observation object, or None when unused.
    """
    allowed = {"source", "scope", "source_type", "find", "contains", "categories", "helpful", "task_id", "assessment", "reset", "new_categories", "expected_revision", "use_role", "use_note"}
    keys(observation, allowed, {"source"})
    source = canonical(observation["source"])
    if "expected_revision" in observation:
        integer(observation["expected_revision"])
        require(observation["expected_revision"] == sources["revision"], "stale expected_revision")
    for value in observation.get("new_categories", []):
        add_category(cats, value)
    today = dt.date.today().isoformat()
    existing = next((s for s in sources["sources"] if s["source"] == source), None)
    item = copy.deepcopy(existing) if existing else {"source": source, "scope": "", "source_type": "general", "usefulness": 0, "usage_events": [], "trustability": 0, "assessment_status": "unassessed", "created": today, "updated": today, "history": []}
    for field in ("scope", "source_type", "find", "contains", "categories"):
        if field in observation:
            item[field] = copy.deepcopy(observation[field])
    changed_scope = existing and any(item[k] != existing[k] for k in ("scope", "source_type"))
    require(not ("assessment" in observation and "reset" in observation), "choose assessment or reset")
    require(not (changed_scope and existing["assessment_status"] == "assessed") or "assessment" in observation or "reset" in observation,
            "assessed scope/type change requires reassessment or justified reset")
    if "assessment" in observation or "reset" in observation:
        reset = "reset" in observation
        review = copy.deepcopy(observation["reset"] if reset else observation["assessment"])
        assessment(review)
        require(review["scope"] == item["scope"], "assessment scope must match source scope")
        require(not reset or review["trustability"] == 0, "reset must be neutral")
        require(review["date"] >= item.get("last_reviewed", item["history"][-1]["date"] if item["history"] else "0001-01-01"), "review predates current state")
        if existing and review["trustability"] != existing["trustability"] and "assessment" in existing:
            require(normalized(review["reason"]) != normalized(existing["assessment"]["reason"]), "changed trust requires a new explanatory reason")
        if not existing or item["assessment_status"] != ("unassessed" if reset else "assessed") or item["trustability"] != review["trustability"] or changed_scope:
            item["history"].append(dict(review, old=item["trustability"], source_type=item["source_type"], reset=reset))
        item["trustability"] = review["trustability"]
        item["assessment_status"] = "unassessed" if reset else "assessed"
        if reset:
            item.pop("assessment", None)
            item.pop("last_reviewed", None)
        else:
            item["assessment"] = review
            item["last_reviewed"] = review["date"]
    helpful = observation.get("helpful", False)
    require(type(helpful) is bool, "helpful must be boolean")
    if "task_id" in observation:
        plain(observation["task_id"])
    require(helpful or not ({"use_role", "use_note"} & set(observation)), "usage role/note requires helpful observation")
    if helpful:
        require({"task_id", "use_role", "use_note"} <= set(observation), "helpful observation requires stable task_id, use_role, and use_note")
        role = observation["use_role"]
        require(type(role) is str and role in USE_ROLES, "invalid use_role")
        plain(observation["use_note"], 32)
        digest = hashlib.sha256(json.dumps([observation["task_id"], source], ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
        event = next((e for e in item["usage_events"] if e["id"] == digest), None)
        require(not (role == "support" and item["trustability"] == -1 and (not event or role not in event["roles"])),
                "unreliable source cannot receive new factual support use")
        if event:
            event["roles"] = sorted(set(event["roles"]) | {role})
        else:
            item["usage_events"].append({"id": digest, "roles": [role], "use_note": observation["use_note"]})
            item["usefulness"] += 1
    item["updated"] = today
    if existing:
        sources["sources"][sources["sources"].index(existing)] = item
    else:
        sources["sources"].append(item)
    validate_categories(cats)
    validate_sources(sources, cats)
    return item


def public(item, history=False, usage=False):
    """Return compact item with role summary and optional historical details.

    Args:
        item: Source record to expose without private usage event IDs.
        history: Whether to include trust-history entries.
        usage: Whether to include historical usage purposes without event IDs.
    """
    result = {k: v for k, v in item.items() if k != "usage_events" and (history or k != "history")}
    result["use_roles"] = sorted({role for event in item["usage_events"] for role in event["roles"]})
    if usage:
        result["usage_events"] = [{k: v for k, v in event.items() if k != "id"} for event in item["usage_events"]]
        result["usage_notice"] = "Historical uses describe past purposes; ratings can change and these uses do not establish current trust."
    return result


def mutate(project, command, observation=None, category_value=None):
    """Execute command under project lock, optionally merging observation or category_value.

    Args:
        project: Existing project directory containing project-owned catalogs.
        command: Mutation command: init, record, or add-category.
        observation: Proposed source-observation object, or None when unused.
        category_value: Category definition for add-category, or None when unused.
    """
    directory = safe_path(project)
    # Preflight rejects invalid input without creating directories or lock files.
    cats, sources = load(directory)
    trial_cats, trial_sources = copy.deepcopy(cats), copy.deepcopy(sources)
    seed(trial_cats)
    if command == "record":
        record(trial_cats, trial_sources, observation)
    elif command == "add-category":
        add_category(trial_cats, category_value)
    directory.mkdir(parents=True, exist_ok=True)
    safe_path(project)
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    descriptor = os.open(directory / ".lock", flags, 0o600)
    try:
        with os.fdopen(descriptor, "r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            safe_path(project)
            cats, sources = load(directory)
            old_cats, old_sources = copy.deepcopy(cats), copy.deepcopy(sources)
            seed(cats)
            result = None
            if command == "record":
                result = record(cats, sources, observation)
            elif command == "add-category":
                add_category(cats, category_value)
            validate_categories(cats)
            validate_sources(sources, cats)
            if cats != old_cats:
                cats["revision"] += 1
            if sources != old_sources:
                sources["revision"] += 1
            cats_text, sources_text = serialize(cats), serialize(sources)
            if cats != old_cats or not (directory / "categories.toml").exists():
                atomic_write(directory / "categories.toml", cats_text)
            if sources != old_sources or not (directory / "sources.toml").exists():
                atomic_write(directory / "sources.toml", sources_text)
            return {"revision": sources["revision"], "categories_revision": cats["revision"], "source": public(result) if result else None}
    except OSError:
        raise CatalogError("catalog write failed") from None


def main(argv=None):
    """Run CLI with optional argv sequence; emit stable JSON and return exit status.

    Args:
        argv: Optional CLI argument sequence; None reads process arguments.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=".")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init")
    commands.add_parser("validate")
    listing = commands.add_parser("list")
    listing.add_argument("--category")
    listing.add_argument("--text")
    listing.add_argument("--role", choices=sorted(USE_ROLES))
    showing = commands.add_parser("show")
    showing.add_argument("source")
    showing.add_argument("--history", action="store_true")
    showing.add_argument("--usage", action="store_true")
    showing.add_argument("--lookup", action="store_true", help="allow longest segment-boundary parent match; does not inherit trust")
    writing = commands.add_parser("record")
    writing.add_argument("--input", required=True, help="JSON file or - for stdin")
    adding = commands.add_parser("add-category")
    adding.add_argument("id")
    adding.add_argument("description")
    args = parser.parse_args(argv)
    try:
        if args.command in ("init", "record", "add-category"):
            observation = None
            if args.command == "record":
                try:
                    if args.input == "-":
                        observation = json.load(sys.stdin)
                    else:
                        with open(args.input, encoding="utf-8") as stream:
                            observation = json.load(stream)
                except (ValueError, UnicodeError):
                    raise CatalogError("invalid observation JSON") from None
            result = mutate(args.project, args.command, observation,
                            {"id": args.id, "description": args.description} if args.command == "add-category" else None)
        else:
            cats, sources = load(safe_path(args.project))
            result = {"revision": sources["revision"], "categories_revision": cats["revision"]}
            if args.command == "list":
                result["sources"] = [public(s) for s in sources["sources"] if
                    (not args.category or args.category in s["categories"]) and
                    (not args.role or any(args.role in event["roles"] for event in s["usage_events"])) and
                    (not args.text or args.text.casefold() in " ".join([s["source"], s["find"], s["contains"], s["scope"]]).casefold())]
            elif args.command == "show":
                requested = canonical(args.source)
                matches = [s for s in sources["sources"] if requested == s["source"] or
                           (args.lookup and requested.startswith(s["source"] + "/"))]
                match = max(matches, key=lambda s: len(s["source"])) if matches else None
                result.update(requested=requested, matched_key=match["source"] if match else None,
                              exact=bool(match and match["source"] == requested),
                              trust_applies_to_requested=bool(match and match["source"] == requested),
                              source=public(match, args.history, args.usage) if match else None)
            else:
                result.update(valid=True, sources=len(sources["sources"]), categories=len(cats["categories"]))
        print(json.dumps({"ok": True, **result}, ensure_ascii=False, separators=(",", ":")))
        return 0
    except (CatalogError, OSError, TypeError, KeyError, AttributeError, OverflowError) as error:
        # Unexpected input types never expose raw source or evidence values.
        message = str(error) if isinstance(error, CatalogError) else "invalid input or inaccessible catalog"
        print(json.dumps({"ok": False, "error": {"code": "catalog_error", "message": message}}, separators=(",", ":")))
        return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Deterministic App Store submission packet validator for Phrasa.

Three fail-closed phases (non-circular):

  packet
      Static packet completeness and internal consistency. Run anytime
      before App Store Connect work. Does not require voice pass, owner
      secrets, archive, upload, or Connect save evidence.

  release-ready
      Everything that must be true before producing/uploading the candidate
      binary: packet + exact build identity + real-device voice evidence +
      owner external readiness + signing/upload-path prerequisites.
      Must NOT require evidence that can only exist after archive/upload/
      processing/selection or Connect field saves.

  submission-ready
      Final App Store Connect state after exact native 1.0(14) upload,
      processing, selection, and metadata/configuration saves — immediately
      before submit. Requires machine-validated connect-evidence.yaml fields.

Legacy alias: final → submission-ready.

Uses only Python 3 stdlib + optional Pillow. Falls back to macOS `sips`.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import struct
import subprocess
import sys
import urllib.parse
from pathlib import Path
from typing import Any


MODES = ("packet", "release-ready", "submission-ready", "final")
MODE_ALIASES = {"final": "submission-ready"}

EXPECTED_NAME = "Phrasa Free Teleprompter"
EXPECTED_VERSION = "1.0"
EXPECTED_BUILD = "14"
EXPECTED_DISPLAY = "1.0 (14)"
EXPECTED_APPLE_ID = "6780259086"
EXPECTED_BUNDLE = "com.phrasa.app"
EXPECTED_TAX_CATEGORY = "App Store software"
EXPECTED_PRIMARY_CAT = "Productivity"
EXPECTED_SECONDARY_CAT = "Utilities"


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.checks: list[str] = []

    def ok(self, msg: str) -> None:
        self.checks.append(f"OK  {msg}")

    def err(self, msg: str) -> None:
        self.errors.append(msg)
        self.checks.append(f"ERR {msg}")

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        self.checks.append(f"WARN {msg}")


# ---------------------------------------------------------------------------
# IO / parsing helpers
# ---------------------------------------------------------------------------


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_text_stripped(path: Path) -> str:
    text = read_text(path)
    if text.endswith("\n"):
        text = text[:-1]
    if text.endswith("\r"):
        text = text[:-1]
    return text


def is_https_exact(url: str, expected: str) -> bool:
    if url != expected:
        return False
    parsed = urllib.parse.urlparse(url)
    return parsed.scheme == "https" and not url.endswith("/")


def _parse_scalar(raw: str) -> Any:
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        return None
    # strip inline comments for simple scalars
    if " #" in raw:
        raw = raw.split(" #", 1)[0].rstrip()
    if raw in ("null", "~", "Null", "NULL"):
        return None
    if raw in ("true", "True", "TRUE"):
        return True
    if raw in ("false", "False", "FALSE"):
        return False
    if (raw.startswith('"') and raw.endswith('"')) or (
        raw.startswith("'") and raw.endswith("'")
    ):
        return raw[1:-1]
    # integer?
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw


def parse_simple_yaml(path: Path) -> dict[str, Any]:
    """Parse nested maps / string lists with 2-space indents (packet YAML).

    Supports:
      - key: scalar
      - key:
          nested: value
      - key:
          - list item
    Folded/literal blocks (>, |) are stored as a single string of following
    indented content (best-effort; sufficient for evidence fields).
    """
    lines = read_text(path).splitlines()
    root: dict[str, Any] = {}
    stack: list[tuple[int, Any]] = [(-1, root)]

    def current_container() -> Any:
        return stack[-1][1]

    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        content = line.strip()

        # Pop stack to parent for this indent
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        container = current_container()

        # List item
        if content.startswith("- "):
            item_raw = content[2:].strip()
            if not isinstance(container, list):
                # malformed relative to our subset — skip
                i += 1
                continue
            # inline map on list item: "- key: value" not used; treat as scalar
            if ":" in item_raw and not item_raw.startswith("{"):
                # could be "order: 1" style map entry — parse as map of one
                # For upload_order in screenshots-manifest we use nested maps
                # under list items with further indented keys; handle:
                # - order: 1
                #   file: foo.jpg
                key, _, rest = item_raw.partition(":")
                key = key.strip()
                rest = rest.strip()
                item: dict[str, Any] = {}
                if rest in (">", "|", ">" + "-", "|-"):
                    # block on list item — rare
                    item[key] = None
                elif rest:
                    item[key] = _parse_scalar(rest)
                else:
                    item[key] = {}
                    stack.append((indent, item[key]))
                # Look ahead for more keys of this list map at indent+2
                j = i + 1
                while j < len(lines):
                    nl = lines[j]
                    if not nl.strip() or nl.lstrip().startswith("#"):
                        j += 1
                        continue
                    nindent = len(nl) - len(nl.lstrip(" "))
                    if nindent <= indent:
                        break
                    ncontent = nl.strip()
                    if ncontent.startswith("- "):
                        break
                    if ":" in ncontent:
                        nk, _, nr = ncontent.partition(":")
                        nk = nk.strip()
                        nr = nr.strip()
                        if nr in (">", "|", ">-", "|-", ">+", "|+"):
                            # collect folded block
                            block_lines: list[str] = []
                            k = j + 1
                            while k < len(lines):
                                bl = lines[k]
                                if not bl.strip():
                                    block_lines.append("")
                                    k += 1
                                    continue
                                bind = len(bl) - len(bl.lstrip(" "))
                                if bind <= nindent:
                                    break
                                block_lines.append(bl.strip())
                                k += 1
                            item[nk] = " ".join(x for x in block_lines if x)
                            j = k
                            continue
                        elif nr == "":
                            item[nk] = {}
                        else:
                            item[nk] = _parse_scalar(nr)
                    j += 1
                container.append(item)
                i = j
                continue
            container.append(_parse_scalar(item_raw))
            i += 1
            continue

        # key: value
        if ":" not in content:
            i += 1
            continue
        key, _, rest = content.partition(":")
        key = key.strip()
        rest = rest.strip()

        if not isinstance(container, dict):
            i += 1
            continue

        if rest in (">", "|", ">-", "|-", ">+", "|+"):
            block_lines = []
            j = i + 1
            while j < len(lines):
                bl = lines[j]
                if not bl.strip():
                    block_lines.append("")
                    j += 1
                    continue
                bind = len(bl) - len(bl.lstrip(" "))
                if bind <= indent:
                    break
                block_lines.append(bl.strip())
                j += 1
            container[key] = " ".join(x for x in block_lines if x)
            i = j
            continue

        if rest == "":
            # Peek next non-empty line to decide list vs map
            j = i + 1
            child: Any = {}
            while j < len(lines):
                peek = lines[j]
                if not peek.strip() or peek.lstrip().startswith("#"):
                    j += 1
                    continue
                peeki = len(peek) - len(peek.lstrip(" "))
                if peeki > indent and peek.strip().startswith("- "):
                    child = []
                break
            container[key] = child
            stack.append((indent, child))
            i += 1
            continue

        container[key] = _parse_scalar(rest)
        i += 1

    return root


def yaml_get(data: dict[str, Any], *path: str, default: Any = None) -> Any:
    cur: Any = data
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return default
        cur = cur[p]
    return cur


def is_nullish(val: Any) -> bool:
    if val is None:
        return True
    if isinstance(val, str):
        s = val.strip()
        if not s or s.lower() == "null" or s.upper().startswith("TODO"):
            return True
        if s.startswith("null"):
            return True
    return False


def is_true(val: Any) -> bool:
    return val is True or (isinstance(val, str) and val.strip().lower() == "true")


def is_false(val: Any) -> bool:
    return val is False or (isinstance(val, str) and val.strip().lower() == "false")


def jpeg_info(path: Path) -> dict[str, Any]:
    """Return width, height, has_alpha for a JPEG using stdlib or sips/PIL."""
    raw = path.read_bytes()
    if raw[:2] != b"\xff\xd8":
        raise ValueError(f"not a JPEG SOI: {path.name}")

    i = 2
    width = height = None
    while i < len(raw) - 8:
        if raw[i] != 0xFF:
            i += 1
            continue
        marker = raw[i + 1]
        if marker == 0xD9:
            break
        if marker in (0xD8, 0x01) or (0xD0 <= marker <= 0xD7):
            i += 2
            continue
        if i + 4 > len(raw):
            break
        seg_len = struct.unpack(">H", raw[i + 2 : i + 4])[0]
        if marker in (
            0xC0,
            0xC1,
            0xC2,
            0xC3,
            0xC5,
            0xC6,
            0xC7,
            0xC9,
            0xCA,
            0xCB,
            0xCD,
            0xCE,
            0xCF,
        ):
            if i + 9 <= len(raw):
                height, width = struct.unpack(">HH", raw[i + 5 : i + 9])
            break
        i += 2 + seg_len

    info: dict[str, Any] = {
        "format": "jpeg",
        "width": width,
        "height": height,
        "has_alpha": False,
        "mode": "RGB",
    }

    try:
        proc = subprocess.run(
            [
                "sips",
                "-g",
                "pixelWidth",
                "-g",
                "pixelHeight",
                "-g",
                "format",
                "-g",
                "hasAlpha",
                "-g",
                "space",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                line = line.strip()
                if line.startswith("pixelWidth:"):
                    info["width"] = int(line.split(":", 1)[1].strip())
                elif line.startswith("pixelHeight:"):
                    info["height"] = int(line.split(":", 1)[1].strip())
                elif line.startswith("format:"):
                    info["format"] = line.split(":", 1)[1].strip().lower()
                elif line.startswith("hasAlpha:"):
                    info["has_alpha"] = line.split(":", 1)[1].strip().lower() in (
                        "yes",
                        "true",
                        "1",
                    )
                elif line.startswith("space:"):
                    info["space"] = line.split(":", 1)[1].strip()
    except FileNotFoundError:
        pass

    try:
        from PIL import Image  # type: ignore

        with Image.open(path) as im:
            info["width"], info["height"] = im.size
            info["format"] = (im.format or "JPEG").lower()
            info["mode"] = im.mode
            info["has_alpha"] = im.mode in ("RGBA", "LA") or (
                im.mode == "P" and "transparency" in im.info
            )
    except Exception:
        pass

    return info


# ---------------------------------------------------------------------------
# Packet-mode checks (static completeness)
# ---------------------------------------------------------------------------


def check_limits(report: Report, root: Path, packet: dict[str, Any]) -> None:
    listing = packet["store_listing"]
    limits = listing["limits"]

    fields = [
        ("name", listing["name_file"], limits["name_chars"], "chars"),
        ("subtitle", listing["subtitle_file"], limits["subtitle_chars"], "chars"),
        (
            "promotional_text",
            listing["promotional_text_file"],
            limits["promotional_text_chars"],
            "chars",
        ),
        (
            "description",
            listing["description_file"],
            limits["description_chars"],
            "chars",
        ),
        (
            "keywords",
            listing["keywords_file"],
            limits["keywords_utf8_bytes"],
            "utf8_bytes",
        ),
    ]

    for label, rel, limit, kind in fields:
        path = root / rel
        if not path.is_file():
            report.err(f"missing {label} file: {rel}")
            continue
        text = read_text_stripped(path)
        if not text.strip():
            report.err(f"{label} is empty")
            continue
        if kind == "chars":
            n = len(text)
            unit = "chars"
        else:
            n = len(text.encode("utf-8"))
            unit = "UTF-8 bytes"
            if " " in text:
                report.err(
                    f"keywords must not contain spaces (got {n} bytes including any spaces)"
                )
            if text != text.strip():
                report.err("keywords has leading/trailing whitespace")
            if ",," in text:
                report.err("keywords has empty entries (double comma)")
        if n > limit:
            report.err(f"{label} exceeds limit: {n} {unit} > {limit}")
        else:
            report.ok(f"{label}: {n}/{limit} {unit}")

    name_text = read_text_stripped(root / listing["name_file"]) if (
        root / listing["name_file"]
    ).is_file() else ""
    if name_text and name_text != EXPECTED_NAME:
        report.err(f"public name file must be exactly {EXPECTED_NAME!r}, got {name_text!r}")
    elif name_text:
        report.ok(f"public name file = {EXPECTED_NAME}")

    rn = root / listing["review_notes_file"]
    if not rn.is_file():
        report.err(f"missing review notes: {listing['review_notes_file']}")
    else:
        notes = read_text_stripped(rn)
        if len(notes) < 100:
            report.err("review notes too short")
        else:
            lower = notes.lower()
            for needle in (
                "no account",
                "microphone",
                "speech",
                "on-device",
                "apple",
                "speed mode",
                "sign in with apple",
                "optional",
                "sync",
            ):
                if needle not in lower:
                    report.err(f"review notes missing expected topic: {needle}")
            if "token revocation" not in lower and "apple token" not in lower:
                report.err(
                    "review notes must disclose Apple token revocation is not claimed complete"
                )
            report.ok(f"review notes present ({len(notes)} chars)")

    if listing.get("whats_new") is not None:
        report.err("whats_new must be null for version 1.0")
    else:
        report.ok("whats_new omitted for 1.0")


def check_urls(report: Report, packet: dict[str, Any]) -> None:
    urls = packet["store_listing"]["urls"]
    expected = {
        "support_url": "https://phrasa.app/support",
        "marketing_url": "https://phrasa.app",
        "privacy_policy_url": "https://phrasa.app/privacy",
    }
    for key, exp in expected.items():
        got = urls.get(key)
        if not is_https_exact(str(got), exp):
            report.err(f"{key}: expected exact {exp!r}, got {got!r}")
        else:
            report.ok(f"{key} = {exp}")
    if packet["privacy"].get("privacy_policy_url") != expected["privacy_policy_url"]:
        report.err("privacy.privacy_policy_url mismatch")
    else:
        report.ok("privacy questionnaire URL matches")


def check_prohibited_claims(report: Report, root: Path, packet: dict[str, Any]) -> None:
    patterns = [p.lower() for p in packet.get("prohibited_claim_patterns", [])]
    files = [
        packet["store_listing"]["description_file"],
        packet["store_listing"]["promotional_text_file"],
        packet["store_listing"]["subtitle_file"],
        packet["store_listing"]["name_file"],
        packet["store_listing"]["keywords_file"],
        packet["store_listing"]["review_notes_file"],
    ]
    for rel in files:
        path = root / rel
        if not path.is_file():
            continue
        text = read_text(path).lower()
        for pat in patterns:
            if pat in text:
                report.err(f"prohibited claim pattern {pat!r} found in {rel}")
    report.ok("no prohibited performance claims in marketing/review text files")


def check_build_identity(report: Report, root: Path, packet: dict[str, Any]) -> None:
    build = packet["build"]
    if (
        build.get("marketing_version") != EXPECTED_VERSION
        or build.get("build_number") != EXPECTED_BUILD
    ):
        report.err(f"packet build must be {EXPECTED_DISPLAY}, got {build}")
    else:
        report.ok(f"packet build identity {EXPECTED_DISPLAY}")
    if build.get("apple_id") != EXPECTED_APPLE_ID:
        report.err(f"packet apple_id must be {EXPECTED_APPLE_ID}")
    else:
        report.ok(f"packet apple_id {EXPECTED_APPLE_ID}")
    if build.get("bundle_id") != EXPECTED_BUNDLE:
        report.err(f"packet bundle_id must be {EXPECTED_BUNDLE}")
    else:
        report.ok(f"packet bundle_id {EXPECTED_BUNDLE}")

    yml = root / packet["project_evidence"]["project_yml"]
    if not yml.is_file():
        report.err(f"missing project.yml at {yml}")
    else:
        ytext = read_text(yml)
        if not re.search(r'MARKETING_VERSION:\s*"?1\.0"?', ytext):
            report.err("project.yml MARKETING_VERSION is not 1.0")
        else:
            report.ok("project.yml MARKETING_VERSION 1.0")
        if not re.search(r'CURRENT_PROJECT_VERSION:\s*"?14"?', ytext):
            report.err("project.yml CURRENT_PROJECT_VERSION is not 14")
        else:
            report.ok("project.yml CURRENT_PROJECT_VERSION 14")

    plist_path = root / packet["project_evidence"]["info_plist"]
    if not plist_path.is_file():
        report.err(f"missing Info.plist at {plist_path}")
    else:
        with plist_path.open("rb") as f:
            info = plistlib.load(f)
        enc = info.get("ITSAppUsesNonExemptEncryption")
        if enc is not False:
            report.err(
                f"ITSAppUsesNonExemptEncryption must be false, got {enc!r}"
            )
        else:
            report.ok("ITSAppUsesNonExemptEncryption = false")
        for key in (
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
        ):
            if not info.get(key):
                report.err(f"Info.plist missing {key}")
            else:
                report.ok(f"Info.plist has {key}")
        speech = str(info.get("NSSpeechRecognitionUsageDescription", ""))
        if "on-device" not in speech.lower() or "Apple may process speech" not in speech:
            report.err(
                "speech usage description missing on-device / Apple processing disclosure"
            )
        else:
            report.ok("speech usage description discloses on-device + Apple fallback")

    privacy = root / packet["project_evidence"]["privacy_manifest"]
    if not privacy.is_file():
        report.err(f"missing PrivacyInfo.xcprivacy at {privacy}")
    else:
        with privacy.open("rb") as f:
            man = plistlib.load(f)
        if man.get("NSPrivacyTracking") is not False:
            report.err("PrivacyInfo NSPrivacyTracking must be false")
        else:
            report.ok("PrivacyInfo NSPrivacyTracking = false")
        collected = man.get("NSPrivacyCollectedDataTypes")
        expected_types = {
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeOtherUserContent",
        }
        if not isinstance(collected, list) or not collected:
            report.err(
                "PrivacyInfo collected data types must declare optional-sync types "
                f"(Email Address, User ID, Other User Content), got {collected!r}"
            )
        else:
            got_types: set[str] = set()
            for entry in collected:
                if not isinstance(entry, dict):
                    report.err(f"PrivacyInfo collected entry must be a dict, got {entry!r}")
                    continue
                dtype = entry.get("NSPrivacyCollectedDataType")
                if dtype:
                    got_types.add(str(dtype))
                if entry.get("NSPrivacyCollectedDataTypeLinked") is not True:
                    report.err(
                        f"PrivacyInfo {dtype!r} must be linked to the user"
                    )
                if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
                    report.err(
                        f"PrivacyInfo {dtype!r} must not be used for tracking"
                    )
                purposes = entry.get("NSPrivacyCollectedDataTypePurposes") or []
                if "NSPrivacyCollectedDataTypePurposeAppFunctionality" not in purposes:
                    report.err(
                        f"PrivacyInfo {dtype!r} must include App Functionality purpose"
                    )
            missing = expected_types - got_types
            extra = got_types - expected_types
            if missing:
                report.err(f"PrivacyInfo missing collected types: {sorted(missing)}")
            if extra:
                report.err(f"PrivacyInfo unexpected collected types: {sorted(extra)}")
            if not missing and not extra:
                report.ok(
                    "PrivacyInfo collected types = Email Address, User ID, Other User Content "
                    "(linked, App Functionality, not tracking)"
                )

    if packet["export_compliance"].get("uses_non_exempt_encryption") is not False:
        report.err("export_compliance.uses_non_exempt_encryption must be false")
    else:
        report.ok("export compliance packet answer: exempt/system only")

    if packet.get("sign_in_required") is not False:
        report.err("sign_in_required must be false")
    else:
        report.ok("sign_in_required = false")

    if packet.get("release_mode_recommendation") != "manual":
        report.err("release_mode_recommendation must be manual")
    else:
        report.ok("release mode recommendation = manual")

    cats = packet.get("categories", {})
    if (
        cats.get("primary") != EXPECTED_PRIMARY_CAT
        or cats.get("secondary") != EXPECTED_SECONDARY_CAT
    ):
        report.err(f"unexpected categories: {cats}")
    else:
        report.ok(f"categories {EXPECTED_PRIMARY_CAT} / {EXPECTED_SECONDARY_CAT}")

    pricing = packet.get("pricing", {})
    if pricing.get("price") != "free":
        report.err("price must be free")
    else:
        report.ok("price = free")
    if pricing.get("availability") != "us_first":
        report.err("availability must be us_first")
    else:
        report.ok("availability = us_first")


def check_privacy_age(report: Report, root: Path, packet: dict[str, Any]) -> None:
    priv = packet["privacy"]
    if priv.get("collects_data") is not True:
        report.err(
            "privacy.collects_data must be true for the optional-sync shipping binary"
        )
    else:
        report.ok("privacy collects_data = true (optional sync)")
    if priv.get("tracks_users") is not False:
        report.err("privacy.tracks_users must be false")
    else:
        report.ok("privacy tracks_users = false")

    expected_type_names = {"Email Address", "User ID", "Other User Content"}
    data_types = priv.get("data_types") or []
    if not isinstance(data_types, list) or not data_types:
        report.err("privacy.data_types must list Email Address, User ID, Other User Content")
    else:
        names: set[str] = set()
        for entry in data_types:
            if not isinstance(entry, dict):
                report.err(f"privacy.data_types entry must be object, got {entry!r}")
                continue
            name = str(entry.get("type") or "")
            names.add(name)
            if entry.get("linked_to_user") is not True:
                report.err(f"privacy data type {name!r} must be linked_to_user true")
            if entry.get("used_for_tracking") is not False:
                report.err(f"privacy data type {name!r} must not be used for tracking")
            purposes = entry.get("purposes") or []
            if "App Functionality" not in purposes:
                report.err(f"privacy data type {name!r} must include App Functionality")
        if names != expected_type_names:
            report.err(
                f"privacy.data_types must be exactly {sorted(expected_type_names)}, got {sorted(names)}"
            )
        else:
            report.ok(
                "privacy data types = Email Address, User ID, Other User Content "
                "(linked, App Functionality, not tracking)"
            )

    if priv.get("primary_sign_in") != "Sign in with Apple":
        report.err("privacy.primary_sign_in must be 'Sign in with Apple'")
    else:
        report.ok("primary sign-in = Sign in with Apple")
    if priv.get("sign_in_required_for_local_use") is not False:
        report.err("privacy.sign_in_required_for_local_use must be false")
    else:
        report.ok("sign-in not required for local use")
    if priv.get("account_optional") is not True:
        report.err("privacy.account_optional must be true")
    else:
        report.ok("account is optional")
    if priv.get("sync_opt_in_by_sign_in") is not True:
        report.err("privacy.sync_opt_in_by_sign_in must be true")
    else:
        report.ok("sync opt-in is by sign-in")
    if priv.get("sync_automatic_after_sign_in") is not True:
        report.err(
            "privacy.sync_automatic_after_sign_in must be true "
            "(shipping runtimes auto-sync after optional sign-in)"
        )
    else:
        report.ok("sync is automatic after sign-in")
    expected_triggers = {
        "launch",
        "authRestored",
        "foreground",
        "durablePush",
        "manual",
    }
    triggers = {str(x) for x in (priv.get("sync_triggers") or [])}
    if triggers != expected_triggers:
        report.err(
            f"privacy.sync_triggers must be {sorted(expected_triggers)}, got {sorted(triggers)}"
        )
    else:
        report.ok("sync triggers = launch, authRestored, foreground, durablePush, manual")
    if priv.get("durable_push_debounce_ms") != 800:
        report.err(
            f"privacy.durable_push_debounce_ms must be 800, got {priv.get('durable_push_debounce_ms')!r}"
        )
    else:
        report.ok("durable push debounce = 800ms")
    if priv.get("manual_sync_now_available") is not True:
        report.err("privacy.manual_sync_now_available must be true")
    else:
        report.ok("Sync now control available")
    if priv.get("unsaved_drafts_uploaded") is not False:
        report.err("privacy.unsaved_drafts_uploaded must be false")
    else:
        report.ok("unsaved drafts not uploaded")
    if priv.get("reader_settings_synced") is not False:
        report.err(
            "privacy.reader_settings_synced must be false "
            "(shipping runtimes force localOnly)"
        )
    else:
        report.ok("reader settings not synced")
    # Reject obsolete false claims if left behind.
    if "sync_user_initiated" in priv or "sync_automatic" in priv:
        if priv.get("sync_user_initiated") is True or priv.get("sync_automatic") is False:
            report.err(
                "privacy must not assert sync_user_initiated=true or sync_automatic=false "
                "(shipping model is opt-in then automatic after sign-in)"
            )
    expected_content = {"scripts", "folders", "tags", "outlines"}
    synced = {str(x) for x in (priv.get("synced_content") or [])}
    if synced != expected_content:
        report.err(
            f"privacy.synced_content must be {sorted(expected_content)}, got {sorted(synced)}"
        )
    else:
        report.ok("synced content = scripts, folders, tags, outlines")
    if priv.get("apple_token_revocation_complete") is not False:
        report.err(
            "privacy.apple_token_revocation_complete must be false "
            "(server-side release blocker; do not claim complete)"
        )
    else:
        report.ok("Apple token revocation not claimed complete")

    pq_path = root / "privacy-questionnaire.yaml"
    if pq_path.is_file():
        pq = parse_simple_yaml(pq_path)
        pq_collects = yaml_get(pq, "data_collection", "collects_data")
        if pq_collects is not True:
            report.err(
                "privacy-questionnaire.yaml data_collection.collects_data must be true"
            )
        else:
            report.ok("privacy-questionnaire collects_data = true")
        pq_tracks = yaml_get(pq, "tracking", "tracks_users")
        if pq_tracks is not False:
            report.err(
                "privacy-questionnaire.yaml tracking.tracks_users must be false"
            )
        else:
            report.ok("privacy-questionnaire tracks_users = false")
        pq_types = pq.get("data_types_declared") or []
        pq_names: set[str] = set()
        if isinstance(pq_types, list):
            for item in pq_types:
                if isinstance(item, dict) and item.get("type"):
                    pq_names.add(str(item["type"]))
        if pq_names != expected_type_names:
            report.err(
                "privacy-questionnaire data_types_declared must be Email Address, "
                f"User ID, Other User Content; got {sorted(pq_names)}"
            )
        else:
            report.ok("privacy-questionnaire declares expected data types")
        pq_text = read_text(pq_path).lower()
        if "sign in with apple" not in pq_text:
            report.err("privacy-questionnaire.yaml must mention Sign in with Apple")
        else:
            report.ok("privacy-questionnaire mentions Sign in with Apple")
        for needle in (
            "after the user opts in by signing in",
            "automatically",
            "launch",
            "foreground",
            "sync now",
            "unsaved drafts",
        ):
            if needle not in pq_text:
                report.err(
                    f"privacy-questionnaire.yaml missing expected sync-model topic: {needle}"
                )
        report.ok("privacy-questionnaire states opt-in then automatic-after-sign-in model")
        if "reader settings" not in pq_text or (
            "not uploaded" not in pq_text and "local-only" not in pq_text and "local only" not in pq_text
        ):
            report.err(
                "privacy-questionnaire.yaml must state reader settings are not synced / local-only"
            )
        else:
            report.ok("privacy-questionnaire states reader settings local-only")
        if "token revocation" not in pq_text and "apple_token_revocation" not in pq_text:
            report.err(
                "privacy-questionnaire.yaml must document Apple token revocation blocker"
            )
        else:
            report.ok("privacy-questionnaire documents Apple token revocation blocker")
    else:
        report.err("privacy-questionnaire.yaml missing")

    desc_path = root / packet["store_listing"]["description_file"]
    if desc_path.is_file():
        desc_lower = read_text(desc_path).lower()
        for needle in (
            "no account is required",
            "optional",
            "sync",
            "sign in with apple",
            "automatically",
            "launch",
            "foreground",
            "sync now",
            "unsaved drafts are not uploaded",
            "scripts, folders, tags, and outlines",
            "reader settings stay",
            "open source",
            "apache license 2.0",
            "github.com/memfactorduke/phrasa-app",
        ):
            if needle not in desc_lower:
                report.err(f"description missing expected topic: {needle}")
        if "reader settings" in desc_lower and "sync scripts, folders, tags, outlines, and reader settings" in desc_lower:
            report.err(
                "description must not claim reader settings sync (shipping is local-only)"
            )
        if "not automatic" in desc_lower or "user-initiated, not automatic" in desc_lower:
            report.err(
                "description must not claim sync is user-initiated-only / not automatic "
                "(shipping auto-syncs after optional sign-in)"
            )
        if "does not upload" in desc_lower and "optional" not in desc_lower:
            report.err("description still claims blanket no-upload without optional sync")
        report.ok(
            "description covers optional opt-in sync with automatic-after-sign-in behavior"
        )

    promotional_path = root / packet["store_listing"]["promotional_text_file"]
    if promotional_path.is_file():
        promotional_lower = read_text(promotional_path).lower()
        if "open-source" not in promotional_lower and "open source" not in promotional_lower:
            report.err("promotional text must advertise that Phrasa is open source")
        else:
            report.ok("promotional text advertises open source")

    notes_path = root / packet["store_listing"]["review_notes_file"]
    if notes_path.is_file():
        notes_lower = read_text(notes_path).lower()
        for needle in (
            "automatically",
            "launch",
            "foreground",
            "sync now",
            "unsaved drafts",
            "scripts, folders, tags, and outlines",
        ):
            if needle not in notes_lower:
                report.err(f"review notes missing expected topic: {needle}")
        if "reader settings remain local" not in notes_lower and "reader settings remain local on each device" not in notes_lower:
            if "reader settings" not in notes_lower or "not uploaded" not in notes_lower:
                report.err(
                    "review notes must state reader settings remain local / not uploaded"
                )
        if "not automatic" in notes_lower and "user-initiated" in notes_lower:
            report.err(
                "review notes must not claim sync is user-initiated-only / not automatic"
            )
        report.ok("review notes cover opt-in automatic-after-sign-in sync model")

    age = packet["age_rating"]
    if age.get("intended_rating") != "4+":
        report.err(f"unexpected age rating {age.get('intended_rating')!r}")
    else:
        report.ok("intended age rating 4+")
    if age.get("unrestricted_web_access") is not False:
        report.err("age_rating.unrestricted_web_access must be false")
    else:
        report.ok("unrestricted web access = no")

    social = age.get("social_media_and_ugc") or {}
    if social.get("includes_social_media_features") is not False:
        report.err(
            "age_rating.social_media_and_ugc.includes_social_media_features must be false"
        )
    else:
        report.ok("social media features = no")
    if social.get("includes_user_generated_content") is not False:
        report.err(
            "age_rating.social_media_and_ugc.includes_user_generated_content must be false"
        )
    else:
        report.ok("user-generated content (social) = no")
    if social.get("answers_all_no_or_none") is not True:
        report.err("age_rating.social_media_and_ugc.answers_all_no_or_none must be true")
    else:
        report.ok("social media / UGC answers_all_no_or_none = true")
    fields = social.get("fields") or {}
    required_social_fields = (
        "social_networking",
        "chat_or_messaging",
        "public_forums_or_feeds",
        "public_sharing",
        "user_generated_content",
        "user_to_user_communication",
        "account_system_for_social",
        "profiles_or_follows",
        "friend_finding_or_contacts_matching",
        "moderated_public_ugc",
        "unmoderated_public_ugc",
    )
    for key in required_social_fields:
        val = str(fields.get(key, "")).strip().lower()
        if val not in ("no", "none", "false"):
            report.err(
                f"social media / UGC field {key} must be no/none/false, got {fields.get(key)!r}"
            )
        else:
            report.ok(f"social/UGC {key} = {val}")

    age_path = root / "age-rating.yaml"
    if age_path.is_file():
        age_text = read_text(age_path)
        if "social_media_and_ugc:" not in age_text:
            report.err("age-rating.yaml missing social_media_and_ugc section")
        else:
            report.ok("age-rating.yaml has social_media_and_ugc section")
        if "includes_social_media_features: false" not in age_text:
            report.err("age-rating.yaml must set includes_social_media_features: false")
        else:
            report.ok("age-rating.yaml includes_social_media_features: false")

    cr = packet["content_rights"]
    ofl = (Path(__file__).resolve().parent / cr["bundled_ofl_path"]).resolve()
    if not ofl.is_file():
        report.err(f"bundled OFL missing: {ofl}")
    else:
        text = read_text(ofl)
        if "SIL OPEN FONT LICENSE" not in text:
            report.err("OFL.txt does not look like SIL OFL")
        else:
            report.ok("bundled Atkinson Hyperlegible OFL present")
    if cr.get("has_rights_to_all_content") is not True:
        report.err("content_rights.has_rights_to_all_content must be true recommendation")
    else:
        report.ok("content rights recommendation = yes")


def check_connect_audit(report: Report, root: Path, packet: dict[str, Any]) -> None:
    """Validate Connect audit snapshot structure and required targets.

    The audit is a point-in-time read-only snapshot (see audit_date). Packet
    mode does not freeze Connect forever as blank — progressive saves are
    recorded in connect-evidence.yaml for submission-ready.
    """
    rel = packet.get("connect_audit_file", "connect-audit.yaml")
    path = root / rel
    if not path.is_file():
        report.err(f"missing connect audit file: {rel}")
        return
    text = read_text(path)
    audit = packet.get("connect_audit") or {}

    if audit.get("apple_id") != EXPECTED_APPLE_ID:
        report.err(
            f"connect_audit.apple_id must be {EXPECTED_APPLE_ID}, got {audit.get('apple_id')!r}"
        )
    else:
        report.ok(f"connect audit apple_id {EXPECTED_APPLE_ID}")
    if EXPECTED_APPLE_ID not in text:
        report.err(f"connect-audit.yaml must document Apple ID {EXPECTED_APPLE_ID}")
    else:
        report.ok("connect-audit.yaml contains Apple ID")

    status_context_present = any(
        marker in text.lower()
        for marker in (
            "prepare for submission",
            "waiting_for_review",
            "waiting for review",
        )
    )
    if not status_context_present:
        report.warn(
            "connect-audit.yaml does not contain a recognized version status"
        )
    else:
        report.ok("connect-audit.yaml status context present")

    # Desired end-state targets (not current live values)
    if audit.get("sign_in_required_must_be") is not False:
        report.err("connect_audit.sign_in_required_must_be must be false")
    else:
        report.ok("sign-in must be OFF before submit (target)")
    if audit.get("release_mode_must_be") != "manual":
        report.err("connect_audit.release_mode_must_be must be manual")
    else:
        report.ok("release must be manual before submit (target)")

    if packet.get("sign_in_required") is not False:
        report.err("packet sign_in_required (desired) must be false")
    if packet.get("release_mode_recommendation") != "manual":
        report.err("packet release_mode_recommendation must be manual")

    # The snapshot may record either a still-open gap or the saved target.
    if audit.get("sign_in_required_current") is True:
        report.ok("connect audit records sign-in currently ON (gap vs target)")
    elif audit.get("sign_in_required_current") is False:
        report.ok("connect audit records sign-in currently OFF (target saved)")
    else:
        report.warn("connect audit sign-in current state is not recorded")
    if audit.get("release_mode_current") == "automatic":
        report.ok("connect audit records release currently automatic (gap vs target)")
    elif audit.get("release_mode_current") == "manual":
        report.ok("connect audit records release currently manual (target saved)")
    else:
        report.warn("connect audit release mode current state is not recorded")

    if "dsa" in text.lower() or "DSA" in text:
        report.ok("connect-audit.yaml mentions DSA")
    else:
        report.warn("connect-audit.yaml missing DSA mention")

    if "social" in text.lower():
        report.ok("connect-audit.yaml mentions social media age rating")
    else:
        report.warn("connect-audit.yaml missing social media age rating mention")

    sign_text = read_text(root / "sign-in.yaml")
    if "must_switch_to: false" not in sign_text and "sign_in_required: false" not in sign_text:
        report.err("sign-in.yaml must document desired sign_in_required: false")
    else:
        report.ok("sign-in.yaml documents desired Sign-in OFF")
    rel_text = read_text(root / "release-mode.yaml")
    if "recommendation: manual" not in rel_text and "must_switch_to: manual" not in rel_text:
        report.err("release-mode.yaml must recommend manual release")
    else:
        report.ok("release-mode.yaml documents manual release target")


def check_current_release_state_consistency(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    """Fail closed when post-submission release records contradict one another.

    Release-ready artifacts intentionally describe an earlier gate. The
    current-state artifacts must agree once review submission is recorded, and
    later source hardening must never be attributed to the submitted binary.
    """
    evidence_path = root / packet.get(
        "connect_evidence_file", "connect-evidence.yaml"
    )
    audit_path = root / packet.get("connect_audit_file", "connect-audit.yaml")
    identity_path = root / "build-identity.yaml"
    if not all(
        path.is_file() for path in (evidence_path, audit_path, identity_path)
    ):
        return

    evidence = parse_simple_yaml(evidence_path)
    review = evidence.get("review_submission") or {}
    if not is_true(review.get("submitted")):
        report.ok(
            "release records are pre-submission; post-submit consistency not required"
        )
        return

    prefix = "CURRENT-RELEASE"
    audit_packet = packet.get("connect_audit") or {}
    audit_file = parse_simple_yaml(audit_path)
    audit_app = audit_file.get("app") or {}
    audit_version = audit_file.get("version_page") or {}
    identity = parse_simple_yaml(identity_path)

    expected_state = str(review.get("app_store_state") or "")
    if expected_state != "WAITING_FOR_REVIEW":
        report.err(
            f"{prefix}: submitted review app_store_state must be "
            f"'WAITING_FOR_REVIEW', got {expected_state!r}"
        )
    else:
        report.ok(f"{prefix}: review state = WAITING_FOR_REVIEW")

    for label, value in (
        ("packet.connect_audit.status", audit_packet.get("status")),
        ("connect-audit.app.status", audit_app.get("status")),
        (
            "build-identity.connect_version_status",
            identity.get("connect_version_status"),
        ),
    ):
        if str(value) != expected_state:
            report.err(
                f"{prefix}: {label} must match submitted state "
                f"{expected_state!r}, got {value!r}"
            )
        else:
            report.ok(f"{prefix}: {label} matches review state")

    for label, value in (
        ("packet.connect_audit.build_selected", audit_packet.get("build_selected")),
        (
            "connect-audit.version_page.build_selected",
            audit_version.get("build_selected"),
        ),
        (
            "build-identity.connect_build_selected",
            identity.get("connect_build_selected"),
        ),
    ):
        if str(value) != EXPECTED_DISPLAY:
            report.err(
                f"{prefix}: {label} must be {EXPECTED_DISPLAY!r}, got {value!r}"
            )
        else:
            report.ok(f"{prefix}: {label} = {EXPECTED_DISPLAY}")

    required_identity = {
        "archive_status": "archived",
        "export_status": "exported",
        "upload_status": "uploaded",
        "processing_status": "processed",
        "review_submission_status": "submitted",
    }
    for key, expected in required_identity.items():
        value = identity.get(key)
        if str(value) != expected:
            report.err(
                f"{prefix}: build-identity.{key} must be {expected!r}, "
                f"got {value!r}"
            )
        else:
            report.ok(f"{prefix}: build-identity.{key} = {expected}")

    if identity.get("post_submission_source_hardening_in_build_14") is not False:
        report.err(
            f"{prefix}: build 14 must not claim post-submission source hardening"
        )
    else:
        report.ok(
            f"{prefix}: post-submission source hardening excluded from build 14"
        )


def check_screenshots(report: Report, root: Path, packet: dict[str, Any]) -> None:
    shots = packet["screenshots"]
    # Local assets only in packet mode; Connect upload count is documentation.
    uploaded = shots.get("connect_uploaded_count")
    if uploaded is not None and not isinstance(uploaded, int):
        report.err("screenshots.connect_uploaded_count must be an int when present")
    else:
        report.ok(
            f"packet documents Connect screenshot count as {uploaded!r} (evidence file is authoritative for uploads)"
        )

    count_range = shots.get("count_range_per_slot") or [1, 10]
    if count_range != [1, 10]:
        report.err(f"count_range_per_slot must be [1, 10], got {count_range!r}")
    else:
        report.ok("official count range 1–10 per device slot")

    manifest = root / shots.get("manifest_file", "screenshots-manifest.yaml")
    if manifest.is_file():
        mtext = read_text(manifest)
        if "6.5" not in mtext or "6.9" not in mtext:
            report.err("screenshots-manifest must mention 6.5 vs 6.9 slot guidance")
        else:
            report.ok("screenshots-manifest includes 6.5 vs 6.9 slot guidance")
        if "Do NOT" not in mtext and "do not" not in mtext.lower():
            report.err("screenshots-manifest must explicitly forbid wrong-size wells")
        else:
            report.ok("screenshots-manifest forbids wrong display wells")
        if "iPad 13" not in mtext and "13-inch" not in mtext:
            report.err("screenshots-manifest must name iPad 13-inch slot")
        else:
            report.ok("screenshots-manifest names iPad 13-inch slot")
    else:
        report.err("screenshots-manifest.yaml missing")

    sets = shots["sets"]
    expected_slots = {
        "iphone_6_9": {
            "slot": "iPhone 6.9-inch",
            "forbidden": "iPhone 6.5-inch",
            "w": 1320,
            "h": 2868,
        },
        "ipad_13": {
            "slot": "iPad 13-inch",
            "forbidden": None,
            "w": 2064,
            "h": 2752,
        },
    }
    for s in sets:
        directory = (root / s["directory"]).resolve()
        if not directory.is_dir():
            report.err(f"screenshot directory missing: {directory}")
            continue
        order = s["upload_order"]
        if not order:
            report.err(f"{s['id']}: empty upload_order")
            continue
        if not order[0].startswith("05-voice"):
            report.err(
                f"{s['id']}: first screenshot must be voice-first (got {order[0]})"
            )
        else:
            report.ok(f"{s['id']}: upload order voice-first ({order[0]})")

        lo, hi = count_range[0], count_range[1]
        if len(order) < lo or len(order) > hi:
            report.err(f"{s['id']}: screenshot count {len(order)} not in {lo}..{hi}")
        else:
            report.ok(f"{s['id']}: {len(order)} frames (within {lo}–{hi})")

        exp = expected_slots.get(s["id"])
        if exp:
            if s.get("connect_media_manager_slot") != exp["slot"]:
                report.err(
                    f"{s['id']}: connect_media_manager_slot must be {exp['slot']!r}, "
                    f"got {s.get('connect_media_manager_slot')!r}"
                )
            else:
                report.ok(f"{s['id']}: Media Manager slot = {exp['slot']}")
            if exp["forbidden"]:
                forb = s.get("forbidden_slots") or []
                if exp["forbidden"] not in forb:
                    report.err(
                        f"{s['id']}: forbidden_slots must include {exp['forbidden']!r}"
                    )
                else:
                    report.ok(f"{s['id']}: forbids upload to {exp['forbidden']}")
            warn = s.get("slot_warning") or ""
            if s["id"] == "iphone_6_9" and "6.5" not in warn:
                report.err(f"{s['id']}: slot_warning must mention 6.5-inch well")
            elif warn:
                report.ok(f"{s['id']}: slot_warning present")

        for idx, name in enumerate(order, start=1):
            path = directory / name
            if not path.is_file():
                report.err(f"{s['id']} slot {idx}: missing {name}")
                continue
            try:
                info = jpeg_info(path)
            except Exception as exc:  # noqa: BLE001
                report.err(f"{s['id']} {name}: inspect failed: {exc}")
                continue
            fmt = str(info.get("format", "")).lower()
            if fmt not in ("jpeg", "jpg"):
                report.err(f"{s['id']} {name}: format {fmt!r} is not jpeg")
            if info.get("has_alpha"):
                report.err(f"{s['id']} {name}: has alpha channel")
            w, h = info.get("width"), info.get("height")
            if w != s["width"] or h != s["height"]:
                report.err(
                    f"{s['id']} {name}: size {w}x{h}, expected {s['width']}x{s['height']}"
                )
            else:
                report.ok(
                    f"{s['id']} slot {idx} {name}: {w}x{h} jpeg no-alpha "
                    f"→ {s.get('connect_media_manager_slot', 'slot')}"
                )


def check_required_packet_files(report: Report, root: Path) -> None:
    required = [
        "packet.json",
        "validate.sh",
        "validate_packet.py",
        "README.md",
        "connect-audit.yaml",
        "connect-evidence.yaml",
        "release-prerequisites.yaml",
        "categories.yaml",
        "privacy-questionnaire.yaml",
        "age-rating.yaml",
        "export-compliance.yaml",
        "content-rights.yaml",
        "pricing-availability.yaml",
        "build-identity.yaml",
        "sign-in.yaml",
        "release-mode.yaml",
        "voice-gate.yaml",
        "operator-placeholders.yaml",
        "screenshots-manifest.yaml",
        "en-US/store-listing.yaml",
        "en-US/name.txt",
        "en-US/subtitle.txt",
        "en-US/promotional-text.txt",
        "en-US/description.txt",
        "en-US/keywords.txt",
        "en-US/review-notes.txt",
    ]
    for rel in required:
        if (root / rel).is_file():
            report.ok(f"present {rel}")
        else:
            report.err(f"missing required packet file: {rel}")


def check_voice_gate_packet_mode(report: Report, root: Path, packet: dict[str, Any]) -> None:
    path = root / packet["voice_gate_file"]
    if not path.is_file():
        report.err("voice-gate.yaml missing")
        return
    data = parse_simple_yaml(path)
    status = data.get("status")
    if status not in ("not_passed", "passed"):
        report.err(f"voice-gate status invalid: {status!r}")
    else:
        report.ok(f"voice-gate status present: {status}")
    text = read_text(path)
    if "acceptance_criteria:" not in text:
        report.err("voice-gate missing acceptance_criteria")
    else:
        report.ok("voice-gate has acceptance criteria section")
    if status == "not_passed":
        report.ok(
            "voice gate not_passed (allowed in packet mode; required passed for release-ready)"
        )


def check_operator_placeholders_packet_mode(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    path = root / packet["operator_placeholders_file"]
    if not path.is_file():
        report.err("operator-placeholders.yaml missing")
        return
    text = read_text(path)
    data = parse_simple_yaml(path)
    # Ensure we did not invent contact details in the unfilled template
    contact = data.get("app_review_contact") or {}
    for key in ("first_name", "last_name", "phone_number", "email"):
        val = contact.get(key)
        if not is_nullish(val):
            # filled is OK if someone filled them; inventing fake is operator error
            report.ok(f"operator contact {key} is set (owner-filled)")
        else:
            report.ok(f"operator contact {key} is null/TODO (not invented)")
    if "TODO" not in text and "null" not in text:
        report.warn("operator placeholders unexpectedly have no null/TODO markers")
    report.ok("operator placeholders present (filled values not required for packet mode)")


def check_evidence_files_packet_mode(report: Report, root: Path, packet: dict[str, Any]) -> None:
    """Evidence templates must exist; unfilled (null) is expected in packet mode."""
    for key, default in (
        ("connect_evidence_file", "connect-evidence.yaml"),
        ("release_prerequisites_file", "release-prerequisites.yaml"),
    ):
        rel = packet.get(key, default)
        path = root / rel
        if not path.is_file():
            report.err(f"missing {rel}")
            continue
        data = parse_simple_yaml(path)
        schema = data.get("schema")
        if not schema:
            report.err(f"{rel} missing schema field")
        else:
            report.ok(f"{rel} schema = {schema}")


# ---------------------------------------------------------------------------
# Release-ready gates (pre-archive / pre-upload)
# ---------------------------------------------------------------------------


def check_voice_gate_release_ready(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    path = root / packet["voice_gate_file"]
    data = parse_simple_yaml(path)
    if data.get("status") != "passed":
        report.err(
            "RELEASE-READY: voice physical-acceptance gate is not passed "
            f"(status={data.get('status')!r})"
        )
        return
    report.ok("RELEASE-READY: voice gate status = passed")

    # Evidence may live under when_status_becomes_passed.evidence or top-level evidence
    evidence = yaml_get(data, "when_status_becomes_passed", "evidence") or data.get(
        "evidence"
    )
    if not isinstance(evidence, dict):
        report.err("RELEASE-READY: voice-gate evidence block missing")
        return
    for key in ("device_model", "ios_version", "tested_on", "notes"):
        val = evidence.get(key)
        if is_nullish(val):
            report.err(f"RELEASE-READY: voice-gate evidence.{key} is still null/TODO")
        elif key == "notes" and isinstance(val, str) and len(val.strip()) < 12:
            report.err("RELEASE-READY: voice-gate evidence.notes too short")
        else:
            report.ok(f"RELEASE-READY: voice evidence.{key} set")


def check_operator_release_ready(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    """Owner/external gates that can and must be true before archive/upload.

    Does not require Connect field saves or post-upload evidence.
    """
    path = root / packet["operator_placeholders_file"]
    data = parse_simple_yaml(path)
    prefix = "RELEASE-READY"

    contact = data.get("app_review_contact") or {}
    for key in ("first_name", "last_name", "phone_number", "email"):
        if is_nullish(contact.get(key)):
            report.err(f"{prefix}: app_review_contact.{key} is still null/TODO")
        else:
            report.ok(f"{prefix}: app_review_contact.{key} set")

    copyright_ = data.get("copyright") or {}
    for key in ("holder", "year", "display_string"):
        if is_nullish(copyright_.get(key)):
            report.err(f"{prefix}: copyright.{key} is still null/TODO")
        else:
            report.ok(f"{prefix}: copyright.{key} set")

    dsa = data.get("dsa_trader_status") or {}
    dsa_status = dsa.get("status")
    allowed_dsa = {"trader", "non_trader", "not_applicable_decision"}
    if is_nullish(dsa_status) or str(dsa_status) not in allowed_dsa:
        report.err(
            f"{prefix}: dsa_trader_status.status must be one of {sorted(allowed_dsa)}, "
            f"got {dsa_status!r}"
        )
    else:
        report.ok(f"{prefix}: dsa_trader_status = {dsa_status}")

    support = data.get("public_support_channel") or {}
    for key in ("activated", "monitored"):
        if not is_true(support.get(key)):
            report.err(
                f"{prefix}: public_support_channel.{key} must be true "
                f"(got {support.get(key)!r})"
            )
        else:
            report.ok(f"{prefix}: support {key} = true")
    if is_nullish(support.get("verified_at")):
        report.err(f"{prefix}: public_support_channel.verified_at still null")
    else:
        report.ok(f"{prefix}: support verified_at = {support.get('verified_at')}")

    redeploy = data.get("production_website_redeploy") or {}
    if not is_true(redeploy.get("latest_source_redeployed")):
        report.err(
            f"{prefix}: production_website_redeploy.latest_source_redeployed must be true"
        )
    else:
        report.ok(f"{prefix}: website latest_source_redeployed = true")
    if is_nullish(redeploy.get("live_urls_reverified_at")):
        report.err(f"{prefix}: live_urls_reverified_at still null")
    else:
        report.ok(
            f"{prefix}: live_urls_reverified_at = {redeploy.get('live_urls_reverified_at')}"
        )


def check_release_prerequisites(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    rel = packet.get("release_prerequisites_file", "release-prerequisites.yaml")
    path = root / rel
    if not path.is_file():
        report.err(f"RELEASE-READY: missing {rel}")
        return
    data = parse_simple_yaml(path)
    prefix = "RELEASE-READY"

    cand = data.get("candidate") or {}
    if cand.get("marketing_version") != EXPECTED_VERSION:
        report.err(
            f"{prefix}: candidate.marketing_version must be {EXPECTED_VERSION!r}, "
            f"got {cand.get('marketing_version')!r}"
        )
    else:
        report.ok(f"{prefix}: candidate marketing_version {EXPECTED_VERSION}")
    if str(cand.get("build_number")) != EXPECTED_BUILD:
        report.err(
            f"{prefix}: candidate.build_number must be {EXPECTED_BUILD!r}, "
            f"got {cand.get('build_number')!r}"
        )
    else:
        report.ok(f"{prefix}: candidate build_number {EXPECTED_BUILD}")
    if cand.get("display") != EXPECTED_DISPLAY:
        report.err(
            f"{prefix}: candidate.display must be {EXPECTED_DISPLAY!r}, "
            f"got {cand.get('display')!r}"
        )
    else:
        report.ok(f"{prefix}: candidate display {EXPECTED_DISPLAY}")
    if cand.get("bundle_id") != EXPECTED_BUNDLE:
        report.err(f"{prefix}: candidate.bundle_id must be {EXPECTED_BUNDLE}")
    if str(cand.get("apple_id")) != EXPECTED_APPLE_ID:
        report.err(f"{prefix}: candidate.apple_id must be {EXPECTED_APPLE_ID}")
    if cand.get("project") != "PhrasaNative.xcodeproj":
        report.err(
            f"{prefix}: candidate.project must be PhrasaNative.xcodeproj "
            f"(not a Finder duplicate)"
        )
    else:
        report.ok(f"{prefix}: project PhrasaNative.xcodeproj")
    if cand.get("forbid_finder_duplicate_projects") is not True:
        report.err(f"{prefix}: forbid_finder_duplicate_projects must be true")
    else:
        report.ok(f"{prefix}: Finder duplicate projects forbidden")

    signing = data.get("signing") or {}
    if not is_true(signing.get("apple_distribution_identity_available")):
        report.err(
            f"{prefix}: signing.apple_distribution_identity_available must be true"
        )
    else:
        report.ok(f"{prefix}: Apple Distribution identity available")
    if not is_true(signing.get("provisioning_for_bundle_ready")):
        report.err(f"{prefix}: signing.provisioning_for_bundle_ready must be true")
    else:
        report.ok(f"{prefix}: provisioning ready for bundle")

    upload = data.get("upload_path") or {}
    method = upload.get("method")
    if method not in ("api_key", "transporter"):
        report.err(
            f"{prefix}: upload_path.method must be api_key or transporter, got {method!r}"
        )
    else:
        report.ok(f"{prefix}: upload_path.method = {method}")
    if not is_true(upload.get("credentials_verified")):
        report.err(f"{prefix}: upload_path.credentials_verified must be true")
    else:
        report.ok(f"{prefix}: upload credentials verified")

    if not is_true(data.get("ready_to_archive")):
        report.err(f"{prefix}: ready_to_archive must be true")
    else:
        report.ok(f"{prefix}: ready_to_archive = true")

    # Fail-closed: do not allow claiming post-upload work in release-ready file
    forbidden = data.get("post_release_claims_forbidden_until_later") or {}
    for key in (
        "archive_completed",
        "export_completed",
        "upload_completed",
        "build_processed_in_connect",
        "build_selected_in_connect",
    ):
        val = forbidden.get(key)
        if is_true(val):
            report.err(
                f"{prefix}: post_release_claims_forbidden_until_later.{key} must not be "
                "true in release-ready (record post-upload state in connect-evidence.yaml)"
            )
        else:
            report.ok(f"{prefix}: {key} not claimed early")


def check_release_ready_excludes_connect_saves(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    """release-ready must not require filled connect-evidence (structural guard)."""
    rel = packet.get("connect_evidence_file", "connect-evidence.yaml")
    path = root / rel
    if not path.is_file():
        return
    data = parse_simple_yaml(path)
    # If someone filled submission evidence early, that's fine for release-ready
    # pass — we simply do not *require* it. Document that exclusion.
    name = yaml_get(data, "public_app_name", "saved_value")
    if is_nullish(name):
        report.ok(
            "RELEASE-READY: connect-evidence public name not required yet (correct)"
        )
    else:
        report.ok(
            "RELEASE-READY: connect-evidence may be partially filled; not required"
        )


# ---------------------------------------------------------------------------
# Submission-ready gates (post Connect saves)
# ---------------------------------------------------------------------------


def _require_exact(
    report: Report, prefix: str, label: str, got: Any, expected: Any
) -> None:
    if got != expected:
        report.err(f"{prefix}: {label} must be {expected!r}, got {got!r}")
    else:
        report.ok(f"{prefix}: {label} = {expected!r}")


def _require_true(report: Report, prefix: str, label: str, got: Any) -> None:
    if not is_true(got):
        report.err(f"{prefix}: {label} must be true, got {got!r}")
    else:
        report.ok(f"{prefix}: {label} = true")


def _require_false(report: Report, prefix: str, label: str, got: Any) -> None:
    if not is_false(got):
        report.err(f"{prefix}: {label} must be false, got {got!r}")
    else:
        report.ok(f"{prefix}: {label} = false")


def check_connect_evidence_submission_ready(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    rel = packet.get("connect_evidence_file", "connect-evidence.yaml")
    path = root / rel
    if not path.is_file():
        report.err(f"SUBMISSION-READY: missing {rel}")
        return
    data = parse_simple_yaml(path)
    prefix = "SUBMISSION-READY"

    # Public App Store name. The exact product name "Phrasa" is already owned
    # by another developer account, so require an owner-selected saved value
    # without hard-coding an unavailable name.
    public_name = yaml_get(data, "public_app_name", "saved_value")
    if (
        is_nullish(public_name)
        or not isinstance(public_name, str)
        or len(public_name.strip()) > 30
        or public_name.strip() == "Phrasa (bd0543)"
    ):
        report.err(
            f"{prefix}: public_app_name.saved_value must be an available, "
            f"owner-selected App Store name (1-30 chars), got {public_name!r}"
        )
    else:
        report.ok(
            f"{prefix}: public_app_name.saved_value = {public_name.strip()!r}"
        )

    # Version metadata
    vm = data.get("version_metadata") or {}
    for key in (
        "subtitle_saved",
        "promotional_text_saved",
        "description_saved",
        "keywords_saved",
        "support_url_saved",
        "marketing_url_saved",
        "privacy_policy_url_saved",
        "whats_new_omitted",
    ):
        _require_true(report, prefix, f"version_metadata.{key}", vm.get(key))

    # Privacy — optional sync collects data (not tracking)
    priv = data.get("privacy") or {}
    _require_true(report, prefix, "privacy.questionnaire_completed", priv.get("questionnaire_completed"))
    _require_true(report, prefix, "privacy.published", priv.get("published"))
    _require_true(report, prefix, "privacy.collects_data_answer", priv.get("collects_data_answer"))
    _require_false(report, prefix, "privacy.tracks_users_answer", priv.get("tracks_users_answer"))
    _require_exact(
        report,
        prefix,
        "privacy.privacy_policy_url",
        priv.get("privacy_policy_url"),
        "https://phrasa.app/privacy",
    )
    if packet.get("privacy", {}).get("collects_data") is not True:
        report.err(f"{prefix}: packet.privacy.collects_data must be true")
    expected_types = {"Email Address", "User ID", "Other User Content"}
    evidence_types = priv.get("expected_data_types") or []
    if isinstance(evidence_types, list):
        got = {str(x) for x in evidence_types}
        if got != expected_types:
            report.err(
                f"{prefix}: privacy.expected_data_types must be {sorted(expected_types)}, got {sorted(got)}"
            )
        else:
            report.ok(f"{prefix}: privacy.expected_data_types match optional-sync set")
    else:
        report.err(f"{prefix}: privacy.expected_data_types must be a list")

    # Age rating
    age = data.get("age_rating") or {}
    _require_true(report, prefix, "age_rating.saved", age.get("saved"))
    _require_exact(report, prefix, "age_rating.intended_rating", age.get("intended_rating"), "4+")
    social_cap = age.get("social_media_capability")
    if str(social_cap).strip().lower() != "no":
        report.err(
            f"{prefix}: age_rating.social_media_capability must be 'no', got {social_cap!r}"
        )
    else:
        report.ok(f"{prefix}: age_rating.social_media_capability = no")
    _require_true(
        report, prefix, "age_rating.social_media_and_ugc_all_no", age.get("social_media_and_ugc_all_no")
    )

    # Categories
    cats = data.get("categories") or {}
    _require_exact(
        report, prefix, "categories.primary_saved", cats.get("primary_saved"), EXPECTED_PRIMARY_CAT
    )
    _require_exact(
        report,
        prefix,
        "categories.secondary_saved",
        cats.get("secondary_saved"),
        EXPECTED_SECONDARY_CAT,
    )

    # Content rights
    cr = data.get("content_rights") or {}
    _require_true(report, prefix, "content_rights.saved", cr.get("saved"))
    _require_true(
        report,
        prefix,
        "content_rights.has_rights_to_all_content",
        cr.get("has_rights_to_all_content"),
    )

    # Export compliance
    exp = data.get("export_compliance") or {}
    _require_true(report, prefix, "export_compliance.saved", exp.get("saved"))
    _require_false(
        report,
        prefix,
        "export_compliance.uses_non_exempt_encryption",
        exp.get("uses_non_exempt_encryption"),
    )

    # Pricing
    pricing = data.get("pricing_availability") or {}
    _require_exact(report, prefix, "pricing_availability.price", pricing.get("price"), "free")
    tax = pricing.get("tax_category")
    if tax != EXPECTED_TAX_CATEGORY:
        report.err(
            f"{prefix}: pricing_availability.tax_category must be exactly "
            f"{EXPECTED_TAX_CATEGORY!r}, got {tax!r}"
        )
    else:
        report.ok(f"{prefix}: tax_category = {EXPECTED_TAX_CATEGORY!r}")
    _require_true(
        report, prefix, "pricing_availability.us_availability_saved", pricing.get("us_availability_saved")
    )
    _require_true(
        report, prefix, "pricing_availability.territories_include_us", pricing.get("territories_include_us")
    )

    # Screenshots — bind to packet manifest
    shots_ev = data.get("screenshots") or {}
    packet_sets = {s["id"]: s for s in packet["screenshots"]["sets"]}
    for set_id, expected_slot in (
        ("iphone_6_9", "iPhone 6.9-inch"),
        ("ipad_13", "iPad 13-inch"),
    ):
        block = shots_ev.get(set_id) or {}
        _require_exact(
            report,
            prefix,
            f"screenshots.{set_id}.connect_slot",
            block.get("connect_slot"),
            expected_slot,
        )
        order = packet_sets[set_id]["upload_order"]
        expected_count = len(order)
        got_count = block.get("uploaded_count")
        if got_count != expected_count:
            report.err(
                f"{prefix}: screenshots.{set_id}.uploaded_count must be {expected_count} "
                f"(manifest-bound), got {got_count!r}"
            )
        else:
            report.ok(f"{prefix}: screenshots.{set_id}.uploaded_count = {expected_count}")
        files = block.get("uploaded_files_in_order")
        if not isinstance(files, list):
            report.err(
                f"{prefix}: screenshots.{set_id}.uploaded_files_in_order must be a list, "
                f"got {files!r}"
            )
        elif files != order:
            report.err(
                f"{prefix}: screenshots.{set_id}.uploaded_files_in_order must match "
                f"manifest {order}, got {files!r}"
            )
        else:
            report.ok(f"{prefix}: screenshots.{set_id} files match manifest order")
        _require_true(
            report,
            prefix,
            f"screenshots.{set_id}.not_uploaded_to_forbidden_slots",
            block.get("not_uploaded_to_forbidden_slots"),
        )

    # Build selection — exact 1.0 (14)
    build = data.get("build_selection") or {}
    _require_exact(
        report, prefix, "build_selection.marketing_version", build.get("marketing_version"), EXPECTED_VERSION
    )
    _require_exact(
        report, prefix, "build_selection.build_number", str(build.get("build_number")), EXPECTED_BUILD
    )
    # allow int 14 from YAML
    if str(build.get("build_number")) != EXPECTED_BUILD:
        pass  # already erred
    _require_exact(
        report, prefix, "build_selection.display", build.get("display"), EXPECTED_DISPLAY
    )
    if str(build.get("processing_state") or "").lower() != "processed":
        report.err(
            f"{prefix}: build_selection.processing_state must be 'processed', "
            f"got {build.get('processing_state')!r}"
        )
    else:
        report.ok(f"{prefix}: build processing_state = processed")
    _require_true(
        report, prefix, "build_selection.selected_for_version", build.get("selected_for_version")
    )

    # Sign-in OFF
    si = data.get("sign_in_required") or {}
    _require_false(report, prefix, "sign_in_required.saved_value", si.get("saved_value"))

    # Manual release
    rel_mode = data.get("release_mode") or {}
    if str(rel_mode.get("saved_value") or "").lower() != "manual":
        report.err(
            f"{prefix}: release_mode.saved_value must be 'manual', "
            f"got {rel_mode.get('saved_value')!r}"
        )
    else:
        report.ok(f"{prefix}: release_mode = manual")

    # Mac / Vision Pro disabled
    mac = data.get("apple_silicon_mac") or {}
    if str(mac.get("availability") or "").lower() != "disabled":
        report.err(
            f"{prefix}: apple_silicon_mac.availability must be 'disabled', "
            f"got {mac.get('availability')!r}"
        )
    else:
        report.ok(f"{prefix}: Apple Silicon Mac availability disabled")

    vision = data.get("vision_pro") or {}
    if str(vision.get("compatibility") or "").lower() != "disabled":
        report.err(
            f"{prefix}: vision_pro.compatibility must be 'disabled', "
            f"got {vision.get('compatibility')!r}"
        )
    else:
        report.ok(f"{prefix}: Vision Pro compatibility disabled")

    # Review contact + notes
    review = data.get("app_review") or {}
    for key in (
        "contact_first_name",
        "contact_last_name",
        "contact_phone_number",
        "contact_email",
    ):
        if is_nullish(review.get(key)):
            report.err(f"{prefix}: app_review.{key} is still null/TODO")
        else:
            report.ok(f"{prefix}: app_review.{key} set")
    _require_true(report, prefix, "app_review.review_notes_saved", review.get("review_notes_saved"))

    # DSA
    dsa = data.get("dsa") or {}
    _require_true(report, prefix, "dsa.decision_saved", dsa.get("decision_saved"))
    allowed_dsa = {"trader", "non_trader", "not_applicable_decision"}
    if str(dsa.get("status")) not in allowed_dsa:
        report.err(
            f"{prefix}: dsa.status must be one of {sorted(allowed_dsa)}, got {dsa.get('status')!r}"
        )
    else:
        report.ok(f"{prefix}: dsa.status = {dsa.get('status')}")

    # Social media age rating answer
    sma = data.get("social_media_age_rating") or {}
    _require_true(report, prefix, "social_media_age_rating.answer_saved", sma.get("answer_saved"))
    if str(sma.get("answer") or "").lower() != "no":
        report.err(
            f"{prefix}: social_media_age_rating.answer must be 'no', got {sma.get('answer')!r}"
        )
    else:
        report.ok(f"{prefix}: social_media_age_rating.answer = no")

    # Accessibility optional — fail if claimed without evidence structure honesty
    acc = data.get("accessibility_labels") or {}
    if is_true(acc.get("required")):
        report.err(
            f"{prefix}: accessibility_labels.required must be false "
            "(labels are optional; do not require without proof)"
        )
    else:
        report.ok(f"{prefix}: accessibility labels not required (optional)")
    if is_true(acc.get("claimed")) and is_nullish(acc.get("evidence")):
        report.err(
            f"{prefix}: accessibility_labels.claimed is true but evidence is null "
            "(do not claim without proof)"
        )


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def run_packet_checks(report: Report, root: Path, packet: dict[str, Any]) -> None:
    check_required_packet_files(report, root)
    check_limits(report, root, packet)
    check_urls(report, packet)
    check_prohibited_claims(report, root, packet)
    check_build_identity(report, root, packet)
    check_connect_audit(report, root, packet)
    check_current_release_state_consistency(report, root, packet)
    check_privacy_age(report, root, packet)
    check_screenshots(report, root, packet)
    check_voice_gate_packet_mode(report, root, packet)
    check_operator_placeholders_packet_mode(report, root, packet)
    check_evidence_files_packet_mode(report, root, packet)


def run_release_ready_checks(report: Report, root: Path, packet: dict[str, Any]) -> None:
    check_voice_gate_release_ready(report, root, packet)
    check_operator_release_ready(report, root, packet)
    check_release_prerequisites(report, root, packet)
    check_release_ready_excludes_connect_saves(report, root, packet)


def run_submission_ready_checks(
    report: Report, root: Path, packet: dict[str, Any]
) -> None:
    check_connect_evidence_submission_ready(report, root, packet)


def normalize_mode(mode: str) -> str:
    return MODE_ALIASES.get(mode, mode)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=MODES,
        default="packet",
        help=(
            "packet | release-ready | submission-ready "
            "(final is a legacy alias for submission-ready)"
        ),
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Submission packet root directory",
    )
    args = parser.parse_args(argv)
    root: Path = args.root.resolve()
    mode = normalize_mode(args.mode)
    report = Report()

    packet_path = root / "packet.json"
    if not packet_path.is_file():
        print(f"ERR missing packet.json at {packet_path}", file=sys.stderr)
        return 1
    packet = json.loads(packet_path.read_text(encoding="utf-8"))

    print("Phrasa App Store packet validator")
    print(f"  root: {root}")
    print(f"  mode: {mode}" + (f" (alias of {args.mode})" if args.mode != mode else ""))
    print()

    # Phase 1 always
    run_packet_checks(report, root, packet)

    if mode in ("release-ready", "submission-ready"):
        run_release_ready_checks(report, root, packet)

    if mode == "submission-ready":
        run_submission_ready_checks(report, root, packet)

    print("--- checks ---")
    for line in report.checks:
        print(line)
    print()
    if report.warnings:
        print(f"{len(report.warnings)} warning(s)")
    if report.errors:
        print(f"RESULT: FAIL ({len(report.errors)} error(s)) [{mode} mode]")
        for e in report.errors:
            print(f"  - {e}")
        return 1

    print(f"RESULT: PASS [{mode} mode]")
    if mode == "packet":
        print(
            "Note: packet completeness ≠ release-ready or submission-ready. "
            "Run --mode release-ready before archive/export/upload; "
            "run --mode submission-ready only after Connect saves."
        )
    elif mode == "release-ready":
        print(
            "Note: release-ready authorizes producing/uploading the 1.0 (14) candidate. "
            "It does not prove Connect saves. After upload/processing/selection and "
            "metadata saves, run --mode submission-ready before submit."
        )
    elif mode == "submission-ready":
        print(
            "Note: submission-ready means Connect evidence matches required exact "
            "values for this release. It does not itself submit or verify Apple's "
            "live review state."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

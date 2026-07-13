#!/usr/bin/env python3

import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path


REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "").strip() or "ivLis-Studio/ivLyrics-IOS"
BUNDLE_IDENTIFIER = "kr.ivlis.ivlyrics.ios"
SOURCE_PATH = Path("altstore-source.json")
TEMPLATE_PATH = Path(".github/release-notes-template.md")
ICON_URL = (
    f"https://raw.githubusercontent.com/{REPOSITORY}/main/"
    "ivLyrics-IOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
)
ALTSTORE_SOURCE_URL = (
    f"https://raw.githubusercontent.com/{REPOSITORY}/main/"
    "altstore-source.json"
)


def run_git(args, allow_fail=False):
    result = subprocess.run(
        ["git", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0 and not allow_fail:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def version_key(tag):
    value = tag[1:] if tag.lower().startswith("v") else tag
    parts = []
    for chunk in re.split(r"[^0-9A-Za-z]+", value):
        if not chunk:
            continue
        parts.append((0, int(chunk)) if chunk.isdigit() else (1, chunk.lower()))
    return parts


def previous_tag(current_tag):
    current_key = version_key(current_tag)
    tags = [
        tag
        for tag in run_git(["tag", "--list", "v*"]).splitlines()
        if tag and tag != current_tag and version_key(tag) < current_key
    ]
    return sorted(tags, key=version_key)[-1] if tags else ""


def resolve_ref(ref):
    if run_git(["rev-parse", "--verify", f"{ref}^{{commit}}"], allow_fail=True):
        return ref
    return "HEAD"


def resolve_commit(ref):
    resolved = run_git(
        ["rev-parse", "--verify", f"{ref}^{{commit}}"], allow_fail=True
    )
    return resolved.splitlines()[0] if resolved else run_git(["rev-parse", "HEAD"])


def release_changes(previous, current_ref):
    range_spec = f"{previous}..{current_ref}" if previous else current_ref
    log_text = run_git(
        [
            "log",
            "--no-merges",
            "--max-count=100",
            "--pretty=format:%h%x09%s",
            range_spec,
        ],
        allow_fail=True,
    )
    if previous:
        stat_text = run_git(["diff", "--stat", range_spec], allow_fail=True)
    else:
        stat_text = run_git(
            ["diff-tree", "--root", "--stat", "--no-commit-id", current_ref],
            allow_fail=True,
        )
    return log_text, stat_text


def compare_url(current_tag, previous):
    if previous:
        return f"https://github.com/{REPOSITORY}/compare/{previous}...{current_tag}"
    return f"https://github.com/{REPOSITORY}/commits/{current_tag}"


def load_ipa(path):
    if not path.is_file():
        raise RuntimeError(f"IPA file not found: {path}")

    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        info_names = [
            name
            for name in names
            if re.fullmatch(r"Payload/[^/]+[.]app/Info[.]plist", name)
        ]
        if len(info_names) != 1:
            raise RuntimeError("IPA must contain exactly one application Info.plist")
        if any(
            name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name
            for name in names
        ):
            raise RuntimeError("IPA unexpectedly contains signing metadata")
        if any(
            part == "__MACOSX" or part.startswith("._")
            for name in names
            for part in name.split("/")
            if part
        ):
            raise RuntimeError("IPA contains macOS metadata files")
        info = plistlib.loads(archive.read(info_names[0]))

    bundle_id = str(info.get("CFBundleIdentifier") or "")
    version_name = str(info.get("CFBundleShortVersionString") or "")
    build_number = str(info.get("CFBundleVersion") or "")
    minimum_os = str(info.get("MinimumOSVersion") or "")
    supported = info.get("CFBundleSupportedPlatforms") or []
    if bundle_id != BUNDLE_IDENTIFIER:
        raise RuntimeError(f"Unexpected bundle identifier: {bundle_id}")
    if "iPhoneOS" not in supported:
        raise RuntimeError("IPA is not an iOS device build")

    expected_version = os.environ.get("VERSION_NAME", "").strip()
    expected_build = os.environ.get("BUILD_NUMBER", "").strip()
    if expected_version and version_name != expected_version:
        raise RuntimeError(
            f"IPA version is {version_name}, expected {expected_version}"
        )
    if expected_build and build_number != expected_build:
        raise RuntimeError(
            f"IPA build is {build_number}, expected {expected_build}"
        )

    privacy = {
        key: value
        for key, value in info.items()
        if key.startswith("NS")
        and key.endswith("UsageDescription")
        and isinstance(value, str)
        and value.strip()
    }
    return {
        "name": path.name,
        "path": str(path.resolve()),
        "size": path.stat().st_size,
        "sha256": digest,
        "bundleIdentifier": bundle_id,
        "versionName": version_name,
        "buildNumber": build_number,
        "minimumOSVersion": minimum_os,
        "privacy": privacy,
    }


def verify_checksum(ipa, checksum_path):
    if not checksum_path:
        return
    path = Path(checksum_path)
    if not path.is_file():
        raise RuntimeError(f"Checksum file not found: {path}")
    expected = path.read_text(encoding="utf-8").split(maxsplit=1)[0].lower()
    if expected != ipa["sha256"]:
        raise RuntimeError("IPA checksum file does not match the IPA")


def commit_subjects(log_text):
    subjects = [
        line.split("\t", 1)[-1].strip()
        for line in log_text.splitlines()
        if line.strip()
    ]
    return subjects or ["Build and publish the iOS application."]


def fallback_content(current_tag, log_text):
    subjects = commit_subjects(log_text)
    highlights = subjects[:8]
    fixes = subjects[8:14] or ["Prepare the unsigned IPA release workflow."]
    return {
        "ko": {
            "summary": f"{current_tag} iOS 릴리스와 AltStore 설치용 무서명 IPA를 제공합니다.",
            "highlights": highlights,
            "fixes": fixes,
        },
        "en": {
            "summary": f"{current_tag} provides the iOS release and an unsigned IPA for AltStore installation.",
            "highlights": highlights,
            "fixes": fixes,
        },
    }


def normalize_chat_url(base_url):
    base = (base_url or "").strip().rstrip("/")
    if not base:
        return ""
    if base.endswith("/chat/completions"):
        return base
    if base.endswith("/v1"):
        return base + "/chat/completions"
    return base + "/v1/chat/completions"


def normalize_note_section(section):
    def string_value(key):
        return str(section.get(key) or "").strip()

    def list_value(key):
        value = section.get(key)
        if isinstance(value, list):
            return [str(item).strip() for item in value if str(item).strip()]
        if isinstance(value, str) and value.strip():
            return [value.strip()]
        return []

    return {
        "summary": string_value("summary"),
        "highlights": list_value("highlights"),
        "fixes": list_value("fixes"),
    }


def parse_ai_json(text):
    value = (text or "").strip()
    value = re.sub(r"^```(?:json)?\s*", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\s*```$", "", value)
    try:
        data = json.loads(value)
    except json.JSONDecodeError:
        return {}
    if not isinstance(data, dict):
        return {}
    ko = data.get("ko") if isinstance(data.get("ko"), dict) else {}
    en = data.get("en") if isinstance(data.get("en"), dict) else {}
    if not ko or not en:
        return {}
    return {
        "ko": normalize_note_section(ko),
        "en": normalize_note_section(en),
    }


def ai_release_content(current_tag, previous, ipa, log_text, stat_text):
    api_key = os.environ.get("AI_API_KEY", "").strip()
    api_url = normalize_chat_url(os.environ.get("AI_BASE_URL", ""))
    model = os.environ.get("AI_MODEL", "").strip() or "gpt-4o-mini"
    if not api_key or not api_url:
        return {}

    prompt = textwrap.dedent(
        f"""
        You write bilingual GitHub release note content for an iOS music lyrics app named ivLyrics iOS.
        Return JSON only. Do not return Markdown.

        Current tag: {current_tag}
        Previous tag: {previous or "(none)"}
        Compare URL: {compare_url(current_tag, previous)}
        iOS version: {ipa["versionName"]}
        iOS build: {ipa["buildNumber"]}
        IPA asset: {ipa["name"]} ({ipa["size"]} bytes, sha256={ipa["sha256"]})

        Output JSON schema:
        {{
          "ko": {{
            "summary": "Korean one-sentence summary",
            "highlights": ["Korean user-facing highlight", "..."],
            "fixes": ["Korean improvement or fix", "..."]
          }},
          "en": {{
            "summary": "English one-sentence summary",
            "highlights": ["English user-facing highlight", "..."],
            "fixes": ["English improvement or fix", "..."]
          }}
        }}

        Requirements:
        - Write both Korean and English with equivalent meaning.
        - Keep every bullet short, concrete, and user-facing.
        - Compare this release against the previous tag.
        - Mention only changes supported by the commit list.
        - State that the IPA is unsigned and intended for user-side signing with AltStore.
        - Do not mention secrets, private URLs, internal endpoints, or a Full Changelog link.

        Commits:
        {log_text or "(no commit log)"}

        Diff stat:
        {stat_text or "(no diff stat)"}
        """
    ).strip()
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "Generate accurate GitHub release notes from the supplied git metadata only.",
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.25,
    }
    request = urllib.request.Request(
        api_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "ivLyrics-iOS-ReleaseBot/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace").strip()
        if len(body) > 1200:
            body = body[:1200] + "...(truncated)"
        detail = f"HTTP {exc.code}: {exc.reason or ''}".strip()
        if body:
            detail += f" / {body}"
        print(f"AI release note generation failed: {detail}", file=sys.stderr)
        return {}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"AI release note generation failed: {exc}", file=sys.stderr)
        return {}

    choices = data.get("choices") or []
    if not choices:
        return {}
    message = choices[0].get("message") or {}
    return parse_ai_json(message.get("content") or "")


def markdown_bullets(values):
    items = [str(value).strip() for value in values if str(value).strip()]
    return "\n".join(f"- {item}" for item in (items or ["No notable changes."]))


def load_template():
    if TEMPLATE_PATH.exists():
        return TEMPLATE_PATH.read_text(encoding="utf-8")
    raise RuntimeError(f"Release notes template not found: {TEMPLATE_PATH}")


def render_notes(current_tag, previous, ipa, content):
    ko = content.get("ko") or {}
    en = content.get("en") or {}
    return load_template().format(
        tag=current_tag,
        version_name=ipa["versionName"],
        build_number=ipa["buildNumber"],
        previous_tag=previous or "None",
        compare_url=compare_url(current_tag, previous),
        ko_summary=ko.get("summary") or "릴리스 노트가 생성되었습니다.",
        ko_highlights=markdown_bullets(ko.get("highlights") or []),
        ko_fixes=markdown_bullets(ko.get("fixes") or []),
        en_summary=en.get("summary") or "Release notes were generated.",
        en_highlights=markdown_bullets(en.get("highlights") or []),
        en_fixes=markdown_bullets(en.get("fixes") or []),
        ipa_name=ipa["name"],
        ipa_sha256=ipa["sha256"],
        altstore_source_url=ALTSTORE_SOURCE_URL,
    )


def default_source():
    return {
        "name": "ivLyrics iOS",
        "subtitle": "Official ivLyrics releases for AltStore Classic.",
        "description": (
            "Spotify 재생 곡의 싱크 가사를 제공하는 ivLyrics iOS 공식 소스입니다. "
            "This is the official AltStore source for ivLyrics iOS."
        ),
        "iconURL": ICON_URL,
        "website": f"https://github.com/{REPOSITORY}",
        "tintColor": "#FF3B7D",
        "featuredApps": [BUNDLE_IDENTIFIER],
        "apps": [],
        "news": [],
    }


def default_app():
    return {
        "name": "ivLyrics",
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "developerName": "ivLis Studio",
        "subtitle": "Synced Spotify lyrics with karaoke effects.",
        "localizedDescription": (
            "Spotify 재생 곡의 싱크 가사, 번역, 발음 및 노래방 효과를 제공하는 "
            "iOS 앱입니다. An iOS lyrics player with synchronized karaoke effects, "
            "translations, and pronunciation guides for Spotify playback."
        ),
        "iconURL": ICON_URL,
        "tintColor": "#FF3B7D",
        "category": "entertainment",
        "versions": [],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }


def load_source():
    if not SOURCE_PATH.is_file():
        return default_source()
    try:
        source = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default_source()
    return source if isinstance(source, dict) else default_source()


def build_altstore_source(current_tag, ipa, content):
    source = load_source()
    defaults = default_source()
    for key, value in defaults.items():
        if key not in source:
            source[key] = value
    source["website"] = f"https://github.com/{REPOSITORY}"
    source["iconURL"] = ICON_URL

    apps = source.get("apps") if isinstance(source.get("apps"), list) else []
    app = next(
        (
            item
            for item in apps
            if isinstance(item, dict)
            and item.get("bundleIdentifier") == BUNDLE_IDENTIFIER
        ),
        default_app(),
    )
    app_defaults = default_app()
    for key, value in app_defaults.items():
        if key not in app:
            app[key] = value
    app["iconURL"] = ICON_URL

    encoded_tag = urllib.parse.quote(current_tag, safe="")
    encoded_name = urllib.parse.quote(ipa["name"], safe="")
    download_url = (
        f"https://github.com/{REPOSITORY}/releases/download/"
        f"{encoded_tag}/{encoded_name}"
    )
    ko_summary = str((content.get("ko") or {}).get("summary") or "").strip()
    en_summary = str((content.get("en") or {}).get("summary") or "").strip()
    description = "\n\n".join(value for value in [ko_summary, en_summary] if value)
    version = {
        "version": ipa["versionName"],
        "buildVersion": ipa["buildNumber"],
        "date": datetime.now(timezone.utc).date().isoformat(),
        "localizedDescription": description or f"ivLyrics iOS {current_tag}",
        "downloadURL": download_url,
        "size": ipa["size"],
        "sha256": ipa["sha256"],
        "minOSVersion": ipa["minimumOSVersion"] or "17.0",
    }
    versions = app.get("versions") if isinstance(app.get("versions"), list) else []
    versions = [
        item
        for item in versions
        if not (
            isinstance(item, dict)
            and str(item.get("version")) == ipa["versionName"]
            and str(item.get("buildVersion")) == ipa["buildNumber"]
        )
    ]
    app["versions"] = [version, *versions]
    app["appPermissions"] = {
        "entitlements": [],
        "privacy": ipa["privacy"],
    }
    source["apps"] = [app]
    source["news"] = source.get("news") if isinstance(source.get("news"), list) else []
    return source


def write_github_outputs(values):
    output_path = os.environ.get("GITHUB_OUTPUT", "").strip()
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main():
    current_tag = os.environ.get("RELEASE_TAG", "").strip()
    if not current_tag:
        current_tag = run_git(
            ["describe", "--tags", "--exact-match"], allow_fail=True
        )
    if not current_tag:
        raise RuntimeError("RELEASE_TAG is required")

    ipa_path = Path(os.environ.get("IPA_PATH", "").strip())
    ipa = load_ipa(ipa_path)
    verify_checksum(ipa, os.environ.get("CHECKSUM_PATH", "").strip())

    previous = previous_tag(current_tag)
    current_ref = resolve_ref(current_tag)
    log_text, stat_text = release_changes(previous, current_ref)
    content = ai_release_content(
        current_tag, previous, ipa, log_text, stat_text
    ) or fallback_content(current_tag, log_text)
    notes = render_notes(current_tag, previous, ipa, content)
    source = build_altstore_source(current_tag, ipa, content)

    out_dir = Path(os.environ.get("RELEASE_METADATA_DIR", "release-metadata"))
    out_dir.mkdir(parents=True, exist_ok=True)
    notes_path = out_dir / "release-notes.md"
    version_path = out_dir / f"ivLyrics-IOS-{current_tag}-version.json"
    source_path = out_dir / "altstore-source.json"

    notes_path.write_text(notes.strip() + "\n", encoding="utf-8")
    version_path.write_text(
        json.dumps(
            {
                "tag": current_tag,
                "commit": resolve_commit(current_tag),
                "previousTag": previous,
                "versionName": ipa["versionName"],
                "versionCode": int(ipa["buildNumber"]),
                "compareUrl": compare_url(current_tag, previous),
                "altStoreSourceUrl": ALTSTORE_SOURCE_URL,
                "ipas": [
                    {
                        "name": ipa["name"],
                        "size": ipa["size"],
                        "sha256": ipa["sha256"],
                        "downloadUrl": source["apps"][0]["versions"][0]["downloadURL"],
                    }
                ],
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    source_path.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_github_outputs(
        {
            "notes_path": notes_path.resolve(),
            "version_path": version_path.resolve(),
            "altstore_source_path": source_path.resolve(),
        }
    )
    print(f"previous_tag={previous}")
    print(f"notes={notes_path}")
    print(f"version_file={version_path}")
    print(f"altstore_source={source_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Release metadata generation failed: {exc}", file=sys.stderr)
        raise

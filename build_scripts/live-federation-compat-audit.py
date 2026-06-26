#!/usr/bin/env python3
"""
    Project: Unfathomably federation smoke tests
    --------------------------------------------

    File: live-federation-compat-audit.py

    Purpose:

        Exercise a live Unfathomably instance against public ActivityPub
        groups and feed-like actors across the broad platform matrix that
        the project intends to support.

    Responsibilities:

        * resolve one curated public target for each platform family
        * follow the target with an existing local user token when needed
        * fetch native preview/feed rows through the public Mastodon-style API
        * verify whether rows hydrate into normal status objects
        * optionally perform reversible favourites
        * optionally perform local-only reply/delete checks

    This file intentionally does NOT contain:

        * platform-specific scraping outside the backend APIs
        * private credentials
        * destructive cleanup of follows or local account state

    Live federation has two different kinds of checks. Read-only checks prove
    that discovery, follow state, and native row hydration work. Action checks
    prove that normal status operations can run on hydrated rows. Action checks
    are explicitly gated by FEDERATION_AUDIT_ACTIONS. Reply checks are limited
    to the local audit group so this script does not post into public remote
    communities.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import json
import os
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


# ---------------------------------------------------------------------------
# Candidate matrix
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Candidate:
    lane: str
    platform: str
    identifier: str
    label: str
    allow_reply: bool = False
    notes: str = ""


SOURCE_CANDIDATES: list[Candidate] = [
    Candidate("source", "funkwhale", "https://baleafunk.eus/federation/actors/albistekia", "Funkwhale public audio feed", allow_reply=True),
    Candidate("source", "wordpress", "https://andypiper.co.uk/author/andypiper/", "WordPress technology blog", allow_reply=True),
    Candidate("source", "writefreely", "https://blogz.zaclys.com/api/collections/1216stories", "WriteFreely public blog"),
    Candidate("source", "gotosocial", "dofh_excuses@gts.chapek9.com", "GoToSocial public account", allow_reply=True),
    Candidate("source", "snac", "@grunfink@comam.es", "snac author", allow_reply=True),
    Candidate("source", "iceshrimp", "https://misskey.pm/users/9k0wukulac6kcgjm", "Iceshrimp public account", allow_reply=True),
    Candidate("source", "mitra", "admin@public.mitra.social", "Public Mitra admin", allow_reply=True),
    Candidate("source", "pixelfed", "stux@pixey.org", "Pixelfed public account", allow_reply=True),
    Candidate("source", "owncast", "https://watch.owncast.online/federation/user/demo", "Owncast demo"),
    Candidate("source", "misskey", "@ai@misskey.io", "Misskey AI account", allow_reply=True),
    Candidate("source", "sharkey", "https://sharkey.ranranhome.info/users/9y9ss045xz", "Sharkey public account", allow_reply=True),
    Candidate("source", "wafrn", "https://app.wafrn.net/fediverse/blog/gabboman", "wafrn public account", allow_reply=True),
]


GROUP_CANDIDATES: list[Candidate] = [
    Candidate("group", "peertube", "@nephitejnf_channel@videos.realnephestate.xyz", "PeerTube channel", allow_reply=True),
    Candidate("group", "lemmy", "selfhosted@lemmy.world", "Lemmy self-hosted", allow_reply=True),
    Candidate("group", "nodebb", "nodebb-development@community.nodebb.org", "NodeBB development forum", allow_reply=True),
    Candidate("group", "piefed", "3dprinting@piefed.world", "PieFed 3D printing", allow_reply=True),
    Candidate("group", "discourse", "fediversereport@socialhub.activitypub.rocks", "SocialHub Fediverse Report", allow_reply=True),
    Candidate("group", "wordpress", "@blog@vivaldi.com", "WordPress blog as group-like feed"),
    Candidate("group", "fedigroups", "18xx@fedigroups.social", "FediGroups board games"),
    Candidate("group", "hubzilla", "@adminsforum@hubzilla.org", "Hubzilla admins forum", allow_reply=True),
    Candidate("group", "friendica", "helpers@forum.friendi.ca", "Friendica helpers forum", allow_reply=True),
    Candidate("group", "mbin", "AskMbin@thebrainbin.org", "Mbin AskMbin magazine", allow_reply=True),
    Candidate("group", "lotide", "general@lotide.fbxl.net", "Lotide general", allow_reply=True),
    Candidate("group", "local", "federation_audit@social.fbxl.net", "Local federation audit group", allow_reply=True),
    Candidate("group", "gancio", "gancio@gancio.cisti.org", "Gancio events", allow_reply=True),
    Candidate("group", "mobilizon", "liberons_nos_ordis@mobilizon.fr", "Mobilizon public group", allow_reply=True),
    Candidate(
        "group",
        "unclassified",
        "08890479-63c5-4dec-81b0-e8f50ea9d290@peertube.openstreetmap.fr",
        "Neutral sample from the unclassified directory",
        allow_reply=True,
        notes="The directory's smaller unknown bucket only had a news target that resolved.",
    ),
]


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


class ApiError(RuntimeError):
    def __init__(self, method: str, url: str, status: int, body: str) -> None:
        super().__init__(f"{method} {url} returned {status}: {body[:500]}")
        self.method = method
        self.url = url
        self.status = status
        self.body = body


class ApiClient:
    def __init__(self, base_url: str, token: str, timeout: float) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        return self.request("GET", path, params=params)

    def post_form(self, path: str, data: dict[str, Any] | None = None) -> Any:
        return self.request("POST", path, data=data or {})

    def delete(self, path: str) -> Any:
        return self.request("DELETE", path)

    def request(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        data: dict[str, Any] | None = None,
    ) -> Any:
        url = self.base_url + path

        if params:
            query = urllib.parse.urlencode(params, doseq=True)
            url = url + ("&" if "?" in url else "?") + query

        body = None
        headers = {
            "accept": "application/json",
            "user-agent": "unfathomably-live-federation-audit/1.0",
        }

        if self.token:
            headers["authorization"] = f"Bearer {self.token}"

        if data is not None:
            body = urllib.parse.urlencode(data, doseq=True).encode("utf-8")
            headers["content-type"] = "application/x-www-form-urlencoded"

        request = urllib.request.Request(url, data=body, headers=headers, method=method)

        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode("utf-8", "replace")
                if not raw:
                    return {}
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            raise ApiError(method, url, exc.code, raw) from exc


# ---------------------------------------------------------------------------
# Audit logic
# ---------------------------------------------------------------------------


def endpoint_base(candidate: Candidate) -> str:
    if candidate.lane == "group":
        return "/api/v1/groups"
    return "/api/v1/feeds"


def lookup_params(candidate: Candidate) -> dict[str, str]:
    if candidate.lane == "group":
        return {"uri": candidate.identifier}
    return {"name": candidate.identifier}


def resolve_target(client: ApiClient, candidate: Candidate) -> dict[str, Any]:
    base = endpoint_base(candidate)

    try:
        return client.get(f"{base}/lookup", lookup_params(candidate))
    except ApiError:
        pass

    results = client.get(f"{base}/search", {"q": candidate.identifier, "limit": 5})

    if not isinstance(results, list) or not results:
        raise RuntimeError("target did not resolve")

    expected = candidate.platform.lower()

    for result in results:
        platform = str(result.get("platform") or "").lower()
        label = str(result.get("platform_label") or "").lower()

        if expected in {platform, label} or expected in platform or expected in label:
            return result

    return results[0]


def ensure_following(client: ApiClient, candidate: Candidate, target: dict[str, Any]) -> dict[str, Any]:
    base = endpoint_base(candidate)
    target_id = target["id"]

    if candidate.lane == "group":
        relationship = target.get("relationship") or {}
        if relationship.get("member") or relationship.get("requested"):
            return relationship
        return client.post_form(f"{base}/{target_id}/join")

    relationship = target.get("relationship") or {}
    if relationship.get("following") or relationship.get("requested"):
        return relationship
    return client.post_form(f"{base}/{target_id}/follow")


def fetch_items(client: ApiClient, candidate: Candidate, target: dict[str, Any], limit: int) -> dict[str, Any]:
    base = endpoint_base(candidate)
    target_id = target["id"]

    if candidate.lane == "group":
        envelope = client.get(f"{base}/{target_id}/preview", {"limit": limit})

        if normalized_items(envelope):
            return envelope

        statuses = client.get(f"{base}/{target_id}/statuses", {"limit": limit})

        if isinstance(statuses, list) and statuses:
            return {
                "items": [
                    {
                        "id": status.get("id"),
                        "type": "Status",
                        "title": status.get("content"),
                        "url": status.get("url"),
                        "status": status,
                    }
                    for status in statuses
                    if isinstance(status, dict)
                ],
                "total_items": len(statuses),
            }

        return envelope

    return client.get(f"{base}/{target_id}/items", {"limit": limit})


def normalized_items(envelope: Any) -> list[dict[str, Any]]:
    if isinstance(envelope, dict):
        items = envelope.get("items") or envelope.get("orderedItems") or []
    elif isinstance(envelope, list):
        items = envelope
    else:
        items = []

    return [item for item in items if isinstance(item, dict)]


def status_from_item(item: dict[str, Any]) -> dict[str, Any] | None:
    status = item.get("status")
    if isinstance(status, dict) and status.get("id"):
        return status
    return None


def perform_status_actions(
    client: ApiClient,
    candidate: Candidate,
    status: dict[str, Any],
    enable_actions: bool,
    enable_replies: bool,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "favourite": "skipped",
        "unfavourite": "skipped",
        "reply": "skipped",
        "delete_reply": "skipped",
    }

    if not enable_actions:
        return result

    status_id = status["id"]

    if status.get("favourited") is True:
        result["favourite"] = "already favourited"
        result["unfavourite"] = "preserved"
    else:
        try:
            client.post_form(f"/api/v1/statuses/{status_id}/favourite")
            result["favourite"] = "ok"
        except Exception as exc:
            result["favourite"] = f"failed: {exc}"

        try:
            client.post_form(f"/api/v1/statuses/{status_id}/unfavourite")
            result["unfavourite"] = "ok"
        except Exception as exc:
            result["unfavourite"] = f"failed: {exc}"

    if not enable_replies or not candidate.allow_reply:
        return result

    if not local_reply_target(candidate):
        result["reply"] = "skipped public target"
        result["delete_reply"] = "skipped public target"
        return result

    body = (
        "Unfathomably federation compatibility smoke test. "
        "This reply should be deleted automatically."
    )

    try:
        reply = client.post_form(
            "/api/v1/statuses",
            {
                "status": body,
                "in_reply_to_id": status_id,
                "visibility": "unlisted",
            },
        )
        reply_id = reply.get("id")
        result["reply"] = "ok" if reply_id else "no reply id returned"

        if reply_id:
            client.delete(f"/api/v1/statuses/{reply_id}")
            result["delete_reply"] = "ok"
    except Exception as exc:
        result["reply"] = f"failed: {exc}"

    return result


def local_reply_target(candidate: Candidate) -> bool:
    return candidate.lane == "group" and candidate.platform == "local"


def audit_candidate(
    client: ApiClient,
    candidate: Candidate,
    limit: int,
    enable_actions: bool,
    enable_replies: bool,
) -> dict[str, Any]:
    started = time.monotonic()
    row: dict[str, Any] = {
        "lane": candidate.lane,
        "expected_platform": candidate.platform,
        "label": candidate.label,
        "identifier": candidate.identifier,
        "resolved": False,
        "followed": False,
        "items_count": 0,
        "native_status_count": 0,
        "actionable": False,
        "ok": False,
    }

    try:
        target = resolve_target(client, candidate)
        row.update(
            {
                "resolved": True,
                "id": target.get("id"),
                "ap_id": target.get("ap_id") or target.get("uri"),
                "actual_platform": target.get("platform"),
                "platform_family": target.get("platform_family"),
                "target_kind": target.get("target_kind") or target.get("source_kind"),
                "capabilities": target.get("capabilities") or [],
            }
        )

        relationship = ensure_following(client, candidate, target)
        row["followed"] = bool(
            relationship.get("member")
            or relationship.get("following")
            or relationship.get("requested")
            or relationship.get("id")
        )
        row["relationship"] = relationship

        envelope = fetch_items(client, candidate, target, limit)
        items = normalized_items(envelope)
        statuses = [status for item in items if (status := status_from_item(item))]
        row["items_count"] = len(items)
        row["native_status_count"] = len(statuses)

        if isinstance(envelope, dict):
            row["total_items"] = envelope.get("total_items") or envelope.get("totalItems")
            row["preview_warning"] = envelope.get("preview_warning")

        if items:
            first = items[0]
            row["first_item"] = {
                "id": first.get("id"),
                "type": first.get("type"),
                "title": first.get("title") or first.get("name"),
                "url": first.get("url"),
                "comments_count": first.get("comments_count") or first.get("commentsCount"),
            }

        if statuses:
            first_status = statuses[0]
            row["actionable"] = True
            row["first_status"] = {
                "id": first_status.get("id"),
                "uri": first_status.get("uri"),
                "url": first_status.get("url"),
                "account": (first_status.get("account") or {}).get("acct"),
                "favourited": first_status.get("favourited"),
                "reblogged": first_status.get("reblogged"),
                "replies_count": first_status.get("replies_count"),
            }
            row["actions"] = perform_status_actions(
                client,
                candidate,
                first_status,
                enable_actions,
                enable_replies,
            )

        row["ok"] = row["resolved"] and row["followed"] and row["items_count"] > 0
    except Exception as exc:
        row["error"] = str(exc)
        row["traceback"] = traceback.format_exc()

    row["elapsed_ms"] = int((time.monotonic() - started) * 1000)
    return row


def write_report(path: str, rows: list[dict[str, Any]]) -> None:
    summary = {
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "rows": rows,
        "totals": {
            "targets": len(rows),
            "resolved": sum(1 for row in rows if row.get("resolved")),
            "followed": sum(1 for row in rows if row.get("followed")),
            "with_items": sum(1 for row in rows if row.get("items_count", 0) > 0),
            "with_native_status": sum(1 for row in rows if row.get("native_status_count", 0) > 0),
            "ok": sum(1 for row in rows if row.get("ok")),
        },
    }

    with open(path, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")


def print_table(rows: list[dict[str, Any]]) -> None:
    print("lane platform resolved followed items native actionable elapsed_ms note")
    for row in rows:
        note = row.get("error") or row.get("preview_warning") or ""
        print(
            "{lane} {platform} {resolved} {followed} {items} {native} {actionable} {elapsed} {note}".format(
                lane=row.get("lane"),
                platform=row.get("expected_platform"),
                resolved="yes" if row.get("resolved") else "no",
                followed="yes" if row.get("followed") else "no",
                items=row.get("items_count", 0),
                native=row.get("native_status_count", 0),
                actionable="yes" if row.get("actionable") else "no",
                elapsed=row.get("elapsed_ms", 0),
                note=str(note).replace("\n", " ")[:120],
            )
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the live federation compatibility audit.")
    parser.add_argument("--base-url", default=os.environ.get("FEDERATION_AUDIT_BASE_URL", "https://social.fbxl.net"))
    parser.add_argument("--token", default=os.environ.get("FEDERATION_AUDIT_TOKEN", ""))
    parser.add_argument("--limit", type=int, default=int(os.environ.get("FEDERATION_AUDIT_LIMIT", "6")))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("FEDERATION_AUDIT_TIMEOUT", "45")))
    parser.add_argument("--only-lane", choices=["source", "group"], default=os.environ.get("FEDERATION_AUDIT_LANE"))
    parser.add_argument("--only-platform", default=os.environ.get("FEDERATION_AUDIT_PLATFORM"))
    parser.add_argument("--identifier", default=os.environ.get("FEDERATION_AUDIT_IDENTIFIER"))
    parser.add_argument("--label", default=os.environ.get("FEDERATION_AUDIT_LABEL", "Ad-hoc federation target"))
    parser.add_argument("--allow-reply", action="store_true", default=os.environ.get("FEDERATION_AUDIT_ALLOW_REPLY") == "1")
    parser.add_argument("--report", default=os.environ.get("FEDERATION_AUDIT_REPORT", "/tmp/unfathomably-live-federation-audit.json"))
    parser.add_argument("--actions", action="store_true", default=os.environ.get("FEDERATION_AUDIT_ACTIONS") == "1")
    parser.add_argument("--replies", action="store_true", default=os.environ.get("FEDERATION_AUDIT_REPLIES") == "1")
    parser.add_argument("--action-delay", type=float, default=float(os.environ.get("FEDERATION_AUDIT_ACTION_DELAY", "0")))
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not args.token:
        print("FEDERATION_AUDIT_TOKEN or --token is required", file=sys.stderr)
        return 2

    if args.identifier:
        if not args.only_lane or not args.only_platform:
            print("--identifier requires --only-lane and --only-platform", file=sys.stderr)
            return 2

        candidates = [
            Candidate(
                args.only_lane,
                args.only_platform,
                args.identifier,
                args.label,
                allow_reply=args.allow_reply,
            )
        ]
    else:
        candidates = SOURCE_CANDIDATES + GROUP_CANDIDATES

    if args.only_lane and not args.identifier:
        candidates = [candidate for candidate in candidates if candidate.lane == args.only_lane]

    if args.only_platform and not args.identifier:
        wanted = args.only_platform.lower()
        candidates = [
            candidate for candidate in candidates if candidate.platform.lower() == wanted
        ]

    client = ApiClient(args.base_url, args.token, args.timeout)
    rows = []

    for index, candidate in enumerate(candidates):
        print(f"checking {candidate.lane}:{candidate.platform} {candidate.identifier}", flush=True)
        rows.append(
            audit_candidate(
                client,
                candidate,
                args.limit,
                args.actions,
                args.replies,
            )
        )

        if args.actions and args.action_delay > 0 and index + 1 < len(candidates):
            time.sleep(args.action_delay)

    write_report(args.report, rows)
    print_table(rows)
    print(f"report={args.report}")

    failed = [row for row in rows if not row.get("ok")]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())


# end of live-federation-compat-audit.py

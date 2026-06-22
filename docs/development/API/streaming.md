<!--
  Project: Unfathomably BE / Pleroma-compatible API
  File: docs/development/API/streaming.md

  Purpose:
    Document the realtime streaming protocol used by clients and integration
    bridges.

  Responsibilities:
    Describe transports, authentication, stream naming, event envelopes, and
    the Unfathomably group/source stream extensions.

  This file intentionally does NOT contain:
    ActivityPub object schemas, OAuth registration policy, or frontend UI
    implementation details.
-->

# Streaming protocol

This document describes the realtime streaming protocol exposed at
`/api/v1/streaming`.

The protocol is compatible with the Mastodon streaming API where practical,
and adds Pleroma/Rebased/Unfathomably extensions for richer fediverse
interoperability. The important extension streams are `group` and `source`.
They allow clients and trusted integration bridges to subscribe directly to
ActivityPub groups and source actors without polling the timeline APIs.

Streaming is an optimization for realtime delivery. ActivityPub inbox delivery,
HTTP signatures, object fetching, and normal REST API reads remain the
canonical federation mechanisms. A remote platform can use this protocol to
mirror or preview live public activity, but it should not treat a WebSocket
event as a signed ActivityPub delivery.

## Endpoint

The base endpoint is:

```text
/api/v1/streaming
```

Clients may use either WebSocket or EventSource/SSE.

| Transport | Example URL | Notes |
| --- | --- | --- |
| WebSocket | `wss://social.example/api/v1/streaming` | Supports authentication after connect and client-sent subscribe/unsubscribe events. |
| EventSource | `https://social.example/api/v1/streaming` | Supports one stream selected by URL parameters. Browser EventSource cannot send subscribe/unsubscribe events. |

For WebSocket, the server upgrades the HTTP request when the client sends a
normal WebSocket upgrade request. If the request is not a WebSocket upgrade,
the endpoint behaves as an EventSource/SSE endpoint.

## Stream selection models

There are three ways to select a stream.

### Query style

Query style works for WebSocket and EventSource:

```text
/api/v1/streaming?stream=public
/api/v1/streaming?stream=list&list=123
/api/v1/streaming?stream=group&group=123
/api/v1/streaming?stream=source&source=123
```

Use query style when an identifier contains characters that are awkward in a
path segment, such as `/`, `?`, or `#`.

### Path style

Path style is convenient for common streams and compact identifiers:

```text
/api/v1/streaming/public
/api/v1/streaming/public/local
/api/v1/streaming/public/remote?instance=remote.example
/api/v1/streaming/hashtag?tag=3dprinting
/api/v1/streaming/hashtag/local?tag=3dprinting
/api/v1/streaming/list?list=123
/api/v1/streaming/group/123
/api/v1/streaming/source/123
/api/v1/streaming/user
/api/v1/streaming/user/notification
/api/v1/streaming/direct
```

Path style keeps access tokens out of the WebSocket URL when combined with
the `Sec-WebSocket-Protocol` authentication method.

### Unified WebSocket style

If a WebSocket connects to `/api/v1/streaming` with no `stream` parameter, it
starts with no subscriptions. The client can then authenticate and subscribe
to one or more streams on the same socket.

```json
{"type":"subscribe","stream":"public"}
{"type":"subscribe","stream":"group","group":"123"}
{"type":"subscribe","stream":"source","source":"123"}
```

This model is the best fit for frontends or integration bridges that need to
watch several groups, sources, or remote timelines at once.

## Authentication

Some streams are public, subject to instance configuration. User streams,
lists, direct messages, notifications, and any restricted public stream need a
valid OAuth access token.

### Query token

Query tokens work for WebSocket and EventSource:

```text
/api/v1/streaming/user?access_token=ACCESS_TOKEN
```

Prefer another method for WebSocket clients when possible, because query
strings are commonly stored in logs.

### WebSocket subprotocol token

WebSocket clients can send the OAuth token in `Sec-WebSocket-Protocol`:

```text
Sec-WebSocket-Protocol: ACCESS_TOKEN
```

This is useful for browser clients because JavaScript WebSocket constructors
can set subprotocols but cannot set arbitrary HTTP headers.

### Authenticate after connect

Unified WebSocket clients can authenticate after connection:

```json
{"type":"pleroma:authenticate","token":"ACCESS_TOKEN"}
```

The server replies with a `pleroma:respond` event.

## Client-sent events

WebSocket clients may send JSON objects to manage subscriptions.

| Type | Purpose |
| --- | --- |
| `pleroma:authenticate` | Attach an OAuth token to the current socket. |
| `subscribe` | Add a stream subscription. |
| `unsubscribe` | Remove a stream subscription. |

Unknown client-sent event types are ignored.

### `pleroma:authenticate`

```json
{"type":"pleroma:authenticate","token":"ACCESS_TOKEN"}
```

### `subscribe`

```json
{"type":"subscribe","stream":"public"}
{"type":"subscribe","stream":"list","list":"123"}
{"type":"subscribe","stream":"hashtag","tag":"3dprinting"}
{"type":"subscribe","stream":"public:remote","instance":"remote.example"}
{"type":"subscribe","stream":"group","group":"123"}
{"type":"subscribe","stream":"source","source":"123"}
```

### `unsubscribe`

```json
{"type":"unsubscribe","stream":"group","group":"123"}
{"type":"unsubscribe","stream":"source","source":"123"}
```

## Server replies to client-sent events

The server replies to recognized client-sent events with
`event: "pleroma:respond"`.

```json
{
  "event": "pleroma:respond",
  "payload": "{\"type\":\"subscribe\",\"result\":\"success\"}"
}
```

The `payload` field is a JSON-encoded string. Parse it as JSON after parsing
the outer event object.

| Payload field | Meaning |
| --- | --- |
| `type` | The client event type being answered. |
| `result` | `success`, `ignored`, or `error`. |
| `error` | Present only when `result` is `error`. |

Common error values are:

| Error | Meaning |
| --- | --- |
| `bad_topic` | The stream name or stream parameters are invalid. |
| `unauthorized` | The current socket is not allowed to access the stream. |

## Server-sent event envelope

Every server-sent message is a JSON object with an `event` field. Most
messages also include a `payload` string and a `stream` array.

```json
{
  "event": "update",
  "payload": "{\"id\":\"109000000000000001\",\"content\":\"...\"}",
  "stream": ["group", "123"]
}
```

The `payload` field is usually a JSON-encoded string. Parse the outer message
first, then parse `payload` according to the `event` type.

The `stream` field helps clients route one WebSocket connection to multiple
timeline surfaces. It is omitted for `pleroma:respond` and may be absent for
some delete events.

## Common server-sent events

| Event | Payload |
| --- | --- |
| `update` | A status object. |
| `status.update` | A status object after edit/update. |
| `delete` | The deleted status id. |
| `notification` | A notification object. |
| `conversation` | A conversation object. |
| `announcement` | An announcement object. |
| `announcement.reaction` | Announcement reaction details. |
| `announcement.delete` | Deleted announcement id or details. |
| `filters_changed` | Empty or implementation-specific payload; clients should refetch filters. |
| `pleroma:chat_update` | Updated chat object. |
| `pleroma:follow_relationships_update` | Follow relationship transition details. |
| `pleroma:respond` | Response to a client-sent control event. |

Clients should ignore unknown events they do not understand. This allows new
event types to be added without breaking older clients.

## Stream names

| Stream | Parameters | Access |
| --- | --- | --- |
| `public` | None | Public or restricted by instance policy. |
| `public:media` | None | Public media timeline or restricted by instance policy. |
| `public:local` | None | Local public timeline or restricted by instance policy. |
| `public:local:media` | None | Local public media timeline or restricted by instance policy. |
| `public:remote` | `instance` | Public timeline for one remote host or restricted by instance policy. |
| `public:remote:media` | `instance` | Public media timeline for one remote host or restricted by instance policy. |
| `hashtag` | `tag` | Public hashtag timeline. |
| `hashtag:local` | `tag` | Local public hashtag timeline. |
| `user` | None | Authenticated user home stream. |
| `user:notification` | None | Authenticated user notification stream. |
| `user:pleroma_chat` | None | Authenticated Pleroma chat stream. |
| `direct` | None | Authenticated direct-message stream. |
| `list` | `list` | Authenticated list stream owned by the user. |
| `group` | `group` | Public/local activity addressed to a resolved group. |
| `source` | `source` | Public/local activity by a resolved source actor. |

The `group` and `source` parameters may be a local API id or another
identifier accepted by the server resolver, such as a known ActivityPub id.
When the identifier contains slashes, use query style or unified subscribe
style rather than path style.

For safety, group and source identifiers are validated before resolver work.
Blank identifiers, invalid UTF-8, NUL bytes, and identifiers larger than 2048
bytes are rejected as `bad_topic`.

## Stream arrays

Server-sent events use the `stream` array to identify the logical stream that
produced the event.

| Stream array | Meaning |
| --- | --- |
| `["public"]` | Federated public timeline. |
| `["public:local"]` | Local public timeline. |
| `["public:remote", "remote.example"]` | Public timeline from `remote.example`. |
| `["hashtag", "3dprinting"]` | Public hashtag stream for `#3dprinting`. |
| `["list", "123"]` | List stream for list `123`. |
| `["group", "123"]` | Group stream for group `123`. |
| `["source", "123"]` | Source stream for source actor `123`. |
| `["user"]` | Authenticated home stream. |
| `["user:notification"]` | Authenticated notification stream. |
| `["direct"]` | Authenticated direct-message stream. |

Clients should not infer authorization from the `stream` array. Authorization
is decided when the subscription is created.

## Group streams

Group streams are for ActivityPub group and community actors.

Query style:

```text
/api/v1/streaming?stream=group&group=123
```

Path style:

```text
/api/v1/streaming/group/123
```

Unified subscribe style:

```json
{"type":"subscribe","stream":"group","group":"123"}
```

The server resolves the `group` parameter to a known group actor. Public or
local activities addressed to that group are published on `group:<id>`.

Closed-group and private activity must not be exposed through unauthenticated
group streams. If a future implementation adds member-only group streaming,
it should perform membership checks during subscribe and again while rendering
events for the socket.

## Source streams

Source streams are for remote actors that are best presented as native feeds,
for example music channels, blogs, video channels, event feeds, and other
ActivityPub publishers.

Query style:

```text
/api/v1/streaming?stream=source&source=123
```

Path style:

```text
/api/v1/streaming/source/123
```

Unified subscribe style:

```json
{"type":"subscribe","stream":"source","source":"123"}
```

The server resolves the `source` parameter to a known source actor. Public or
local activities where that actor is the activity actor are published on
`source:<id>`.

Source streams are intended to reduce polling for source preview and native
feed surfaces. Clients should still use the REST source-items API after
reconnect to fill gaps.

## Cross-instance bridge profile

A remote platform can use this protocol as a realtime bridge when it wants to
show live public activity from an Unfathomably/Pleroma-compatible instance.

Recommended bridge behavior:

| Requirement | Reason |
| --- | --- |
| Use TLS WebSockets. | Protect OAuth tokens and event contents in transit. |
| Use a service account OAuth token when authentication is needed. | Avoid tying bridge uptime to a human session. |
| Prefer unified WebSocket subscriptions for many groups or sources. | One socket is cheaper than many independent sockets. |
| Backfill with REST APIs after reconnect. | WebSocket delivery is realtime but not a durable queue. |
| Dedupe by status id and event type. | Reconnects and overlapping streams can deliver the same status more than once. |
| Treat WebSocket events as hints, not signed federation. | ActivityPub fetch/signature validation remains the trust boundary. |
| Ignore unknown event types and unknown payload fields. | The protocol is designed to grow. |

Good bridge subscription examples:

```json
{"type":"subscribe","stream":"public:remote","instance":"video.example"}
{"type":"subscribe","stream":"group","group":"https://groups.example/c/printing"}
{"type":"subscribe","stream":"source","source":"https://audio.example/channels/library"}
```

For cross-instance use, the bridge should verify or refetch ActivityPub objects
before using them for moderation, permanent storage, or onward federation.
The streaming event can wake the bridge up quickly; it should not replace the
normal ActivityPub trust model.

## Reconnect and gap handling

The streaming endpoint is not a persistent message queue. If the socket drops,
events that occurred while the client was disconnected may be missed.

Clients should:

| Behavior | Recommendation |
| --- | --- |
| Reconnect delay | Use exponential backoff with jitter. |
| Gap fill | Fetch the relevant REST timeline, group, source, or notification endpoint after reconnect. |
| Duplicate handling | Dedupe by object id/status id. |
| Delete handling | Apply deletes even if the original status is not present locally. |
| Edit handling | Treat `status.update` as replacing the local copy of the status. |

## Privacy and safety rules

Implementations should keep these boundaries:

| Rule | Explanation |
| --- | --- |
| Do not publish private activity to public group/source streams. | A group/source subscription can be anonymous on instances that allow public timelines. |
| Check authorization at subscribe time. | A socket may authenticate after connect, so stream access must be decided when the subscription is added. |
| Bound identifiers before resolver work. | Public WebSocket endpoints should reject oversized or malformed group/source identifiers before doing database or network work. |
| Filter per receiving user before rendering. | Blocks, mutes, domain restrictions, and visibility rules can differ per socket. |
| Keep access tokens out of logs. | Prefer subprotocol authentication for WebSocket clients. |
| Do not accept posts, likes, follows, or moderation actions over this protocol. | Writes belong to the REST API or ActivityPub inbox/outbox flows. |

## Compatibility notes

Mastodon-compatible clients can continue using standard streams and standard
event names. Clients that do not understand `group` or `source` should ignore
those streams.

The `group` and `source` streams are Unfathomably/Rebased extensions. They are
designed to be easy for Lemmy-like groups, Lotide-like groups, media channels,
blogs, and other ActivityPub source actors to consume later, but they do not
require those platforms to implement this protocol for normal federation to
work.

<!-- end of docs/development/API/streaming.md -->

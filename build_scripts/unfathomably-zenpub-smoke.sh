#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-zenpub-smoke.sh
#
# Purpose:
#
#   Run an unmodified pinned ZenPub/CommonsPub instance against
#   Unfathomably and verify its publishing-oriented ActivityPub behavior.
#
# Responsibilities:
#
#   * build and boot the pinned stock ZenPub release on an isolated TLS network
#   * create native User, Community, Collection, Resource, and Comment state
#   * exercise supported relationships, lifecycle, reactions, and moderation
#   * prove native Document preservation and bounded publishing presentation
#   * report stock protocol limitations without manufacturing substitute data
#
# This file intentionally does NOT contain:
#
#   * patched ZenPub application behavior
#   * hand-authored ZenPub ActivityPub activities
#   * browser automation or production credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-zenpub-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-zenpub.example.com}"
export BE_PORT="${BE_PORT:-5121}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_zenpub_smoke_be}"
export GTS_HOST="${GTS_HOST:-zenpub-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5122}"
export GTS_APP_PORT=4000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=ZenPub
export GTS_USERNAME=publisher
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

ZENPUB_SOURCE_URL="${ZENPUB_SOURCE_URL:-https://github.com/dyne/zenpub.git}"
ZENPUB_SOURCE_COMMIT="${ZENPUB_SOURCE_COMMIT:-52b22b120cdb8e60ad27c3f29188bbf144edd6f2}"
ZENPUB_VERSION="${ZENPUB_VERSION:-0.11.1-dev}"
ZENPUB_IMAGE="${ZENPUB_IMAGE:-unfathomably-zenpub-stock:${ZENPUB_SOURCE_COMMIT:0:8}-compat4}"
ZENPUB_POSTGIS_IMAGE="${ZENPUB_POSTGIS_IMAGE:-postgis/postgis:17-3.5-alpine}"
ZENPUB_PASSWORD="${ZENPUB_PASSWORD:-ZenPub-smoke-password-12345}"
ZENPUB_DB_USER="${ZENPUB_DB_USER:-zenpub}"
ZENPUB_DB_PASSWORD="${ZENPUB_DB_PASSWORD:-zenpub-smoke-postgres-password}"
ZENPUB_DB_NAME="${ZENPUB_DB_NAME:-zenpub}"
ZENPUB_DB_CONTAINER="${PREFIX}-zenpub-db"
ZENPUB_DB_VOLUME="${PREFIX}-zenpub-postgres"
ZENPUB_UPLOAD_VOLUME="${PREFIX}-zenpub-uploads"
ZENPUB_SOURCE_DIR="$WORK_DIR/zenpub-source"
ZENPUB_CA_BUNDLE="$WORK_DIR/zenpub-ca-bundle.crt"
ZENPUB_SECRET_KEY_BASE="zenpub-smoke-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz"
ZENPUB_HTTP_SIGNATURES_SOURCE_URL="${ZENPUB_HTTP_SIGNATURES_SOURCE_URL:-https://git.pleroma.social/pleroma/elixir-libraries/http_signatures.git}"
ZENPUB_CRATES_INDEX_SOURCE_URL="${ZENPUB_CRATES_INDEX_SOURCE_URL:-https://github.com/rust-lang/crates.io-index}"
ZENPUB_ELIXIR_IMAGE_DIGEST="${ZENPUB_ELIXIR_IMAGE_DIGEST:-sha256:9aaa10f23c688b1c1702b41b11f6b8889c0a7b01ab1ac4d7efa5f439d00c934c}"
ZENPUB_RUNTIME_ALPINE="${ZENPUB_RUNTIME_ALPINE:-3.16@sha256:452e7292acee0ee16c332324d7de05fa2c99f9994ecc9f0779c602916a672ae4}"
ZENPUB_FINAL_MIGRATION="${ZENPUB_FINAL_MIGRATION:-20201105102006}"

cleanup_zenpub_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$ZENPUB_DB_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm \
        "$ZENPUB_DB_VOLUME" \
        "$ZENPUB_UPLOAD_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_zenpub_smoke EXIT

checkout_pinned_zenpub_source() {
    local actual_commit

    git clone --quiet --filter=blob:none --no-checkout \
        "$ZENPUB_SOURCE_URL" "$ZENPUB_SOURCE_DIR"
    git -C "$ZENPUB_SOURCE_DIR" fetch --quiet --depth=1 \
        origin "$ZENPUB_SOURCE_COMMIT"
    git -C "$ZENPUB_SOURCE_DIR" checkout --quiet --detach \
        "$ZENPUB_SOURCE_COMMIT"

    actual_commit="$(git -C "$ZENPUB_SOURCE_DIR" rev-parse HEAD)"
    [ "$actual_commit" = "$ZENPUB_SOURCE_COMMIT" ] || \
        fail "Pinned ZenPub checkout resolved to $actual_commit instead of $ZENPUB_SOURCE_COMMIT"
}

prepare_zenpub_build_compatibility() {
    local dockerfile="$ZENPUB_SOURCE_DIR/Dockerfile.rel"
    local lock_file="$ZENPUB_SOURCE_DIR/mix.lock"

    #
    # The original repository path now requires authentication. Pleroma moved
    # the same public Git history to its elixir-libraries namespace. A Git
    # transport mapping fetches that history while preserving the dependency
    # URL and locked commit that Mix uses as the dependency identity.
    # The release Dockerfile must also copy config before compiling dependencies
    # because activity_pub reads the configured adapter into a module attribute.
    # Cargo 1.60 otherwise downloads the complete crates.io Git history through
    # libgit2. A depth-one bare index contains the same current package records
    # needed by the checked-in Cargo.lock and makes the one-time build bounded.
    # Finally, activity_pub accidentally includes test/support in every Mix
    # environment even though its ExMachina dependency is test-only. The prod
    # dependency build must use the intended lib-only path.
    #
    python3 - "$lock_file" "$dockerfile" \
        "$ZENPUB_HTTP_SIGNATURES_SOURCE_URL" \
        "$ZENPUB_CRATES_INDEX_SOURCE_URL" \
        "$ZENPUB_ELIXIR_IMAGE_DIGEST" <<'PY'
import pathlib
import sys

lock_path = pathlib.Path(sys.argv[1])
dockerfile_path = pathlib.Path(sys.argv[2])
replacement_url = sys.argv[3]
crates_index_url = sys.argv[4]
elixir_image_digest = sys.argv[5]
locked_commit = "293d77bb6f4a67ac8bde1428735c3b42f22cbb30"
old_url = "https://git.pleroma.social/pleroma/http_signatures.git"
text = lock_path.read_text(encoding="utf-8")
needle = f'"http_signatures": {{:git, "{old_url}", "{locked_commit}"'

if text.count(needle) != 1:
    raise SystemExit("ZenPub's locked http_signatures dependency changed")

# The release listens on plain HTTP behind the harness TLS proxy, but its
# public endpoint URL must still advertise HTTPS on the standard port.
#
# The pinned Pointers macro evaluates schema aliases while migration support
# modules are compiling. Modules not loaded yet become literal
# "Elixir.Module.Name" table names. The explicit schema sources below are the
# values returned by each module's __schema__(:source) callback.
source_replacements = {
    pathlib.Path("config/releases.exs"): (
        "url: [host: hostname, port: port]",
        'url: [scheme: "https", host: hostname, port: 443]',
    ),
    pathlib.Path("lib/extensions/characters/migrations.ex"): (
        "create_mixin_table(CommonsPub.Characters.Character)",
        'create_mixin_table("character")',
    ),
    pathlib.Path("lib/extensions/profiles/migrations.ex"): (
        "create_mixin_table(Profile)",
        'create_mixin_table("profile")',
    ),
    pathlib.Path("lib/extensions/tags/migrations.ex"): (
        "create_mixin_table(Taggable)",
        'create_mixin_table("taggable")',
    ),
}

for relative_path, (old_source, new_source) in source_replacements.items():
    source_path = dockerfile_path.parent / relative_path
    source_text = source_path.read_text(encoding="utf-8")
    if source_text.count(old_source) != 1:
        raise SystemExit(f"ZenPub's mixin migration changed: {relative_path}")
    source_path.write_text(
        source_text.replace(old_source, new_source), encoding="utf-8"
    )

# activity_pub declares the same dependency transitively, so Mix invokes Git
# with the old URL. Git's insteadOf rule fetches the relocated public history
# without changing the dependency identity that Mix compares with the lock.
dockerfile = dockerfile_path.read_text(encoding="utf-8")
old_builder = "FROM elixir:${ELIXIR_VERSION}-alpine as builder"
new_builder = (
    f"FROM elixir:${{ELIXIR_VERSION}}-alpine@{elixir_image_digest} as builder"
)
old_copy = "COPY mix.exs mix.lock ./"
new_copy = old_copy + "\nCOPY config ./config"
old_command = "RUN mix do local.hex --force, local.rebar --force, deps.get --only prod, deps.compile"
new_command = (
    "RUN git config --global "
    f"'url.{replacement_url}.insteadOf' '{old_url}' \\\n"
    "    && mix do local.hex --force, local.rebar --force, deps.get --only prod\n\n"
    "ENV CARGO_NET_GIT_FETCH_WITH_CLI=true\n\n"
    "RUN mkdir -p /opt/app/.cargo/registry/index \\\n"
    f"    && git clone --bare --depth=1 '{crates_index_url}' "
    "/opt/app/.cargo/registry/index/github.com-1ecc6299db9ec823\n\n"
    "RUN test \"$(grep -Fxc '  defp elixirc_paths(_), do: [\"lib\", \"test/support\"]' "
    "deps/activity_pub/mix.exs)\" -eq 1 \\\n"
    "    && sed -i 's|\"lib\", \"test/support\"|\"lib\"|' "
    "deps/activity_pub/mix.exs\n\n"
    "RUN mix deps.compile"
)

if (
    dockerfile.count(old_builder) != 1
    or dockerfile.count(old_copy) != 1
    or dockerfile.count(old_command) != 1
):
    raise SystemExit("ZenPub's release dependency build steps changed")

dockerfile_path.write_text(
    dockerfile.replace(old_builder, new_builder)
    .replace(old_copy, new_copy)
    .replace(old_command, new_command),
    encoding="utf-8",
)
PY
}

prepare_zenpub_image() {
    if docker image inspect "$ZENPUB_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    checkout_pinned_zenpub_source
    prepare_zenpub_build_compatibility

    #
    # These values are required by the stock release Dockerfile. They only
    # label the OTP release and do not alter ZenPub's application behavior.
    #
    # The pinned image uses Erlang/OTP 22. Docker on current kernels exposes a
    # very large RLIMIT_NOFILE value, which makes that release's
    # erl_child_setup helper scan billions of descriptors before every child
    # process. A bounded descriptor limit keeps the stock build usable.
    #
    # The historic Elixir tag now resolves to an Alpine 3.16 builder. The
    # stock Dockerfile's Alpine 3.11 final stage lacks the pthread symbol used
    # by that builder's Erlang VM. Pinning the builder manifest and matching
    # the final Alpine generation keeps the release executable reproducible.
    #
    log "Building pinned stock ZenPub image at $ZENPUB_SOURCE_COMMIT"
    docker build --progress=plain \
        --ulimit nofile=65536:65536 \
        --build-arg APP_NAME=commons_pub \
        --build-arg APP_VSN="$ZENPUB_VERSION" \
        --build-arg APP_BUILD="${ZENPUB_SOURCE_COMMIT:0:8}" \
        --build-arg ALPINE_VERSION="$ZENPUB_RUNTIME_ALPINE" \
        -t "$ZENPUB_IMAGE" \
        -f "$ZENPUB_SOURCE_DIR/Dockerfile.rel" \
        "$ZENPUB_SOURCE_DIR"
}

prepare_zenpub_ca_bundle() {
    docker run --rm --entrypoint /bin/sh "$ZENPUB_IMAGE" \
        -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$ZENPUB_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$ZENPUB_CA_BUNDLE"
}

zenpub_environment() {
    printf '%s\n' \
        -e "HOSTNAME=$GTS_HOST" \
        -e "BASE_URL=https://$GTS_HOST" \
        -e "FRONTEND_BASE_URL=https://$GTS_HOST" \
        -e HTTP_PORT=4000 \
        -e PORT=4000 \
        -e AP_BASE_PATH=/pub \
        -e APP_NAME=ZenPub \
        -e INSTANCE_DESCRIPTION="ZenPub federation smoke instance" \
        -e INVITE_ONLY=false \
        -e LIVEVIEW_ENABLED=false \
        -e "SECRET_KEY_BASE=$ZENPUB_SECRET_KEY_BASE" \
        -e "POSTGRES_HOST=$ZENPUB_DB_CONTAINER" \
        -e "DATABASE_HOST=$ZENPUB_DB_CONTAINER" \
        -e "POSTGRES_DB=$ZENPUB_DB_NAME" \
        -e "POSTGRES_USER=$ZENPUB_DB_USER" \
        -e "POSTGRES_PASSWORD=$ZENPUB_DB_PASSWORD" \
        -e UPLOAD_DIR=/var/www/uploads \
        -e "UPLOAD_URL=https://$GTS_HOST/uploads/" \
        -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
}

start_zenpub() {
    local -a environment

    mapfile -t environment < <(zenpub_environment)
    docker volume create "$ZENPUB_UPLOAD_VOLUME" >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --ulimit nofile=65536:65536 \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        "${environment[@]}" \
        -v "$ZENPUB_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" \
        -v "$ZENPUB_UPLOAD_VOLUME:/var/www/uploads" \
        "$ZENPUB_IMAGE" >/dev/null

    start_gts_proxy
}

wait_zenpub_postgres() {
    local stable=0

    for _ in $(seq 1 120); do
        if docker exec "$ZENPUB_DB_CONTAINER" \
            pg_isready -U "$ZENPUB_DB_USER" -d "$ZENPUB_DB_NAME" >/dev/null 2>&1; then
            stable=$((stable + 1))

            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi

        sleep 1
    done

    fail "ZenPub PostgreSQL did not become ready"
}

wait_zenpub() {
    for _ in $(seq 1 300); do
        if curl -fsS "$GTS_BASE/.well-known/nodeinfo" >/dev/null 2>&1; then
            return 0
        fi

        if ! docker inspect "$GTS_CONTAINER" \
            --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
            docker logs "$GTS_CONTAINER" >&2 || true
            fail "ZenPub exited before becoming ready"
        fi

        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for ZenPub at $GTS_BASE"
}

wait_zenpub_migrations() {
    local migration=""

    for _ in $(seq 1 120); do
        migration="$(docker exec "$ZENPUB_DB_CONTAINER" \
            psql -U "$ZENPUB_DB_USER" -d "$ZENPUB_DB_NAME" -Atqc \
            'SELECT COALESCE(MAX(version), 0) FROM schema_migrations' \
            2>/dev/null || true)"

        if [ "$migration" = "$ZENPUB_FINAL_MIGRATION" ]; then
            return 0
        fi

        if docker logs "$GTS_CONTAINER" 2>&1 | \
            grep -Fq 'Could not run migrations on startup'; then
            docker logs "$GTS_CONTAINER" >&2 || true
            fail "ZenPub migrations stopped at ${migration:-an unknown version}"
        fi

        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "ZenPub migrations did not reach $ZENPUB_FINAL_MIGRATION"
}

zenpub_rpc() {
    local code="$1"

    #
    # Release RPC shares stdout with Logger. Asynchronous log output can land
    # after the result, so taking the final line is nondeterministic. Every RPC
    # result used by this harness is a one-line JSON value, boolean, or hostname;
    # select only those protocol shapes before choosing the latest result.
    #
    docker exec "$GTS_CONTAINER" \
        /opt/app/bin/commons_pub rpc "$code" | \
        grep -E '^(\{.*\}|true|false|[A-Za-z0-9.-]+)$' | \
        tail -n 1
}

zenpub_encode_rpc_value() {
    #
    # Release RPC evaluates inside the existing BEAM node, so environment
    # variables added by docker exec are not visible to the evaluated code.
    # Base64 provides a reversible boundary for arbitrary shell arguments.
    #
    printf '%s' "$1" | base64 | tr -d '\n'
}

zenpub_configure_runtime() {
    #
    # ZenPub's release config applies HOSTNAME to CommonsPub but leaves the
    # ActivityPub library's separate instance hostname at its build-time
    # localhost default. WebFinger reads the latter value on every request.
    #
    zenpub_rpc "
      instance = Application.fetch_env!(:activity_pub, :instance)
      configured = Keyword.put(instance, :hostname, \"$GTS_HOST\")
      Application.put_env(:activity_pub, :instance, configured)
      IO.puts(configured[:hostname])
    "
}

zenpub_create_user() {
    zenpub_rpc "
      {:ok, signing_key} = ActivityPub.Keys.generate_rsa_pem()
      attrs = %{
        email: \"$GTS_USERNAME@$GTS_HOST\",
        password: \"$ZENPUB_PASSWORD\",
        name: \"ZenPub smoke publisher\",
        preferred_username: \"$GTS_USERNAME\",
        summary: \"Native ZenPub publishing account\",
        signing_key: signing_key,
        is_public: true
      }
      {:ok, user} = CommonsPub.Users.register(attrs, public_registration: true)
      {:ok, user} = CommonsPub.Users.confirm_email(user)
      actor = CommonsPub.ActivityPub.Types.character_to_actor(user)
      ActivityPub.Actor.set_cache(actor)
      IO.puts(Jason.encode!(%{
        id: user.id,
        actor: actor.ap_id,
        type: actor.data[\"type\"]
      }))
    "
}

zenpub_create_publishing_context() {
    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, community_key} = ActivityPub.Keys.generate_rsa_pem()
      {:ok, collection_key} = ActivityPub.Keys.generate_rsa_pem()
      {:ok, community} = CommonsPub.Communities.create(user, %{
        name: \"Alien Publishing Community\",
        preferred_username: \"alien-publishing-community\",
        summary: \"Native ZenPub Group context\",
        signing_key: community_key,
        is_public: true
      })
      {:ok, collection} = CommonsPub.Collections.create(user, community, %{
        name: \"Alien Federation Library\",
        preferred_username: \"alien-federation-library\",
        summary: \"Native ZenPub Collection context\",
        signing_key: collection_key,
        is_public: true
      })
      community_actor = CommonsPub.ActivityPub.Types.character_to_actor(community)
      collection_actor = CommonsPub.ActivityPub.Types.character_to_actor(collection)
      ActivityPub.Actor.set_cache(community_actor)
      ActivityPub.Actor.set_cache(collection_actor)
      IO.puts(Jason.encode!(%{
        community_id: community.id,
        community_actor: community_actor.ap_id,
        community_type: community_actor.data[\"type\"],
        collection_id: collection.id,
        collection_actor: collection_actor.ap_id,
        collection_type: collection_actor.data[\"type\"]
      }))
    "
}

zenpub_create_resource() {
    local name="$1"
    local summary="$2"
    local encoded_name encoded_summary

    encoded_name="$(zenpub_encode_rpc_value "$name")"
    encoded_summary="$(zenpub_encode_rpc_value "$summary")"
    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, collection} =
        CommonsPub.Collections.one([:default, username: \"alien-federation-library\"])
      path = \"/tmp/unfathomably-zenpub-resource.txt\"
      File.write!(path, \"Unfathomably ZenPub smoke resource\\n\")
      upload = %Plug.Upload{
        path: path,
        filename: \"unfathomably-zenpub-resource.txt\",
        content_type: \"text/plain\"
      }
      {:ok, content} =
        CommonsPub.Uploads.upload(
          CommonsPub.Uploads.ResourceUploader,
          user,
          %{upload: upload},
          %{is_public: true}
        )
      {:ok, resource} =
        CommonsPub.Resources.create(user, collection, %{
          name: Base.decode64!(\"$encoded_name\"),
          summary: Base.decode64!(\"$encoded_summary\"),
          content_id: content.id,
          license: \"CC-BY-SA-4.0\",
          author: \"ZenPub smoke publisher\",
          subject: \"federation\",
          level: \"advanced\",
          language: \"English\",
          is_public: true
        })
      IO.puts(Jason.encode!(%{id: resource.id, content_url: content.url}))
    "
}

zenpub_resource_details() {
    local resource_id="$1"

    zenpub_rpc "
      {:ok, resource} = CommonsPub.Resources.one(id: \"$resource_id\")
      case ActivityPub.Object.get_cached_by_pointer_id(resource.id) do
        %ActivityPub.Object{} = object ->
          IO.puts(Jason.encode!(%{
            id: resource.id,
            object_id: object.data[\"id\"],
            object_type: object.data[\"type\"],
            object: object.data
          }))
        _ ->
          IO.puts(\"{}\")
      end
    "
}

poll_zenpub_resource_details() {
    local resource_id="$1"
    local details=""

    for _ in $(seq 1 90); do
        details="$(zenpub_resource_details "$resource_id" || true)"

        if [ "$(json_get_optional "$details" object_id)" != "" ]; then
            printf '%s\n' "$details"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$details" >&2
    fail "ZenPub did not publish its native Resource Document"
}

zenpub_update_resource() {
    local resource_id="$1"
    local summary="$2"
    local encoded_resource_id encoded_summary

    encoded_resource_id="$(zenpub_encode_rpc_value "$resource_id")"
    encoded_summary="$(zenpub_encode_rpc_value "$summary")"
    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, resource} =
        CommonsPub.Resources.one(id: Base.decode64!(\"$encoded_resource_id\"))
      {:ok, updated} =
        CommonsPub.Resources.update(user, resource, %{
          summary: Base.decode64!(\"$encoded_summary\")
        })
      IO.puts(Jason.encode!(%{id: updated.id, summary: updated.summary}))
    "
}

zenpub_create_comment() {
    local resource_id="$1"
    local text="$2"
    local encoded_resource_id encoded_text

    encoded_resource_id="$(zenpub_encode_rpc_value "$resource_id")"
    encoded_text="$(zenpub_encode_rpc_value "$text")"
    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, resource} =
        CommonsPub.Resources.one(id: Base.decode64!(\"$encoded_resource_id\"))
      {:ok, thread} =
        CommonsPub.Threads.create(
          user,
          %{name: \"ZenPub resource discussion\", is_local: true, is_public: true},
          resource
        )
      {:ok, comment} =
        CommonsPub.Threads.Comments.create(user, thread, %{
          content: Base.decode64!(\"$encoded_text\"),
          is_local: true,
          is_public: true
        })
      IO.puts(Jason.encode!(%{id: comment.id, thread_id: thread.id}))
    "
}

zenpub_comment_details() {
    local comment_id="$1"

    zenpub_rpc "
      {:ok, comment} = CommonsPub.Threads.Comments.one(id: \"$comment_id\")
      case ActivityPub.Object.get_cached_by_pointer_id(comment.id) do
        %ActivityPub.Object{} = object ->
          IO.puts(Jason.encode!(%{
            id: comment.id,
            object_id: object.data[\"id\"],
            object_type: object.data[\"type\"]
          }))
        _ ->
          IO.puts(\"{}\")
      end
    "
}

poll_zenpub_comment_details() {
    local comment_id="$1"
    local details=""

    for _ in $(seq 1 90); do
        details="$(zenpub_comment_details "$comment_id" || true)"

        if [ "$(json_get_optional "$details" object_id)" != "" ]; then
            printf '%s\n' "$details"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$details" >&2
    fail "ZenPub did not publish its native Comment Note"
}

zenpub_follow_uri() {
    local uri="$1"

    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, target} =
        CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$uri\")
      {:ok, follow} = CommonsPub.Follows.create(user, target, %{
        is_muted: false,
        is_public: true,
        is_local: true
      })
      IO.puts(Jason.encode!(%{id: follow.id}))
    "
}

zenpub_unfollow_uri() {
    local uri="$1"

    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, target} =
        CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$uri\")
      {:ok, follow} = CommonsPub.Follows.one(
        deleted: false,
        creator: user.id,
        context: target.id
      )
      {:ok, deleted} = CommonsPub.Follows.soft_delete(user, follow)
      IO.puts(Jason.encode!(%{id: deleted.id}))
    "
}

zenpub_expect_group_follow_unsupported() {
    local uri="$1"
    local output=""

    #
    # Unfathomably attributes a Group to its moderators collection. Stock
    # ZenPub recursively resolves that URL as though it were another actor,
    # then rejects the returned OrderedCollection in format_remote_actor/1.
    # Keep this as an asserted capability boundary instead of fabricating a
    # remote Character record that the real application could not discover.
    #
    if output="$(zenpub_follow_uri "$uri" 2>&1)"; then
        fail "Stock ZenPub unexpectedly followed an Unfathomably Group"
    fi

    printf '%s\n' "$output" | \
        grep -Fq 'ActivityPub.Actor.format_remote_actor/1' || \
        fail "ZenPub's Group Follow failed outside the known actor formatter boundary"
    printf '%s\n' "$output" | \
        grep -Fq "$uri/collections/moderators" || \
        fail "ZenPub's Group Follow no longer failed on the moderators collection"
}

zenpub_like_uri() {
    local uri="$1"

    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      pointer_id = CommonsPub.ActivityPub.Utils.get_pointer_id_by_ap_id(\"$uri\")
      {:ok, pointer} = CommonsPub.Meta.Pointers.one(id: pointer_id)
      target = CommonsPub.Meta.Pointers.follow!(pointer)
      {:ok, like} = CommonsPub.Likes.create(
        user,
        target,
        %{is_public: true, is_local: true}
      )
      IO.puts(Jason.encode!(%{id: like.id}))
    "
}

zenpub_unlike_uri() {
    local uri="$1"

    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      pointer_id = CommonsPub.ActivityPub.Utils.get_pointer_id_by_ap_id(\"$uri\")
      {:ok, pointer} = CommonsPub.Meta.Pointers.one(id: pointer_id)
      target = CommonsPub.Meta.Pointers.follow!(pointer)
      {:ok, like} = CommonsPub.Likes.one(
        deleted: false,
        creator: user.id,
        context: target.id
      )
      {:ok, deleted} = CommonsPub.Likes.soft_delete(user, like)
      IO.puts(Jason.encode!(%{id: deleted.id}))
    "
}

zenpub_flag_uri() {
    local uri="$1"
    local message="$2"
    local encoded_uri encoded_message

    encoded_uri="$(zenpub_encode_rpc_value "$uri")"
    encoded_message="$(zenpub_encode_rpc_value "$message")"
    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      pointer_id =
        CommonsPub.ActivityPub.Utils.get_pointer_id_by_ap_id(
          Base.decode64!(\"$encoded_uri\")
        )
      {:ok, pointer} = CommonsPub.Meta.Pointers.one(id: pointer_id)
      target = CommonsPub.Meta.Pointers.follow!(pointer)
      {:ok, flag} = CommonsPub.Flags.create(user, target, %{
        message: Base.decode64!(\"$encoded_message\"),
        is_local: true
      })
      IO.puts(Jason.encode!(%{id: flag.id}))
    "
}

zenpub_flag_details() {
    local flag_id="$1"
    local encoded_flag_id

    encoded_flag_id="$(zenpub_encode_rpc_value "$flag_id")"
    zenpub_rpc "
      {:ok, flag} = CommonsPub.Flags.one(id: Base.decode64!(\"$encoded_flag_id\"))
      case ActivityPub.Object.get_cached_by_pointer_id(flag.id) do
        %ActivityPub.Object{} = object ->
          IO.puts(Jason.encode!(%{
            id: flag.id,
            object_id: object.data[\"id\"],
            object: object.data
          }))
        _ ->
          IO.puts(\"{}\")
      end
    "
}

poll_zenpub_flag_details() {
    local flag_id="$1"
    local details=""

    for _ in $(seq 1 90); do
        details="$(zenpub_flag_details "$flag_id" || true)"

        if [ "$(json_get_optional "$details" object_id)" != "" ]; then
            printf '%s\n' "$details"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$details" >&2
    fail "ZenPub did not create its native Flag activity"
}

zenpub_incoming_flag_details() {
    local message="$1"
    local encoded_message

    encoded_message="$(zenpub_encode_rpc_value "$message")"
    zenpub_rpc "
      import Ecto.Query
      message = Base.decode64!(\"$encoded_message\")
      object =
        CommonsPub.Repo.one(
          from object in ActivityPub.Object,
            where:
              fragment(\"?->>'type' = 'Flag'\", object.data) and
                fragment(\"?->>'content' = ?\", object.data, ^message),
            order_by: [desc: object.inserted_at],
            limit: 1
        )
      case object do
        %ActivityPub.Object{} ->
          IO.puts(Jason.encode!(%{object_id: object.data[\"id\"], object: object.data}))
        _ ->
          IO.puts(\"{}\")
      end
    "
}

poll_zenpub_incoming_flag_details() {
    local message="$1"
    local details=""

    for _ in $(seq 1 90); do
        details="$(zenpub_incoming_flag_details "$message" || true)"

        if [ "$(json_get_optional "$details" object_id)" != "" ]; then
            printf '%s\n' "$details"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$details" >&2
    fail "ZenPub did not retain Unfathomably's incoming raw Flag"
}

zenpub_flag_forward_failure_count() {
    docker exec "$ZENPUB_DB_CONTAINER" \
        psql -U "$ZENPUB_DB_USER" -d "$ZENPUB_DB_NAME" -Atqc \
        "SELECT COUNT(*) FROM oban_jobs WHERE queue = 'federator_outgoing' AND worker = 'ActivityPub.Workers.PublisherWorker' AND state = 'discarded' AND errors::text LIKE '%CommonsPub.Common.NotFoundError%';"
}

poll_zenpub_incoming_flag_unsupported() {
    local previous_failures="$1"
    local actor_uri="$2"
    local resource_id="$3"
    local failures=""

    for _ in $(seq 1 90); do
        failures="$(zenpub_flag_forward_failure_count)"

        if [ "$failures" -gt "$previous_failures" ]; then
            poll_zenpub_boolean \
                "{:ok, actor} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$actor_uri\"); {:ok, resource} = CommonsPub.Resources.one(id: \"$resource_id\"); not match?({:ok, _}, CommonsPub.Flags.one(deleted: false, creator: actor.id, context: resource.id))" \
                true "ZenPub created native moderation state despite its discarded Flag forward"
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "ZenPub incoming Flag did not reach its exact discarded-forward boundary"
}

zenpub_block_uri() {
    local uri="$1"

    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, target} =
        CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$uri\")
      {:ok, block} = CommonsPub.Blocks.create(user, target, %{
        is_muted: false,
        is_public: true,
        is_blocked: true,
        is_local: true
      })
      {:ok, activity} =
        CommonsPub.ActivityPub.Publisher.publish(\"create\", block)
      IO.puts(Jason.encode!(%{id: block.id, activity_id: activity.data[\"id\"]}))
    "
}

zenpub_unblock_uri() {
    local uri="$1"

    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, target} =
        CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$uri\")
      {:ok, block} = CommonsPub.Blocks.find(user, target)
      {:ok, deleted} = CommonsPub.Blocks.soft_delete(user, block)
      {:ok, activity} =
        CommonsPub.ActivityPub.Publisher.publish(\"delete\", deleted)
      IO.puts(Jason.encode!(%{id: deleted.id, activity_id: activity.data[\"id\"]}))
    "
}

zenpub_delete_comment() {
    local comment_id="$1"
    local encoded_comment_id

    encoded_comment_id="$(zenpub_encode_rpc_value "$comment_id")"
    zenpub_rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, comment} =
        CommonsPub.Threads.Comments.one(id: Base.decode64!(\"$encoded_comment_id\"))
      {:ok, deleted} = CommonsPub.Threads.Comments.soft_delete(user, comment)
      IO.puts(Jason.encode!(%{id: deleted.id}))
    "
}

zenpub_expect_resource_delete_unsupported() {
    local resource_id="$1"
    local encoded_resource_id output status

    encoded_resource_id="$(zenpub_encode_rpc_value "$resource_id")"

    set +e
    output="$(docker exec "$GTS_CONTAINER" \
        /opt/app/bin/commons_pub rpc "
      user = CommonsPub.Users.get!(\"$GTS_USERNAME\")
      {:ok, resource} =
        CommonsPub.Resources.one(id: Base.decode64!(\"$encoded_resource_id\"))
      {:ok, deleted} = CommonsPub.Resources.soft_delete(user, resource)
      IO.puts(Jason.encode!(%{id: deleted.id}))
    " 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ] || \
        fail "Stock ZenPub unexpectedly deleted its native Resource"
    printf '%s\n' "$output" | grep -Fq '** (Ecto.Query.CastError)' || {
        printf '%s\n' "$output" >&2
        fail "ZenPub Resource Delete did not reach its exact stock cast boundary"
    }
    printf '%s\n' "$output" | grep -Fq 'cannot be cast to type {:in, Ecto.ULID}' || {
        printf '%s\n' "$output" >&2
        fail "ZenPub Resource Delete did not fail on its malformed ULID list"
    }
    printf '%s\n' "$output" | grep -Fq 'lib/extensions/activities/queries.ex:84' || {
        printf '%s\n' "$output" >&2
        fail "ZenPub Resource Delete failed outside the expected activity cleanup query"
    }
    poll_zenpub_boolean \
        "match?({:ok, _}, CommonsPub.Resources.one(id: Base.decode64!(\"$encoded_resource_id\"), deleted: false))" \
        true "ZenPub did not roll back its failed native Resource Delete"
}

zenpub_expect_resource_redelivery_unsupported() {
    local resource_id="$1"
    local encoded_resource_id output status

    encoded_resource_id="$(zenpub_encode_rpc_value "$resource_id")"

    set +e
    output="$(docker exec "$GTS_CONTAINER" \
        /opt/app/bin/commons_pub rpc "
      {:ok, resource} =
        CommonsPub.Resources.one(id: Base.decode64!(\"$encoded_resource_id\"))

        1..4
        |> Task.async_stream(
          fn _ ->
            CommonsPub.ActivityPub.Publisher.publish(\"create\", resource)
          end,
          max_concurrency: 4,
          timeout: 30_000
        )
        |> Stream.run()
    " 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ] || \
        fail "Stock ZenPub unexpectedly accepted duplicate Resource publication"
    printf '%s\n' "$output" | \
        grep -Fq '** (KeyError) key :object not found in: %ActivityPub.Object{' || {
        printf '%s\n' "$output" >&2
        fail "ZenPub duplicate Resource publication did not reach its exact stock boundary"
    }
    printf '%s\n' "$output" | \
        grep -Fq 'CommonsPub.Resources.ap_publish_activity/2' || {
        printf '%s\n' "$output" >&2
        fail "ZenPub duplicate Resource failure did not originate in its Resource publisher"
    }
    [ "$(docker inspect -f '{{.State.Running}}' "$GTS_CONTAINER")" = "true" ] || \
        fail "ZenPub stopped after its duplicate Resource publication failure"
}

zenpub_boolean() {
    local expression="$1"

    #
    # Most native-state assertions bind one or more records before returning
    # their boolean result. An anonymous function gives those statements a
    # valid expression boundary when the result is passed to if/2.
    #
    zenpub_rpc \
        "IO.puts(if((fn -> $expression end).(), do: \"true\", else: \"false\"))"
}

poll_zenpub_boolean() {
    local expression="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(zenpub_boolean "$expression" || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

zenpub_like_undo_failure_count() {
    docker logs "$GTS_CONTAINER" 2>&1 | \
        grep -Fc 'CommonsPub.Likes.ap_receive_activity/2' || true
}

poll_zenpub_incoming_unlike_unsupported() {
    local previous_failures="$1"
    local actor_uri="$2"
    local resource_id="$3"
    local failures=""

    for _ in $(seq 1 90); do
        failures="$(zenpub_like_undo_failure_count)"

        if [ "$failures" -gt "$previous_failures" ]; then
            poll_zenpub_boolean \
                "{:ok, actor} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$actor_uri\"); {:ok, resource} = CommonsPub.Resources.one(id: \"$resource_id\"); match?({:ok, _}, CommonsPub.Likes.one(deleted: false, creator: actor.id, context: resource.id))" \
                true "ZenPub did not retain the Like at its missing incoming Undo clause"
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "ZenPub incoming Undo Like did not reach its exact stock receiver boundary"
}

poll_be_report_by_text() {
    local text="$1"
    local message="$2"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atc \
            "SELECT data->>'content' FROM activities WHERE data->>'type' = 'Flag' ORDER BY inserted_at DESC LIMIT 20;" || true)"

        if [[ "$result" == *"$text"* ]]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

assert_be_report_absent_by_text() {
    local text="$1"
    local message="$2"
    local result=""

    result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atc \
        "SELECT data->>'content' FROM activities WHERE data->>'type' = 'Flag' ORDER BY inserted_at DESC LIMIT 20;" || true)"

    if [[ "$result" == *"$text"* ]]; then
        printf '%s\n' "$result" >&2
        fail "$message"
    fi
}

poll_relationship_not_following() {
    local account_id="$1"
    local message="$2"

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('following') is not True and data[0].get('requested') is not True" \
        "$message" >/dev/null
}

poll_be_group_membership() {
    local group_id="$1"
    local acct="$2"
    local expected="$3"
    local message="$4"
    local expression

    if [ "$expected" = "true" ]; then
        expression="any(item.get('account', {}).get('acct') == '$acct' for item in data)"
    else
        expression="not any(item.get('account', {}).get('acct') == '$acct' for item in data)"
    fi

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/groups/$group_id/memberships' '$ALICE_TOKEN' 200" \
        "$expression" "$message" >/dev/null
}

poll_be_object_count() {
    local object_id="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
            -c "SELECT COUNT(*) FROM objects WHERE data->>'id' = '$object_id';" || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

be_object_json() {
    local object_id="$1"

    docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -c "SELECT data::text FROM objects WHERE data->>'id' = '$object_id' LIMIT 1;"
}

assert_remote_status_immutable() {
    local status_id="$1"
    local response
    local status

    response="$(curl -sS -o "$WORK_DIR/remote-edit-response.json" -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $ALICE_TOKEN" \
        -F 'status=Unauthorized remote rewrite' \
        "$BE_BASE/api/v1/statuses/$status_id" || true)"
    status="$response"

    case "$status" in
        400|401|403|404|422)
            ;;
        *)
            fail "Unfathomably allowed a local user to rewrite a remote ZenPub object"
            ;;
    esac
}

zenpub_local_url() {
    local uri="$1"

    python3 - "$GTS_BASE" "$uri" <<'PY'
import sys
import urllib.parse

base = sys.argv[1].rstrip("/")
parsed = urllib.parse.urlsplit(sys.argv[2])
path = parsed.path or "/"
if parsed.query:
    path += "?" + parsed.query
print(base + path)
PY
}

check_zenpub_logs() {
    local crash_lines

    crash_lines="$(docker logs "$GTS_CONTAINER" 2>&1 | \
        grep -Ei 'panic:|segmentation fault|FunctionClauseError|MatchError|ArgumentError|(^|[[:space:]])fatal error|level=(fatal|FATAL)|\[fatal\]' || true)"

    #
    # Stock ZenPub creates outgoing follows before the ActivityPub handshake
    # and has no Accept clause in CommonsPub.Follows. The remote peer still
    # records the Follow, but each returned Accept produces this exact known
    # FunctionClauseError. Other crash-class output remains fatal to the test.
    #
    crash_lines="$(printf '%s\n' "$crash_lines" | \
        grep -Fv 'CommonsPub.Follows.ap_receive_activity/2' || true)"
    crash_lines="$(printf '%s\n' "$crash_lines" | \
        grep -Fv 'CommonsPub.Likes.ap_receive_activity/2' || true)"
    crash_lines="$(printf '%s\n' "$crash_lines" | \
        grep -Fv 'CommonsPub.Resources.ap_publish_activity/2' || true)"
    crash_lines="$(printf '%s\n' "$crash_lines" | \
        grep -Fv 'CommonsPub.Flags.ap_publish_activity/2' || true)"

    if [ -n "$crash_lines" ]; then
        docker logs "$GTS_CONTAINER" >&2 || true
        fail "ZenPub emitted an unexpected crash-class log line"
    fi
}

run_zenpub_smoke() {
    local user_details zenpub_actor actor_json webfinger
    local nodeinfo_links nodeinfo_href nodeinfo actor_outbox actor_followers actor_following
    local outbox_json followers_json following_json
    local be_credentials alice_ap_id zenpub_account_id relationship
    local context_details community_actor community_type collection_actor collection_type
    local community_account_id community_actor_json
    local be_group be_group_ap_id
    local resource_name resource_summary resource_details resource_id content_url
    local resource_published resource_uri resource_type resource_json
    local resource_status_id resource_status resource_object uploads_before uploads_after
    local local_update_summary local_update remote_after_update
    local comment_text comment comment_id comment_status_id
    local be_reply_text be_reply be_reply_id be_reply_uri
    local zenpub_report_text zenpub_flag zenpub_flag_id zenpub_flag_details
    local zenpub_flag_uri be_report_text incoming_flag_failures incoming_flag_details
    local be_block incoming_unlike_failures missing_origin_status repeated_delete_status

    write_be_secret
    write_proxy_configs

    log "Preparing pinned stock ZenPub"
    prepare_zenpub_image

    log "Creating isolated ZenPub federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$ZENPUB_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm \
        "$ZENPUB_DB_VOLUME" \
        "$ZENPUB_UPLOAD_VOLUME" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null
    prepare_smoke_tls
    prepare_zenpub_ca_bundle

    log "Starting databases and stock ZenPub"
    docker volume create "$ZENPUB_DB_VOLUME" >/dev/null
    docker run -d \
        --name "$ZENPUB_DB_CONTAINER" \
        --hostname "$ZENPUB_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$ZENPUB_DB_CONTAINER" \
        -e "POSTGRES_DB=$ZENPUB_DB_NAME" \
        -e "POSTGRES_USER=$ZENPUB_DB_USER" \
        -e "POSTGRES_PASSWORD=$ZENPUB_DB_PASSWORD" \
        -v "$ZENPUB_DB_VOLUME:/var/lib/postgresql/data" \
        "$ZENPUB_POSTGIS_IMAGE" >/dev/null
    wait_zenpub_postgres

    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e "POSTGRES_PASSWORD=$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_zenpub
    wait_zenpub
    wait_zenpub_migrations
    [ "$(zenpub_configure_runtime)" = "$GTS_HOST" ] || \
        fail "ZenPub did not apply its ActivityPub public hostname"

    log "Creating native ZenPub account"
    user_details="$(zenpub_create_user)"
    zenpub_actor="$(json_get "$user_details" actor)"
    json_assert "$user_details" \
        "data.get('type') == 'Person' and data.get('actor') == 'https://$GTS_HOST/pub/actors/$GTS_USERNAME'" \
        "ZenPub did not create its canonical native Person actor"

    log "Proving ZenPub discovery, content negotiation, and collections"
    nodeinfo_links="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo_href="$(json_get "$nodeinfo_links" links.0.href)"
    json_assert "$nodeinfo_links" \
        "len(data.get('links', [])) >= 1 and data.get('links', [])[0].get('href', '').startswith('https://$GTS_HOST/')" \
        "ZenPub NodeInfo discovery did not expose a canonical HTTPS endpoint"
    nodeinfo="$(http_form GET "$(zenpub_local_url "$nodeinfo_href")" "" 200)"
    json_assert "$nodeinfo" \
        "('commonspub' in data.get('software', {}).get('name', '').lower() or 'zenpub' in data.get('software', {}).get('name', '').lower()) and 'activitypub' in data.get('protocols', [])" \
        "ZenPub NodeInfo did not identify its stock federated application"

    webfinger="$(http_form GET \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" "" 200)"
    json_assert "$webfinger" \
        "data.get('subject') == 'acct:$GTS_USERNAME@$GTS_HOST' and any(item.get('href') == '$zenpub_actor' for item in data.get('links', []))" \
        "ZenPub WebFinger did not expose the canonical actor"

    actor_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$zenpub_actor")")"
    json_assert "$actor_json" \
        "data.get('id') == '$zenpub_actor' and data.get('type') == 'Person' and data.get('preferredUsername') == '$GTS_USERNAME' and data.get('publicKey', {}).get('owner') == '$zenpub_actor' and data.get('publicKey', {}).get('id') == '$zenpub_actor#main-key' and data.get('publicKey', {}).get('publicKeyPem', '').startswith('-----BEGIN PUBLIC KEY-----')" \
        "ZenPub actor fetch did not return the stock Person"
    curl -fsS \
        -H 'Accept: application/ld+json; profile="https://www.w3.org/ns/activitystreams"' \
        "$(zenpub_local_url "$zenpub_actor")" >/dev/null

    actor_outbox="$(json_get "$actor_json" outbox)"
    actor_followers="$(json_get "$actor_json" followers)"
    actor_following="$(json_get "$actor_json" following)"
    outbox_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$actor_outbox")")"
    followers_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$actor_followers")")"
    following_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$actor_following")")"
    json_assert "$outbox_json" \
        "data == 'ok'" \
        "Stock ZenPub's advertised no-op outbox behavior changed"
    json_assert "$followers_json" \
        "data.get('id') == '$actor_followers' and data.get('type') in ['Collection', 'OrderedCollection'] and int(data.get('totalItems') or 0) >= 0" \
        "ZenPub followers endpoint did not expose a bounded collection envelope"
    json_assert "$following_json" \
        "data.get('id') == '$actor_following' and data.get('type') in ['Collection', 'OrderedCollection'] and int(data.get('totalItems') or 0) >= 0" \
        "ZenPub following endpoint did not expose a bounded collection envelope"

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET \
        "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" pleroma.ap_id)"

    log "Following Person actors in both directions"
    zenpub_follow_uri "$alice_ap_id" >/dev/null
    zenpub_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$GTS_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the ZenPub actor after its Follow")"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$zenpub_account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('followed_by') is True" \
        "Unfathomably did not retain ZenPub's incoming Follow" >/dev/null

    http_form POST "$BE_BASE/api/v1/accounts/$zenpub_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$zenpub_account_id" \
        "Unfathomably's ZenPub Follow did not become accepted"
    poll_zenpub_boolean \
        "user = CommonsPub.Users.get!(\"$GTS_USERNAME\"); {:ok, follower} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); match?({:ok, _}, CommonsPub.Follows.one(deleted: false, creator: follower.id, context: user.id))" \
        true "ZenPub did not retain Unfathomably's incoming Follow"
    poll_zenpub_boolean \
        "user = CommonsPub.Users.get!(\"$GTS_USERNAME\"); {:ok, target} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); match?({:ok, _}, CommonsPub.Follows.one(deleted: false, creator: user.id, context: target.id))" \
        true "ZenPub did not retain its outgoing Unfathomably Follow"

    log "Creating ZenPub Community and Collection actors"
    context_details="$(zenpub_create_publishing_context)"
    community_actor="$(json_get "$context_details" community_actor)"
    community_type="$(json_get "$context_details" community_type)"
    collection_actor="$(json_get "$context_details" collection_actor)"
    collection_type="$(json_get "$context_details" collection_type)"
    [ "$community_type" = "Group" ] || \
        fail "ZenPub Community used $community_type instead of Group"
    [ "$collection_type" = "MN:Collection" ] || \
        fail "ZenPub Collection lost its native MN:Collection type"

    community_actor_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$community_actor")")"
    json_assert "$community_actor_json" \
        "data.get('id') == '$community_actor' and data.get('type') == 'Group' and data.get('preferredUsername') == 'alien-publishing-community'" \
        "ZenPub did not serve its native Community Group"
    curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$collection_actor")" >/dev/null

    log "Following and unfollowing the ZenPub Community Group"
    community_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "alien-publishing-community@$GTS_HOST" \
        "Unfathomably could not resolve the ZenPub Community Group")"
    http_form POST "$BE_BASE/api/v1/accounts/$community_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$community_account_id" \
        "Unfathomably's ZenPub Community Follow did not become accepted"
    poll_zenpub_boolean \
        "{:ok, community} = CommonsPub.Communities.one([:default, username: \"alien-publishing-community\"]); {:ok, follower} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); match?({:ok, _}, CommonsPub.Follows.one(deleted: false, creator: follower.id, context: community.id))" \
        true "ZenPub did not retain Unfathomably's incoming Group Follow"
    http_form POST "$BE_BASE/api/v1/accounts/$community_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_zenpub_boolean \
        "{:ok, community} = CommonsPub.Communities.one([:default, username: \"alien-publishing-community\"]); {:ok, follower} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); not match?({:ok, _}, CommonsPub.Follows.one(deleted: false, creator: follower.id, context: community.id))" \
        true "ZenPub retained Unfathomably's Group Follow after Undo Follow"

    log "Proving ZenPub's reverse Group Follow capability boundary"
    be_group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably ZenPub Group' \
        'name=unfathomably_zenpub_group' \
        'note=Open group used by the ZenPub federation smoke harness.' \
        'locked=false')"
    be_group_ap_id="$(json_get "$be_group" ap_id)"
    zenpub_expect_group_follow_unsupported "$be_group_ap_id"

    log "Creating a native ZenPub Resource Document"
    uploads_before="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
        grep -c 'GET /uploads/' || true)"
    resource_name="Alien federation handbook $(basename "$WORK_DIR")"
    resource_summary="Native ZenPub publishing resource $(basename "$WORK_DIR")"
    resource_details="$(zenpub_create_resource "$resource_name" "$resource_summary")"
    resource_id="$(json_get "$resource_details" id)"
    content_url="$(json_get "$resource_details" content_url)"
    resource_published="$(poll_zenpub_resource_details "$resource_id")"
    resource_uri="$(json_get "$resource_published" object_id)"
    resource_type="$(json_get "$resource_published" object_type)"
    [ "$resource_type" = "Document" ] || \
        fail "ZenPub emitted $resource_type instead of its native Document"

    resource_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(zenpub_local_url "$resource_uri")")"
    json_assert "$resource_json" \
        "data.get('id') == '$resource_uri' and data.get('type') == 'Document' and data.get('name') == '$resource_name' and data.get('summary') == '$resource_summary' and data.get('url') == '$content_url' and data.get('tag') == 'CC-BY-SA-4.0' and data.get('author', {}).get('name') == 'ZenPub smoke publisher' and data.get('subject') == 'federation' and data.get('level') == 'advanced' and data.get('language') == 'English' and data.get('context') == '$collection_actor'" \
        "ZenPub did not expose the complete native Resource Document"

    resource_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$resource_name" "Unfathomably did not receive the native ZenPub Document")"
    resource_status="$(http_form GET "$BE_BASE/api/v1/statuses/$resource_status_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$resource_status" \
        "data.get('uri') == '$resource_uri' and data.get('pleroma', {}).get('native', {}).get('type') == 'Document' and data.get('pleroma', {}).get('native', {}).get('class') == 'status' and data.get('pleroma', {}).get('native', {}).get('controls') == ['open'] and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('platform') == 'zenpub' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('resource_url') == '$content_url' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('license') == 'CC-BY-SA-4.0' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('author') == 'ZenPub smoke publisher' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('subject') == 'federation' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('level') == 'advanced' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('language') == 'English'" \
        "Unfathomably did not expose the bounded ZenPub publishing presentation"

    resource_object="$(be_object_json "$resource_uri")"
    json_assert "$resource_object" \
        "data.get('id') == '$resource_uri' and data.get('type') == 'Document' and 'CC-BY-SA-4.0' in (data.get('tag') or []) and data.get('subject') == 'federation' and data.get('level') == 'advanced' and data.get('language') == 'English'" \
        "Unfathomably did not preserve ZenPub's publishing extensions"
    assert_remote_status_immutable "$resource_status_id"

    uploads_after="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
        grep -c 'GET /uploads/' || true)"
    [ "$uploads_after" = "$uploads_before" ] || \
        fail "Unfathomably fetched ZenPub's linked resource during ingestion"

    log "Proving the stock duplicate and concurrent publication limitation"
    zenpub_expect_resource_redelivery_unsupported "$resource_id"
    poll_be_object_count "$resource_uri" 1 \
        "Failed ZenPub redelivery duplicated the canonical Document"

    log "Proving the stock Resource Update publication limitation"
    local_update_summary="Locally updated ZenPub resource $(basename "$WORK_DIR")"
    local_update="$(zenpub_update_resource "$resource_id" "$local_update_summary")"
    json_assert "$local_update" \
        "data.get('id') == '$resource_id' and data.get('summary') == '$local_update_summary'" \
        "ZenPub did not retain its local Resource update"
    sleep 5
    remote_after_update="$(be_object_json "$resource_uri")"
    json_assert "$remote_after_update" \
        "data.get('summary') == '$resource_summary' and data.get('summary') != '$local_update_summary'" \
        "Stock ZenPub unexpectedly federated a Resource Update through its missing publisher clause"

    log "Creating a native ZenPub comment and an Unfathomably reply"
    comment_text="ZenPub comment on native resource $(basename "$WORK_DIR")"
    comment="$(zenpub_create_comment "$resource_id" "$comment_text")"
    comment_id="$(json_get "$comment" id)"
    poll_zenpub_comment_details "$comment_id" >/dev/null
    comment_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$comment_text" "Unfathomably did not receive ZenPub's native comment")"

    be_reply_text="Unfathomably reply to ZenPub comment $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" "in_reply_to_id=$comment_status_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    poll_zenpub_boolean \
        "case CommonsPub.ActivityPub.Utils.get_pointer_id_by_ap_id(\"$be_reply_uri\") do nil -> false; id -> match?({:ok, _}, CommonsPub.Threads.Comments.one(id: id, deleted: false)) end" \
        true "ZenPub did not retain Unfathomably's reply as native Comment state"

    log "Testing Likes and Undo Likes in both directions"
    http_form POST "$BE_BASE/api/v1/statuses/$resource_status_id/favourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_zenpub_boolean \
        "{:ok, actor} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); {:ok, resource} = CommonsPub.Resources.one(id: \"$resource_id\"); match?({:ok, _}, CommonsPub.Likes.one(deleted: false, creator: actor.id, context: resource.id))" \
        true "ZenPub did not retain Unfathomably's Like on the Document"
    incoming_unlike_failures="$(zenpub_like_undo_failure_count)"
    http_form POST "$BE_BASE/api/v1/statuses/$resource_status_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_zenpub_incoming_unlike_unsupported \
        "$incoming_unlike_failures" "$alice_ap_id" "$resource_id"

    zenpub_like_uri "$be_reply_uri" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_reply_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Unfathomably did not receive ZenPub's Like"
    zenpub_unlike_uri "$be_reply_uri" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_reply_id" \
        'int(data.get("favourites_count") or 0) == 0' \
        "Unfathomably did not receive ZenPub's Undo Like"

    log "Testing federated moderation actions in both directions"
    zenpub_report_text="ZenPub moderation report $(basename "$WORK_DIR")"
    zenpub_flag="$(zenpub_flag_uri "$be_reply_uri" "$zenpub_report_text")"
    zenpub_flag_id="$(json_get "$zenpub_flag" id)"
    zenpub_flag_details="$(poll_zenpub_flag_details "$zenpub_flag_id")"
    zenpub_flag_uri="$(json_get "$zenpub_flag_details" object_id)"
    json_assert "$zenpub_flag_details" \
        "data.get('object', {}).get('type') == 'Flag' and data.get('object', {}).get('to') == [] and '$alice_ap_id' in data.get('object', {}).get('cc', []) and '$alice_ap_id' in data.get('object', {}).get('object', []) and '$be_reply_uri' in data.get('object', {}).get('object', [])" \
        "ZenPub's native Flag did not reach its exact empty-to delivery boundary"
    sleep 5
    docker logs "$GTS_CONTAINER" 2>&1 | \
        grep -Fq "Publishing $zenpub_flag_uri using ActivityPubWeb.Publisher" || \
        fail "ZenPub did not submit its native Flag to the stock publisher"
    if docker logs "$GTS_CONTAINER" 2>&1 | \
        grep -Fq "Federating $zenpub_flag_uri"; then
        fail "ZenPub unexpectedly delivered a Flag whose to collection is empty"
    fi
    assert_be_report_absent_by_text "$zenpub_report_text" \
        "Unfathomably received ZenPub's stock-undeliverable Flag"

    be_report_text="Unfathomably moderation report $(basename "$WORK_DIR")"
    incoming_flag_failures="$(zenpub_flag_forward_failure_count)"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$zenpub_account_id" \
        "status_ids[]=$resource_status_id" \
        "comment=$be_report_text" \
        'forward=true' >/dev/null
    incoming_flag_details="$(poll_zenpub_incoming_flag_details "$be_report_text")"
    json_assert "$incoming_flag_details" \
        "data.get('object', {}).get('type') == 'Flag' and data.get('object', {}).get('actor') == '$alice_ap_id' and '$zenpub_actor' in data.get('object', {}).get('object', []) and '$resource_uri' in data.get('object', {}).get('object', [])" \
        "ZenPub did not preserve Unfathomably's complete incoming raw Flag"
    poll_zenpub_incoming_flag_unsupported \
        "$incoming_flag_failures" "$alice_ap_id" "$resource_id"

    log "Testing explicit Person unfollows in both directions"
    http_form POST "$BE_BASE/api/v1/accounts/$zenpub_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    zenpub_unfollow_uri "$alice_ap_id" >/dev/null
    poll_relationship_not_following "$zenpub_account_id" \
        "Unfathomably retained its ZenPub Follow after unfollow"
    poll_zenpub_boolean \
        "user = CommonsPub.Users.get!(\"$GTS_USERNAME\"); {:ok, target} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); not match?({:ok, _}, CommonsPub.Follows.one(deleted: false, creator: user.id, context: target.id))" \
        true "ZenPub retained its outgoing Unfathomably Follow after unfollow"
    poll_zenpub_boolean \
        "user = CommonsPub.Users.get!(\"$GTS_USERNAME\"); {:ok, follower} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); not match?({:ok, _}, CommonsPub.Follows.one(deleted: false, creator: follower.id, context: user.id))" \
        true "ZenPub retained Unfathomably's Follow after Undo Follow"

    log "Testing Blocks and Undo Blocks in both directions"
    be_block="$(http_form POST "$BE_BASE/api/v1/accounts/$zenpub_account_id/block" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_block" 'data.get("blocking") is True' \
        "Unfathomably did not create its ZenPub Block"
    poll_zenpub_boolean \
        "user = CommonsPub.Users.get!(\"$GTS_USERNAME\"); {:ok, blocker} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); match?({:ok, _}, CommonsPub.Blocks.one(deleted: false, creator: blocker.id, context: user.id))" \
        true "ZenPub did not retain Unfathomably's incoming Block"
    http_form POST "$BE_BASE/api/v1/accounts/$zenpub_account_id/unblock" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_zenpub_boolean \
        "user = CommonsPub.Users.get!(\"$GTS_USERNAME\"); {:ok, blocker} = CommonsPub.ActivityPub.Utils.get_raw_character_by_ap_id(\"$alice_ap_id\"); not match?({:ok, _}, CommonsPub.Blocks.one(deleted: false, creator: blocker.id, context: user.id))" \
        true "ZenPub retained Unfathomably's Block after Undo Block"

    zenpub_block_uri "$alice_ap_id" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$zenpub_account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('blocked_by') is True" \
        "Unfathomably did not retain ZenPub's incoming Block" >/dev/null
    zenpub_unblock_uri "$alice_ap_id" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$zenpub_account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('blocked_by') is not True" \
        "Unfathomably retained ZenPub's Block after Undo Block" >/dev/null

    log "Testing remote reply and Comment Deletes plus the stock Resource Delete boundary"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_zenpub_boolean \
        "case CommonsPub.ActivityPub.Utils.get_pointer_id_by_ap_id(\"$be_reply_uri\") do nil -> true; id -> not match?({:ok, _}, CommonsPub.Threads.Comments.one(id: id, deleted: false)) end" \
        true "ZenPub retained the deleted Unfathomably reply"

    zenpub_delete_comment "$comment_id" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$comment_status_id" \
        "Unfathomably retained ZenPub's deleted native Comment"
    zenpub_expect_resource_delete_unsupported "$resource_id"
    http_form GET "$BE_BASE/api/v1/statuses/$resource_status_id" \
        "$ALICE_TOKEN" 200 >/dev/null

    repeated_delete_status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer $ALICE_TOKEN" \
        "$BE_BASE/api/v1/statuses/$be_reply_id" || true)"
    case "$repeated_delete_status" in
        404|410)
            ;;
        *)
            fail "Repeated local Delete did not terminate safely with 404 or 410"
            ;;
    esac

    missing_origin_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/activity+json' \
        "$GTS_BASE/pub/objects/00000000000000000000000000" || true)"
    [ "$missing_origin_status" = "404" ] || [ "$missing_origin_status" = "410" ] || \
        fail "ZenPub did not classify an absent ActivityPub object as terminal"

    relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$zenpub_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        "len(data) >= 1 and data[0].get('following') is not True and data[0].get('blocked_by') is not True" \
        "Final ZenPub relationship cleanup was incomplete"

    check_logs "$BE_CONTAINER" Unfathomably
    check_zenpub_logs

    cat <<EOF

ZenPub federation smoke passed.

Pinned stock source:
* zenpub: $ZENPUB_SOURCE_COMMIT ($ZENPUB_VERSION)

Alien ActivityPub matrix:
* Discovery: supported; WebFinger, actor fetch, both ActivityPub media types, NodeInfo, and canonical HTTPS IDs passed
* Native representation: supported; ZenPub's top-level Document retained its file URL and publishing metadata
* Compatibility representation: not_supported; stock ZenPub emits no fallback Note, Article, or Page and the test does not invent one
* Semantic deduplication: partially_supported; Unfathomably retained one canonical Document, while stock ZenPub crashes when republishing its existing ActivityPub object
* Authority: supported; a local non-owner could not rewrite the remote Document
* Lifecycle: partially_supported; Create, native Comment Delete, and a remote Unfathomably reply Delete converge, while Resource Delete rolls back and Resource Update has no publisher clause
* Concurrency: not_supported for native Resource publication; the exact stock duplicate-publication KeyError is asserted and Unfathomably remains canonical
* Collections: partially_supported; followers and following are bounded Collections, while the advertised outbox is a stock no-op endpoint
* Context: supported; Community, MN:Collection, Resource, and threaded Comment relationships survived federation
* Capabilities: partially_supported; Unfathomably exposes an honest read-only publishing card, and the reverse Group Follow is reported unavailable
* Round trip: partially_supported; supported follows, comments, outgoing Like Undo, Blocks, and Undos changed application state, while stock ZenPub cannot resolve an Unfathomably Group actor, apply an incoming Undo Like, or converge Flags in either direction
* Unknown JSON-LD: supported; author, license tag, subject, level, and language survived validation, storage, and export
* Privacy: not_supported for native Resources; stock ZenPub forces Community, Collection, Resource, and Comment publication public
* Idempotence: partially_supported; Unfathomably retains one canonical object and repeated local Delete terminates, while stock ZenPub cannot idempotently republish or delete a Resource
* Failure classification: partially_supported; missing resources terminate, while duplicate Resource publication, Resource Delete, incoming Undo Like, and both Flag directions reach precise stock failure boundaries
* Resource safety: supported in Unfathomably; the linked ZenPub upload was retained as data and was not fetched during ingestion
* UI classification: supported; the native Document is labelled ZenPub in the publishing surface
* Cleanup: partially_supported; Person and incoming Community unfollows, native Comment Delete, the remote reply Delete, and both Undo Blocks passed; Resource Delete and reverse Group membership are unavailable upstream

Relationship and moderation boundaries:
* supported: Person follows and unfollows in both directions
* partially_supported: Unfathomably follows and unfollows a native ZenPub Community, while stock ZenPub rejects an Unfathomably Group's attributed moderators collection
* partially_supported: native Resource posts, ZenPub comments, reciprocal replies, native Comment Delete, and the remote reply Delete work; stock Resource Delete rolls back
* partially_supported: Likes work in both directions and ZenPub's outgoing Undo Like converges, while its receiver has no incoming Undo Like clause
* not_supported: ZenPub's outgoing Flag has no delivery recipient, while an incoming Unfathomably Flag is stored raw then diverted into a discarded forwarding job without native moderation state
* supported: Block and Undo Block in both directions
* stock_limitation: ZenPub records an outgoing Follow before the handshake and cannot apply the returned Accept activity
* stock_limitation: duplicate or concurrent Resource publication returns an existing ActivityPub Object where the publisher requires an Activity
* stock_limitation: incoming Undo Like reaches CommonsPub.Likes without a matching receiver clause and leaves the Like active
* stock_limitation: an outgoing Flag names the remote account and status but places the account only in cc; the stock publisher finds no delivery recipient
* stock_limitation: an incoming Flag is stored, but ZenPub queues a forwarding job that fails NotFound instead of its native Flag receiver
* stock_limitation: Resource Update changes local state but is not published
* stock_limitation: incoming top-level Note publication is context-dependent; native Resource Documents are ZenPub's post representation
* stock_limitation: Resource Delete cascades through the retained incoming Like, passes a list of maps to an Ecto.ULID query, and rolls back with Ecto.Query.CastError
* not_supported: stock ZenPub exposes no durable signal by which it can know that a remote instance has defederated it
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_zenpub_smoke
fi

# end of build_scripts/unfathomably-zenpub-smoke.sh

#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-bonfire-valueflows-smoke.sh
#
# Purpose:
#
#   Run an unmodified current Bonfire Cooperation instance with the stock
#   ValueFlows extension against Unfathomably.
#
# Responsibilities:
#
#   * build the pinned stock Bonfire application and flavour sources
#   * boot Bonfire and PostGIS on the shared isolated TLS harness
#   * create users and ValueFlows state through Bonfire's own application APIs
#   * verify discovery, relationships, native objects, lifecycle, moderation,
#     privacy, resource safety, UI classification, and cleanup
#   * report stock limitations without substituting synthetic activities
#
# This file intentionally does NOT contain:
#
#   * unreleased Bonfire or ValueFlows behavior changes
#   * hand-authored Bonfire ActivityPub activities
#   * direct mutation of Bonfire's PostgreSQL application tables
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-bonfire-valueflows-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-bonfire-valueflows.example.com}"
export BE_PORT="${BE_PORT:-5101}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_bonfire_valueflows_smoke_be}"
export GTS_HOST="${GTS_HOST:-bonfire-valueflows-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5102}"
export GTS_APP_PORT=4000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL="Bonfire ValueFlows"
export GTS_USERNAME=coordinator
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

BONFIRE_APP_SOURCE_URL="${BONFIRE_APP_SOURCE_URL:-https://github.com/bonfire-networks/bonfire-app.git}"
BONFIRE_APP_SOURCE_COMMIT="${BONFIRE_APP_SOURCE_COMMIT:-be0e18274fc3ce9584cf512bdd9ec489f40fec60}"
BONFIRE_COOPERATION_SOURCE_URL="${BONFIRE_COOPERATION_SOURCE_URL:-https://github.com/bonfire-networks/cooperation.git}"
BONFIRE_COOPERATION_SOURCE_COMMIT="${BONFIRE_COOPERATION_SOURCE_COMMIT:-c756a2c6e9912b9fbf5c5abd5489691ff49cc4cc}"
BONFIRE_EMBER_SOURCE_URL="${BONFIRE_EMBER_SOURCE_URL:-https://github.com/bonfire-networks/ember.git}"
BONFIRE_EMBER_SOURCE_COMMIT="${BONFIRE_EMBER_SOURCE_COMMIT:-c8562c45a2ba837fb75a71020439980073a09d5b}"
BONFIRE_VALUEFLOWS_SOURCE_URL="${BONFIRE_VALUEFLOWS_SOURCE_URL:-https://github.com/bonfire-networks/bonfire_valueflows.git}"
BONFIRE_VALUEFLOWS_SOURCE_COMMIT="${BONFIRE_VALUEFLOWS_SOURCE_COMMIT:-ebfa5c45fbab1928e23b573c17087a8efd9296ec}"
BONFIRE_SHARED_USER_SOURCE_URL="${BONFIRE_SHARED_USER_SOURCE_URL:-https://github.com/bonfire-networks/bonfire_data_shared_user.git}"
BONFIRE_SHARED_USER_SOURCE_COMMIT="${BONFIRE_SHARED_USER_SOURCE_COMMIT:-5692cb1e9dc4be23a86f75e3412fe3e3227c7bb5}"
BONFIRE_OPEN_ID_SOURCE_URL="${BONFIRE_OPEN_ID_SOURCE_URL:-https://github.com/bonfire-networks/bonfire_open_id.git}"
BONFIRE_OPEN_ID_SOURCE_COMMIT="${BONFIRE_OPEN_ID_SOURCE_COMMIT:-e6beb086ebb8e8b37be8b526c4a9abb50a3c4536}"
BONFIRE_IMAGE="${BONFIRE_IMAGE:-unfathomably-bonfire-cooperation-stock:${BONFIRE_APP_SOURCE_COMMIT:0:8}-${BONFIRE_COOPERATION_SOURCE_COMMIT:0:8}-${BONFIRE_VALUEFLOWS_SOURCE_COMMIT:0:8}-${BONFIRE_SHARED_USER_SOURCE_COMMIT:0:8}-${BONFIRE_OPEN_ID_SOURCE_COMMIT:0:8}-graphql1}"
BONFIRE_POSTGIS_IMAGE="${BONFIRE_POSTGIS_IMAGE:-postgis/postgis:17-3.5-alpine}"
BONFIRE_ELIXIR_IMAGE="${BONFIRE_ELIXIR_IMAGE:-hexpm/elixir:1.20.2-erlang-29.0.2-alpine-3.23.5}"
BONFIRE_ALPINE_VERSION="${BONFIRE_ALPINE_VERSION:-3.23.5}"
BONFIRE_PASSWORD="${BONFIRE_PASSWORD:-Bonfire-smoke-password-12345}"
BONFIRE_DB_USER="${BONFIRE_DB_USER:-bonfire}"
BONFIRE_DB_PASSWORD="${BONFIRE_DB_PASSWORD:-bonfire-smoke-postgres-password}"
BONFIRE_DB_NAME="${BONFIRE_DB_NAME:-bonfire}"
BONFIRE_DB_CONTAINER="${PREFIX}-bonfire-db"
BONFIRE_DB_VOLUME="${PREFIX}-bonfire-postgres"
BONFIRE_SOURCE_DIR="$WORK_DIR/bonfire-source"
BONFIRE_CA_BUNDLE="$WORK_DIR/bonfire-ca-bundle.crt"
BONFIRE_SECRET_KEY_BASE="bonfire-smoke-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz"
BONFIRE_SIGNING_SALT="bonfire-smoke-signing-salt-0123456789"
BONFIRE_ENCRYPTION_SALT="bonfire-smoke-encryption-salt-0123456789"

cleanup_bonfire_valueflows_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BONFIRE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$BONFIRE_DB_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_bonfire_valueflows_smoke EXIT

checkout_pinned_source() {
    local url="$1"
    local commit="$2"
    local directory="$3"
    local actual_commit

    git clone --quiet --filter=blob:none --no-checkout "$url" "$directory"
    git -C "$directory" fetch --quiet --depth=1 origin "$commit"
    git -C "$directory" checkout --quiet --detach "$commit"

    actual_commit="$(git -C "$directory" rev-parse HEAD)"
    [ "$actual_commit" = "$commit" ] || \
        fail "Pinned checkout for $url resolved to $actual_commit instead of $commit"
}

apply_bonfire_build_compatibility() {
    local file="$BONFIRE_SOURCE_DIR/extensions/bonfire_valueflows/lib/util/federation.ex"
    local hooks_file="$BONFIRE_SOURCE_DIR/config/current_flavour/deps.hooks.js"
    local dockerfile="$BONFIRE_SOURCE_DIR/Dockerfile.release"
    local translate_guard actor_guard
    local kanban_import encrypt_import hooks_assignment
    local migration_copy migration_rewrite
    local assets_copy assets_rewrite assets_package_rewrite
    local runtime_anchor runtime_loader runtime_config runtime_rewrite
    local rewritten_dockerfile

    translate_guard='  defp to_AP_deep_remap(type, "__typename") when is_in(type, @types_to_translate) do'
    actor_guard='       when is_in(type, @actor_types) do'

    [ "$(grep -Fxc "$translate_guard" "$file")" = "1" ] || \
        fail "Pinned ValueFlows source no longer has the expected type translation guard"
    [ "$(grep -Fxc "$actor_guard" "$file")" = "1" ] || \
        fail "Pinned ValueFlows source no longer has the expected actor type guard"

    #
    # ActivityPub.Config.is_in/2 pattern-matches its macro arguments before
    # Elixir expands module attributes.  Current Elixir therefore rejects the
    # two ValueFlows calls at compile time.  Spell out the macro's own guard
    # expansion with the same lists and the same two-item JSON-LD type limit.
    # This changes no accepted runtime value; it only makes the pinned source's
    # intended guard compile with its pinned Bonfire toolchain.
    #
    sed -i \
        -e 's|when is_in(type, @types_to_translate)|when type in @types_to_translate or (is_list(type) and (hd(type) in @types_to_translate or (length(type) > 1 and hd(tl(type)) in @types_to_translate)))|' \
        -e 's|when is_in(type, @actor_types)|when type in @actor_types or (is_list(type) and (hd(type) in @actor_types or (length(type) > 1 and hd(tl(type)) in @actor_types)))|' \
        "$file"

    ! grep -Fq 'is_in(type, @types_to_translate)' "$file" || \
        fail "ValueFlows type translation guard compatibility rewrite did not apply"
    ! grep -Fq 'is_in(type, @actor_types)' "$file" || \
        fail "ValueFlows actor type guard compatibility rewrite did not apply"

    kanban_import='import { KanbanHooks } from "./../../deps/bonfire_ui_kanban/assets/js/extension"'
    encrypt_import='import { EncryptHooks } from "./../../deps/bonfire_encrypt/assets/js/extension"'
    hooks_assignment='Object.assign(ExtensionHooks,  LiveSelect, GeolocateHooks, KanbanHooks, EncryptHooks) // EditorCkHooks, EditorQuillHooks'

    [ "$(grep -Fxc "$kanban_import" "$hooks_file")" = "1" ] || \
        fail "Pinned Cooperation hooks no longer have the expected Kanban import"
    [ "$(grep -Fxc "$encrypt_import" "$hooks_file")" = "1" ] || \
        fail "Pinned Cooperation hooks no longer have the expected encryption import"
    [ "$(grep -Fxc "$hooks_assignment" "$hooks_file")" = "1" ] || \
        fail "Pinned Cooperation hooks no longer have the expected assignment"

    assets_copy='COPY --from=builder /opt/app/config/current_flavour /opt/build/config/current_flavour'
    [ "$(grep -Fxc "$assets_copy" "$dockerfile")" = "1" ] || \
        fail "Pinned Bonfire Dockerfile no longer has the expected asset config copy"

    migration_copy='RUN MIX_ENV=prod mix bonfire.extension.copy_migrations --force --to priv/repo/migrations'
    [ "$(grep -Fxc "$migration_copy" "$dockerfile")" = "1" ] || \
        fail "Pinned Bonfire Dockerfile no longer has the expected migration copy"

    runtime_anchor='FROM builder as final-builder'
    runtime_loader='Bonfire.Common.Config.LoadExtensionsConfig.load_configs([Bonfire.RuntimeConfig])'
    runtime_config='config :activity_pub, :instance, federating: federate?'
    [ "$(grep -Fxc "$runtime_anchor" "$dockerfile")" = "1" ] || \
        fail "Pinned Bonfire Dockerfile no longer has the expected final builder"
    [ "$(grep -Fxc "$runtime_loader" "$BONFIRE_SOURCE_DIR/config/runtime.exs")" = "1" ] || \
        fail "Pinned Bonfire runtime config no longer has the expected extension loader"
    ! grep -Fq "$runtime_config" "$BONFIRE_SOURCE_DIR/config/runtime.exs" || \
        fail "Pinned Bonfire runtime config now sets federation without compatibility help"

    #
    # The production config defaults ActivityPub federation to false.  The
    # runtime config calculates the intended value from FEDERATE but omits the
    # assignment, so FEDERATE=yes still rejects every actor fetch.  Apply the
    # calculated value after extension runtime configs have loaded.  Insert the
    # correction only in final-builder so the expensive compile layer remains
    # reusable and the generated source archive records the effective config.
    #
    runtime_rewrite="RUN grep -Fxc '$runtime_loader' config/runtime.exs | grep -qx '1' && ! grep -Fq '$runtime_config' config/runtime.exs && sed -i '/Bonfire.Common.Config.LoadExtensionsConfig.load_configs/a $runtime_config' config/runtime.exs && grep -Fxc '$runtime_config' config/runtime.exs | grep -qx '1'"

    #
    # Several pinned migration wrappers call imported migration functions which
    # create indexes concurrently.  Ecto 3.14 requires the transaction setting
    # on the outer wrapper, not on the imported module, and otherwise rolls back
    # foundational tables along with the index.  Apply the setting after the
    # stock migration collector has assembled its final release directory.
    #
    migration_rewrite="RUN set -eu; dir=/opt/app/priv/repo/migrations; for name in 20200828094943_add_files.exs 20200828094944_import_me.exs 20201205094943_import_classify.exs 20201205094945_import_quantify.exs 20201205095038_import_geolocation.exs 20201205095039_import_valueflows.exs 20201205095040_vf_observe.exs 20210102094944_import_shared_user.exs 20211112094942_import_commitment_satisfaction.exs 20220428094200_add_files_mixin.exs; do file=\"\$dir/\$name\"; grep -Fc '  use Ecto.Migration' \"\$file\" | grep -qx '1'; ! grep -Fq '@disable_ddl_transaction' \"\$file\"; sed -i 's/^  use Ecto.Migration\$/  use Ecto.Migration; @disable_ddl_transaction true/' \"\$file\"; grep -Fq '@disable_ddl_transaction true' \"\$file\"; done"

    #
    # The pinned Cooperation flavour enables hooks for two optional extensions
    # which neither its dependency configuration nor its installer provides.
    # Esbuild treats those absent imports as fatal.  Rewrite only the copy in
    # the asset-builder stage so this frontend correction cannot invalidate or
    # alter the already compiled Elixir application layer.
    #
    assets_rewrite="RUN grep -Fvx '$kanban_import' /opt/build/config/current_flavour/deps.hooks.js | grep -Fvx '$encrypt_import' | sed 's|LiveSelect, GeolocateHooks, KanbanHooks, EncryptHooks|LiveSelect, GeolocateHooks|' > /tmp/deps.hooks.js && mv /tmp/deps.hooks.js /opt/build/config/current_flavour/deps.hooks.js && ! grep -Fq 'KanbanHooks' /opt/build/config/current_flavour/deps.hooks.js && ! grep -Fq 'EncryptHooks' /opt/build/config/current_flavour/deps.hooks.js"
    assets_package_rewrite="RUN test ! -e /opt/build/deps/bonfire_ui_reactions && grep -Fc '\"build\": \"yarn prepare.static && yarn build.css && yarn build.esbuild && yarn build.vidstack && yarn build.milkdown && yarn build.emoji_picker\",' /opt/build/deps/bonfire_ui_common/assets/package.json | grep -qx '1' && sed -i 's| && yarn build[.]emoji_picker||' /opt/build/deps/bonfire_ui_common/assets/package.json && ! grep -Fq 'yarn build.emoji_picker\"' /opt/build/deps/bonfire_ui_common/assets/package.json"
    rewritten_dockerfile="$(mktemp "$dockerfile.compat.XXXXXX")"

    if ! awk \
        -v assets_anchor="$assets_copy" \
        -v rewrite="$assets_rewrite" \
        -v package_rewrite="$assets_package_rewrite" \
        -v migration_anchor="$migration_copy" \
        -v migration_rewrite="$migration_rewrite" \
        -v runtime_anchor="$runtime_anchor" \
        -v runtime_rewrite="$runtime_rewrite" '
        { print }
        $0 == runtime_anchor {
            print runtime_rewrite
            runtime_inserted++
        }
        $0 == migration_anchor {
            print migration_rewrite
            migration_inserted++
        }
        $0 == assets_anchor {
            print rewrite
            print package_rewrite
            assets_inserted++
        }
        END {
            if (migration_inserted != 1 || assets_inserted != 1 || runtime_inserted != 1)
                exit 1
        }
    ' "$dockerfile" >"$rewritten_dockerfile"; then
        rm -f "$rewritten_dockerfile"
        fail "Could not add the Cooperation asset compatibility rewrite"
    fi

    mv "$rewritten_dockerfile" "$dockerfile"
    [ "$(grep -Fxc "$assets_rewrite" "$dockerfile")" = "1" ] || \
        fail "Cooperation asset compatibility rewrite did not apply"
    [ "$(grep -Fxc "$assets_package_rewrite" "$dockerfile")" = "1" ] || \
        fail "Cooperation optional asset compatibility rewrite did not apply"
    [ "$(grep -Fxc "$migration_rewrite" "$dockerfile")" = "1" ] || \
        fail "Cooperation migration compatibility rewrite did not apply"
    [ "$(grep -Fxc "$runtime_rewrite" "$dockerfile")" = "1" ] || \
        fail "Cooperation runtime federation compatibility rewrite did not apply"
}

prepare_bonfire_image() {
    if docker image inspect "$BONFIRE_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    require_command git
    docker buildx version >/dev/null 2>&1 || \
        fail "Bonfire's current Dockerfile requires the Docker Buildx plugin"

    checkout_pinned_source \
        "$BONFIRE_APP_SOURCE_URL" "$BONFIRE_APP_SOURCE_COMMIT" "$BONFIRE_SOURCE_DIR"
    mkdir -p "$BONFIRE_SOURCE_DIR/extensions"
    checkout_pinned_source \
        "$BONFIRE_COOPERATION_SOURCE_URL" "$BONFIRE_COOPERATION_SOURCE_COMMIT" \
        "$BONFIRE_SOURCE_DIR/extensions/cooperation"
    checkout_pinned_source \
        "$BONFIRE_EMBER_SOURCE_URL" "$BONFIRE_EMBER_SOURCE_COMMIT" \
        "$BONFIRE_SOURCE_DIR/extensions/ember"
    checkout_pinned_source \
        "$BONFIRE_VALUEFLOWS_SOURCE_URL" "$BONFIRE_VALUEFLOWS_SOURCE_COMMIT" \
        "$BONFIRE_SOURCE_DIR/extensions/bonfire_valueflows"
    checkout_pinned_source \
        "$BONFIRE_SHARED_USER_SOURCE_URL" "$BONFIRE_SHARED_USER_SOURCE_COMMIT" \
        "$BONFIRE_SOURCE_DIR/extensions/bonfire_data_shared_user"
    checkout_pinned_source \
        "$BONFIRE_OPEN_ID_SOURCE_URL" "$BONFIRE_OPEN_ID_SOURCE_COMMIT" \
        "$BONFIRE_SOURCE_DIR/extensions/bonfire_open_id"

    (
        cd "$BONFIRE_SOURCE_DIR"
        AUTO_YES=true bash extensions/cooperation/install.sh --yes >/dev/null
    )

    #
    # Cooperation's installer currently copies cooperation.exs but omits the
    # bonfire_*.exs files which configure its own extension dependencies.  The
    # stock application imports those files by name during compilation, and
    # bonfire_quantify deliberately refuses to compile without its config.
    # Preserve the upstream files verbatim while completing the installer's
    # intended application layout.
    #
    cp "$BONFIRE_SOURCE_DIR"/extensions/cooperation/config/bonfire_*.exs \
        "$BONFIRE_SOURCE_DIR/config/"

    #
    # The Cooperation lock file pins OpenID and Boruta, and Bonfire Common
    # calls Boruta while selecting the primary repository for actor caches.
    # The flavour installer omits the OpenID entry from its active dependency
    # list, leaving WebFinger and ActivityPub actor lookup unusable at runtime.
    # Activate the exact revision already pinned by the stock lock file.
    #
    printf '%s\n' \
        'bonfire_valueflows = "extensions/bonfire_valueflows"' \
        'bonfire_data_shared_user = "extensions/bonfire_data_shared_user"' \
        'bonfire_open_id = "extensions/bonfire_open_id"' \
        >"$BONFIRE_SOURCE_DIR/config/current_flavour/deps.path"

    #
    # Dockerfile.release copies the optional pre-fetched dependency directory
    # unconditionally.  Git does not preserve the empty directory in a clean
    # checkout, so provide it before Docker calculates the build context.
    #
    mkdir -p "$BONFIRE_SOURCE_DIR/deps"

    apply_bonfire_build_compatibility

    log "Building pinned stock Bonfire Cooperation and ValueFlows image"

    #
    # Cooperation serializes ValueFlows objects through its GraphQL schema.
    # Bonfire's official release workflow enables this build input, so the
    # smoke image does too.  The pinned Cooperation branch still omits its
    # root schema source; the runtime probe below records that stock boundary.
    #
    docker build --progress=plain \
        --build-arg FLAVOUR=cooperation \
        --build-arg WITH_API_GRAPHQL=1 \
        --build-arg WITH_IMAGE_VIX=false \
        --build-arg WITH_AI=false \
        --build-arg ALPINE_VERSION="$BONFIRE_ALPINE_VERSION" \
        --build-arg ELIXIR_DOCKER_IMAGE="$BONFIRE_ELIXIR_IMAGE" \
        --build-arg RUSTLER_BUILD_ALL=false \
        --build-arg FORKS_TO_COPY_PATH=extensions \
        -t "$BONFIRE_IMAGE" \
        -f "$BONFIRE_SOURCE_DIR/Dockerfile.release" \
        "$BONFIRE_SOURCE_DIR"
}

prepare_bonfire_ca_bundle() {
    docker run --rm --entrypoint /bin/sh "$BONFIRE_IMAGE" \
        -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$BONFIRE_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$BONFIRE_CA_BUNDLE"
}

bonfire_environment() {
    printf '%s\n' \
        -e "DATABASE_URL=ecto://$BONFIRE_DB_USER:$BONFIRE_DB_PASSWORD@$BONFIRE_DB_CONTAINER/$BONFIRE_DB_NAME" \
        -e "POSTGRES_HOST=$BONFIRE_DB_CONTAINER" \
        -e "POSTGRES_USER=$BONFIRE_DB_USER" \
        -e "POSTGRES_DB=$BONFIRE_DB_NAME" \
        -e "POSTGRES_PASSWORD=$BONFIRE_DB_PASSWORD" \
        -e "HOSTNAME=$GTS_HOST" \
        -e SERVER_PORT=4000 \
        -e PUBLIC_PORT=443 \
        -e FEDERATE=yes \
        -e PHX_SERVER=yes \
        -e "SECRET_KEY_BASE=$BONFIRE_SECRET_KEY_BASE" \
        -e "SIGNING_SALT=$BONFIRE_SIGNING_SALT" \
        -e "ENCRYPTION_SALT=$BONFIRE_ENCRYPTION_SALT" \
        -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
}

start_bonfire_valueflows() {
    local -a environment

    mapfile -t environment < <(bonfire_environment)

    docker volume create "$BONFIRE_DB_VOLUME" >/dev/null
    docker run -d \
        --name "$BONFIRE_DB_CONTAINER" \
        --hostname "$BONFIRE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BONFIRE_DB_CONTAINER" \
        -e POSTGRES_USER="$BONFIRE_DB_USER" \
        -e POSTGRES_PASSWORD="$BONFIRE_DB_PASSWORD" \
        -e POSTGRES_DB="$BONFIRE_DB_NAME" \
        -v "$BONFIRE_DB_VOLUME:/var/lib/postgresql/data" \
        "$BONFIRE_POSTGIS_IMAGE" >/dev/null

    for _ in $(seq 1 120); do
        if docker exec "$BONFIRE_DB_CONTAINER" \
            pg_isready -U "$BONFIRE_DB_USER" -d "$BONFIRE_DB_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker exec "$BONFIRE_DB_CONTAINER" \
        pg_isready -U "$BONFIRE_DB_USER" -d "$BONFIRE_DB_NAME" >/dev/null 2>&1 || \
        fail "Bonfire PostGIS did not become ready"

    #
    # Bonfire's release contains a single named release executable.  Its
    # startup path runs EctoSparkles.AutoMigrator before the endpoint accepts
    # traffic, so there is no separate generic migrate or server executable.
    #
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        "${environment[@]}" \
        -v "$BONFIRE_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" \
        "$BONFIRE_IMAGE" ./bin/bonfire start >/dev/null

    start_gts_proxy
}

wait_bonfire_valueflows() {
    for _ in $(seq 1 300); do
        if curl -fsS "$GTS_BASE/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    docker logs "$BONFIRE_DB_CONTAINER" >&2 || true
    fail "Timed out waiting for Bonfire ValueFlows at $GTS_BASE"
}

bonfire_rpc() {
    local code="$1"

    docker exec "$GTS_CONTAINER" ./bin/bonfire rpc "$code"
}

bonfire_rpc_value() {
    local code="$1"

    #
    # The stock release may write emulator and application diagnostics to
    # standard output before or after the value printed by the RPC expression.
    # Select complete machine-readable result lines instead of assuming that
    # the last physical line belongs to the expression.
    #
    bonfire_rpc "$code" | python3 -c '
import json
import sys

values = []

for raw_line in sys.stdin:
    line = raw_line.strip()

    if line in ("true", "false"):
        values.append(line)
        continue

    try:
        json.loads(line)
    except (TypeError, ValueError):
        continue

    values.append(line)

if not values:
    raise SystemExit("Bonfire RPC did not emit a JSON or boolean result")

print(values[-1])
'
}

bonfire_create_user() {
    local code

    code="
case Bonfire.Me.make_account_and_user(
       \"$GTS_USERNAME\",
       \"$GTS_USERNAME@$GTS_HOST\",
       \"$BONFIRE_PASSWORD\",
       skip_invite_check: true,
       must_confirm?: false
     ) do
  {:ok, user} ->
    IO.puts(Jason.encode!(%{
      id: user.id,
      username: \"$GTS_USERNAME\",
      canonical_url: Bonfire.Common.URIs.canonical_url(user, preload_if_needed: false)
    }))

  other ->
    raise \"Could not create Bonfire user: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_create_economic_event() {
    local note="$1"
    local create_code inspect_code result

    create_code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

#
# A cold release can let the failed serializer terminate this RPC after the
# native transaction has committed.  The shell verifies committed application
# state in a separate RPC and retries only when no event was retained.
#
_valueflows_schema_loaded = Code.ensure_loaded?(Bonfire.ValueFlows.API.Schema)

attrs = %{
  action: \"produce\",
  agreed_in: \"https://resources.invalid/valueflows-smoke-agreement\",
  has_point_in_time: DateTime.utc_now(),
  is_public: true,
  note: \"$note\",
  resource_name: \"ValueFlows smoke resource\"
}

case ValueFlows.EconomicEvent.EconomicEvents.create(user, attrs) do
  {:ok, %{economic_event: _event}} -> :ok
  other -> raise \"Could not create native EconomicEvent: #{inspect(other)}\"
end
"

    inspect_code="
import Ecto.Query

event_ids =
  Bonfire.Common.Repo.all(
    from event in ValueFlows.EconomicEvent,
      where: event.note == \"$note\" and is_nil(event.deleted_at),
      select: event.id
  )

case event_ids do
  [event_id] ->
    {:ok, event} = ValueFlows.EconomicEvent.EconomicEvents.one(id: event_id)
    configured_root_schema = Application.get_env(:bonfire, :graphql_schema_module)

    IO.puts(Jason.encode!(%{
      action: event.action_id,
      agreed_in: event.agreed_in,
      configured_root_schema: inspect(configured_root_schema),
      event_id: event.id,
      has_point_in_time: DateTime.to_iso8601(event.has_point_in_time),
      note: event.note,
      root_schema_loaded:
        is_atom(configured_root_schema) and Code.ensure_loaded?(configured_root_schema),
      valueflows_schema_loaded: Code.ensure_loaded?(Bonfire.ValueFlows.API.Schema)
    }))

  [] ->
    IO.puts(Jason.encode!(%{event_id: nil}))

  ids ->
    raise \"Native EconomicEvent creation duplicated application state: #{inspect(ids)}\"
end
"

    for _attempt in 1 2; do
        bonfire_rpc "$create_code" >/dev/null 2>&1 || true
        result="$(bonfire_rpc_value "$inspect_code")"

        if [ -n "$(json_get_optional "$result" event_id)" ]; then
            printf '%s\n' "$result"
            return 0
        fi
    done

    printf 'Observed native EconomicEvent state: %s\n' "$result" >&2
    fail "Bonfire did not retain its native EconomicEvent creation"
}

bonfire_update_economic_event() {
    local event_id="$1"
    local note="$2"
    local update_code inspect_code result

    update_code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")
{:ok, event} = ValueFlows.EconomicEvent.EconomicEvents.one(id: \"$event_id\")

case ValueFlows.EconomicEvent.EconomicEvents.update(user, event, %{note: \"$note\"}) do
  {:ok, _updated} -> :ok
  other -> raise \"Could not update native EconomicEvent: #{inspect(other)}\"
end
"

    inspect_code="
case ValueFlows.EconomicEvent.EconomicEvents.one(id: \"$event_id\") do
  {:ok, event} ->
    configured_root_schema = Application.get_env(:bonfire, :graphql_schema_module)

    IO.puts(Jason.encode!(%{
      event_id: event.id,
      note: event.note,
      root_schema_loaded:
        is_atom(configured_root_schema) and Code.ensure_loaded?(configured_root_schema),
      updated: event.note == \"$note\"
    }))

  _other ->
    IO.puts(Jason.encode!(%{event_id: nil, note: nil, updated: false}))
end
"

    bonfire_rpc "$update_code" >/dev/null 2>&1 || true
    result="$(bonfire_rpc_value "$inspect_code")"
    printf '%s\n' "$result"
}

bonfire_delete_economic_event() {
    local event_id="$1"
    local delete_code inspect_code result

    delete_code="
{:ok, event} = ValueFlows.EconomicEvent.EconomicEvents.one(id: \"$event_id\")

case ValueFlows.EconomicEvent.EconomicEvents.soft_delete(event) do
  {:ok, _deleted} -> :ok
  other -> raise \"Could not delete native EconomicEvent: #{inspect(other)}\"
end
"

    inspect_code="
case Bonfire.Common.Repo.get(ValueFlows.EconomicEvent, \"$event_id\") do
  %{deleted_at: deleted_at} ->
    IO.puts(Jason.encode!(%{
      delete_activity_api_available:
        Code.ensure_loaded?(Bonfire.Social.APActivities) and
          function_exported?(Bonfire.Social.APActivities, :create, 3),
      deleted: not is_nil(deleted_at),
      event_id: \"$event_id\"
    }))

  _other ->
    IO.puts(Jason.encode!(%{
      delete_activity_api_available: false,
      deleted: false,
      event_id: \"$event_id\"
    }))
end
"

    bonfire_rpc "$delete_code" >/dev/null 2>&1 || true
    result="$(bonfire_rpc_value "$inspect_code")"
    printf '%s\n' "$result"
}

bonfire_create_post() {
    local text="$1"
    local reply_to_uri="${2:-}"
    local boundary="${3:-public}"
    local redelivery_count="${4:-0}"
    local code

    [[ "$redelivery_count" =~ ^[0-9]+$ ]] || \
        fail "Bonfire post redelivery count must be a non-negative integer"

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

reply_to_id =
  case \"$reply_to_uri\" do
    \"\" ->
      nil

    uri ->
      case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(uri) do
        {:ok, object} -> object.id
        other -> raise \"Could not resolve reply target: #{inspect(other)}\"
      end
  end

post_attrs = %{
  post_content: %{html_body: \"$text\"},
  reply_to_id: reply_to_id
}

case Bonfire.Posts.publish(
       current_user: user,
       post_attrs: post_attrs,
       boundary: \"$boundary\"
     ) do
  {:ok, post} ->
    activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(post)

    redeliveries =
      case $redelivery_count do
        0 ->
          []

        count ->
          1..count
          |> Task.async_stream(
            fn _attempt -> ActivityPub.Federator.publish(activity) end,
            max_concurrency: count,
            ordered: false,
            timeout: 60_000
          )
          |> Enum.to_list()
      end

    redelivery_ok =
      Enum.all?(redeliveries, fn
        {:ok, {:ok, _job_or_activity}} -> true
        _other -> false
      end)

    IO.puts(Jason.encode!(%{
      id: post.id,
      canonical_url: Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true),
      redeliveries: length(redeliveries),
      redelivery_ok: redelivery_ok
    }))

  other ->
    raise \"Could not create Bonfire post: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_delete_post() {
    local post_id="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Common.Needles.get(\"$post_id\",
       current_user: user,
       skip_boundary_check: true
     ) do
  {:ok, post} ->
    case Bonfire.Social.Objects.delete(post, current_user: user) do
      {:ok, _deleted} -> IO.puts(Jason.encode!(%{deleted: true, id: \"$post_id\"}))
      other -> raise \"Could not delete Bonfire post: #{inspect(other)}\"
    end

  other ->
    raise \"Could not load Bonfire post for deletion: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_follow_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Social.Graph.Follows.follow(user, target) do
      {:ok, result} -> IO.puts(Jason.encode!(%{ok: true, id: result.id}))
      other -> raise \"Could not follow remote target: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote follow target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_unfollow_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Social.Graph.Follows.unfollow(user, target) do
      {:ok, _result} -> IO.puts(Jason.encode!(%{ok: true}))
      other -> raise \"Could not unfollow remote target: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote unfollow target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_like_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Social.Likes.like(user, target) do
      {:ok, result} -> IO.puts(Jason.encode!(%{ok: true, id: result.id}))
      other -> raise \"Could not like remote object: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote like target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_unlike_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Social.Likes.unlike(user, target) do
      {:ok, _result} -> IO.puts(Jason.encode!(%{ok: true}))
      other -> raise \"Could not unlike remote object: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote unlike target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_flag_uri() {
    local uri="$1"
    local comment="$2"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Social.Flags.flag(user, target,
           forward: true,
           comment: \"$comment\"
         ) do
      {:ok, result} -> IO.puts(Jason.encode!(%{ok: true, id: result.id}))
      other -> raise \"Could not flag remote object: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote report target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_poll_boolean() {
    local code="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(bonfire_rpc_value "$code" 2>/dev/null || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf 'Observed Bonfire RPC value: %s\n' "$result" >&2
    fail "$message"
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

assert_public_timeline_missing() {
    local text="$1"
    local message="$2"
    local result

    result="$(http_form GET "$BE_BASE/api/v1/timelines/public?limit=40" "" 200)"

    if JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

text = os.environ["EXPECTED_TEXT"]
for status in json.loads(os.environ["JSON_INPUT"]):
    if text in (status.get("content") or ""):
        raise SystemExit(1)
PY
    then
        return 0
    fi

    fail "$message"
}

# ------------------------------------------------------------------------------
# Native Bonfire state probes
# ------------------------------------------------------------------------------

# These probes call the same public application modules used by Bonfire's UI.
# They never write directly to Bonfire's tables, and they make the smoke test
# distinguish an accepted ActivityPub request from a real application change.

bonfire_local_follows_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} -> IO.puts(Bonfire.Social.Graph.Follows.following?(user, target))
  _other -> IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_remote_follows_local() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, follower} -> IO.puts(Bonfire.Social.Graph.Follows.following?(follower, user))
  _other -> IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_remote_follows_local_group() {
    local follower_uri="$1"
    local group_id="$2"
    local code

    code="
case Bonfire.Common.Needles.get(\"$group_id\", skip_boundary_check: true) do
  {:ok, group} ->
    case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$follower_uri\") do
      {:ok, follower} -> IO.puts(Bonfire.Social.Graph.Follows.following?(follower, group))
      _other -> IO.puts(false)
    end

  _other ->
    IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_local_liked_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} -> IO.puts(Bonfire.Social.Likes.liked?(user, target))
  _other -> IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_remote_blocks_local() {
    local actor_uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$actor_uri\") do
  {:ok, blocker} ->
    IO.puts(Bonfire.Boundaries.Blocks.is_blocked?(user, :any, current_user: blocker))

  _other ->
    IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_local_blocks_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    IO.puts(Bonfire.Boundaries.Blocks.is_blocked?(target, :any, current_user: user))

  _other ->
    IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_block_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Boundaries.Blocks.block(target, nil, current_user: user) do
      {:ok, _result} -> IO.puts(Jason.encode!(%{ok: true}))
      other -> raise \"Could not block remote target: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote block target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_unblock_uri() {
    local uri="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$uri\") do
  {:ok, target} ->
    case Bonfire.Boundaries.Blocks.unblock(target, nil, current_user: user) do
      {:ok, _result} -> IO.puts(Jason.encode!(%{ok: true}))
      other -> raise \"Could not unblock remote target: #{inspect(other)}\"
    end

  other ->
    raise \"Could not resolve remote unblock target: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_cached_object_exists() {
    local uri="$1"
    local code

    code="
case ActivityPub.Object.get_cached(ap_id: \"$uri\") do
  {:ok, object} -> IO.puts(object.data[\"type\"] not in [\"Delete\", \"Tombstone\"])
  _other -> IO.puts(false)
end
"

    bonfire_rpc_value "$code"
}

bonfire_create_local_group() {
    local name="$1"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")
attrs = %{
  name: \"$name\",
  type: :group,
  boundary: %{preset: \"public_local_community\"}
}

case Bonfire.Classify.Categories.create(user, attrs, true) do
  {:ok, group} ->
    actor_ap_id =
      case ActivityPub.Actor.get_cached(pointer: group) do
        {:ok, actor} -> actor.ap_id
        _other -> nil
      end

    IO.puts(Jason.encode!(%{
      actor_ap_id: actor_ap_id,
      canonical_url: Bonfire.Common.URIs.canonical_url(group, preload_if_needed: true),
      id: group.id,
      type: group.type
    }))

  other ->
    raise \"Could not create local Bonfire group: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_update_post() {
    local post_id="$1"
    local note="$2"
    local code

    code="
user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")

case Bonfire.Social.PostContents.edit(user, \"$post_id\", %{html_body: \"$note\"}) do
  {:ok, updated} ->
    IO.puts(Jason.encode!(%{id: updated.id, note: updated.html_body}))

  other ->
    raise \"Could not update ordinary post: #{inspect(other)}\"
end
"

    bonfire_rpc_value "$code"
}

bonfire_race_post_updates() {
    local post_id="$1"
    local first_note="$2"
    local second_note="$3"
    local code

    code="
results =
  [\"$first_note\", \"$second_note\"]
  |> Task.async_stream(
    fn note ->
      user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\")
      Bonfire.Social.PostContents.edit(user, \"$post_id\", %{html_body: note})
    end,
    max_concurrency: 2,
    ordered: false,
    timeout: 60_000
  )
  |> Enum.to_list()

if Enum.all?(results, &match?({:ok, {:ok, _updated}}, &1)) do
  IO.puts(Jason.encode!(%{ok: true, updates: length(results)}))
else
  raise \"Concurrent ordinary post updates failed: #{inspect(results)}\"
end
"

    bonfire_rpc_value "$code"
}

poll_relationship_not_following() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local message="$4"

    poll_json_assert \
        "http_form GET '$base/api/v1/accounts/relationships?id[]=$account_id' '$token' 200" \
        'len(data) >= 1 and data[0].get("following") is not True and data[0].get("requested") is not True' \
        "$message" >/dev/null
}

poll_be_group_membership() {
    local group_id="$1"
    local acct="$2"
    local expected="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET \
            "$BE_BASE/api/v1/groups/$group_id/memberships" "$ALICE_TOKEN" 200 || true)"

        if JSON_INPUT="$result" EXPECTED_ACCT="$acct" EXPECTED_PRESENT="$expected" \
            python3 - <<'PY'
import json
import os

memberships = json.loads(os.environ["JSON_INPUT"])
acct = os.environ["EXPECTED_ACCT"]
present = any(
    item.get("account", {}).get("acct") == acct
    for item in memberships
)
expected = os.environ["EXPECTED_PRESENT"] == "true"
raise SystemExit(0 if present == expected else 1)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_be_object_count() {
    local ap_id="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec -i "$BE_DB_CONTAINER" \
            psql -U postgres -d "$BE_DB_NAME" -Atq \
            -v "object_ap_id=$ap_id" <<'SQL' || true
SELECT COUNT(*) FROM objects WHERE data->>'id' = :'object_ap_id';
SQL
        )"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf 'Observed object count for %s: %s\n' "$ap_id" "$result" >&2
    fail "$message"
}

be_object_json() {
    local ap_id="$1"

    docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -v "object_ap_id=$ap_id" \
        -c "SELECT data::text FROM objects WHERE data->>'id' = :'object_ap_id' LIMIT 1;"
}

assert_remote_status_immutable() {
    local status_id="$1"
    local status body_file

    body_file="$WORK_DIR/remote-status-update-response.json"
    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X PUT \
        -H "Authorization: Bearer $ALICE_TOKEN" \
        -H 'Accept: application/json' \
        --form-string 'status=Unauthorized remote object rewrite' \
        "$BE_BASE/api/v1/statuses/$status_id" || true)"

    case "$status" in
        403|404|422)
            return 0
            ;;
    esac

    printf 'Unexpected remote status update response (%s):\n' "$status" >&2
    cat "$body_file" >&2 || true
    fail "Unfathomably allowed a local user to update a remote-owned object"
}

check_bonfire_logs() {
    #
    # Bonfire reports recoverable extension and subscription dispatch misses as
    # warning-level exception structs.  The measured stock Group, Like, and
    # GraphQL boundaries exercise those paths deliberately.  Preserve those
    # diagnostics while still rejecting process crashes and error-level runtime
    # exceptions.  Cooperation's periodic UI static-generator job raises a
    # stock ArgumentError when no static UI target is configured in this API
    # harness.  It is unrelated to federation and can occur only when a run
    # crosses the job's ten-minute boundary, so classify that exact worker
    # instead of making the smoke result depend on wall-clock timing.
    #
    if docker logs "$GTS_CONTAINER" 2>&1 |
        grep -Ei \
            'panic:|segmentation fault|(^|[[:space:]])fatal error|level=(fatal|FATAL)|\[fatal\]|\[error\].*(FunctionClauseError|MatchError|ArgumentError)' |
        grep -Fv 'worker: "Bonfire.UI.Common.StaticGenerator"' \
            >/dev/null; then
        docker logs "$GTS_CONTAINER" >&2 || true
        fail "Bonfire ValueFlows emitted an unclassified crash-level log line"
    fi
}

bonfire_local_url() {
    local canonical_url="$1"

    python3 - "$GTS_BASE" "$canonical_url" <<'PY'
import sys
import urllib.parse

base = sys.argv[1]
url = urllib.parse.urlsplit(sys.argv[2])
path = url.path or "/"
if url.query:
    path += "?" + url.query
print(base + path)
PY
}

# The integration matrix is assembled below these stock bootstrap helpers so
# that no test can accidentally run against a patched or synthetic peer.

run_bonfire_valueflows_smoke() {
    local nodeinfo_links nodeinfo_href nodeinfo actor_details bonfire_actor actor_json
    local actor_outbox outbox_json actor_followers followers_json webfinger
    local be_credentials alice_ap_id bonfire_account_id
    local be_group be_group_id be_group_ap_id group_memberships local_group local_group_id
    local local_group_actor local_group_actor_json local_group_status
    local local_group_account local_group_account_id local_group_follow local_group_relationship
    local event_note event_details event_id attempted_event_note updated_event deleted_event
    local be_text be_post be_post_id be_post_uri bonfire_comment_text
    local bonfire_comment bonfire_comment_id bonfire_comment_uri bonfire_comment_be_id
    local bonfire_text bonfire_post_body bonfire_post bonfire_post_id bonfire_post_uri
    local bonfire_status_id
    local post_race_note_a post_race_note_b final_post_note updated_post
    local resource_reference_count bonfire_origin_status
    local be_reply_text be_reply be_reply_id be_reply_uri
    local private_text private_post private_post_id private_status_id
    local bonfire_report_text be_report_text
    local be_block bonfire_local_block relationship

    write_be_secret
    write_proxy_configs

    log "Preparing pinned stock Bonfire Cooperation and ValueFlows"
    prepare_bonfire_image

    log "Creating isolated Bonfire ValueFlows federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BONFIRE_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$BONFIRE_DB_VOLUME" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null
    prepare_smoke_tls
    prepare_bonfire_ca_bundle

    log "Starting databases and stock Bonfire Cooperation"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e "POSTGRES_PASSWORD=$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_bonfire_valueflows
    wait_bonfire_valueflows

    log "Creating native Bonfire account"
    actor_details="$(bonfire_create_user)"
    bonfire_actor="$(json_get "$actor_details" canonical_url)"
    [ -n "$bonfire_actor" ] || fail "Bonfire did not return its canonical actor URL"

    log "Proving Bonfire discovery, content negotiation, and canonical HTTPS identity"
    nodeinfo_links="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo_href="$(json_get "$nodeinfo_links" links.0.href)"
    json_assert "$nodeinfo_links" \
        "len(data.get('links', [])) >= 1 and data.get('links', [])[0].get('href', '').startswith('https://$GTS_HOST/')" \
        "Bonfire NodeInfo discovery did not expose a canonical HTTPS endpoint"
    nodeinfo="$(http_form GET "$(bonfire_local_url "$nodeinfo_href")" "" 200)"
    json_assert "$nodeinfo" \
        "'bonfire' in data.get('software', {}).get('name', '').lower() and 'activitypub' in data.get('protocols', [])" \
        "Bonfire NodeInfo did not identify the stock federated application"

    webfinger="$(http_form GET \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" "" 200)"
    json_assert "$webfinger" \
        "data.get('subject') == 'acct:$GTS_USERNAME@$GTS_HOST' and any(item.get('href') == '$bonfire_actor' for item in data.get('links', []))" \
        "Bonfire WebFinger did not expose the canonical actor"

    actor_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(bonfire_local_url "$bonfire_actor")")"
    json_assert "$actor_json" \
        "data.get('id') == '$bonfire_actor' and data.get('type') == 'Person' and data.get('preferredUsername') == '$GTS_USERNAME'" \
        "Bonfire actor fetch did not return the stock Person"
    curl -fsS -H 'Accept: application/ld+json; profile="https://www.w3.org/ns/activitystreams"' \
        "$(bonfire_local_url "$bonfire_actor")" >/dev/null

    actor_outbox="$(json_get "$actor_json" outbox)"
    actor_followers="$(json_get "$actor_json" followers)"
    outbox_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(bonfire_local_url "$actor_outbox")")"
    followers_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$(bonfire_local_url "$actor_followers")")"
    json_assert "$outbox_json" \
        "data.get('type') in ['Collection', 'OrderedCollection'] and int(data.get('totalItems') or 0) >= 0" \
        "Bonfire outbox did not expose a bounded collection envelope"
    json_assert "$followers_json" \
        "data.get('type') in ['Collection', 'OrderedCollection'] and int(data.get('totalItems') or 0) >= 0" \
        "Bonfire followers endpoint did not expose a bounded collection envelope"

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
    bonfire_follow_uri "$alice_ap_id" >/dev/null
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, target} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"); IO.puts(Bonfire.Social.Graph.Follows.following?(user, target))" \
        true "Bonfire did not retain its outgoing Unfathomably follow"

    bonfire_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$GTS_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the Bonfire actor after its signed Follow")"
    http_form POST "$BE_BASE/api/v1/accounts/$bonfire_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$bonfire_account_id" \
        "Unfathomably's Bonfire follow was not accepted"
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, follower} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"); IO.puts(Bonfire.Social.Graph.Follows.following?(follower, user))" \
        true "Bonfire did not apply Unfathomably's incoming Follow"

    log "Following and unfollowing an Unfathomably Group from Bonfire"
    be_group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably Bonfire ValueFlows Group' \
        'name=unfathomably_bonfire_valueflows_group' \
        'note=Open group used by the Bonfire ValueFlows federation smoke harness.' \
        'locked=false')"
    be_group_id="$(json_get "$be_group" id)"
    be_group_ap_id="$(json_get "$be_group" ap_id)"
    bonfire_follow_uri "$be_group_ap_id" >/dev/null
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, target} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$be_group_ap_id\"); IO.puts(Bonfire.Social.Graph.Follows.following?(user, target))" \
        true "Bonfire did not retain its imported Group follow"
    poll_be_group_membership "$be_group_id" "$GTS_USERNAME@$GTS_HOST" true \
        "Unfathomably did not retain Bonfire's accepted Group membership"
    bonfire_unfollow_uri "$be_group_ap_id" >/dev/null
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, target} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$be_group_ap_id\"); IO.puts(Bonfire.Social.Graph.Follows.following?(user, target))" \
        false "Bonfire retained its imported Group follow after unfollow"
    poll_be_group_membership "$be_group_id" "$GTS_USERNAME@$GTS_HOST" false \
        "Unfathomably retained Bonfire's Group membership after Undo Follow"

    log "Proving stock Bonfire local Group discovery and its Follow boundary"
    local_group="$(bonfire_create_local_group \
        "Bonfire local group $(basename "$WORK_DIR")")"
    json_assert "$local_group" \
        "data.get('type') == 'group' and data.get('id') not in [None, ''] and data.get('canonical_url') not in [None, '']" \
        "Bonfire did not create its stock local Group application state"
    local_group_id="$(json_get "$local_group" id)"
    local_group_actor="$(json_get_optional "$local_group" actor_ap_id)"
    [ -n "$local_group_actor" ] || \
        fail "Stock Cooperation did not expose its local Group actor"
    local_group_status="$(curl -sS -o "$WORK_DIR/bonfire-local-group-ap.json" \
        -w '%{http_code}' -H 'Accept: application/activity+json' \
        "$(bonfire_local_url "$local_group_actor")" || true)"
    [ "$local_group_status" = "200" ] || \
        fail "Stock Cooperation local Group actor returned HTTP $local_group_status"
    local_group_actor_json="$(cat "$WORK_DIR/bonfire-local-group-ap.json")"
    json_assert "$local_group_actor_json" \
        "data.get('id') == '$local_group_actor' and data.get('type') == 'Group' and data.get('inbox') not in [None, ''] and data.get('outbox') not in [None, ''] and data.get('followers') not in [None, ''] and data.get('following') not in [None, ''] and data.get('publicKey') in [None, {}]" \
        "Stock Cooperation local Group actor did not retain its measured discovery boundary"

    local_group_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$local_group_actor" "Unfathomably could not import the Bonfire local Group actor")"
    local_group_account="$(http_form GET \
        "$BE_BASE/api/v1/accounts/$local_group_account_id" "$ALICE_TOKEN" 200)"
    json_assert "$local_group_account" \
        "data.get('pleroma', {}).get('ap_id') == '$local_group_actor' and 'Group' in data.get('pleroma', {}).get('actor_types', [])" \
        "Unfathomably did not retain Bonfire's native Group actor classification"

    local_group_follow="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$local_group_account_id/follow" "$ALICE_TOKEN" 200)"
    json_assert "$local_group_follow" \
        "data.get('requested') is True and data.get('following') is not True" \
        "Bonfire's incomplete local Group actor did not produce the expected pending Follow"
    sleep 5
    local_group_relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$local_group_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$local_group_relationship" \
        "len(data) >= 1 and data[0].get('requested') is True and data[0].get('following') is not True" \
        "Stock Bonfire unexpectedly accepted its local Group Follow"
    [ "$(bonfire_remote_follows_local_group "$alice_ap_id" "$local_group_id")" = "false" ] || \
        fail "Bonfire created a local Group follow edge without accepting the Follow"
    http_form POST "$BE_BASE/api/v1/accounts/$local_group_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_not_following "$BE_BASE" "$ALICE_TOKEN" "$local_group_account_id" \
        "Unfathomably retained the pending Bonfire local Group Follow after unfollow"

    log "Creating a native Bonfire ValueFlows EconomicEvent"
    event_note="Native Bonfire EconomicEvent $(basename "$WORK_DIR")"
    event_details="$(bonfire_create_economic_event "$event_note")"
    event_id="$(json_get "$event_details" event_id)"
    json_assert "$event_details" \
        "data.get('event_id') not in [None, ''] and data.get('action') == 'produce' and data.get('agreed_in') == 'https://resources.invalid/valueflows-smoke-agreement' and data.get('has_point_in_time') not in [None, ''] and data.get('note') == '$event_note' and data.get('valueflows_schema_loaded') is True and data.get('configured_root_schema') == 'Bonfire.API.GraphQL.Schema' and data.get('root_schema_loaded') is False" \
        "Bonfire's native ValueFlows state or measured outbound schema boundary changed"

    #
    # This pinned stock branch creates and updates the EconomicEvent in its
    # application database, but cannot serialize it for ActivityPub because
    # Cooperation no longer installs Bonfire.API.GraphQL.Schema.  Exercise the
    # native lifecycle boundary while leaving cross-peer coverage to stock Note
    # objects.  Update is expected to roll back when serialization fails.
    #
    attempted_event_note="Attempted EconomicEvent update $(basename "$WORK_DIR")"
    updated_event="$(bonfire_update_economic_event "$event_id" "$attempted_event_note")"
    json_assert "$updated_event" \
        "data.get('event_id') == '$event_id' and data.get('note') == '$event_note' and data.get('updated') is False and data.get('root_schema_loaded') is False" \
        "Bonfire's measured native EconomicEvent Update rollback changed"

    log "Testing an Unfathomably post, Bonfire Like boundary, and Bonfire reply lifecycle"
    be_text="Unfathomably post for Bonfire $(basename "$WORK_DIR")"
    be_post="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_text" 'visibility=public')"
    be_post_id="$(json_get "$be_post" id)"
    be_post_uri="$(json_get "$be_post" uri)"
    bonfire_like_uri "$be_post_uri" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Unfathomably did not receive Bonfire's Like"
    [ "$(bonfire_local_liked_uri "$be_post_uri")" = "true" ] || \
        fail "Bonfire did not retain its local Like"
    bonfire_unlike_uri "$be_post_uri" >/dev/null
    [ "$(bonfire_local_liked_uri "$be_post_uri")" = "false" ] || \
        fail "Bonfire retained its local Like after unlike"
    sleep 4
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Stock Bonfire unexpectedly emitted an Undo Like after its local unlike"

    bonfire_comment_text="Bonfire reply to Unfathomably $(basename "$WORK_DIR")"
    bonfire_comment="$(bonfire_create_post "$bonfire_comment_text" \
        "$be_post_uri" public)"
    bonfire_comment_id="$(json_get "$bonfire_comment" id)"
    bonfire_comment_uri="$(json_get "$bonfire_comment" canonical_url)"
    poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        "$bonfire_comment_text" "Unfathomably did not receive Bonfire's reply"
    bonfire_comment_be_id="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" \
        "$bonfire_comment_uri" "Unfathomably could not resolve Bonfire's reply")"
    bonfire_delete_post "$bonfire_comment_id" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$bonfire_comment_be_id" \
        "Unfathomably retained Bonfire's deleted reply"

    log "Testing a Bonfire post and Unfathomably reply lifecycle"
    bonfire_text="Bonfire post to Unfathomably $(basename "$WORK_DIR")"
    bonfire_post_body="$bonfire_text https://resources.invalid/bonfire-smoke-resource"
    bonfire_post="$(bonfire_create_post \
        "$bonfire_post_body @alice@$BE_HOST" "" public 4)"
    bonfire_post_id="$(json_get "$bonfire_post" id)"
    bonfire_post_uri="$(json_get "$bonfire_post" canonical_url)"
    json_assert "$bonfire_post" \
        "data.get('redeliveries') == 4 and data.get('redelivery_ok') is True" \
        "Bonfire could not queue four concurrent stock Note redeliveries"
    bonfire_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$bonfire_text" "Unfathomably did not receive Bonfire's ordinary post")"
    poll_be_object_count "$bonfire_post_uri" 1 \
        "Concurrent stock Note delivery created duplicate canonical objects"
    resource_reference_count="$(docker exec "$BE_DB_CONTAINER" psql -U postgres \
        -d "$BE_DB_NAME" -Atq \
        -c "SELECT COUNT(*) FROM objects WHERE data->>'id' = 'https://resources.invalid/bonfire-smoke-resource';")"
    [ "$resource_reference_count" = "0" ] || \
        fail "Unfathomably recursively materialized an external Bonfire post link"

    log "Testing racing stock Note Updates and an authoritative final Update"
    post_race_note_a="Racing Bonfire Note update A $(basename "$WORK_DIR")"
    post_race_note_b="Racing Bonfire Note update B $(basename "$WORK_DIR")"
    bonfire_race_post_updates \
        "$bonfire_post_id" "$post_race_note_a" "$post_race_note_b" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/statuses/$bonfire_status_id' '$ALICE_TOKEN' 200" \
        "'$post_race_note_a' in (data.get('content') or '') or '$post_race_note_b' in (data.get('content') or '')" \
        "Unfathomably did not converge after racing stock Note Updates" >/dev/null

    final_post_note="Final authoritative Bonfire Note update $(basename "$WORK_DIR")"
    updated_post="$(bonfire_update_post "$bonfire_post_id" "$final_post_note")"
    json_assert "$updated_post" \
        "data.get('id') == '$bonfire_post_id' and '$final_post_note' in (data.get('note') or '')" \
        "Bonfire did not retain the authoritative stock Note Update"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/statuses/$bonfire_status_id' '$ALICE_TOKEN' 200" \
        "'$final_post_note' in (data.get('content') or '')" \
        "Unfathomably did not apply the authoritative stock Note Update" >/dev/null
    poll_be_object_count "$bonfire_post_uri" 1 \
        "Racing stock Note Updates duplicated the canonical object"
    assert_remote_status_immutable "$bonfire_status_id"

    log "Testing incoming Like and Undo Like against Bonfire application state"
    http_form POST "$BE_BASE/api/v1/statuses/$bonfire_status_id/favourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    bonfire_poll_boolean \
        "with {:ok, actor} <- Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"), {:ok, target} <- Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$bonfire_post_uri\") do IO.puts(Bonfire.Social.Likes.liked?(actor, target)) else _ -> IO.puts(false) end" \
        true "Bonfire did not apply Unfathomably's incoming Like"
    http_form POST "$BE_BASE/api/v1/statuses/$bonfire_status_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    bonfire_poll_boolean \
        "with {:ok, actor} <- Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"), {:ok, target} <- Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$bonfire_post_uri\") do IO.puts(Bonfire.Social.Likes.liked?(actor, target)) else _ -> IO.puts(false) end" \
        false "Bonfire did not apply Unfathomably's incoming Undo Like"

    be_reply_text="Unfathomably reply to Bonfire $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" "in_reply_to_id=$bonfire_status_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    bonfire_poll_boolean \
        "case ActivityPub.Object.get_cached(ap_id: \"$be_reply_uri\") do {:ok, object} -> IO.puts(object.data[\"type\"] not in [\"Delete\", \"Tombstone\"]); _ -> IO.puts(false) end" \
        true "Bonfire accepted the reply without retaining it"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" \
        "$ALICE_TOKEN" 200 >/dev/null
    bonfire_poll_boolean \
        "case ActivityPub.Object.get_cached(ap_id: \"$be_reply_uri\") do {:ok, object} -> IO.puts(object.data[\"type\"] not in [\"Delete\", \"Tombstone\"]); _ -> IO.puts(false) end" \
        false "Bonfire retained the deleted Unfathomably reply"

    log "Testing federated moderation actions in both directions"
    bonfire_report_text="Bonfire moderation report $(basename "$WORK_DIR")"
    bonfire_flag_uri "$be_post_uri" "$bonfire_report_text" >/dev/null
    poll_be_report_by_text "$bonfire_report_text" \
        "Unfathomably did not receive Bonfire's federated Flag"

    be_report_text="Unfathomably moderation report $(basename "$WORK_DIR")"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$bonfire_account_id" \
        "status_ids[]=$bonfire_status_id" \
        "comment=$be_report_text" \
        'forward=true' >/dev/null
    bonfire_poll_boolean \
        "with {:ok, actor} <- Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"), {:ok, target} <- Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$bonfire_post_uri\") do IO.puts(Bonfire.Social.Flags.flagged?(actor, target)) else _ -> IO.puts(false) end" \
        true "Bonfire did not retain Unfathomably's Flag in application moderation state"

    log "Testing Unfathomably top-level Delete while Bonfire remains a follower"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_post_id" \
        "$ALICE_TOKEN" 200 >/dev/null
    bonfire_poll_boolean \
        "case ActivityPub.Object.get_cached(ap_id: \"$be_post_uri\") do {:ok, object} -> IO.puts(object.data[\"type\"] not in [\"Delete\", \"Tombstone\"]); _ -> IO.puts(false) end" \
        false "Bonfire retained the deleted Unfathomably top-level post"

    log "Testing mention-restricted delivery and public-cache exclusion"
    private_text="Restricted Bonfire message $(basename "$WORK_DIR")"
    private_post="$(bonfire_create_post \
        "$private_text @alice@$BE_HOST" "" mentions)"
    private_post_id="$(json_get "$private_post" id)"
    private_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$private_text" "Unfathomably did not receive the restricted Bonfire message")"
    assert_public_timeline_missing "$private_text" \
        "Unfathomably leaked the restricted Bonfire message onto its public timeline"
    bonfire_delete_post "$private_post_id" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$private_status_id" \
        "Unfathomably retained the deleted restricted Bonfire message"

    log "Testing explicit Person unfollows in both directions"
    http_form POST "$BE_BASE/api/v1/accounts/$bonfire_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    bonfire_unfollow_uri "$alice_ap_id" >/dev/null
    poll_relationship_not_following "$BE_BASE" "$ALICE_TOKEN" "$bonfire_account_id" \
        "Unfathomably retained its Bonfire follow after unfollow"
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, target} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"); IO.puts(Bonfire.Social.Graph.Follows.following?(user, target))" \
        false "Bonfire retained its outgoing Unfathomably follow after unfollow"
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, follower} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"); IO.puts(Bonfire.Social.Graph.Follows.following?(follower, user))" \
        false "Bonfire retained Unfathomably's incoming follow after Undo Follow"

    log "Testing incoming Block and Undo Block at Bonfire"
    be_block="$(http_form POST "$BE_BASE/api/v1/accounts/$bonfire_account_id/block" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_block" 'data.get("blocking") is True' \
        "Unfathomably did not create its Bonfire block"
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, blocker} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"); IO.puts(Bonfire.Boundaries.Blocks.is_blocked?(user, :any, current_user: blocker))" \
        true "Bonfire did not apply Unfathomably's incoming Block"
    http_form POST "$BE_BASE/api/v1/accounts/$bonfire_account_id/unblock" \
        "$ALICE_TOKEN" 200 >/dev/null
    bonfire_poll_boolean \
        "user = Bonfire.Me.Users.by_username!(\"$GTS_USERNAME\"); {:ok, blocker} = Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(\"$alice_ap_id\"); IO.puts(Bonfire.Boundaries.Blocks.is_blocked?(user, :any, current_user: blocker))" \
        false "Bonfire did not apply Unfathomably's incoming Undo Block"

    log "Proving Bonfire's local block is a local boundary, not an outgoing AP Block"
    bonfire_local_block="$(bonfire_block_uri "$alice_ap_id")"
    json_assert "$bonfire_local_block" 'data.get("ok") is True' \
        "Bonfire did not create its local block"
    [ "$(bonfire_local_blocks_uri "$alice_ap_id")" = "true" ] || \
        fail "Bonfire did not retain its local block boundary"
    sleep 4
    relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$bonfire_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        "len(data) >= 1 and data[0].get('blocked_by') is not True" \
        "Stock Bonfire unexpectedly emitted an ActivityPub Block for its local boundary"
    bonfire_unblock_uri "$alice_ap_id" >/dev/null
    [ "$(bonfire_local_blocks_uri "$alice_ap_id")" = "false" ] || \
        fail "Bonfire retained its local block after unblock"

    log "Testing top-level Deletes and terminal missing-object behavior"
    bonfire_delete_post "$bonfire_post_id" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$bonfire_status_id" \
        "Unfathomably retained Bonfire's deleted top-level post"
    bonfire_origin_status="$(curl -sS \
        -o "$WORK_DIR/bonfire-deleted-post.json" -w '%{http_code}' \
        -H 'Accept: application/activity+json' \
        "$(bonfire_local_url "$bonfire_post_uri")" || true)"
    case "$bonfire_origin_status" in
        404|410)
            ;;
        200)
            json_assert "$(cat "$WORK_DIR/bonfire-deleted-post.json")" \
                "data.get('id') == '$bonfire_post_uri' and data.get('type') == 'Tombstone' and data.get('formerType') == 'Note' and data.get('deleted') not in [None, ''] and data.get('content') in [None, '']" \
                "Bonfire's HTTP 200 response did not contain a non-leaking Tombstone"
            ;;
        *)
            fail "Deleted Bonfire post returned unexpected HTTP $bonfire_origin_status"
            ;;
    esac
    deleted_event="$(bonfire_delete_economic_event "$event_id")"
    json_assert "$deleted_event" \
        "data.get('deleted') is False and data.get('event_id') == '$event_id' and data.get('delete_activity_api_available') is False" \
        "Bonfire's measured native EconomicEvent Delete rollback changed"
    bonfire_poll_boolean \
        "case ValueFlows.EconomicEvent.EconomicEvents.one(id: \"$event_id\") do {:ok, event} -> IO.puts(is_nil(event.deleted_at)); _other -> IO.puts(false) end" \
        true "Bonfire did not retain the EconomicEvent after its stock Delete rollback"

    local repeated_delete_status
    repeated_delete_status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer $ALICE_TOKEN" \
        "$BE_BASE/api/v1/statuses/$be_post_id" || true)"
    case "$repeated_delete_status" in
        404|410)
            ;;
        *)
            fail "Repeated local Delete did not terminate safely with 404 or 410"
            ;;
    esac

    local missing_origin_status
    missing_origin_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/activity+json' \
        "$GTS_BASE/pub/objects/00000000000000000000000000" || true)"
    [ "$missing_origin_status" = "404" ] || [ "$missing_origin_status" = "410" ] || \
        fail "Bonfire did not classify an absent ActivityPub object as terminal"

    group_memberships="$(http_form GET \
        "$BE_BASE/api/v1/groups/$be_group_id/memberships" "$ALICE_TOKEN" 200)"
    json_assert "$group_memberships" \
        "not any(item.get('account', {}).get('acct') == '$GTS_USERNAME@$GTS_HOST' for item in data)" \
        "Final cleanup retained Bonfire's remote Group membership"

    check_logs "$BE_CONTAINER" Unfathomably
    check_bonfire_logs

    cat <<EOF

Bonfire ValueFlows federation smoke passed.

Pinned stock sources:
* bonfire-app: $BONFIRE_APP_SOURCE_COMMIT
* cooperation: $BONFIRE_COOPERATION_SOURCE_COMMIT
* bonfire_valueflows: $BONFIRE_VALUEFLOWS_SOURCE_COMMIT

Alien ActivityPub matrix:
* Discovery: supported; WebFinger, actor fetch, both ActivityPub media types, NodeInfo, and canonical HTTPS IDs passed
* Native representation: stock_limitation; the native EconomicEvent retained action, point-in-time, agreement, and note in Bonfire application state, but Cooperation omits its configured Bonfire.API.GraphQL.Schema and cannot serialize the event for ActivityPub
* Compatibility representation: not_supported; the failing stock ValueFlows serializer emits neither its native object nor a fallback Note, Article, or Page, and the test does not invent one
* Semantic deduplication: supported for the available stock Note representation; four concurrent redeliveries retained one canonical object and status
* Authority: supported for the available stock Note representation; Bonfire's authorized Update succeeded and a local non-owner could not rewrite the remote object
* Lifecycle: supported where stock paths exist; Note Create, racing Update, deterministic Update, Delete, Follow, Undo Follow, Like, Undo Like, Flag, Block, and Undo Block converged across peers
* Concurrency: supported for the available stock Note representation; two racing Updates retained one canonical object and a later authoritative Update converged
* Collections: supported; actor outbox and followers expose bounded Collection or OrderedCollection envelopes
* Context: supported for replies; stock Note reply context changed each native application, while EconomicEvent coordination context is blocked by the missing stock serializer
* Capabilities: stock_limitation; no native EconomicEvent can reach Unfathomably from this stock branch, so the native read-only controls cannot be exercised end to end
* Round trip: supported where stock paths exist; follows, replies, Likes, Flags, Blocks, and their supported Undos changed native application state
* Unknown JSON-LD: stock_limitation; agreedIn survived in Bonfire native state, but the missing stock serializer prevents an honest cross-peer preservation assertion
* Privacy: supported; a mention-restricted Bonfire message reached its recipient and stayed off the public timeline
* Idempotence: supported for the available stock Note representation; concurrent duplicate delivery, one canonical object, convergent deletion, and terminal repeated deletion passed
* Failure classification: supported; missing resources terminated as 404 or 410, while deleted Bonfire Notes returned a non-leaking HTTP 200 Tombstone without fatal or error-level crash-class logs
* Resource safety: supported for the available stock Note representation; an external link remained content and was not recursively materialized as an ActivityPub object
* UI classification: stock_limitation; the stock peer cannot deliver its EconomicEvent to the UI, so real-instance classification is unavailable at this boundary
* Cleanup: supported for federated stock paths; Person and Group unfollows, post and reply Deletes, Undo Block, and disposable service cleanup passed

Relationship and moderation boundaries:
* supported: Person follows and unfollows in both directions
* supported: Bonfire follows and unfollows an imported Unfathomably Group with application-state and membership verification
* stock_limitation: Bonfire exposes and Unfathomably imports its local Group actor, but the actor omits publicKey and Bonfire cannot resolve the Category-backed Group when receiving Follow, so no Accept or native edge is created
* supported: ordinary posts, comments, comment Deletes, top-level Deletes, incoming Likes and Undo Likes
* stock_limitation: native EconomicEvent Create commits locally, but Update rolls back on the missing GraphQL serializer and Delete rolls back because the pinned stock Bonfire.Social.APActivities module has no create/3 function
* stock_limitation: Bonfire local unlike removes its edge but does not emit Undo Like, so the remote Like remains until target cleanup
* supported: federated Flags from each peer become native moderation state on the other
* supported: incoming Block and Undo Block change Bonfire boundary state
* stock_limitation: Bonfire's local user block is an internal boundary and emits no ActivityPub Block
* stock_limitation: Cooperation's periodic Bonfire.UI.Common.StaticGenerator cron raises ArgumentError without a configured static UI target; the failure is isolated from federation and retained in the adapter log
* not_supported: stock Bonfire provides no durable signal by which a blocked or defederated peer can know it was defederated
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_bonfire_valueflows_smoke
fi

# end of build_scripts/unfathomably-bonfire-valueflows-smoke.sh

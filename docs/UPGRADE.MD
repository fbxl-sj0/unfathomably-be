# Upgrading to Unfathomably

This guide covers source installs that currently run either:

- Rebased with Soapbox
- Pleroma

The target system is:

- Backend: `https://github.com/fbxl-sj0/unfathomably-be`
- Frontend: `https://github.com/fbxl-sj0/unfathomably-fe`

Unfathomably keeps the Pleroma OTP application name, database layout,
configuration keys, service conventions, and many `mix pleroma.*` commands.
That compatibility is intentional. In the commands below the Unix user,
database, systemd service, and helper command are still named `pleroma`.

These instructions were rehearsed with database-backed configuration enabled,
because that is the most common admin-UI setup and the safest way to switch the
primary frontend without hand-editing production config.

## 1. Before You Start

Set these variables for your server:

```sh
export DOMAIN=social.example.com
export DB_NAME=pleroma
export DB_USER=pleroma
export BACKUP_DIR=/root/unfathomably-upgrade-$(date -u +%Y%m%d-%H%M%S)
```

Check available disk, memory, and swap before compiling:

```sh
df -h
free -h
swapon --show
```

Source builds can use a lot of memory. If the machine has no swap, add a
temporary swapfile before building:

```sh
if [ "$(swapon --noheadings | wc -l)" -eq 0 ]; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 0600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
```

## 2. Back Up the Existing Instance

Stop the service so the database dump and source/config snapshot agree:

```sh
sudo systemctl stop pleroma
```

Create a database and filesystem backup:

```sh
sudo mkdir -p "$BACKUP_DIR"

sudo -u postgres pg_dump -Fc "$DB_NAME" >"$BACKUP_DIR/${DB_NAME}.dump"

sudo rsync -a /opt/pleroma/ "$BACKUP_DIR/pleroma-source/"
sudo rsync -a /var/lib/pleroma/ "$BACKUP_DIR/pleroma-data/"
```

If your existing frontend lives outside `/var/lib/pleroma`, back that path up
too. Older Soapbox instructions sometimes placed files under an `instance`
directory in the source tree.

Record the current version:

```sh
cd /opt/pleroma
sudo -Hu pleroma env MIX_ENV=prod mix pleroma.version || true
git rev-parse --short HEAD || true
```

## 3. Ensure the Runtime Helper Exists

The upgrade commands assume a helper that runs commands as the `pleroma` user
with the production environment and asdf shims on `PATH`:

```sh
sudo tee /usr/local/bin/pleroma-run >/dev/null <<'SH'
#!/bin/sh
exec sudo -Hu pleroma env \
  HOME=/var/lib/pleroma \
  PATH=/var/lib/pleroma/bin:/var/lib/pleroma/.asdf/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  MIX_ENV=prod \
  "$@"
SH

sudo chmod 0755 /usr/local/bin/pleroma-run
```

If you already have an equivalent helper, keep using it. The important parts
are `HOME=/var/lib/pleroma`, `MIX_ENV=prod`, and the asdf shim path.

## 4. Install or Update asdf

Unfathomably BE and FE both carry `.tool-versions` files. Use them as the
runtime source of truth.

```sh
pleroma-run bash -lc '
set -eu
mkdir -p "$HOME/bin" "$HOME/src"

if [ ! -x "$HOME/bin/asdf" ]; then
  ASDF_VERSION=v0.19.0

  case "$(uname -m)" in
    x86_64)
      ASDF_ARCH=amd64
      ;;
    aarch64|arm64)
      ASDF_ARCH=arm64
      ;;
    *)
      echo "Unsupported asdf Linux architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  curl -fsSL \
    -o /tmp/asdf.tar.gz \
    "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-${ASDF_ARCH}.tar.gz"

  tar -xzf /tmp/asdf.tar.gz -C "$HOME/bin"
  chmod 0755 "$HOME/bin/asdf"
  rm -f /tmp/asdf.tar.gz
fi
'

pleroma-run bash -lc 'asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git || asdf plugin update erlang'
pleroma-run bash -lc 'asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git || asdf plugin update elixir'
pleroma-run bash -lc 'asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git || asdf plugin update nodejs'
```

## 5. Replace the Backend Source

Move the old backend source aside, then clone Unfathomably BE into the normal
backend path:

```sh
sudo mv /opt/pleroma /opt/pleroma-before-unfathomably
sudo mkdir -p /opt/pleroma
sudo chown pleroma:pleroma /opt/pleroma

sudo -Hu pleroma git clone https://github.com/fbxl-sj0/unfathomably-be.git /opt/pleroma
sudo cp /opt/pleroma-before-unfathomably/config/prod.secret.exs /opt/pleroma/config/prod.secret.exs
sudo chown -R pleroma:pleroma /opt/pleroma
```

If your old install used extra imported config files, copy those too, or merge
their settings into `config/prod.secret.exs`.

Install the backend runtime, dependencies, compile, and migrate:

```sh
cd /opt/pleroma
pleroma-run env MAKEFLAGS=-j2 asdf install
pleroma-run asdf reshim
pleroma-run mix local.hex --force
pleroma-run mix local.rebar --force
pleroma-run mix deps.get --only prod
pleroma-run mix compile
pleroma-run mix ecto.migrate
```

Do not run `migrate_to_db` again during an ordinary upgrade unless you changed
file config and intentionally want to import those changes into the config
table. Existing database-backed settings remain in the database.

## 6. Build and Enable Unfathomably FE

Build the frontend from the public repository:

```sh
sudo rm -rf /opt/unfathomably-fe
sudo mkdir -p /opt/unfathomably-fe
sudo chown pleroma:pleroma /opt/unfathomably-fe

sudo -Hu pleroma git clone https://github.com/fbxl-sj0/unfathomably-fe.git /opt/unfathomably-fe

cd /opt/unfathomably-fe
pleroma-run asdf install
pleroma-run asdf reshim
pleroma-run bash -lc 'command -v corepack >/dev/null || { npm install -g corepack && asdf reshim nodejs; }'
pleroma-run npm exec -- corepack yarn install --immutable
pleroma-run env NODE_OPTIONS=--max-old-space-size=4096 npm exec -- corepack yarn build
```

Install the built files under the backend static frontend directory:

```sh
sudo mkdir -p /var/lib/pleroma/static/frontends/unfathomably-fe/current

sudo rsync -a --delete \
  /opt/unfathomably-fe/dist/ \
  /var/lib/pleroma/static/frontends/unfathomably-fe/current/

sudo chown -R pleroma:pleroma /var/lib/pleroma/static/frontends/unfathomably-fe
```

If database-backed configuration is enabled, enable the frontend with the Mix
task:

```sh
cd /opt/pleroma
pleroma-run mix pleroma.frontend enable unfathomably-fe --ref current --primary
```

If database-backed configuration is not enabled, add this to
`/opt/pleroma/config/prod.secret.exs` instead:

```elixir
config :pleroma, :frontends,
  primary: %{
    "name" => "unfathomably-fe",
    "ref" => "current"
  }
```

## 7. Start and Smoke Test

Start the service:

```sh
sudo systemctl daemon-reload
sudo systemctl start pleroma
sudo systemctl status pleroma --no-pager
```

Run local probes from the server:

```sh
curl -fsS http://127.0.0.1:4000/.well-known/nodeinfo
curl -fsS http://127.0.0.1:4000/nodeinfo/2.1.json
curl -fsS http://127.0.0.1:4000/api/v1/instance
curl -fsS http://127.0.0.1:4000/ | head
```

The instance API should identify `unfathomably-be` and include
Unfathomably-specific features such as `groups`, `groups_discovery`,
`groups_search`, `sources`, `bookmark_folders`, and `notifications_v2`.

Check the browser through the public hostname after nginx is pointed at the
backend:

```sh
curl -fsSI "https://$DOMAIN/"
curl -fsS "https://$DOMAIN/.well-known/nodeinfo"
```

## 8. Rebased plus Soapbox Notes

For a Rebased install, the upgrade path is usually direct:

1. Back up `/opt/pleroma`, `/var/lib/pleroma`, and the database.
2. Stop `pleroma`.
3. Replace `/opt/pleroma` with `unfathomably-be`.
4. Copy `config/prod.secret.exs` from the Rebased source tree.
5. Compile and migrate.
6. Build `unfathomably-fe`.
7. Enable `unfathomably-fe` as the primary frontend.
8. Start and smoke test.

You do not need to rebuild old Soapbox to upgrade a live Rebased/Soapbox
server. The rehearsal did build and boot old Soapbox first to prove the source
upgrade from that stack, but a real production upgrade only needs the existing
database, config, uploads, static data, and old source snapshot.

If your Rebased install used Soapbox artifact files directly under an
`instance` directory, leave that backup in place. The new primary frontend will
be read from `/var/lib/pleroma/static/frontends/unfathomably-fe/current` once it
is enabled.

## 9. Pleroma Notes

For a plain Pleroma install, the backend upgrade steps are the same, but there
are two common differences:

- Older source installs may not have a `.tool-versions` file. That only matters
  for building the old baseline. After cloning Unfathomably BE, use
  Unfathomably BE's `.tool-versions`.
- Some Pleroma installs keep frontend config in files rather than in the
  database. Use the file-config snippet in section 6 if
  `mix pleroma.frontend enable ...` says database configuration is disabled.

The rehearsal path used upstream Pleroma `v2.6.3` with
`configurable_from_database: true`, then upgraded the same database to
Unfathomably BE and installed Unfathomably FE as the primary frontend.

## 10. Optional OpenTranslate After Upgrade

If you want translation support, configure OpenTranslate after the backend is
upgraded. The full service setup is in `docs/INSTALLATION.MD`.

The backend config shape is:

```elixir
config :pleroma, Pleroma.Language.Translation,
  provider: Pleroma.Language.Translation.Opentranslate,
  allow_unauthenticated: false,
  allow_remote: true

config :pleroma, Pleroma.Language.Translation.Opentranslate,
  base_url: "http://127.0.0.1:5000",
  api_key: nil
```

If these keys are managed through database-backed configuration, update them
through the admin UI or import the changed file config intentionally.

## 11. Rollback

Schema migrations are forward-only. For a real rollback, restore both the old
source tree and the database dump:

```sh
sudo systemctl stop pleroma

sudo rm -rf /opt/pleroma
sudo mv /opt/pleroma-before-unfathomably /opt/pleroma
sudo chown -R pleroma:pleroma /opt/pleroma

sudo -u postgres dropdb "$DB_NAME"
sudo -u postgres createdb "$DB_NAME"
sudo -u postgres pg_restore -d "$DB_NAME" "$BACKUP_DIR/${DB_NAME}.dump"

sudo systemctl start pleroma
```

If you only need to roll back the frontend after the backend upgrade succeeded,
switch the primary frontend back to the old frontend in database config or
`prod.secret.exs`, then restart.

## 12. Rehearsal Results

The documented path was rehearsed in Docker with:

- Rebased `main` plus Soapbox `v3.2.0`, database-backed config, then
  Unfathomably BE and FE.
- Pleroma `v2.6.3`, database-backed config, then Unfathomably BE and FE.

The required pass condition is that the upgraded service starts under systemd
and answers:

```sh
curl -fsS http://127.0.0.1:4000/.well-known/nodeinfo
curl -fsS http://127.0.0.1:4000/api/v1/instance
curl -fsS http://127.0.0.1:4000/
```

<!-- end of UPGRADE.MD -->

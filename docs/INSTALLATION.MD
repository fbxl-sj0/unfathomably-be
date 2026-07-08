# Installing Unfathomably From Source

This guide installs a complete Unfathomably instance from the public source
repositories:

- Backend: `https://github.com/unfathomably/unfathomably-be`
- Frontend: `https://github.com/unfathomably/unfathomably-fe`

The backend still uses the Pleroma OTP application name, configuration keys,
database layout, and many inherited command names. That compatibility is
intentional. In this document, `pleroma` is the Unix service user and several
commands still start with `mix pleroma.*`, even though the installed software is
Unfathomably.

The commands below assume a fresh Debian 12 or Ubuntu 24.04 style server, a
single public hostname, PostgreSQL on the same host, nginx as the TLS reverse
proxy, and OpenTranslate-compatible translation served privately on localhost.

Replace these example values before running commands:

```sh
export DOMAIN=social.example.com
export INSTANCE_NAME="Example Social"
export ADMIN_EMAIL=admin@example.com
export NOTIFY_EMAIL=noreply@example.com
export DB_NAME=pleroma
export DB_USER=pleroma
export DB_PASS="change-this-password"
```

## 1. Install System Packages

```sh
sudo apt update

sudo apt install -y \
  autoconf \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  ffmpeg \
  git \
  gnupg \
  imagemagick \
  libimage-exiftool-perl \
  libmagic-dev \
  libncurses-dev \
  libssl-dev \
  libssh-dev \
  libvips-dev \
  libxml2-utils \
  m4 \
  nginx \
  openssl \
  postgresql \
  postgresql-contrib \
  python3 \
  python3-certbot-nginx \
  rsync \
  sudo \
  tar \
  unzip \
  unixodbc-dev \
  xsltproc
```

If your Erlang build asks for extra optional libraries, install the distribution
equivalents and rerun `asdf install`. The required runtime path does not need wx
or Java, but some Erlang builds probe for them.

Start PostgreSQL after package installation:

```sh
sudo systemctl enable --now postgresql
```

Source builds can briefly use a lot of memory, especially Erlang and the Vite
frontend build. If the machine has no swap, add a small swapfile before building
so the kernel does not kill unrelated services under transient pressure:

```sh
if [ "$(swapon --noheadings | wc -l)" -eq 0 ]; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 0600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
```

## 2. Create the Service User and Directories

```sh
sudo useradd -r -m -d /var/lib/pleroma -s /bin/bash -U pleroma

sudo mkdir -p \
  /opt/pleroma \
  /opt/unfathomably-fe \
  /var/lib/pleroma/uploads \
  /var/lib/pleroma/static

sudo chown -R pleroma:pleroma \
  /opt/pleroma \
  /opt/unfathomably-fe \
  /var/lib/pleroma
```

The source trees live in `/opt`. Mutable uploads and static runtime files live
under `/var/lib/pleroma`, which keeps updates from mixing source code with site
data.

Create a small helper so the rest of the commands run with the same environment
that systemd will use:

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

## 3. Clone the Backend

```sh
sudo -Hu pleroma git clone https://github.com/unfathomably/unfathomably-be /opt/pleroma
```

## 4. Install Erlang and Elixir With asdf

Unfathomably BE carries a `.tool-versions` file. Use it as the source of truth
for the exact Erlang and Elixir versions.

```sh
sudo -Hu pleroma bash -lc '
set -e

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

cd /opt/pleroma
pleroma-run env MAKEFLAGS=-j2 asdf install
pleroma-run asdf reshim

pleroma-run mix local.hex --force
pleroma-run mix local.rebar --force
pleroma-run mix deps.get --only prod
```

## 5. Generate the Backend Configuration

The instance generator writes a private Phoenix config and a PostgreSQL setup
script. Keep both out of Git.

```sh
cd /opt/pleroma

pleroma-run mix pleroma.instance gen \
  --domain "$DOMAIN" \
  --instance-name "$INSTANCE_NAME" \
  --admin-email "$ADMIN_EMAIL" \
  --notify-email "$NOTIFY_EMAIL" \
  --dbhost localhost \
  --dbname "$DB_NAME" \
  --dbuser "$DB_USER" \
  --dbpass "$DB_PASS" \
  --indexable y \
  --listen-ip 127.0.0.1 \
  --listen-port 4000 \
  --uploads-dir /var/lib/pleroma/uploads \
  --static-dir /var/lib/pleroma/static

sudo -Hu pleroma mv /opt/pleroma/config/generated_config.exs /opt/pleroma/config/prod.secret.exs
sudo chmod 0640 /opt/pleroma/config/prod.secret.exs
```

Append the Unfathomably-specific production services you want enabled:

```sh
sudo -Hu pleroma tee -a /opt/pleroma/config/prod.secret.exs >/dev/null <<'EOF'

# OpenTranslate-compatible translation service.
config :pleroma, Pleroma.Language.Translation,
  provider: Pleroma.Language.Translation.Opentranslate,
  allow_unauthenticated: false,
  allow_remote: true

config :pleroma, Pleroma.Language.Translation.Opentranslate,
  base_url: "http://127.0.0.1:5000",
  api_key: nil
EOF
```

If you use database-backed configuration, later changes from the admin UI will
override matching entries in this file. Keep this file as the base config that
lets the application boot.

## 6. Create and Migrate the Database

```sh
sudo -u postgres psql -f /opt/pleroma/config/setup_db.psql

cd /opt/pleroma
pleroma-run mix compile
pleroma-run mix ecto.migrate
pleroma-run mix pleroma.config migrate_to_db
```

`migrate_to_db` is expected because the generated config enables
database-backed configuration. It lets the admin UI manage runtime settings
without requiring every setting change to be a file edit.

## 7. Install OpenTranslate

Unfathomably talks to the OpenTranslate provider through a LibreTranslate-style
HTTP API. The service should stay private to the host. Do not publish port 5000
through nginx.

Install Docker if it is not already present:

```sh
sudo apt install -y docker.io
sudo systemctl enable --now docker
```

Create persistent model and database directories:

```sh
sudo mkdir -p /var/lib/opentranslate/home /var/lib/opentranslate/db
sudo chmod 0777 /var/lib/opentranslate/home /var/lib/opentranslate/db
```

Install a practical source-to-English model set:

```sh
sudo docker run --rm \
  --entrypoint sh \
  -v /var/lib/opentranslate/home:/home/libretranslate \
  -v /var/lib/opentranslate/db:/app/db \
  libretranslate/libretranslate:latest \
  -lc '
/app/venv/bin/python3 - <<PY
import argostranslate.package

sources = ["ar", "de", "en", "es", "fr", "ga", "hi", "it", "ja", "ko", "pl", "pt", "ru", "zh"]
target = "en"

argostranslate.package.update_package_index()
packages = argostranslate.package.get_available_packages()

for source in sources:
    if source == target:
        continue

    matches = [
        package for package in packages
        if package.from_code == source and package.to_code == target
    ]

    if not matches:
        print(f"missing model {source}->{target}")
        continue

    package = matches[0]
    print(f"installing {source}->{target}")
    argostranslate.package.install_from_path(package.download())
PY
'
```

Start OpenTranslate on localhost only:

```sh
sudo docker run -d \
  --name opentranslate \
  --restart unless-stopped \
  -v /var/lib/opentranslate/home:/home/libretranslate \
  -v /var/lib/opentranslate/db:/app/db \
  -p 127.0.0.1:5000:5000 \
  libretranslate/libretranslate:latest \
  --host 0.0.0.0 \
  --load-only ar,de,en,es,fr,ga,hi,it,ja,ko,pl,pt,ru,zh \
  --disable-files-translation \
  --req-limit 60 \
  --hourly-req-limit 1000 \
  --daily-req-limit 5000 \
  --char-limit 5000 \
  --batch-limit 10
```

Verify it before starting the backend:

```sh
curl -s http://127.0.0.1:5000/languages | python3 -m json.tool | head

curl -s http://127.0.0.1:5000/translate \
  -H 'Content-Type: application/json' \
  -d '{"q":"Bonjour le monde","source":"auto","target":"en","format":"text"}'
```

The second command should return an English translation. If a source language is
not installed, the backend can still show a translation button, but the provider
will return an error for that language pair.

## 8. Build and Install the Frontend

Unfathomably FE is a static Vite application. It should be built from its own
repository and installed as the backend primary frontend. Do not use the old
`mix pleroma.frontend install soapbox` command for this fork.

Install Node using the frontend `.tool-versions` file:

```sh
sudo -Hu pleroma git clone https://github.com/unfathomably/unfathomably-fe /opt/unfathomably-fe

pleroma-run bash -lc 'asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git || asdf plugin update nodejs'

cd /opt/unfathomably-fe
pleroma-run asdf install
pleroma-run asdf reshim
pleroma-run bash -lc 'command -v corepack >/dev/null || { npm install -g corepack && asdf reshim nodejs; }'
pleroma-run npm exec -- corepack yarn install --immutable
pleroma-run env NODE_OPTIONS=--max-old-space-size=4096 npm exec -- corepack yarn build
```

If the frontend is served from the same origin as the backend, leave
`BACKEND_URL` unset. If you intentionally host the frontend on another origin,
set `BACKEND_URL=https://your-backend-host` before `yarn build`.

Install the built frontend into the backend static frontend directory:

```sh
sudo -Hu pleroma mkdir -p /var/lib/pleroma/static/frontends/unfathomably-fe/current

sudo -Hu pleroma rsync -a --delete \
  /opt/unfathomably-fe/dist/ \
  /var/lib/pleroma/static/frontends/unfathomably-fe/current/

cd /opt/pleroma
pleroma-run mix pleroma.frontend enable unfathomably-fe --ref current --primary
```

Site-specific frontend settings are read from the frontend's `instance` assets,
including `soapbox.json`. The name survives because clients and inherited
configuration still expect it.

## 9. Install the systemd Service

```sh
sudo tee /etc/systemd/system/pleroma.service >/dev/null <<'EOF'
[Unit]
Description=Unfathomably social server
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=pleroma
Group=pleroma
Environment="MIX_ENV=prod"
Environment="HOME=/var/lib/pleroma"
Environment="PATH=/var/lib/pleroma/bin:/var/lib/pleroma/.asdf/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WorkingDirectory=/opt/pleroma
ExecStart=/var/lib/pleroma/.asdf/shims/mix phx.server
ExecReload=/bin/kill $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/pleroma /opt/pleroma

[Install]
WantedBy=multi-user.target
EOF
```

Enable and start it:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now pleroma
sudo journalctl -u pleroma -n 100 --no-pager
```

At this point the backend should answer on localhost:

```sh
curl -I http://127.0.0.1:4000/
curl -s http://127.0.0.1:4000/.well-known/nodeinfo
```

## 10. Configure nginx and TLS

Create the websocket connection map once. It must live in nginx's `http`
context, not inside a `server` block:

```sh
sudo tee /etc/nginx/conf.d/connection_upgrade.conf >/dev/null <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
```

Create a temporary HTTP-only site so Certbot can issue the first certificate:

```sh
sudo mkdir -p /var/www/certbot

sudo tee /etc/nginx/sites-available/unfathomably.conf >/dev/null <<'EOF'
server {
    listen 80;
    server_name social.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'Unfathomably certificate bootstrap';
        add_header Content-Type text/plain;
    }
}
EOF

sudo sed -i "s/social.example.com/$DOMAIN/g" /etc/nginx/sites-available/unfathomably.conf
sudo ln -s /etc/nginx/sites-available/unfathomably.conf /etc/nginx/sites-enabled/unfathomably.conf
sudo nginx -t
sudo systemctl reload nginx

sudo certbot certonly --webroot \
  -w /var/www/certbot \
  -d "$DOMAIN" \
  -m "$ADMIN_EMAIL" \
  --agree-tos \
  --no-eff-email
```

Replace the temporary site with the production reverse proxy:

```sh
sudo tee /etc/nginx/sites-available/unfathomably.conf >/dev/null <<'EOF'
proxy_cache_path /tmp/pleroma-media-cache
    levels=1:2
    keys_zone=pleroma_media_cache:10m
    max_size=512m
    inactive=1d
    use_temp_path=off;

upstream unfathomably_backend {
    server 127.0.0.1:4000;
    keepalive 32;
}

server {
    listen 80;
    server_name social.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name social.example.com;

    ssl_certificate /etc/letsencrypt/live/social.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/social.example.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 64m;
    ignore_invalid_headers off;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/javascript
        application/javascript
        application/json
        application/activity+json
        application/atom+xml
        application/xml
        application/xml+rss;

    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    location / {
        proxy_pass http://unfathomably_backend;
    }

    location ~ ^/(media|proxy) {
        slice 1m;
        proxy_cache pleroma_media_cache;
        proxy_cache_key $host$uri$is_args$args$slice_range;
        proxy_set_header Range $slice_range;
        proxy_cache_valid 200 206 301 304 1h;
        proxy_cache_lock on;
        proxy_ignore_client_abort on;
        proxy_buffering on;
        chunked_transfer_encoding on;

        proxy_pass http://unfathomably_backend;
    }

    location ^~ /api/v1/streaming {
        proxy_pass http://unfathomably_backend;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }

    location ^~ /websocket {
        proxy_pass http://unfathomably_backend;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_buffering off;
    }
}
EOF
```

Replace `social.example.com` with your real domain and reload nginx:

```sh
sudo sed -i "s/social.example.com/$DOMAIN/g" /etc/nginx/sites-available/unfathomably.conf
sudo nginx -t
sudo systemctl reload nginx
```

The two websocket locations are both intentional. Mastodon-compatible clients
use `/api/v1/streaming`; older Pleroma-compatible clients may still use
`/websocket`.

## 11. Create the First Admin User

```sh
cd /opt/pleroma
pleroma-run mix pleroma.user new admin "$ADMIN_EMAIL" --admin
```

The command prints an initial password or reset link, depending on current
configuration.

## 12. Optional: Enable Meilisearch for Better Post Search

The database search backend works without extra services. For a larger public
instance, Meilisearch is usually a better fit.

```sh
MEILI_MASTER_KEY="$(openssl rand -base64 48)"

sudo mkdir -p /var/lib/meilisearch

sudo docker run -d \
  --name meilisearch \
  --restart unless-stopped \
  -p 127.0.0.1:7700:7700 \
  -e MEILI_MASTER_KEY="$MEILI_MASTER_KEY" \
  -e MEILI_NO_ANALYTICS=true \
  -v /var/lib/meilisearch:/meili_data \
  getmeili/meilisearch:latest
```

Append this block to `/opt/pleroma/config/prod.secret.exs`, replacing the key:

```elixir
config :pleroma, Pleroma.Search,
  module: Pleroma.Search.Meilisearch

config :pleroma, Pleroma.Search.Meilisearch,
  url: "http://127.0.0.1:7700/",
  private_key: "put-the-meilisearch-master-key-here",
  initial_indexing_chunk_size: 100_000
```

Restart, index existing posts, and check stats:

```sh
sudo systemctl restart pleroma

cd /opt/pleroma
pleroma-run mix pleroma.search.meilisearch index
pleroma-run mix pleroma.search.meilisearch stats
```

## 13. Smoke Checks

Run these checks after nginx is live:

```sh
curl -I "https://$DOMAIN/"
curl -s "https://$DOMAIN/.well-known/nodeinfo" | python3 -m json.tool
curl -s "https://$DOMAIN/api/v1/instance" | python3 -m json.tool | head
curl -s "https://$DOMAIN/api/v2/instance" | python3 -m json.tool | head
curl -s http://127.0.0.1:5000/languages | python3 -m json.tool | head
sudo journalctl -u pleroma -n 200 --no-pager
```

Open the site in a browser and check:

1. Deep links refresh without a server error.
2. A websocket connection appears for the home timeline.
3. Search returns results or a clear empty result.
4. A non-English remote post offers translation and translates successfully.
5. Uploads, custom emoji, and previews work after a restart.

## 14. Updating Later

Use the same source paths for normal updates:

```sh
cd /opt/pleroma
sudo -Hu pleroma git pull --ff-only
pleroma-run mix deps.get --only prod
pleroma-run mix compile
pleroma-run mix ecto.migrate

cd /opt/unfathomably-fe
sudo -Hu pleroma git pull --ff-only
pleroma-run bash -lc 'command -v corepack >/dev/null || npm install -g corepack'
pleroma-run npm exec -- corepack yarn install --immutable
pleroma-run env NODE_OPTIONS=--max-old-space-size=4096 npm exec -- corepack yarn build

sudo -Hu pleroma rsync -a --delete \
  /opt/unfathomably-fe/dist/ \
  /var/lib/pleroma/static/frontends/unfathomably-fe/current/

sudo systemctl restart pleroma
sudo journalctl -u pleroma -n 100 --no-pager
```

If `.tool-versions` changes in either repository, run `pleroma-run asdf install`
from that repository before compiling or building.

## 15. Troubleshooting Notes

If frontend refreshes return 500 or 404, confirm nginx proxies all unknown paths
to the backend. Do not serve the Vite files directly from nginx unless you also
configure an SPA `try_files` fallback.

If translations do not appear, check three things in order:

1. `prod.secret.exs` has the OpenTranslate provider block.
2. `curl http://127.0.0.1:5000/languages` works on the server.
3. The source language has an installed model to English, or the provider can
   auto-detect it.

If browser developer tools warn about `interest-cohort`, make sure the backend
is current and that nginx is not adding an old Permissions-Policy header.

If websocket clients reconnect often, confirm `/api/v1/streaming` and
`/websocket` both pass `Upgrade` and `Connection` headers and have long read
timeouts.

If OpenTranslate, Meilisearch, or PostgreSQL are moved to separate hosts, keep
them on private network interfaces and update only the backend config. They do
not need public nginx locations.

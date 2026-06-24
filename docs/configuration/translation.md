# Configuring translation

Rebased can translate statuses through a configured backend provider.

DeepL remains supported for hosted translation. OpenTranslate is available for
operators who want translation to stay on the local network.

## OpenTranslate on an internal network

OpenTranslate-compatible services expose a simple REST API with `/translate`
and `/languages` endpoints. The backend connects to that service directly, so
the translation server does not need to be exposed to the public Internet.
The Rebased OpenTranslate provider advertises English as the only target
language. Source languages come from the languages loaded by the translation
service.

For example, if the translation service is running on `127.0.0.1` and
listening on port `5000`, configure Rebased like this:

```elixir
config :pleroma, Pleroma.Language.Translation,
  provider: Pleroma.Language.Translation.Opentranslate

config :pleroma, Pleroma.Language.Translation.Opentranslate,
  base_url: "http://127.0.0.1:5000",
  api_key: nil
```

`api_key` is optional. Leave it as `nil` when the OpenTranslate service is only
reachable from trusted internal hosts.

After changing the config, restart the backend.

## English-only Docker setup

The OpenTranslate provider uses the same JSON API shape as LibreTranslate.
For an English-only target, install only the source-to-English models you want
and then start the service without the broad `--update-models` startup option.

The example below loads Arabic, German, Spanish, French, Irish, Hindi, Italian,
Japanese, Korean, Polish, Portuguese, Russian, and Chinese as source languages.

First, create persistent storage and install the source-to-English models:

```sh
mkdir -p "$HOME/opentranslate/home" "$HOME/opentranslate/db"
chmod 777 "$HOME/opentranslate/home" "$HOME/opentranslate/db"

docker run --rm -i \
  -v "$HOME/opentranslate/home:/home/libretranslate" \
  -v "$HOME/opentranslate/db:/app/db" \
  --entrypoint /app/venv/bin/python \
  libretranslate/libretranslate:latest - <<'PY'
from argostranslate import package

wanted = ["ar", "de", "es", "fr", "ga", "hi", "it", "ja", "ko", "pl", "pt", "ru", "zh"]

package.update_package_index()
available = package.get_available_packages()
installed_pairs = {(pkg.from_code, pkg.to_code) for pkg in package.get_installed_packages()}
missing = []

for source in wanted:
    if (source, "en") in installed_pairs:
        continue

    candidates = [pkg for pkg in available if pkg.from_code == source and pkg.to_code == "en"]

    if not candidates:
        missing.append(source)
        continue

    path = candidates[0].download()
    package.install_from_path(path)

if missing:
    raise SystemExit("No source-to-English package found for: " + ",".join(missing))
PY
```

Then start the permanent service:

```sh
docker run -d \
  --name opentranslate \
  --restart unless-stopped \
  -v "$HOME/opentranslate/home:/home/libretranslate" \
  -v "$HOME/opentranslate/db:/app/db" \
  -p 0.0.0.0:5000:5000 \
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

Bind the published port to the internal IP address of the host that should
serve translations if it should not listen on every interface. If Rebased and
the translation service run on the same machine, `127.0.0.1:5000:5000` is
enough.

For a more permanent deployment, use a service manager or compose stack and
restart the translation service automatically with the host.

## DeepL

DeepL is still available:

```elixir
config :pleroma, Pleroma.Language.Translation,
  provider: Pleroma.Language.Translation.Deepl

config :pleroma, Pleroma.Language.Translation.Deepl,
  base_url: "https://api-free.deepl.com",
  api_key: "API_KEY"
```

Use DeepL when you want the hosted provider. Use OpenTranslate when you want
the translation path to stay local.

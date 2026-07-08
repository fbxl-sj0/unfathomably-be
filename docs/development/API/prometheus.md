# Prometheus Metrics

Unfathomably exposes Prometheus-compatible runtime metrics through PromEx at
`/api/metrics`.

Metrics often include enough operational detail to help an attacker profile a
server. For that reason the endpoint fails closed by default: if no bearer token
is configured, requests to `/api/metrics` are not served.

## Configuration

Add a long random token to your runtime configuration:

```elixir
config :pleroma, Pleroma.Web.Plugs.MetricsPredicate,
  auth_token: "replace-this-with-a-long-random-token"
```

Then configure Prometheus or another scraper to send the token:

```bash
curl \
  -H "Authorization: Bearer replace-this-with-a-long-random-token" \
  https://example.com/api/metrics
```

If you intentionally expose metrics only on a private network or behind a
trusted reverse proxy, source installs may set `auth_token: :disabled` to allow
unauthenticated scraping. Do not use that setting on a public endpoint.

Unset, `nil`, and empty token values all disable the endpoint.

## `/api/metrics`

### Exports Prometheus application metrics

* Method: `GET`
* Authentication: bearer token required unless explicitly disabled in source
  configuration
* Params: none
* Response: Prometheus text exposition format

## Grafana and Prometheus

Example Prometheus scrape configuration:

```yaml
- job_name: "unfathomably"
  metrics_path: /api/metrics
  scheme: https
  bearer_token: replace-this-with-a-long-random-token
  static_configs:
    - targets:
        - example.com
```

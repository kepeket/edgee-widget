# Edgee integration

`EdgeeService` is the production implementation of `EdgeeServing`. It uses Edgee CLI 0.10.1 for authentication and route changes, and the Edgee Console API for member-scoped usage and read-only key/model state.

## Authentication and credentials

- Identity comes from `edgee auth status --json`.
- Login runs `edgee auth login --json`, which starts the CLI's browser and loopback-callback flow. The service does not implement or invent a separate OAuth flow.
- The service reads the selected v4 profile in `~/.config/edgee/credentials.toml` directly. This avoids the CLI reader's automatic migration writes during normal refreshes.
- Credentials are accepted only for `https://api.edgee.app`. Redirects are followed only when the destination is the same HTTPS host, so a bearer credential is never forwarded elsewhere.
- A 401 is treated as expired authentication and requires a fresh CLI login. The service does not attempt an undocumented refresh-token flow.
- CLI stderr is discarded because browser-login progress may contain callback URLs. API errors are bounded and reject sensitive-looking messages before display.

The CLI executable is resolved from fixed Homebrew and user-install locations so the app works when launched by Finder without a shell `PATH`:

1. `/opt/homebrew/bin/edgee`
2. `/usr/local/bin/edgee`
3. `~/.local/bin/edgee`
4. `~/.edgee/bin/edgee`

Subprocess arguments are passed as an array through `Process`; no shell is involved. Output is drained concurrently with an 8 MiB capture limit, stderr is discarded as it arrives, and every operation has a timeout with forced termination if graceful termination fails.

## Usage

Usage is fetched from:

```http
POST https://api.edgee.app/v1/organizations/{org_id}/usage
Authorization: Bearer {user_token}
Content-Type: application/json

{
  "period": "24h | 7d | 30d",
  "user_id": ["{authenticated_user_id}"],
  "interval": "hour | day"
}
```

`user_id` is mandatory in the service. If the selected profile has no user ID, the request fails instead of returning or labeling organization-wide data as personal data. The service does not use `edgee stats` as a fallback because CLI 0.10.1 silently returns `source: "local"` on API failure, and local results ignore the requested rolling period.

The deployed response contains `summary`, `stats_by_model`, and `stats_by_time`. Monetary fields are integer nanoUSD and are divided by `1_000_000_000`. `token_cost_savings` is not mapped to money. `savedCost` is the sum of the explicitly monetary `tool_compression_cost_savings`, `output_cost_savings`, and `mcp_surface_cost_savings` fields when any are present.

`stats_by_model` can contain multiple usage buckets for the same model across API keys and providers. The parser groups rows by the exact `model` identifier and sums cost, tokens, and requests before producing `ModelUsage`. Cost is summed in nanoUSD before conversion. Each model therefore has one stable, unique UI identity; equal costs are ordered by model identifier. Summary totals remain those supplied by the API.

Token categories map as follows:

| Domain category | Count | Cost |
| --- | --- | --- |
| Input | `input_tokens` | `input_cost` |
| Cache write | `cache_creation_input_tokens` | `cache_creation_input_cost` |
| Cache read | `cached_input_tokens` | `cached_input_cost` |
| Output | `output_tokens` | `output_cost` |

`total_requests`, `total_cost`, and `total_tokens` are required. A response missing any of them is rejected. Category rows are emitted only when their count field is present; an absent category is left unavailable instead of being displayed as zero. A present count with an absent category cost keeps the cost unavailable.

`total_tokens` also includes `reasoning_output_tokens`. `Domain.swift` currently has no reasoning `TokenKind`, so the four displayed category counts do not sum to the total when reasoning was used. The snapshot notice says: “Reasoning tokens are included in the total.”

The 24-hour series uses hourly buckets. The 7-day and 30-day series request calendar-day buckets from the Console API. The domain's rolling period labels remain unchanged.

Session history is fetched read-only from:

```http
GET /v1/organizations/{org_id}/sessions
    ?from_date={rolling_window_start}
    &to_date={request_time}
    &user_id[]={authenticated_user_id}
    &api_key_id[]={selected_profile_key_id}
    &page={page}
    &page_size=100
```

Both the authenticated member ID and every configured key ID from the selected profile are sent. Returned rows are accepted only when `key_uuid` matches one of those configured IDs and `last_request` remains inside the requested rolling window, so an ignored server filter cannot be mislabeled as personal data. All pages are read, with a defensive 100-page bound that rejects a still-incomplete response rather than returning a partial list.

If session history is unavailable, the app retains the successfully fetched usage totals, skips session spike checks, and displays a session-monitoring notice.

Session `total_cost` is nanoUSD. Session tokens are the sum of input, cache creation, cached input, output, and reasoning output counters. A row missing any required counter is omitted instead of receiving a fabricated zero. The deployed response does not currently include a session name, so the configured agent name is used. `POST /v1/organizations/{org}/sessions/{id}/end` is never called because it closes a live session.

## Agents, settings, and models

Configured agents are discovered from provider sections in the selected credential profile. Existing key state is read with:

```http
GET /v1/organizations/{org_id}/api_keys/{key_id}
```

The service never calls the CLI's get-or-create key path during refresh. A configured provider without a persisted `api_key_id` remains visible but is marked non-editable.

Compression toggles use the Console endpoint required by the CLI source:

```http
POST /v1/organizations/{org_id}/api_keys/{key_id}
```

The endpoint expects the full compression/fallback/reroute settings bundle. Before changing one compression flag, the service reads current state and preserves the original raw fallback and reroute arrays, including fields unknown to this app.

Model switching is currently disabled at the app-store boundary, including passthrough. Clicking the current route opens a read-only preview beside the agent card, with a “Soon available” overlay. The preview has no editable search field, avoiding the field-editor focus transfer implicated in the old picker crash.

The preview fetches the real Console catalog with `GET /v1/models`, using the active CLI profile's Console credentials. This is the same endpoint used by `ApiClient::list_models` in the current Edgee CLI. Inactive and app-subscription-only models are excluded; the preview is not an agent-specific access guarantee. Loading errors are visible and retryable.

Edgee CLI 0.11.1 removed the previous `route models` command. The older route command parsers and service mutation method remain for future work, but the app cannot invoke route mutations while switching is unavailable.

## Source contracts

The implementation was checked against Edgee CLI 0.10.1, the current open-source CLI, the deployed Console client, and read-only live responses:

- [Edgee CLI repository](https://github.com/edgee-ai/edgee)
- [`src/api.rs`](https://github.com/edgee-ai/edgee/blob/main/src/api.rs)
- [`src/commands/stats.rs`](https://github.com/edgee-ai/edgee/blob/main/src/commands/stats.rs)
- [`src/commands/auth/login.rs`](https://github.com/edgee-ai/edgee/blob/main/src/commands/auth/login.rs)
- [`src/commands/auth/status.rs`](https://github.com/edgee-ai/edgee/blob/main/src/commands/auth/status.rs)
- [`src/commands/settings/agent.rs`](https://github.com/edgee-ai/edgee/blob/main/src/commands/settings/agent.rs)
- [Deployed Console API client chunk](https://www.edgee.ai/_next/static/chunks/3fdw-jafafylc.js)

The Console's production gateway and API server are not part of the public repository. Parser tests pin the response fields observed from the deployed API; unknown fields are ignored.

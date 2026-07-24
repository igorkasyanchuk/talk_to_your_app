# Security Policy

## Supported versions

This gem is pre-1.0. Security fixes land on the latest prerelease / release on
[RubyGems](https://rubygems.org/gems/talk_to_your_app) and on `main`. Older
prereleases are not patched.

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories on
[igorkasyanchuk/talk_to_your_app](https://github.com/igorkasyanchuk/talk_to_your_app/security/advisories/new),
or email **igorkasyanchuk@gmail.com**.

Do not open a public issue for vulnerabilities that could let an unauthenticated
or under-authorized caller reach tools, bypass auth, or escalate privileges.

Include:

- Affected gem version
- A minimal reproduction (or clear description)
- Impact (e.g. unauthenticated access, write via `db.query`, secret leakage)

You should hear back within a few business days. We will coordinate disclosure
once a fix is available.

## Operator checklist (misconfiguration is the common failure mode)

This gem mounts an authenticated MCP control surface on your Rails app. A valid
API key can use every enabled plugin unless you scope it. Before production:

1. **Use HTTPS** — Bearer / Basic credentials must not travel in clear text.
2. **High-entropy, per-principal keys** from `ENV` or credentials — never a
   shared forever-secret in source.
3. **Set `config.authorize`** — without it, every authenticated principal may
   call every enabled tool.
4. **DB plugin** — point `:reading` connections at a **SELECT-only** database
   role or a physical replica, never your writable primary credentials. The gem
   does not parse SQL; the database role is the write boundary. See
   [docs/read_only_connections.md](docs/read_only_connections.md).
5. **Multi-worker / multi-replica** — set `config.stateless = true`.
6. **`config.allowed_hosts`** — list every non-loopback host that serves the
   endpoint (the install generator defaults this to `TalkToYourApp.rails_hosts`).
7. **Enable the minimum plugins** — treat `:sidekiq` / `:solid_queue` job args,
   `:flipper` writes, `:rake`, and `:cache` as sensitive; scope with `authorize`.
8. **Audit sinks** — full SQL (and tool params) may appear in logs; filter or
   retain accordingly.
9. **Rate-limit the endpoint** — the gem does not throttle or lock out repeated
   failures. Put a limiter (e.g. Rack::Attack) in front of `config.mount_at` to
   bound both credential guessing and expensive tool calls.
10. **Alert on rejected requests** — every `401` emits a `WARN` line and a
    `talk_to_your_app.auth_failure` event (`reason`, `scheme`, `ip`; never any
    credential material). A burst from one source is the signal that credentials
    are being guessed.
11. **Trust the principal, not the IP** — the logged IP comes from
    `Rack::Request#ip`, which honours `X-Forwarded-For`. It is accurate behind a
    proxy you control and forgeable when the endpoint is directly exposed.

## Threat model (summary)

- **In scope for the gem:** fail-closed boot, request authentication, optional
  per-tool authorization, Host/Origin DNS-rebinding controls (via the MCP SDK),
  audit logging of both successful calls and rejected requests, and refusing to
  expose plugins that are not explicitly enabled.
- **Out of scope / operator-owned:** network exposure, TLS termination, rate
  limiting and lockout, database grants, resource exhaustion from expensive
  queries (`max_rows` bounds the response, not memory), Redis/job payload
  sensitivity, LLM prompt injection against data the agent is allowed to read,
  and custom tools you author.

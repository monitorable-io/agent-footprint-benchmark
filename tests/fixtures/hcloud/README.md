Recorded Hetzner Cloud API responses (https://api.hetzner.cloud/v1, 2026-10-31) used by
`bench --fixtures tests/fixtures/hcloud`: `servers` (the ten CX23 boxes of the 2026 bed, public
IPv4 addresses replaced by 192.0.2.10-19, trimmed to the fields the client reads), `server_types`
(`?name=cx23`), `images` (`?type=system`, Ubuntu only), `pricing` (hel1 only). `rebuild.json` and
`actions_*.json` are hand-written in the documented shape (POST .../actions/rebuild, GET /actions/{id}).

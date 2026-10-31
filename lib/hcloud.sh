#!/usr/bin/env bash
# Hetzner Cloud API client (BENCH_PROVIDER=hcloud). Sourced by bench; the vm_* dispatchers live in common.sh.
#
# API (https://docs.hetzner.cloud/reference/cloud, read 2026-10-31):
#   base URL   https://api.hetzner.cloud/v1      auth: Authorization: Bearer <token> (project -> Security -> API tokens, Read & Write)
#   GET  /servers?per_page=50                      {servers: [{id, name, status, public_net.ipv4.ip, image.name, server_type.name, ...}]}
#   POST /servers/{id}/actions/rebuild {image}     {action: {id, status}, root_password}   reinstalls in place: same server, same IPs
#   GET  /actions/{id}                             {action: {status: running|success|error, error: {message}}}
#   GET  /server_types?name=cx23                   {server_types: [{cores, memory, disk, cpu_type, prices: [{location, price_hourly, price_monthly}]}]}
#   GET  /images?type=system                       {images: [{id, name, architecture}]}
#   GET  /pricing                                  {pricing: {currency, vat_rate, primary_ips: [{type, prices: [...]}]}}
#   POST /servers {name, server_type, image, location, ssh_keys[], start_after_create}   DELETE /servers/{id}
# The bed's boxes are the founder's servers (ordered by hand, names like ubuntu-4gb-hel1-7): a box is
# matched to its server by public IPv4 (BOX_<NAME>_IP), nothing is renamed. The 2026 run never destroys a
# box (stock may not come back): hcloud_vm_destroy refuses unless BENCH_ALLOW_DESTROY=1.

HCLOUD_API="${HCLOUD_API:-https://api.hetzner.cloud/v1}"
HCLOUD_POLL_SECONDS="${HCLOUD_POLL_SECONDS:-5}"

# hcloud_auth_config: a curl config carrying the bearer header, so the token is never in argv.
hcloud_auth_config() { printf 'header = "Authorization: Bearer %s"\n' "$HCLOUD_TOKEN"; }

# hcloud_fixture PATH: the fixture file for PATH's first segment (actions -> HCLOUD_ACTIONS_FIXTURE).
hcloud_fixture() {
  local seg
  seg=$(cut -d/ -f2 <<<"${1%%\?*}")
  if [[ "$seg" == "actions" ]]; then printf '%s/%s' "$BENCH_FIXTURES" "${HCLOUD_ACTIONS_FIXTURE:-actions.json}"; else printf '%s/%s.json' "$BENCH_FIXTURES" "$seg"; fi
}

hcloud_get() {
  local path=$1
  if [[ -n "$BENCH_FIXTURES" ]]; then
    local f; f=$(hcloud_fixture "$path")
    [[ -f "$f" ]] || die "fixture missing: $f"
    cat "$f"; return
  fi
  require_env HCLOUD_TOKEN
  curl -fsS -K <(hcloud_auth_config) -H 'Accept: application/json' "$HCLOUD_API$path"
}

hcloud_post() {
  local path=$1 body=$2
  if [[ -n "$BENCH_FIXTURES" ]]; then
    [[ -n "${HCLOUD_POST_FIXTURE:-}" ]] || die "no fixture for POST $path"
    cat "$BENCH_FIXTURES/$HCLOUD_POST_FIXTURE"; return
  fi
  require_env HCLOUD_TOKEN
  curl -fsS -X POST -K <(hcloud_auth_config) -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data "$body" "$HCLOUD_API$path"
}

hcloud_delete() {
  local path=$1
  [[ -z "$BENCH_FIXTURES" ]] || die "no fixture for DELETE $path"
  require_env HCLOUD_TOKEN
  curl -fsS -X DELETE -K <(hcloud_auth_config) -H 'Accept: application/json' "$HCLOUD_API$path"
}

hcloud_servers() { hcloud_get "/servers?per_page=50" | jq -c '.servers | sort_by(.id)'; }

# hcloud_server_for_box NAME: the server object whose public IPv4 is BOX_<NAME>_IP.
hcloud_server_for_box() {
  local name=$1 ip server
  ip=$(box_ip "$name")
  server=$(hcloud_servers | jq -c --arg ip "$ip" '[.[] | select(.public_net.ipv4.ip == $ip)] | first // empty')
  [[ -n "$server" ]] || die "no Hetzner server has the address of $name ($ip)"
  printf '%s' "$server"
}

hcloud_vm_list() {
  local line
  {
    printf 'BOX NAME ID STATUS IPV4 IMAGE\n'
    while IFS=$'\t' read -r id name status ip image; do
      printf '%s %s %s %s %s %s\n' "$(box_name_of_ip "$ip")" "$name" "$id" "$status" "$ip" "$image"
    done < <(hcloud_servers | jq -r '.[] | [.id, .name, .status, (.public_net.ipv4.ip // "-"), (.image.name // "-")] | @tsv')
  } | column -t | { read -r line; printf '%s\n' "$line" >&2; cat; }
}

# hcloud_vm_quote: prices from the API for the configured type, location and image; rents nothing.
hcloud_vm_quote() {
  require_env HCLOUD_SERVER_TYPE HCLOUD_LOCATION HCLOUD_IMAGE
  local st image pricing hourly monthly ip4h ip4m currency vat
  st=$(hcloud_get "/server_types?name=$HCLOUD_SERVER_TYPE" | jq -c --arg l "$HCLOUD_LOCATION" \
    '.server_types[0] // empty | {name, cores, memory, disk, cpu_type, price: ([.prices[] | select(.location == $l)] | first)}')
  [[ -n "$st" ]] || die "server type $HCLOUD_SERVER_TYPE not found"
  [[ "$(jq -r .price <<<"$st")" != "null" ]] || die "server type $HCLOUD_SERVER_TYPE has no price in $HCLOUD_LOCATION"
  image=$(hcloud_get "/images?type=system&per_page=50" | jq -r --arg n "$HCLOUD_IMAGE" \
    '[.images[] | select(.name == $n and (.architecture // "x86") == "x86")] | first | if . == null then "" else "\(.name) (id \(.id))" end')
  [[ -n "$image" ]] || die "no system image named $HCLOUD_IMAGE"
  pricing=$(hcloud_get /pricing)
  currency=$(jq -r .pricing.currency <<<"$pricing"); vat=$(jq -r .pricing.vat_rate <<<"$pricing")
  hourly=$(jq -r '.price.price_hourly.gross | tonumber' <<<"$st"); monthly=$(jq -r '.price.price_monthly.gross | tonumber' <<<"$st")
  ip4h=$(jq -r --arg l "$HCLOUD_LOCATION" '[.pricing.primary_ips[] | select(.type == "ipv4") | .prices[] | select(.location == $l)] | first | .price_hourly.gross | tonumber' <<<"$pricing")
  ip4m=$(jq -r --arg l "$HCLOUD_LOCATION" '[.pricing.primary_ips[] | select(.type == "ipv4") | .prices[] | select(.location == $l)] | first | .price_monthly.gross | tonumber' <<<"$pricing")
  printf 'Hetzner Cloud quote (nothing rented)\n'
  printf '  location      %s\n' "$HCLOUD_LOCATION"
  printf '  server type   %s: %s vCPU %s, %s GB RAM, %s GB disk\n' "$(jq -r .name <<<"$st")" "$(jq -r .cores <<<"$st")" "$(jq -r .cpu_type <<<"$st")" "$(jq -r .memory <<<"$st")" "$(jq -r .disk <<<"$st")"
  printf '  image         %s\n' "$image"
  printf '  price         %.4f %s/h + IPv4 %.4f %s/h = %.4f %s/h (gross, VAT %.2f %%); %.2f %s/month + IPv4 %.2f\n' \
    "$hourly" "$currency" "$ip4h" "$currency" "$(awk -v a="$hourly" -v b="$ip4h" 'BEGIN{print a+b}')" "$currency" "$vat" "$monthly" "$currency" "$ip4m"
  printf '  10 boxes x 110 h = %.2f %s (4 slots of ~26 h plus setup)\n' "$(awk -v a="$hourly" -v b="$ip4h" 'BEGIN{print (a+b)*10*110}')" "$currency"
}

hcloud_rebuild_body() { require_env HCLOUD_IMAGE; jq -n --arg i "$HCLOUD_IMAGE" '{image: $i}'; }

hcloud_create_body() {
  require_env HCLOUD_SERVER_TYPE HCLOUD_LOCATION HCLOUD_IMAGE HCLOUD_SSH_KEY
  jq -n --arg n "$1" --arg t "$HCLOUD_SERVER_TYPE" --arg i "$HCLOUD_IMAGE" --arg l "$HCLOUD_LOCATION" --arg k "$HCLOUD_SSH_KEY" \
    '{name: $n, server_type: $t, image: $i, location: $l, ssh_keys: [$k], start_after_create: true}'
}

# hcloud_wait_action ID: poll until success; die on error or after 120 polls.
hcloud_wait_action() {
  local id=$1 _i action status
  for _i in $(seq 1 120); do
    action=$(hcloud_get "/actions/$id")
    status=$(jq -r .action.status <<<"$action")
    case "$status" in
      success) return 0;;
      error) die "action $id failed: $(jq -r '.action.error.message // "unknown error"' <<<"$action")";;
    esac
    sleep "$HCLOUD_POLL_SECONDS"
  done
  die "action $id still $status after $((120 * HCLOUD_POLL_SECONDS)) s"
}

# wait_for_ssh NAME: up to 5 minutes for root SSH to answer on the box.
wait_for_ssh() {
  local name=$1 _i
  for _i in $(seq 1 60); do
    # shellcheck disable=SC2046
    if ssh $(ssh_opts) "root@$(box_ip "$name")" true 2>/dev/null; then return 0; fi
    sleep 5
  done
  die "$name: no SSH after 5 min"
}

# hcloud_vm_reimage NAME (bench vm rebuild): reinstall the image in place; the server and its IPs stay.
hcloud_vm_reimage() {
  local name=$1 server id ip action_id
  require_env HCLOUD_IMAGE
  server=$(hcloud_server_for_box "$name")
  id=$(jq -r .id <<<"$server"); ip=$(jq -r .public_net.ipv4.ip <<<"$server")
  log "rebuilding $name ($ip, server $id, $(jq -r .name <<<"$server")) from $HCLOUD_IMAGE ..."
  action_id=$(hcloud_post "/servers/$id/actions/rebuild" "$(hcloud_rebuild_body)" | jq -r '.action.id // empty')
  [[ -n "$action_id" ]] || die "rebuild of $name returned no action id"
  hcloud_wait_action "$action_id"
  if [[ -z "$BENCH_FIXTURES" ]]; then
    ssh-keygen -R "$ip" > /dev/null 2>&1 || true   # the rebuilt box has a new host key
    wait_for_ssh "$name"
  fi
  log "rebuilt $name ($ip) from $HCLOUD_IMAGE"
}

hcloud_vm_destroy() {
  local name=$1 server id ip
  [[ "${BENCH_ALLOW_DESTROY:-0}" == "1" ]] || die "refused: Hetzner boxes are never destroyed during the run (BENCH_ALLOW_DESTROY=1 overrides)"
  server=$(hcloud_server_for_box "$name")
  id=$(jq -r .id <<<"$server"); ip=$(jq -r .public_net.ipv4.ip <<<"$server")
  hcloud_delete "/servers/$id" > /dev/null
  ssh-keygen -R "$ip" > /dev/null 2>&1 || true
  write_env_var "$(env_key_for "$name")_IP" ""
  log "destroyed $name ($id)"
}

# hcloud_vm_create NAME: one server from the configured type/image/location; records BOX_<NAME>_IP.
# Not exercised live for the 2026 bed (the account's 10-server limit is reached).
hcloud_vm_create() {
  local name=$1 resp id ip="" status="" _i
  resp=$(hcloud_post /servers "$(hcloud_create_body "$name")") || die "create refused for $name"
  id=$(jq -r '.server.id // empty' <<<"$resp")
  [[ -n "$id" ]] || die "created $name but found no server id in the response"
  for _i in $(seq 1 60); do
    resp=$(hcloud_get "/servers/$id")
    status=$(jq -r .server.status <<<"$resp"); ip=$(jq -r '.server.public_net.ipv4.ip // empty' <<<"$resp")
    [[ "$status" == "running" && -n "$ip" ]] && break
    sleep "$HCLOUD_POLL_SECONDS"
  done
  [[ "$status" == "running" && -n "$ip" ]] || die "$name is $status after waiting (server $id)"
  write_env_var "$(env_key_for "$name")_IP" "$ip"
  log "$name is $ip (server $id)"
}

#!/usr/bin/env bash
# Onidel Cloud API client. Sourced by bench.
#
# API (read from https://developers.onidel.com/api-reference/openapi.yaml, 2026-10-29):
#   base URL      https://api.cloud.onidel.com
#   auth          Authorization: Bearer <token>   (token: cloud.onidel.com/account/settings, API Key tab)
#   GET  /instance_types      [{id, type, cpu, max_vcpu, max_ram, max_disk, locations[]}]
#   GET  /os_templates        [{id, name, family}]
#   GET  /instance_price?vcpu&ram&disk&location&instance_type  {price_per_month, currency, ...}
#   GET  /ssh_keys            {ssh_keys: [{id, name, ...}]}
#   GET  /vm                  [{id, name, vcpu, ram, disk, main_ipv4, main_ipv6, template, status}]
#   POST /vm                  {name, payment_cycle: hourly|monthly|..., instance_type, location, cpu, ram, disk, os, ssh_keys[], ipv6}
#   GET  /vm/{id}             status: building|active|suspended|awaiting_payment|taking_snaphot|restoring|terminating|migrating
#   DELETE /vm/{id}
# There is no reinstall endpoint: reimage = destroy + create.
# Hourly billing exists only "in select locations" (kb.onidel.com, Hourly Billing); the hourly
# rate is the monthly price / 672. A create with payment_cycle=hourly fails loudly if refused.

ONIDEL_API="${ONIDEL_API:-https://api.cloud.onidel.com}"
ONIDEL_FIXTURES=""
HOURS_PER_MONTH=672

# strip_fixtures ARGS...: consumes a leading `--fixtures DIR`, leaves the rest in REST[].
strip_fixtures() {
  REST=()
  while (($#)); do
    if [[ "$1" == "--fixtures" ]]; then ONIDEL_FIXTURES=$2; shift 2; else REST+=("$1"); shift; fi
  done
}

# onidel_get PATH [QUERY]: GET as JSON; with fixtures, reads <dir>/<first path segment>.json.
onidel_get() {
  local path=$1 query=${2:-}
  if [[ -n "$ONIDEL_FIXTURES" ]]; then
    local f
    f="$ONIDEL_FIXTURES/$(tr -d '/' <<<"${path%%\?*}").json"
    [[ -f "$f" ]] || die "fixture missing: $f"
    cat "$f"
    return
  fi
  require_env ONIDEL_TOKEN
  curl -fsS -H "Authorization: Bearer $ONIDEL_TOKEN" -H 'Accept: application/json' \
    "$ONIDEL_API$path${query:+?$query}"
}

onidel_post() {
  local path=$1 body=$2
  [[ -z "$ONIDEL_FIXTURES" ]] || die "no fixture for POST $path"
  require_env ONIDEL_TOKEN
  curl -fsS -X POST -H "Authorization: Bearer $ONIDEL_TOKEN" -H 'Content-Type: application/json' \
    -H 'Accept: application/json' --data "$body" "$ONIDEL_API$path"
}

onidel_delete() {
  local path=$1
  [[ -z "$ONIDEL_FIXTURES" ]] || die "no fixture for DELETE $path"
  require_env ONIDEL_TOKEN
  curl -fsS -X DELETE -H "Authorization: Bearer $ONIDEL_TOKEN" -H 'Accept: application/json' "$ONIDEL_API$path"
}

# resolve_instance_type: prints the uuid of ONIDEL_INSTANCE_TYPE (a type slug like "vhp", or a uuid) offered in ONIDEL_LOCATION.
resolve_instance_type() {
  require_env ONIDEL_INSTANCE_TYPE ONIDEL_LOCATION
  local id
  id=$(onidel_get /instance_types | jq -r --arg t "$ONIDEL_INSTANCE_TYPE" --arg l "$ONIDEL_LOCATION" \
    '[.[] | select(.type == $t or .id == $t)] | first | if . == null then "NOTYPE" elif (.locations | index($l)) == null then "NOLOC" else .id end')
  case "$id" in
    NOTYPE) die "instance type $ONIDEL_INSTANCE_TYPE not found (bench quote lists them)";;
    NOLOC) die "instance type $ONIDEL_INSTANCE_TYPE is not offered in $ONIDEL_LOCATION";;
  esac
  printf '%s' "$id"
}

# resolve_template: prints "<id> <name>" of the OS template whose name contains ONIDEL_TEMPLATE.
resolve_template() {
  require_env ONIDEL_TEMPLATE
  local t
  t=$(onidel_get /os_templates | jq -r --arg n "$ONIDEL_TEMPLATE" '[.[] | select(.name | contains($n))] | first | if . == null then "" else "\(.id) \(.name)" end')
  [[ -n "$t" ]] || die "no OS template containing '$ONIDEL_TEMPLATE'"
  printf '%s' "$t"
}

# vm_quote: the billing gate. Prints plan, template and price; never creates anything.
vm_quote() {
  require_env ONIDEL_VCPU ONIDEL_RAM ONIDEL_DISK
  local type_id tmpl price
  type_id=$(resolve_instance_type)
  tmpl=$(resolve_template)
  price=$(onidel_get /instance_price "vcpu=$ONIDEL_VCPU&ram=$ONIDEL_RAM&disk=$ONIDEL_DISK&location=$ONIDEL_LOCATION&instance_type=$type_id")
  local monthly currency hourly
  monthly=$(jq -r .price_per_month <<<"$price")
  currency=$(jq -r .currency <<<"$price")
  hourly=$(awk -v m="$monthly" -v h="$HOURS_PER_MONTH" 'BEGIN{printf "%.4f", m/h}')
  printf 'Onidel quote (nothing rented)\n'
  printf '  location       %s\n' "$ONIDEL_LOCATION"
  printf '  instance type  %s (%s)\n' "$ONIDEL_INSTANCE_TYPE" "$type_id"
  printf '  size           %s vCPU / %s GB RAM / %s GB disk\n' "$ONIDEL_VCPU" "$((ONIDEL_RAM / 1024))" "$ONIDEL_DISK"
  printf '  template       %s (id %s)\n' "${tmpl#* }" "${tmpl%% *}"
  printf '  price          %.2f %s/month = %s %s/hour (monthly / %s)\n' "$monthly" "$currency" "$hourly" "$currency" "$HOURS_PER_MONTH"
  printf '  13 boxes x 100 h at the hourly rate = %.2f %s; at the monthly rate = %.2f %s\n' \
    "$(awk -v h="$hourly" 'BEGIN{print h*13*100}')" "$currency" "$(awk -v m="$monthly" 'BEGIN{print m*13}')" "$currency"
  printf '  hourly billing in %s: not knowable from the API; bench vm create asks for payment_cycle=hourly and stops if refused.\n' "$ONIDEL_LOCATION"
}

vm_list() {
  onidel_get /vm | jq -r '.[] | [.name, .status, (.main_ipv4 // "-"), .id] | @tsv' | column -t
}

# vm_id_of NAME: the uuid of the VM called NAME, or empty.
vm_id_of() {
  onidel_get /vm | jq -r --arg n "$1" '[.[] | select(.name == $n)] | first | .id // empty'
}

# write_env_var KEY VALUE: set KEY in bench.env in place (keeps mode 0600).
write_env_var() {
  local key=$1 value=$2
  if grep -q "^$key=" "$BENCH_ENV"; then
    sed -i "s|^$key=.*|$key=$value|" "$BENCH_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >> "$BENCH_ENV"
  fi
}

env_key_for() { printf 'BOX_%s' "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"; }

# vm_create NAME: provision one box, wait for an address, record BOX_<NAME>_IP and _ID.
vm_create() {
  local name=$1
  require_env ONIDEL_VCPU ONIDEL_RAM ONIDEL_DISK ONIDEL_SSH_KEY_ID
  [[ -z "$(vm_id_of "$name")" ]] || die "a VM named $name already exists (bench vm list)"
  local type_id tmpl body resp id
  type_id=$(resolve_instance_type)
  tmpl=$(resolve_template)
  body=$(jq -n --arg name "$name" --arg t "$type_id" --arg l "$ONIDEL_LOCATION" --arg k "$ONIDEL_SSH_KEY_ID" \
    --argjson cpu "$ONIDEL_VCPU" --argjson ram "$ONIDEL_RAM" --argjson disk "$ONIDEL_DISK" --argjson os "${tmpl%% *}" \
    '{name: $name, payment_cycle: "hourly", instance_type: $t, location: $l, cpu: $cpu, ram: $ram, disk: $disk, os: $os, ssh_keys: [$k], ipv6: true}')
  log "creating $name (hourly) ..."
  resp=$(onidel_post /vm "$body") || die "create refused for $name (hourly billing not offered here?)"
  id=$(jq -r '.id // .vm.id // empty' <<<"$resp")
  [[ -n "$id" ]] || id=$(vm_id_of "$name")
  [[ -n "$id" ]] || die "created $name but found no id in the response: $resp"
  local ip="" status="" _i
  for _i in $(seq 1 60); do
    resp=$(onidel_get "/vm/$id")
    status=$(jq -r .status <<<"$resp"); ip=$(jq -r '.main_ipv4 // empty' <<<"$resp")
    [[ "$status" == "active" && -n "$ip" ]] && break
    sleep 10
  done
  [[ "$status" == "active" && -n "$ip" ]] || die "$name is $status after 10 min (id $id)"
  write_env_var "$(env_key_for "$name")_IP" "$ip"
  write_env_var "$(env_key_for "$name")_ID" "$id"
  log "$name is $ip (id $id)"
}

vm_destroy() {
  local name=$1 id
  id=$(vm_id_of "$name")
  [[ -n "$id" ]] || { log "$name: no such VM, nothing to destroy"; return 0; }
  onidel_delete "/vm/$id" > /dev/null
  write_env_var "$(env_key_for "$name")_IP" ""
  write_env_var "$(env_key_for "$name")_ID" ""
  log "destroyed $name ($id)"
}

vm_reimage() {
  local name=$1
  vm_destroy "$name"
  local _i
  for _i in $(seq 1 30); do
    [[ -z "$(vm_id_of "$name")" ]] && break
    sleep 10
  done
  vm_create "$name"
}

cmd_quote() { strip_fixtures "$@"; load_env; vm_quote; }

cmd_vm() {
  strip_fixtures "$@"
  load_env
  local sub=${REST[0]:-}
  case "$sub" in
    list) vm_list;;
    create|destroy|reimage) [[ -n "${REST[1]:-}" ]] || die "usage: bench vm $sub <name>"; "vm_$sub" "${REST[1]}";;
    *) die "usage: bench vm list|create|destroy|reimage <name>";;
  esac
}

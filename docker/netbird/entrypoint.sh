#!/bin/bash
# Join NetBird (userspace netstack), then start the web administrator.
# This image always requires a setup key and management URL — there is no
# "skip NetBird" path. See docker/netbird/Dockerfile.

set -eEuo pipefail

pid_nb_daemon=""
pid_web=""

export NB_USE_NETSTACK_MODE="true"
export NB_ENABLE_NETSTACK_LOCAL_FORWARDING="true"
export NB_STATE_DIR="/var/lib/netbird"
export PATH="/usr/bin:/bin:/sbin"

handle_path=/etc/podinfo/handle
management_url_path=/config/urls/netbird_management_url
setup_key_file_path=/config/netbird/setup.key
notification_url_path=/config/urls/portal_web_companion_notification_url
auth_token_path=/config/portal/auth_token

NOTIF_PEER_CONNECTING='PEER_CONNECTING'
NOTIF_PEER_CONNECTED='PEER_CONNECTED'
NOTIF_PEER_DISCONNECTING='PEER_DISCONNECTING'
NOTIF_PEER_DISCONNECTED='PEER_DISCONNECTED'

trim() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

function notify() {
  local notificationType=$1

  if [ -z "${notification_url:-}" ] || [ -z "${auth_token:-}" ]; then
    echo "- skip portal notification $notificationType (no webhook config)"
    return 0
  fi

  local payloadElements=(
    "\"type\": \"$notificationType\""
  )

  if [[ $# -gt 1 ]]; then
    local dataObjectElements=()
    shift
    for key in "$@"; do
      dataObjectElements+=("$key")
    done
    local joinedDataObject
    joinedDataObject=$(IFS=','; echo "${dataObjectElements[*]}")
    payloadElements+=("\"data\": { $joinedDataObject }")
  fi

  local joinedPayload
  joinedPayload=$(IFS=','; echo "${payloadElements[*]}")
  local finalPayload="{ $joinedPayload }"
  echo "- sending notification to $notification_url with payload '$finalPayload'"

  curl \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $auth_token" \
    -d "$finalPayload" \
    "$notification_url"
}

function prepare() {
  local hasErrors=0

  if [ -e "$handle_path" ]; then
    hostname=$(trim "$(<"$handle_path")")
    echo "Found handle '$hostname'"
  elif [ -n "${NETBIRD_HOSTNAME:-}" ]; then
    hostname=$(trim "$NETBIRD_HOSTNAME")
    echo "Using NETBIRD_HOSTNAME '$hostname'"
  else
    hostname=$(hostname)
    echo "Using container hostname '$hostname'"
  fi
  if [ -z "$hostname" ]; then
    echo "Peer hostname is empty"
    hasErrors=1
  fi

  if [ -f "$management_url_path" ]; then
    echo "Found NetBird management_url file"
    management_url=$(trim "$(<"$management_url_path")")
  elif [ -n "${NETBIRD_MANAGEMENT_URL:-}" ]; then
    management_url=$(trim "$NETBIRD_MANAGEMENT_URL")
    echo "Using NETBIRD_MANAGEMENT_URL"
  else
    echo "NetBird management URL not found (mount $management_url_path or set NETBIRD_MANAGEMENT_URL)"
    hasErrors=1
  fi
  if [ -n "${management_url:-}" ]; then
    echo "Using management_url '$management_url'"
  fi

  local setup_key_content=""
  if [ -f "$setup_key_file_path" ]; then
    echo "Found NetBird setup key file"
    setup_key_content=$(trim "$(<"$setup_key_file_path")")
  elif [ -n "${NETBIRD_SETUP_KEY:-}" ]; then
    echo "Using NETBIRD_SETUP_KEY"
    setup_key_content=$(trim "$NETBIRD_SETUP_KEY")
  else
    echo "NetBird setup key not found (mount $setup_key_file_path or set NETBIRD_SETUP_KEY)"
    hasErrors=1
  fi

  if [ -n "$setup_key_content" ]; then
    local expected_char_count=36
    local character_count=${#setup_key_content}
    if [[ "$character_count" -ne "$expected_char_count" ]]; then
      echo "Setup key is of invalid length - '$character_count' characters when '$expected_char_count' was expected"
      exit 1
    fi
    # Always write a newline-free copy; k8s secrets often append a trailing newline.
    mkdir -p "$NB_STATE_DIR"
    setup_key_path="$NB_STATE_DIR/setup.key"
    printf '%s' "$setup_key_content" > "$setup_key_path"
    chmod 600 "$setup_key_path"
  fi

  if [ -f "$notification_url_path" ]; then
    echo "Found portal backend notification_url file"
    notification_url=$(trim "$(<"$notification_url_path")")
    echo "Using notification_url '$notification_url'"
  else
    echo "Portal backend notification_url not found (web companion webhook disabled)"
  fi

  if [ -f "$auth_token_path" ]; then
    echo "Found portal backend auth_token file"
    auth_token=$(trim "$(<"$auth_token_path")")
    echo "Using auth_token '${auth_token:0:4}...'"
  else
    echo "Portal backend auth_token not found (web companion webhook disabled)"
  fi

  if [[ "$hasErrors" -eq 1 ]]; then
    echo "Preparation errors found. Exiting..."
    exit 1
  fi

  daemon_addr=(--daemon-addr unix:///var/lib/netbird/netbird.sock)

  netbird_flags=(
    "${daemon_addr[@]}"
    --hostname "$hostname"
    --management-url "$management_url"
    --setup-key-file "$setup_key_path"
    --log-file "console,$NB_STATE_DIR/client.log"
  )
}

function on_exit() {
  notify $NOTIF_PEER_DISCONNECTING
  echo "Shutting down..."
  if [ -n "$pid_web" ]; then
    kill -TERM "$pid_web" 2>/dev/null || true
  fi
  if [ -n "$pid_nb_daemon" ]; then
    echo "Shutting down NetBird daemon..."
    kill -TERM "$pid_nb_daemon" 2>/dev/null || true
    wait "$pid_nb_daemon" 2>/dev/null || true
  fi
  notify $NOTIF_PEER_DISCONNECTED
}

function wait_for_daemon_startup() {
  local timeout="${1}"
  echo "Waiting '$timeout' seconds for netbird daemon to start"

  local deadline=$(( $(date +%s) + timeout ))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    if netbird "${daemon_addr[@]}" status --check live 2>/dev/null; then
      return
    fi
    sleep 1
  done

  echo "daemon did not become responsive after ${timeout} seconds, exiting..."
  exit 1
}

function wait_for_daemon_connected() {
  local timeout="${1}"
  echo "Waiting '$timeout' seconds for netbird daemon to connect"

  local deadline=$(( $(date +%s) + timeout ))
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    if netbird "${daemon_addr[@]}" status --json | jq -e '.daemonStatus == "Connected"' >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  echo "daemon did not connect after ${timeout} seconds, exiting..."
  exit 1
}

function main() {
  trap 'on_exit' SIGTERM SIGINT EXIT

  echo "using hostname '$hostname' and management url '$management_url'"

  notify $NOTIF_PEER_CONNECTING

  netbird service run \
    --config="$NB_STATE_DIR/config.json" \
    "${netbird_flags[@]}" \
    &
  pid_nb_daemon="$!"

  wait_for_daemon_startup 30

  echo "running 'netbird up'..."
  netbird up --disable-dns "${netbird_flags[@]}" &

  wait_for_daemon_connected 10

  local peerIp
  peerIp=$(netbird "${daemon_addr[@]}" status --ipv4)
  echo "NetBird connected as $peerIp — starting web administrator on port ${WEBADMIN_PORT:-3030}"
  notify $NOTIF_PEER_CONNECTED "\"peerIp\": \"$peerIp\""

  node web-administrator/server/index.js &
  pid_web="$!"

  # If either process exits, tear the other down so the container does not
  # keep serving with a dead mesh (or keep a mesh with a dead UI).
  wait -n "$pid_nb_daemon" "$pid_web"
  exit $?
}

prepare
main "$@"

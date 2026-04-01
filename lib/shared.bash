#!/bin/bash

# Reads a list from plugin config into a global result array
# Returns success if values were read
function plugin_read_list_into_result() {
  result=()

  for prefix in "$@" ; do
    local i=0
    local parameter="${prefix}_${i}"

    if [[ -n "${!prefix:-}" ]] ; then
      echo "🚨 Plugin received a string for $prefix, expected an array" >&2
      exit 1
    fi

    while [[ -n "${!parameter:-}" ]]; do
      result+=("${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  done

  [[ ${#result[@]} -gt 0 ]] || return 1
}

function join_by {
  local IFS="$1"
  shift
  echo "$*";
}

# Decodes the payload (second segment) of a JWT token.
# Outputs the raw JSON string on success, returns 1 on failure.
function decode_jwt_payload() {
  local token="$1"
  local payload_b64

  payload_b64=$(echo "$token" | cut -d. -f2)
  [[ -n "$payload_b64" ]] || return 1

  # JWT uses base64url encoding: - instead of +, _ instead of /
  payload_b64=$(echo "$payload_b64" | sed 's/-/+/g; s/_/\//g')

  # Add padding if needed
  case $(( ${#payload_b64} % 4 )) in
    2) payload_b64+="==" ;;
    3) payload_b64+="=" ;;
  esac

  base64 -d <<< "$payload_b64" 2>/dev/null || return 1
}

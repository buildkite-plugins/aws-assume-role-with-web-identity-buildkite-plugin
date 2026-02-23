#!/bin/bash

set -euo pipefail

DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

# shellcheck source=lib/shared.bash
. "$DIR/shared.bash"

if [[ -z "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN:-}" ]]; then
  echo "🚨 Missing 'role-arn' plugin configuration"
  exit 1
fi

role_arn="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN}"
session_name="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_NAME:-buildkite-job-${BUILDKITE_JOB_ID}}"

# prepare Buildkite command; optional args to be added before executing
request_token_cmd=(buildkite-agent oidc request-token --audience sts.amazonaws.com)

# prepare AWS command; OIDC token and optional args to be added before executing
assume_role_cmd=(aws sts assume-role-with-web-identity
  --role-arn "$role_arn"
  --role-session-name "$session_name")

# optionally add the session duration to the AWS command
if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION:-}" ]]; then
  ttl_seconds=$(printf "%d" "$BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION")
  assume_role_cmd+=(--duration-seconds "$ttl_seconds")
fi

# optionally set the OIDC token lifetime
if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME:-}" ]]; then
  request_token_cmd+=(--lifetime "$(printf "%d" "$BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME")")
fi

# If the user has provided a specific set of claims to include in the token as AWS session tags, we'll request them
if plugin_read_list_into_result BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS; then
  claims=$(join_by "," "${result[@]}")
  request_token_cmd+=(--aws-session-tag "${claims}")
  echo "Including session tags in OIDC request: ${claims}"
fi

echo "~~~ :buildkite::key::aws: Requesting an OIDC token for AWS from Buildkite"
buildkite_oidc_token=$("${request_token_cmd[@]}")

echo "~~~ :aws: Assuming role using OIDC token"
echo "Role ARN: ${role_arn}"
assume_role_cmd+=(--web-identity-token "$buildkite_oidc_token")

# Capture stderr separately so it doesn't pollute the JSON response on success
assume_role_stderr=$(mktemp)
assume_role_response=$("${assume_role_cmd[@]}" 2>"$assume_role_stderr") || assume_role_cmd_status=$?
assume_role_err=$(<"$assume_role_stderr")
rm -f "$assume_role_stderr"

if [[ ${assume_role_cmd_status:-0} -ne 0 ]]; then
  echo "^^^ +++"
  echo "Failed to assume role: ${role_arn}"
  echo ""
  echo "${assume_role_err}"
  echo ""

  # Decode the OIDC JWT to show the sub claim for debugging
  if [[ -n "${buildkite_oidc_token:-}" ]]; then
    token_payload=$(decode_jwt_payload "$buildkite_oidc_token" 2>/dev/null || true)
    token_sub=$(jq -r '.sub // empty' <<< "$token_payload" 2>/dev/null || true)
    if [[ -n "$token_sub" ]]; then
      token_ref=$(echo "$token_sub" | sed -n 's/.*ref:\(refs\/[^:]*\).*/\1/p' || true)
      echo "Token claims:"
      echo "  sub: ${token_sub}"
      if [[ -n "$token_ref" ]]; then
        echo "  ref: ${token_ref}"
      fi
      echo ""
    fi
  fi

  exit 1
fi

# Use default empty prefix if not set
CREDENTIAL_NAME_PREFIX="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX:-}"

# Parse credentials once
credentials=$(jq -r '.Credentials | "\(.AccessKeyId) \(.SecretAccessKey) \(.SessionToken)"' <<< "${assume_role_response}")
read -r ACCESS_KEY_ID SECRET_ACCESS_KEY SESSION_TOKEN <<< "${credentials}"

# Export credentials with or without prefix
if [[ -n "${CREDENTIAL_NAME_PREFIX}" ]]; then
  export "${CREDENTIAL_NAME_PREFIX}AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
  export "${CREDENTIAL_NAME_PREFIX}AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
  export "${CREDENTIAL_NAME_PREFIX}AWS_SESSION_TOKEN=${SESSION_TOKEN}"
else
  export "AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
  export "AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
  export "AWS_SESSION_TOKEN=${SESSION_TOKEN}"
fi

echo "Assumed role: $(jq -r .AssumedRoleUser.AssumedRoleId <<< "${assume_role_response}")"

if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_REGION:-}" ]]; then
  export AWS_DEFAULT_REGION="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_REGION}"
  export AWS_REGION="${AWS_DEFAULT_REGION}"
  echo "Using region: ${AWS_REGION}"
fi

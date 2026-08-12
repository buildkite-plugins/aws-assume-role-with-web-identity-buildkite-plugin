#!/bin/bash

set -euo pipefail

DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

# default maximum oidc token lifetime in seconds https://buildkite.com/docs/platform/limits
DEFAULT_MAX_OIDC_TOKEN_LIFETIME=7200

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
# if unset, and session duration is set, use the session duration if it's less than the default maximum
if [[ -z "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME:-}" && -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION:-}" ]]; then
  if [[ "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION}" -gt "${DEFAULT_MAX_OIDC_TOKEN_LIFETIME}" ]]; then
    BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME="${DEFAULT_MAX_OIDC_TOKEN_LIFETIME}"
  else
    BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION}"
  fi
fi
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

# Capture stderr separately so a failure can be reported after "^^^ +++";
# without that marker the error stays hidden inside this collapsed group.
oidc_stderr=$(mktemp)
buildkite_oidc_token=$("${request_token_cmd[@]}" 2>"$oidc_stderr") || oidc_cmd_status=$?
oidc_err=$(<"$oidc_stderr")
rm -f "$oidc_stderr"

if [[ ${oidc_cmd_status:-0} -ne 0 ]]; then
  echo "^^^ +++"
  echo "Failed to request an OIDC token from Buildkite (audience: sts.amazonaws.com)"
  echo ""
  echo "${oidc_err}"
  echo ""
  echo "The agent makes up to 5 attempts internally for 429, 5xx, and transient"
  echo "network errors, so a failure here is usually non-retryable."
  echo "'failed to decode JSON response' means the endpoint returned a 2xx with a"
  echo "non-JSON body - retry, and if it persists raise it with Buildkite support"
  echo "quoting job ${BUILDKITE_JOB_ID:-unknown}."
  exit 1
elif [[ -n "$oidc_err" ]]; then
  # Retry warnings on an eventually-successful request are worth keeping
  echo "${oidc_err}"
fi

if [[ -z "$buildkite_oidc_token" ]]; then
  echo "^^^ +++"
  echo "Buildkite returned an empty OIDC token for audience sts.amazonaws.com"
  echo "Job: ${BUILDKITE_JOB_ID:-unknown}"
  exit 1
fi

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

# jq emits "null null null" at exit 0 when .Credentials is absent, which would
# otherwise export the literal string "null" as the credentials. A non-JSON body
# makes jq exit non-zero, so this covers both.
if ! jq -e '.Credentials.AccessKeyId // empty' <<< "${assume_role_response}" >/dev/null 2>&1; then
  echo "^^^ +++"
  echo "sts assume-role-with-web-identity returned an unexpected response (no Credentials)"
  echo "Role ARN: ${role_arn}"
  exit 1
fi

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

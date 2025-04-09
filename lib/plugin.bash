#!/bin/bash

set -euo pipefail

DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

# shellcheck source=shared.bash
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

# optionally add the session duration to Buildkite and AWS commands
if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION:-}" ]]; then
  ttl_seconds=$(printf "%d" "$BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION")
  request_token_cmd+=(--lifetime "$ttl_seconds")
  assume_role_cmd+=(--duration-seconds "$ttl_seconds")
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
assume_role_response=$("${assume_role_cmd[@]}")
assume_role_cmd_status=$?

if [[ ${assume_role_cmd_status} -ne 0 ]]; then
  echo "^^^ +++"
  echo "Failed to assume AWS role:"
  echo "${assume_role_response}"
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

#!/bin/bash

set -euo pipefail

if [[ -z "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN:-}" ]]; then
  echo "🚨 Missing 'role-arn' plugin configuration"
  exit 1
fi

echo "--- :buildkite::key::aws: Requesting an OIDC token for AWS from buildkite"

BUILDKITE_OIDC_TOKEN="$(buildkite-agent oidc request-token --audience sts.amazonaws.com)"

echo "--- :aws: Assuming role using OIDC token"

echo "Role ARN: ${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN}"

RESPONSE="$(aws sts assume-role-with-web-identity \
  --role-arn "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN}" \
  --role-session-name "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_NAME:-buildkite-job-${BUILDKITE_JOB_ID}}" \
  --web-identity-token "${BUILDKITE_OIDC_TOKEN}")"

if [[ $? -ne 0 ]]; then
  echo "^^^ +++"
  echo "Failed to assume AWS role:"
  echo "${RESPONSE}"
  exit 1
fi

export AWS_ACCESS_KEY_ID="$(jq -r ".Credentials.AccessKeyId" <<< "${RESPONSE}")"
export AWS_SECRET_ACCESS_KEY="$(jq -r ".Credentials.SecretAccessKey" <<< "${RESPONSE}")"
export AWS_SESSION_TOKEN="$(jq -r ".Credentials.SessionToken" <<< "${RESPONSE}")"

echo "Assumed role: $(jq -r .AssumedRoleUser.AssumedRoleId <<< "${RESPONSE}")"

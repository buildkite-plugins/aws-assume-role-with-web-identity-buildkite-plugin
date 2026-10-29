#!/bin/bash
#
# Reference credential_process helper for the aws-assume-role-with-web-identity
# Buildkite plugin's credential-process mode.
#
# Copy this script somewhere your build commands can execute it — baked into
# your agent image or checked into your repository — and point the plugin's
# credential-process option at it:
#
#   plugins:
#     - aws-assume-role-with-web-identity#v1.8.1:
#         role-arn: arn:aws:iam::111111111111:role/example-role
#         credential-process: /usr/local/bin/aws-credential-process.sh
#
# AWS SDKs and the AWS CLI invoke this script whenever credentials are needed
# and re-invoke it when the returned credentials approach expiry; see
# https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html
# Each invocation requests a fresh Buildkite OIDC token and assumes the role
# anew, so the job keeps valid AWS credentials for as long as it can request
# OIDC tokens.
#
# Configuration is read from the AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_* environment
# variables the plugin exports; see the README for the full list.
#
# Requirements (the same ones the plugin's hook already has): buildkite-agent
# with the job's BUILDKITE_AGENT_ACCESS_TOKEN in the environment, and aws and
# jq on PATH.

set -euo pipefail

role_arn="${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN:?must be exported by the aws-assume-role-with-web-identity plugin}"
session_name="${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_NAME:?must be exported by the aws-assume-role-with-web-identity plugin}"
audience="${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_AUDIENCE:-sts.amazonaws.com}"

request_token_cmd=(buildkite-agent oidc request-token --audience "${audience}")
if [[ -n "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME:-}" ]]; then
	request_token_cmd+=(--lifetime "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME}")
fi
if [[ -n "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS:-}" ]]; then
	request_token_cmd+=(--aws-session-tag "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS}")
fi

# AssumeRoleWithWebIdentity is not signed, so --no-sign-request stops the CLI
# from loading credentials it would not use (on EC2, a fetch from instance
# metadata).
assume_role_cmd=(aws --no-sign-request sts assume-role-with-web-identity
	--role-arn "${role_arn}"
	--role-session-name "${session_name}")
if [[ -n "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION:-}" ]]; then
	assume_role_cmd+=(--duration-seconds "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION}")
fi

# The OIDC token is passed to the AWS CLI via file:// so it never appears in
# the process list.
token_file=$(mktemp "${TMPDIR:-/tmp}/buildkite-oidc-token.XXXXXX")
trap 'rm -f "${token_file}"' EXIT

if ! buildkite_oidc_token=$("${request_token_cmd[@]}"); then
	echo "credential_process: failed to request a Buildkite OIDC token" >&2
	exit 1
fi
if [[ -z "${buildkite_oidc_token}" ]]; then
	echo "credential_process: Buildkite returned an empty OIDC token" >&2
	exit 1
fi
printf '%s' "${buildkite_oidc_token}" >"${token_file}"

if ! response=$("${assume_role_cmd[@]}" --web-identity-token "file://${token_file}"); then
	echo "credential_process: sts assume-role-with-web-identity failed" >&2
	exit 1
fi

# Optionally chain into a second role with sts:AssumeRole, using the first
# role's credentials. Chained sessions are capped at one hour by AWS, which is
# exactly the case credential-process mode exists for.
if [[ -n "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN:-}" ]]; then
	credentials=$(jq -r '.Credentials | "\(.AccessKeyId) \(.SecretAccessKey) \(.SessionToken)"' <<<"${response}")
	read -r ACCESS_KEY_ID SECRET_ACCESS_KEY SESSION_TOKEN <<<"${credentials}"
	if ! response=$(AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}" AWS_SESSION_TOKEN="${SESSION_TOKEN}" \
		aws sts assume-role --role-arn "${AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN}" --role-session-name "${session_name}"); then
		echo "credential_process: sts assume-role for the chained role failed" >&2
		exit 1
	fi
fi

if ! jq -e '.Credentials.AccessKeyId // empty' <<<"${response}" >/dev/null 2>&1; then
	echo "credential_process: sts response did not contain Credentials" >&2
	exit 1
fi
jq '{Version: 1} + .Credentials' <<<"${response}"

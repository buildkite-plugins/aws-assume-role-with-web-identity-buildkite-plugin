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
audience="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_AUDIENCE:-sts.amazonaws.com}"

# prepare Buildkite command; optional args to be added before executing
request_token_cmd=(buildkite-agent oidc request-token --audience "${audience}")

# prepare AWS command; OIDC token and optional args to be added before executing
# AssumeRoleWithWebIdentity is not signed,
# so --no-sign-request stops the CLI from loading credentials it would not use
# (on EC2, a fetch from instance metadata)
assume_role_cmd=(aws --no-sign-request sts assume-role-with-web-identity
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

credential_process_mode="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS:-false}"
if [[ "${credential_process_mode}" == "true" ]]; then
  if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX:-}" ]]; then
    echo "🚨 'credential-process' cannot be combined with 'credential-name-prefix'"
    exit 1
  fi
  # The credential_process helper runs in whatever environment the process that
  # triggers it happens to have, which may not include this hook's PATH, so the
  # tools it needs are baked in as absolute paths.
  if ! aws_bin=$(command -v aws); then
    echo "🚨 'credential-process' requires 'aws' on PATH"
    exit 1
  fi
  if ! jq_bin=$(command -v jq); then
    echo "🚨 'credential-process' requires 'jq' on PATH"
    exit 1
  fi
  if ! buildkite_agent_bin=$(command -v buildkite-agent); then
    echo "🚨 'credential-process' requires 'buildkite-agent' on PATH"
    exit 1
  fi
  # Serialize the fully-built commands for the credential_process helper, before
  # the one-time OIDC token is appended to assume_role_cmd below. The helper
  # mints a fresh token on every invocation instead.
  serialized_request_token_cmd=$(printf '%q ' "${buildkite_agent_bin}" "${request_token_cmd[@]:1}")
  serialized_assume_role_cmd=$(printf '%q ' "${aws_bin}" "${assume_role_cmd[@]:1}")
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
  echo "Failed to request an OIDC token from Buildkite (audience: ${audience})"
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
  echo "Buildkite returned an empty OIDC token for audience ${audience}"
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
echo "Assumed role: $(jq -r .AssumedRoleUser.AssumedRoleId <<< "${assume_role_response}")"
read -r ACCESS_KEY_ID SECRET_ACCESS_KEY SESSION_TOKEN <<< "${credentials}"
# The identity the job is expected to run as; credential-process mode verifies
# the resolved caller identity against it.
assumed_role_arn=$(jq -r '.AssumedRoleUser.Arn // empty' <<< "${assume_role_response}")

# Optionally chain into a second role with sts:AssumeRole, using the first role's credentials
if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN:-}" ]]; then
  chain_role_arn="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN}"

  echo "~~~ :aws: Assuming chained role"
  echo "Role ARN: ${chain_role_arn}"

  # Pass the credentials explicitly; they are not in AWS_* yet, and never are with credential-name-prefix
  chain_role_stderr=$(mktemp)
  chain_role_response=$(
    AWS_ACCESS_KEY_ID="${ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${SECRET_ACCESS_KEY}" \
    AWS_SESSION_TOKEN="${SESSION_TOKEN}" \
    aws sts assume-role --role-arn "$chain_role_arn" --role-session-name "$session_name" 2>"$chain_role_stderr"
  ) || chain_role_cmd_status=$?
  chain_role_err=$(<"$chain_role_stderr")
  rm -f "$chain_role_stderr"

  if [[ ${chain_role_cmd_status:-0} -ne 0 ]]; then
    echo "^^^ +++"
    echo "Failed to assume chained role: ${chain_role_arn}"
    echo ""
    echo "${chain_role_err}"
    exit 1
  fi

  if ! jq -e '.Credentials.AccessKeyId // empty' <<< "${chain_role_response}" >/dev/null 2>&1; then
    echo "^^^ +++"
    echo "sts assume-role returned an unexpected response (no Credentials)"
    echo "Role ARN: ${chain_role_arn}"
    exit 1
  fi

  credentials=$(jq -r '.Credentials | "\(.AccessKeyId) \(.SecretAccessKey) \(.SessionToken)"' <<< "${chain_role_response}")
  read -r ACCESS_KEY_ID SECRET_ACCESS_KEY SESSION_TOKEN <<< "${credentials}"
  echo "Assumed chained role: $(jq -r .AssumedRoleUser.AssumedRoleId <<< "${chain_role_response}")"
  assumed_role_arn=$(jq -r '.AssumedRoleUser.Arn // empty' <<< "${chain_role_response}")
fi

if [[ "${credential_process_mode}" == "true" ]]; then
  # credential-process mode: instead of exporting the static credentials obtained
  # above (they only served as fail-fast validation), write a self-contained
  # credential_process helper and point AWS_CONFIG_FILE at it. AWS SDKs and the
  # AWS CLI invoke the helper whenever credentials are needed and re-invoke it
  # when the returned credentials approach expiry, so the job keeps valid AWS
  # credentials for its whole lifetime regardless of the role session duration.
  echo "~~~ :aws: Configuring credential_process for automatic credential refresh"
  credential_process_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildkite-aws-credential-process.XXXXXX")
  helper_script="${credential_process_dir}/credential-process.sh"
  {
    cat <<'EOF'
#!/bin/bash
# Generated by the aws-assume-role-with-web-identity Buildkite plugin
# (credential-process mode). Invoked by AWS SDKs and the AWS CLI as an external
# credential process; see
# https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html
# Each invocation mints a fresh Buildkite OIDC token and assumes the role anew,
# so credentials are refreshed for as long as the job can request OIDC tokens.
set -euo pipefail
EOF
    printf 'AWS_BIN=%q\n' "${aws_bin}"
    printf 'JQ_BIN=%q\n' "${jq_bin}"
    printf 'CREDENTIAL_PROCESS_DIR=%q\n' "${credential_process_dir}"
    cat <<'EOF'

# The OIDC token is passed to the AWS CLI via file:// so it never appears in
# the process list.
token_file=$(mktemp "${CREDENTIAL_PROCESS_DIR}/oidc-token.XXXXXX")
trap 'rm -f "${token_file}"' EXIT
EOF
    printf "if ! buildkite_oidc_token=\$(%s); then\n" "${serialized_request_token_cmd}"
    cat <<'EOF'
  echo "credential_process: failed to request a Buildkite OIDC token" >&2
  exit 1
fi
if [[ -z "${buildkite_oidc_token}" ]]; then
  echo "credential_process: Buildkite returned an empty OIDC token" >&2
  exit 1
fi
printf '%s' "${buildkite_oidc_token}" > "${token_file}"
EOF
    printf "if ! response=\$(%s --web-identity-token \"file://\${token_file}\"); then\n" "${serialized_assume_role_cmd}"
    cat <<'EOF'
  echo "credential_process: sts assume-role-with-web-identity failed" >&2
  exit 1
fi
EOF
    if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN:-}" ]]; then
      cat <<EOF
credentials=\$("\${JQ_BIN}" -r '.Credentials | "\(.AccessKeyId) \(.SecretAccessKey) \(.SessionToken)"' <<< "\${response}")
read -r ACCESS_KEY_ID SECRET_ACCESS_KEY SESSION_TOKEN <<< "\${credentials}"
if ! response=\$(AWS_ACCESS_KEY_ID="\${ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="\${SECRET_ACCESS_KEY}" AWS_SESSION_TOKEN="\${SESSION_TOKEN}" "\${AWS_BIN}" sts assume-role --role-arn $(printf '%q' "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN}") --role-session-name $(printf '%q' "${session_name}")); then
  echo "credential_process: sts assume-role for the chained role failed" >&2
  exit 1
fi
EOF
    fi
    cat <<'EOF'
if ! "${JQ_BIN}" -e '.Credentials.AccessKeyId // empty' <<< "${response}" > /dev/null 2>&1; then
  echo "credential_process: sts response did not contain Credentials" >&2
  exit 1
fi
"${JQ_BIN}" '{Version: 1} + .Credentials' <<< "${response}"
EOF
  } > "${helper_script}"
  chmod +x "${helper_script}"

  # credential_process is read from the active profile; mirror AWS_PROFILE if
  # set. In a config file the default profile is "[default]" — a
  # "[profile default]" section matches nothing — so AWS_PROFILE=default gets
  # the same header as an unset AWS_PROFILE.
  if [[ -n "${AWS_PROFILE:-}" && "${AWS_PROFILE}" != "default" ]]; then
    profile_header="[profile ${AWS_PROFILE}]"
  else
    profile_header="[default]"
  fi
  aws_config="${credential_process_dir}/aws-config"
  cat > "${aws_config}" <<EOF
${profile_header}
credential_process = "${helper_script}"
EOF

  # Anything that outranks credential_process must not silently resolve to a
  # different identity: static environment credentials and IRSA-style
  # web-identity variables are unset, and the shared credentials file
  # (~/.aws/credentials ranks above the config file) is replaced with an empty
  # one.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  unset AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE
  : > "${credential_process_dir}/aws-shared-credentials"
  export AWS_SHARED_CREDENTIALS_FILE="${credential_process_dir}/aws-shared-credentials"

  # Without other credentials, a tool that ignores AWS_CONFIG_FILE would
  # silently fall back to the node's instance profile via IMDS. Disable that
  # fallback so the failure is loud instead.
  export AWS_EC2_METADATA_DISABLED=true

  export AWS_CONFIG_FILE="${aws_config}"
  export AWS_SDK_LOAD_CONFIG=1
  echo "AWS_CONFIG_FILE: ${aws_config}"

  # So the pre-exit hook can remove the working directory when the job ends.
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS_DIR="${credential_process_dir}"

  # Exercise the full chain (config file -> credential_process helper -> STS)
  # and confirm the resolved identity matches the role assumed above. Without
  # this, a config that is not picked up would only surface mid-job, possibly
  # as a different identity.
  echo "Verifying the identity resolved through credential_process"
  if [[ -z "${assumed_role_arn}" ]]; then
    echo "^^^ +++"
    echo "sts returned an unexpected response (no AssumedRoleUser.Arn); cannot verify the credential_process identity"
    exit 1
  fi
  caller_identity_stderr=$(mktemp)
  caller_identity=$(aws sts get-caller-identity 2>"${caller_identity_stderr}") || caller_identity_status=$?
  caller_identity_err=$(<"${caller_identity_stderr}")
  rm -f "${caller_identity_stderr}"
  if [[ ${caller_identity_status:-0} -ne 0 ]]; then
    echo "^^^ +++"
    echo "credential_process verification failed: aws sts get-caller-identity did not succeed"
    echo ""
    echo "${caller_identity_err}"
    exit 1
  fi
  caller_identity_arn=$(jq -r '.Arn // empty' <<< "${caller_identity}")
  if [[ "${caller_identity_arn}" != "${assumed_role_arn}" ]]; then
    echo "^^^ +++"
    echo "credential_process resolved to an unexpected identity"
    echo "Expected: ${assumed_role_arn}"
    echo "Actual:   ${caller_identity_arn:-<none>}"
    echo ""
    echo "Something other than the generated AWS config file supplied the"
    echo "credentials. Failing the step rather than running as that identity."
    exit 1
  fi
  echo "Verified caller identity: ${caller_identity_arn}"
elif [[ -n "${CREDENTIAL_NAME_PREFIX}" ]]; then
  # Export credentials with prefix
  export "${CREDENTIAL_NAME_PREFIX}AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
  export "${CREDENTIAL_NAME_PREFIX}AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
  export "${CREDENTIAL_NAME_PREFIX}AWS_SESSION_TOKEN=${SESSION_TOKEN}"
else
  # Export credentials without prefix
  export "AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
  export "AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
  export "AWS_SESSION_TOKEN=${SESSION_TOKEN}"
fi

if [[ -n "${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_REGION:-}" ]]; then
  export AWS_DEFAULT_REGION="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_REGION}"
  export AWS_REGION="${AWS_DEFAULT_REGION}"
  echo "Using region: ${AWS_REGION}"
fi

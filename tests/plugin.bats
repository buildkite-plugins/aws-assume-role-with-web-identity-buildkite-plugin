#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

# Uncomment to enable stub debugging
# export AWS_STUB_DEBUG=/dev/tty

# Source the command and print environment variables to allow for assertions.
# This could be done by skipping the "run" command, but it makes for a more readable test.
run_test_command() {
  local VARNAMES=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION AWS_CONFIG_FILE AWS_SDK_LOAD_CONFIG AWS_EC2_METADATA_DISABLED AWS_SHARED_CREDENTIALS_FILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_NAME AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_AUDIENCE AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN)
  local NAME_PREFIX="${BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX:-}"

  ( # using a subshell to avoid polluting the test environment
    # shellcheck source=lib/plugin.bash
    source "$PWD/lib/plugin.bash"
    for var in "${VARNAMES[@]}"; do
      echo "TESTRESULT:${var}=${!var:-<value not set>}"
      if [ -n "${NAME_PREFIX}" ]; then
        varname="${NAME_PREFIX}${var}"
        echo "TESTRESULT:${varname}=${!varname:-<value not set>}"
      fi
    done
  )
}

@test "calls aws sts and exports AWS_ env vars" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "requests OIDC token with custom audience" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_AUDIENCE="my-custom-audience"

  stub buildkite-agent "oidc request-token --audience my-custom-audience : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "calls aws sts and exports AWS_ env vars in pre-command hook" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "failure to get token" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'failed to get OIDC token' >&2; exit 1"

  run run_test_command

  assert_failure
  # Without the expansion marker the error stays hidden in the collapsed group
  assert_output --partial "^^^ +++"
  assert_output --partial "Failed to request an OIDC token from Buildkite (audience: sts.amazonaws.com)"
  assert_output --partial "failed to get OIDC token"
  assert_output --partial "job job-uuid-42"

  unstub buildkite-agent
}

@test "empty OIDC token is rejected before calling sts" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  # Exits 0 but prints nothing; aws must not be called with an empty token
  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : true"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "Buildkite returned an empty OIDC token for audience sts.amazonaws.com"
  assert_output --partial "Job: job-uuid-42"
  refute_output --partial "Role ARN: role123"

  unstub buildkite-agent
}

@test "agent stderr is preserved when the token request eventually succeeds" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'warn: 503 (attempt 2/5)' >&2; echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "warn: 503 (attempt 2/5)"
  assert_output --partial "Assumed role: assumed-role-id-value"
  refute_output --partial "^^^ +++"

  unstub aws
  unstub buildkite-agent
}

@test "sts response without Credentials fails instead of exporting null" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo '{\"AssumedRoleUser\":{\"AssumedRoleId\":\"x\"}}'"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "sts assume-role-with-web-identity returned an unexpected response (no Credentials)"
  refute_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=null"

  unstub aws
  unstub buildkite-agent
}

@test "non-JSON sts response fails instead of exporting null" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo '<html><body>502 Bad Gateway</body></html>'"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "sts assume-role-with-web-identity returned an unexpected response (no Credentials)"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume role" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo 'Not authorized to perform sts:AssumeRoleWithWebIdentity' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "Failed to assume role: role123"
  assert_output --partial "Not authorized to perform sts:AssumeRoleWithWebIdentity"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume role shows token claims" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  # Build a fake JWT with a sub claim containing a ref
  # Payload: {"sub":"organization:test-org:pipeline:my-pipeline:ref:refs/heads/main:commit:abc123:step:build"}
  jwt_payload='{"sub":"organization:test-org:pipeline:my-pipeline:ref:refs/heads/main:commit:abc123:step:build"}'
  jwt_payload_b64=$(echo -n "$jwt_payload" | base64 | tr -d '\n')
  fake_jwt="header.${jwt_payload_b64}.signature"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo '${fake_jwt}'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "Failed to assume role: role123"
  assert_output --partial "Token claims:"
  assert_output --partial "sub: organization:test-org:pipeline:my-pipeline:ref:refs/heads/main:commit:abc123:step:build"
  assert_output --partial "ref: refs/heads/main"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume role with base64url encoded JWT decodes token claims" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  # JWT uses base64url: replace + with -, / with _, strip = padding
  jwt_payload='{"sub":"organization:test-org:pipeline:my-pipeline:ref:refs/heads/feat/my-branch:commit:abc123:step:build"}'
  jwt_payload_b64=$(echo -n "$jwt_payload" | base64 | tr '+/' '-_' | tr -d '=\n')
  fake_jwt="header.${jwt_payload_b64}.signature"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo '${fake_jwt}'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "Token claims:"
  assert_output --partial "sub: organization:test-org:pipeline:my-pipeline:ref:refs/heads/feat/my-branch:commit:abc123:step:build"
  assert_output --partial "ref: refs/heads/feat/my-branch"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume role with no sub claim omits token claims" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  jwt_payload='{"aud":"sts.amazonaws.com","iss":"agent.buildkite.com"}'
  jwt_payload_b64=$(echo -n "$jwt_payload" | base64 | tr -d '\n')
  fake_jwt="header.${jwt_payload_b64}.signature"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo '${fake_jwt}'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "Failed to assume role: role123"
  refute_output --partial "Token claims:"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume role with sub but no ref omits ref line" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  jwt_payload='{"sub":"organization:test-org:service-account:my-sa"}'
  jwt_payload_b64=$(echo -n "$jwt_payload" | base64 | tr -d '\n')
  fake_jwt="header.${jwt_payload_b64}.signature"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo '${fake_jwt}'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "Token claims:"
  assert_output --partial "sub: organization:test-org:service-account:my-sa"
  refute_output --partial "  ref:"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume role with non-JWT token omits token claims" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'not-a-jwt-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token not-a-jwt-token : echo 'AccessDenied' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "Failed to assume role: role123"
  refute_output --partial "Token claims:"

  unstub aws
  unstub buildkite-agent
}

@test "calls aws sts with custom oidc token lifetime" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME="300"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --lifetime 300 : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "calls aws sts with custom duration and custom oidc token lifetime" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION="43200"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME="7201"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --lifetime 7201 : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 43200 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "calls aws sts with custom duration less than maximum default oidc lifetime" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION="6800"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --lifetime 6800 : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 6800 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "calls aws sts with custom duration greater than default maximum oidc lifetime" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION="43200"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --lifetime 7200 : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 43200 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "passes in a custom region" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_REGION="eu-central-1"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Using region: eu-central-1"
  assert_output --partial "Role ARN: role123"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"
  assert_output --partial "TESTRESULT:AWS_REGION=eu-central-1"
  assert_output --partial "TESTRESULT:AWS_DEFAULT_REGION=eu-central-1"

  unstub aws
  unstub buildkite-agent
}

@test "passes in a set of session-tags" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS_0="organization_id"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS_1="pipeline_id"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --aws-session-tag organization_id,pipeline_id : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Including session tags in OIDC request: organization_id,pipeline_id"
  assert_output --partial "Role ARN: role123"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "region not used for STS call" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_REGION="eu-central-1"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo \"STS-REGION:[\${AWS_REGION-<not set>}]\" 1>&2; cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Using region: eu-central-1"
  assert_output --partial "Role ARN: role123"
  # The stub writes STS-REGION to stderr, which is captured separately and not
  # shown in stdout. The key assertion is that region is NOT eu-central-1 during
  # the STS call (i.e. it's only set after assume-role succeeds).
  refute_output --partial "STS-REGION:[eu-central-1]"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"
  assert_output --partial "TESTRESULT:AWS_REGION=eu-central-1"
  assert_output --partial "TESTRESULT:AWS_DEFAULT_REGION=eu-central-1"

  unstub aws
  unstub buildkite-agent
}

@test "does not pass in a custom region" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=session-token-value"
  assert_output --partial "TESTRESULT:AWS_REGION=<value not set>"
  assert_output --partial "TESTRESULT:AWS_DEFAULT_REGION=<value not set>"

  unstub aws
  unstub buildkite-agent
}

@test "chains a second role assumption when chain-role-arn is set" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN="chain-role456"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws \
    "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json" \
    "sts assume-role --role-arn chain-role456 --role-session-name buildkite-job-job-uuid-42 : cat tests/chain-sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"
  assert_output --partial "Role ARN: chain-role456"
  assert_output --partial "Assumed chained role: chain-assumed-role-id-value"

  # Final credentials should be those from the chained role
  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=chain-access-key-id-value"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=chain-secret-access-key-value"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=chain-session-token-value"

  unstub aws
  unstub buildkite-agent
}

@test "chains a second role assumption using role-session-name" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_NAME="custom-session"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN="chain-role456"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws \
    "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name custom-session --web-identity-token buildkite-oidc-token : cat tests/sts.json" \
    "sts assume-role --role-arn chain-role456 --role-session-name custom-session : cat tests/chain-sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Assumed chained role: chain-assumed-role-id-value"
  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=chain-access-key-id-value"

  unstub aws
  unstub buildkite-agent
}

@test "chained role response without Credentials fails instead of exporting null" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN="chain-role456"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws \
    "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json" \
    "sts assume-role --role-arn chain-role456 --role-session-name buildkite-job-job-uuid-42 : echo '{\"AssumedRoleUser\":{\"AssumedRoleId\":\"x\"}}'"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "sts assume-role returned an unexpected response (no Credentials)"
  assert_output --partial "Role ARN: chain-role456"
  refute_output --partial "AWS_ACCESS_KEY_ID=null"

  unstub aws
  unstub buildkite-agent
}

@test "failure to assume chained role exits with error" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN="chain-role456"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws \
    "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json" \
    "sts assume-role --role-arn chain-role456 --role-session-name buildkite-job-job-uuid-42 : echo 'AccessDenied' >&2; exit 1"

  run run_test_command

  assert_failure
  assert_output --partial "^^^ +++"
  assert_output --partial "Failed to assume chained role: chain-role456"
  assert_output --partial "AccessDenied"

  unstub aws
  unstub buildkite-agent
}

@test "chains a second role assumption and respects credential name prefix" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN="chain-role456"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX="MY_PREFIX_"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws \
    "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json" \
    "sts assume-role --role-arn chain-role456 --role-session-name buildkite-job-job-uuid-42 : cat tests/chain-sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Assumed chained role: chain-assumed-role-id-value"

  # Final prefixed credentials should be from the chained role
  assert_output --partial "TESTRESULT:MY_PREFIX_AWS_ACCESS_KEY_ID=chain-access-key-id-value"
  assert_output --partial "TESTRESULT:MY_PREFIX_AWS_SECRET_ACCESS_KEY=chain-secret-access-key-value"
  assert_output --partial "TESTRESULT:MY_PREFIX_AWS_SESSION_TOKEN=chain-session-token-value"

  # Standard vars should remain unset
  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=<value not set>"

  unstub aws
  unstub buildkite-agent
}

@test "uses credential name prefix when specified" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX="MY_PREFIX_"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  assert_output --partial "Role ARN: role123"
  assert_output --partial "Assumed role: assumed-role-id-value"

  # Check that prefixed environment variables are set
  assert_output --partial "TESTRESULT:MY_PREFIX_AWS_ACCESS_KEY_ID=access-key-id-value"
  assert_output --partial "TESTRESULT:MY_PREFIX_AWS_SECRET_ACCESS_KEY=secret-access-key-value"
  assert_output --partial "TESTRESULT:MY_PREFIX_AWS_SESSION_TOKEN=session-token-value"

  # Original variables should not be set
  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=<value not set>"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=<value not set>"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=<value not set>"

  unstub aws
  unstub buildkite-agent
}

@test "credential-process mode writes config instead of exporting AWS_ env vars" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="$PWD/tests/credential-process.sh"
  # Pre-existing credentials from other sources must be neutralized
  export AWS_ACCESS_KEY_ID="pre-existing-access-key"
  export AWS_SECRET_ACCESS_KEY="pre-existing-secret-key"
  export AWS_SESSION_TOKEN="pre-existing-session-token"
  export AWS_ROLE_ARN="arn:aws:iam::111111111111:role/irsa-role"
  export AWS_WEB_IDENTITY_TOKEN_FILE="/var/run/secrets/eks.amazonaws.com/serviceaccount/token"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  # The up-front assume-role call still happens, as fail-fast validation
  assert_output --partial "Assumed role: assumed-role-id-value"
  assert_output --partial "Configuring credential_process for automatic credential refresh"

  # Static and IRSA credentials must not be exported; the config file points at the script
  assert_output --partial "TESTRESULT:AWS_ACCESS_KEY_ID=<value not set>"
  assert_output --partial "TESTRESULT:AWS_SECRET_ACCESS_KEY=<value not set>"
  assert_output --partial "TESTRESULT:AWS_SESSION_TOKEN=<value not set>"
  assert_output --partial "TESTRESULT:AWS_ROLE_ARN=<value not set>"
  assert_output --partial "TESTRESULT:AWS_WEB_IDENTITY_TOKEN_FILE=<value not set>"
  assert_output --partial "TESTRESULT:AWS_SDK_LOAD_CONFIG=1"
  assert_output --partial "TESTRESULT:AWS_EC2_METADATA_DISABLED=true"

  # The plugin's resolved configuration is exported for the script to consume
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN=role123"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_NAME=buildkite-job-job-uuid-42"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_AUDIENCE=sts.amazonaws.com"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION=<value not set>"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME=<value not set>"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS=<value not set>"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN=<value not set>"

  aws_config=$(echo "$output" | sed -n 's/^TESTRESULT:AWS_CONFIG_FILE=//p')
  [ -f "$aws_config" ]
  grep -q '^\[default\]$' "$aws_config"
  grep -qF "credential_process = \"$PWD/tests/credential-process.sh\"" "$aws_config"

  # The shared credentials file is replaced with an empty one so it cannot
  # outrank credential_process
  shared_credentials_file=$(echo "$output" | sed -n 's/^TESTRESULT:AWS_SHARED_CREDENTIALS_FILE=//p')
  [ -f "$shared_credentials_file" ]
  [ ! -s "$shared_credentials_file" ]

  unstub aws
  unstub buildkite-agent
}

@test "credential-process mode fails when the script does not exist" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="/nonexistent/credential-process.sh"

  run run_test_command

  assert_failure
  assert_output --partial "'credential-process' script not found: /nonexistent/credential-process.sh"
}

@test "credential-process mode fails when the script is not executable" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  non_executable=$(mktemp)
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="${non_executable}"

  run run_test_command

  assert_failure
  assert_output --partial "'credential-process' script is not executable: ${non_executable}"
}

@test "credential-process mode exports session config for the script" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="$PWD/tests/credential-process.sh"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION="6800"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS_0="organization_id"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS_1="pipeline_id"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN="chain-role456"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --lifetime 6800 --aws-session-tag organization_id,pipeline_id : echo 'buildkite-oidc-token'"
  stub aws \
    "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 6800 --web-identity-token buildkite-oidc-token : cat tests/sts.json" \
    "sts assume-role --role-arn chain-role456 --role-session-name buildkite-job-job-uuid-42 : cat tests/chain-sts.json"

  run run_test_command

  assert_success
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION=6800"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_OIDC_TOKEN_LIFETIME=6800"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_SESSION_TAGS=organization_id,pipeline_id"
  assert_output --partial "TESTRESULT:AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CHAIN_ROLE_ARN=chain-role456"

  unstub aws
  unstub buildkite-agent
}

@test "credential-process mode resolves a relative script path to absolute" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="tests/credential-process.sh"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  aws_config=$(echo "$output" | sed -n 's/^TESTRESULT:AWS_CONFIG_FILE=//p')
  grep -qF "credential_process = \"$PWD/tests/credential-process.sh\"" "$aws_config"

  unstub aws
  unstub buildkite-agent
}

@test "credential-process mode writes the config header for AWS_PROFILE when set" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="$PWD/tests/credential-process.sh"
  export AWS_PROFILE="myprofile"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  aws_config=$(echo "$output" | sed -n 's/^TESTRESULT:AWS_CONFIG_FILE=//p')
  grep -q '^\[profile myprofile\]$' "$aws_config"

  unstub aws
  unstub buildkite-agent
}

@test "credential-process mode writes [default] when AWS_PROFILE is default" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="$PWD/tests/credential-process.sh"
  export AWS_PROFILE="default"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "--no-sign-request sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

  run run_test_command

  assert_success
  aws_config=$(echo "$output" | sed -n 's/^TESTRESULT:AWS_CONFIG_FILE=//p')
  grep -q '^\[default\]$' "$aws_config"
  ! grep -q 'profile default' "$aws_config"

  unstub aws
  unstub buildkite-agent
}

@test "credential-process mode rejects credential-name-prefix" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS="$PWD/tests/credential-process.sh"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX="MY_PREFIX_"

  run run_test_command

  assert_failure
  assert_output --partial "'credential-process' cannot be combined with 'credential-name-prefix'"
}


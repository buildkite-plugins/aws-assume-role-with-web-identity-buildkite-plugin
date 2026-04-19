#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

# Uncomment to enable stub debugging
# export AWS_STUB_DEBUG=/dev/tty

# Source the command and print environment variables to allow for assertions.
# This could be done by skipping the "run" command, but it makes for a more readable test.
run_test_command() {
  local VARNAMES=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION)
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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  assert_output --partial "failed to get OIDC token"

  unstub buildkite-agent
}

@test "failure to assume role" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo 'Not authorized to perform sts:AssumeRoleWithWebIdentity' >&2; exit 1"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token ${fake_jwt} : echo 'AccessDenied' >&2; exit 1"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token not-a-jwt-token : echo 'AccessDenied' >&2; exit 1"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 43200 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 6800 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --duration-seconds 43200 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo \"STS-REGION:[\${AWS_REGION-<not set>}]\" 1>&2; cat tests/sts.json"

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
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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

@test "uses credential name prefix when specified" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX="MY_PREFIX_"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : cat tests/sts.json"

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

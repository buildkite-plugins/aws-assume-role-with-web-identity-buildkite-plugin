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

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'failed to get OIDC token' >&2; false"

  run run_test_command

  assert_failure
  assert_output <<EOF
~~~ Assuming IAM role role123 ...
Not authorized to perform sts:AssumeRoleWithWebIdentity
EOF

  unstub buildkite-agent
}

@test "failure to assume role" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com * : echo 'buildkite-oidc-token'"
  stub aws "sts assume-role-with-web-identity --role-arn role123 --role-session-name buildkite-job-job-uuid-42 --web-identity-token buildkite-oidc-token : echo 'Not authorized to perform sts:AssumeRoleWithWebIdentity' >&2; false"

  run run_test_command

  assert_failure
  assert_output <<EOF
~~~ Assuming IAM role role123 ...
Not authorized to perform sts:AssumeRoleWithWebIdentity
EOF

  unstub aws
  unstub buildkite-agent
}

@test "calls aws sts with custom duration" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_SESSION_DURATION="43200"

  stub buildkite-agent "oidc request-token --audience sts.amazonaws.com --lifetime 43200 : echo 'buildkite-oidc-token'"
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
  refute_output --partial "STS-REGION:[eu-central-1]"
  assert_output --partial "STS-REGION:[<not set>]"

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

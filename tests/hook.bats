#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

@test "pre-command hook does nothing when configured to use the environment hook" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_HOOK="environment"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  run "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "Skipping pre-command hook"
}

@test "environment hook does nothing when configured to use the pre-command hook" {
  export BUILDKITE_JOB_ID="job-uuid-42"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_HOOK="pre-command"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_ROLE_ARN="role123"

  run "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Skipping environment hook"
}

@test "pre-exit hook removes the credential_process working directory" {
  credential_process_dir=$(mktemp -d "${TMPDIR:-/tmp}/buildkite-aws-credential-process.XXXXXX")
  touch "${credential_process_dir}/aws-config"
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS_DIR="${credential_process_dir}"

  run "$PWD/hooks/pre-exit"

  assert_success
  assert_output --partial "Removed credential_process working directory"
  [ ! -d "${credential_process_dir}" ]
}

@test "pre-exit hook does nothing when credential-process mode was not used" {
  unset BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS_DIR || true

  run "$PWD/hooks/pre-exit"

  assert_success
  refute_output --partial "Removed credential_process working directory"
}

@test "pre-exit hook does not remove a directory it did not create" {
  other_dir=$(mktemp -d "${TMPDIR:-/tmp}/some-other-dir.XXXXXX")
  export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_PROCESS_DIR="${other_dir}"

  run "$PWD/hooks/pre-exit"

  assert_success
  refute_output --partial "Removed credential_process working directory"
  [ -d "${other_dir}" ]
  rm -rf "${other_dir}"
}

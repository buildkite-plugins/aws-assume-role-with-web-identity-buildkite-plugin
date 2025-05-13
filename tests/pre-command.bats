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

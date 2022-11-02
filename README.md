# AWS assume-role-with-web-identity

A [Buildkite plugin](https://buildkite.com/docs/plugins) to [assume-role-with-web-identity](https://docs.aws.amazon.com/cli/latest/reference/sts/assume-role-with-web-identity.html) using a Buildkite OIDC token before running the build command.

## Usage

Use the plugin in your steps like this:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
    - sj26/aws-assume-role-with-web-identity:
        role-arn: arn:aws:iam::AWS-ACCOUNT-ID:role/SOME-ROLE
```

The `$BUILDKITE_OIDC_TOKEN` will be exchanged for AWS credentials which are then added into the environment so tools like the AWS CLI will use the assumed role.

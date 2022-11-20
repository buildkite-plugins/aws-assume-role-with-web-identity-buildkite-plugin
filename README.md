# AWS assume-role-with-web-identity

A [Buildkite plugin](https://buildkite.com/docs/plugins) to [assume-role-with-web-identity](https://docs.aws.amazon.com/cli/latest/reference/sts/assume-role-with-web-identity.html) using a Buildkite OIDC token before running the build command.

**This plugin is currently experimental.**

## Usage

You will need to configure an appopriate [OIDC identity provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc.html) in your AWS account with a _Provider URL_ of `https://agent.buildkite.com` and an _Audience_ of `sts.amazonaws.com`. Then you can [create a role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html) to be assumed.

Use the plugin in your steps like this:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
    - aws-assume-role-with-web-identity:
        role-arn: arn:aws:iam::AWS-ACCOUNT-ID:role/SOME-ROLE
```

This will call `buildkite-agent oidc request-token --audience sts.amazonaws.com` and exchange the resulting token for AWS credentials which are then added into the environment so tools like the AWS CLI will use the assumed role.

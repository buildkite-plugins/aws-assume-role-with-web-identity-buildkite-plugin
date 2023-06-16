# AWS assume-role-with-web-identity

A [Buildkite plugin](https://buildkite.com/docs/plugins) to [assume-role-with-web-identity](https://docs.aws.amazon.com/cli/latest/reference/sts/assume-role-with-web-identity.html) using a Buildkite OIDC token before running the build command.

## Usage

You will need to configure an appropriate [OIDC identity provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc.html) in your AWS account with a _Provider URL_ of `https://agent.buildkite.com` and an _Audience_ of `sts.amazonaws.com`. This can be [automated with Terraform](#terraform). Then you can [create a role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html) to be assumed.

Use the plugin in your steps like this:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
    - aws-assume-role-with-web-identity:
        role-arn: arn:aws:iam::AWS-ACCOUNT-ID:role/SOME-ROLE
```

This will call `buildkite-agent oidc request-token --audience sts.amazonaws.com` and exchange the resulting token for AWS credentials which are then added into the environment so tools like the AWS CLI will use the assumed role.

### Terraform

If you automate your infrastructure with Terraform, the following configuration will setup a valid OIDC IdP in AWS -- adapted from [an example for using OIDC with EKS](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster.html#enabling-iam-roles-for-service-accounts):

```terraform
locals {
  agent_endpoint = "https://agent.buildkite.com"
}

data "tls_certificate" "buildkite-agent" {
  url = locals.agent_endpoint
}

resource "aws_iam_openid_connect_provider" "buildkite-agent" {
  url = locals.agent_endpoint

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    data.tls_certificate.buildkite-agent.certificates[0].sha1_fingerprint,
  ]
}
```

# AWS assume-role-with-web-identity

A [Buildkite plugin] to [assume-role-with-web-identity] using a [Buildkite OIDC token] before running the build command.

[Buildkite plugin]: https://buildkite.com/docs/plugins
[assume-role-with-web-identity]: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/sts/assume-role-with-web-identity.html
[assume-role-with-web-identity-options]: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/sts/assume-role-with-web-identity.html#options
[Buildkite OIDC token]: https://buildkite.com/docs/agent/v3/cli-oidc

> [!IMPORTANT]
> You will need to configure an appropriate [OIDC identity
> provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc.html)
> in your AWS account with a _Provider URL_ of `https://agent.buildkite.com` and
> an _Audience_ of `sts.amazonaws.com`. This can be [automated with
> Terraform](#aws-configuration-with-terraform). Then you can [create a
> role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html)
> to be assumed.

## Example

Use the plugin in your steps like this:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
      - aws-assume-role-with-web-identity#v1.1.0:
          role-arn: arn:aws:iam::AWS-ACCOUNT-ID:role/SOME-ROLE
```

This will call `buildkite-agent oidc request-token --audience sts.amazonaws.com` and exchange the resulting token for AWS credentials which are then added into the environment so tools like the AWS CLI will use the assumed role.

## Configuration

### `role-name` (required, string)

The name of the IAM role this plugin should assume.

### `role-session-name` (optional, string)

The value of the [`role-session-name`][assume-role-with-web-identity-options] to pass with the STS request. This value can be [referred to in assume-role policy][sts-role-session-name], and will be recorded in Cloudtrail.

Defaults to `buildkite-job-${BUILDKITE_JOB_ID}`.

[sts-role-session-name]: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#ck_rolesessionname

### `role-session-duration` (optional, integer)

An integer number of seconds that the assumed role session should last. Passed as the value of the [`duration-seconds`][assume-role-with-web-identity-options]  parameter in the STS request.

Defaults to `3600` (via the AWS CLI).

### `session-tags` (optional, string)

A comma separated list of [claims supported in Buildkite OIDC
tokens](https://buildkite.com/docs/agent/v3/cli-oidc). When provided, the
returned OIDC tokens will have the requested claims duplicated into AWS Session
Tokens. These can then be checked in Conditions on the IAM Role Trist Policy.

Eg. `organization_slug,pipeline_slug,build_branch`

Defaults to `` (empty).

> [!NOTE]
> `session-tags` requires buildkite-agent v3.83.0 or better

### `region` (optional, string)

Exports `AWS_REGION` and `AWS_DEFAULT_REGION` with the value you set. If not set
the values of `AWS_REGION` and `AWS_DEFAULT_REGION` will not be changed.

Note that and `AWS_REGION` is used by the AWS CLI v2 and most SDKs.
`AWS_DEFAULT_REGION` is included for compatibility with older SDKs and CLI
versions.

## IAM Role Trust Policies

There are two main options for defining which Buildkite OIDC tokens are permitted to assume an IAM Role.

### Without Session Tags

This is the default behaviour of this plugin. Given a Buildkite pipeline step like so:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
      - aws-assume-role-with-web-identity#v1.1.0:
          role-arn: arn:aws:iam::111111111111:role/example-role
```
The following trust policy on the IAM role will permit a Buildkite Job to assume the role if:

* The organization slug is `ORG_SLUG`
* The pipeline slug is `PIPELINE_SLUG`
* The build is for the `main` branch
* The agent is using either of the two provided IP addresses

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::111111111111:oidc-provider/agent.buildkite.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "agent.buildkite.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "agent.buildkite.com:sub": "organization:ORG_SLUG:pipeline:PIPELINE_SLUG:ref:main:*"
                },
                "IpAddress": {
                    "aws:SourceIp": [
                        "AGENT_PUBLIC_IP_ONE",
                        "AGENT_PUBLIC_IP_TWO"
                    ]
                }

            }
        }
    ]
}
```

### With Session Tags

Alternatively, the Buildkite pipeline step can include the `session-tags` option:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
      - aws-assume-role-with-web-identity#v1.1.0:
          role-arn: arn:aws:iam::111111111111:role/example-role
          session-tags: organization_slug,pipeline_slug,build_branch
```
This means the trust policy on the IAM role can implement the same conditions, but avoid the error prone `sub` claim:


```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::111111111111:oidc-provider/agent.buildkite.com"
            },
            "Action": [
                "sts:AssumeRoleWithWebIdentity",
                "sts:TagSession"
            ],
            "Condition": {
                "StringEquals": {
                    "agent.buildkite.com:aud": "sts.amazonaws.com"
                },
                "ForAnyValue:StringEquals": {
                    "aws:RequestTag/organization_slug": "ORG_SLUG",
                    "aws:RequestTag/pipeline_slug": "PIPELINE_SLUG",
                    "aws:RequestTag/build_branch": "main"
                },
                "IpAddress": {
                    "aws:SourceIp": [
                        "AGENT_PUBLIC_IP_ONE",
                        "AGENT_PUBLIC_IP_TWO"
                    ]
                }
            }
        }
    ]
}
```

A useful pattern with `session-tags` is to request the `organization_id` and `pipeline_id` claims. These values
are UUIDs that will never change, so they:

* will continue to work even if an organization or pipeline is renamed
* mitigate any risk of being reused by different organizations or pipelines in
  the future, should the intended organization or pipeline be deleted

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
      - aws-assume-role-with-web-identity#v1.1.0:
          role-arn: arn:aws:iam::111111111111:role/example-role
          session-tags: organization_id,pipeline_id
```

## AWS configuration with Terraform

If you automate your infrastructure with Terraform, the following configuration will setup a valid OIDC IdP in AWS -- adapted from [an example for using OIDC with EKS](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster.html#enabling-iam-roles-for-service-accounts):

```terraform
locals {
  agent_endpoint = "https://agent.buildkite.com"
}

data "tls_certificate" "buildkite-agent" {
  url = local.agent_endpoint
}

resource "aws_iam_openid_connect_provider" "buildkite-agent" {
  url = local.agent_endpoint

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    data.tls_certificate.buildkite-agent.certificates[0].sha1_fingerprint,
  ]
}
```

The oidc request will set the audience and subject as follows:
- Audience: `sts.amazonaws.com`
- Subject: `organization:<ORG_SLUG>:pipeline:<PIPELINE_SLUG>:ref:<BRANCH_REF>:commit:<BUILD_COMMIT>:step:<STEP_ID>`

In addition to the `aws_iam_openid_connect_provider` the role being assumed should have a trust policy that can be defined like so.
Be sure to replace the <ORG_SLUG> and/or <PIPELINE_SLUG> placeholders.

```terraform
data "aws_iam_policy_document" "buildkite-oidc-assume-role-trust-policy" {
  statement {
    sid     = "BuildkiteAssumeRole"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.buildkite-agent.arn]
    }
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "agent.buildkite.com:sub"
      values   = [
        "organization:<ORG_SLUG>:pipeline:*", # Example: Allow any pipeline in the organization access
        "organization:<ORG_SLUG>:pipeline:<PIPELINE_SLUG>:*", # Example: Restrict access to a pipeline in the organization
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "agent.buildkite.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
```

# AWS assume-role-with-web-identity

A [Buildkite plugin] to [assume-role-with-web-identity] using a [Buildkite OIDC token] before running the build command.

[Buildkite plugin]: https://buildkite.com/docs/plugins
[assume-role-with-web-identity]: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/sts/assume-role-with-web-identity.html
[assume-role-with-web-identity-options]: https://awscli.amazonaws.com/v2/documentation/api/latest/reference/sts/assume-role-with-web-identity.html#options
[Buildkite OIDC token]: https://buildkite.com/docs/agent/cli/reference/oidc
[buildkite-agent-oidc-options]: https://buildkite.com/docs/agent/cli/reference/oidc#request-oidc-token-options

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
      - aws-assume-role-with-web-identity#v1.8.1:
          role-arn: arn:aws:iam::AWS-ACCOUNT-ID:role/SOME-ROLE
```

This will call `buildkite-agent oidc request-token --audience sts.amazonaws.com` and exchange the resulting token for AWS credentials which are then added into the environment so tools like the AWS CLI will use the assumed role.

## Configuration

### `role-arn` (required, string)

ARN of the IAM role this plugin should assume.

### `audience` (optional, string)

The audience (`aud` claim) requested in the Buildkite OIDC token. Passed as the value of the [`--audience`][buildkite-agent-oidc-options] parameter in the OIDC request.

Defaults to `sts.amazonaws.com`. Set a custom value when a role's trust policy should require a specific audience — e.g. to scope a sensitive role so that a token minted for one role cannot be used to assume another (audience restriction). Note that the OIDC identity provider's _Audience_ list must include any custom value used.

### `role-session-name` (optional, string)

The value of the [`role-session-name`][assume-role-with-web-identity-options] to pass with the STS request. This value can be [referred to in assume-role policy][sts-role-session-name], and will be recorded in Cloudtrail.

Defaults to `buildkite-job-${BUILDKITE_JOB_ID}`.

[sts-role-session-name]: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#ck_rolesessionname

### `role-session-duration` (optional, integer)

An integer number of seconds that the assumed role session should last. Passed as the value of the [`duration-seconds`][assume-role-with-web-identity-options]  parameter in the STS request.

Defaults to `3600` (via the AWS CLI). When `oidc-token-lifetime` is not set, this value is also used as the OIDC token lifetime, capped at `7200` (2 hours), the maximum enforced by Buildkite.

### `oidc-token-lifetime` (optional, integer)

An integer number of seconds that the buildkite oidc token should last. Passed as the value of the [`lifetime`][buildkite-agent-oidc-options]  parameter in the OIDC request.

Defaults to `300` (via the BUILDKITE AGENT) unless `role-session-duration` is set, in which case it defaults to whichever is smaller: `role-session-duration` or `7200`.
Note: Buildkite enforces a maximum OIDC token lifetime of `7200` (2 hours) — values above this will be rejected.

### `session-tags` (optional, array)

A list of [Buildkite OIDC claims](https://buildkite.com/docs/agent/cli/reference/oidc#claims) to also pass to AWS as session tags. Session tags are available in the role session as `aws:PrincipalTag/<claim>` condition keys which are useful for attribute-based access control, and are recorded in AWS CloudTrail. You don't need session tags to restrict which pipelines can assume a role. Using session tags requires `sts:TagSession` in the role's trust policy. See [Using AWS session tags](https://buildkite.com/docs/pipelines/security/oidc/aws#using-aws-session-tags) for details.

Eg.

```yaml
session-tags:
- organization_slug
- pipeline_slug
- build_branch
```

Defaults to `` (empty).

> [!NOTE]
> `session-tags` requires buildkite-agent v3.83.0 or better

### `region` (optional, string)

Exports `AWS_REGION` and `AWS_DEFAULT_REGION` with the value you set. If not set
the values of `AWS_REGION` and `AWS_DEFAULT_REGION` will not be changed.

Note that and `AWS_REGION` is used by the AWS CLI v2 and most SDKs.
`AWS_DEFAULT_REGION` is included for compatibility with older SDKs and CLI
versions.

### `credential-name-prefix` (optional, string)

The plugin supports a `credential-name-prefix` option to prefix the default AWS credential names with a specific string. This is useful when you have multiple AWS credentials in your environment and you want to avoid conflicts.

For example, by setting `credential-name-prefix: MY_PREFIX_` the plugin will export `MY_PREFIX_AWS_ACCESS_KEY_ID`, `MY_PREFIX_AWS_SECRET_ACCESS_KEY` and `MY_PREFIX_AWS_SESSION_TOKEN` instead of the default `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`.

```yaml
plugins:
  - aws-assume-role-with-web-identity#v1.8.1:
      role-arn: arn:aws:iam::111111111111:role/example-role
      credential-name-prefix: MY_PREFIX_
```

### `chain-role-arn` (optional, string)

ARN of a second IAM role to assume after the initial OIDC-based role assumption. Useful for multi-account setups where the OIDC provider only exists in one account (e.g. an Identity Account), but the target resources live in another account.

The typical pattern is: Buildkite OIDC → entry role in Identity Account → `sts:AssumeRole` into Target Account.

```yaml
plugins:
  - aws-assume-role-with-web-identity#v1.8.1:
      role-arn: arn:aws:iam::IDENTITY-ACCOUNT-ID:role/CI-ENTRY-ROLE
      chain-role-arn: arn:aws:iam::TARGET-ACCOUNT-ID:role/TARGET-ROLE
```

The chained `sts:AssumeRole` call uses the credentials obtained from the first hop, so the entry role must have `sts:AssumeRole` permission on the target role. The chained session uses the same `role-session-name` as the first one. The final exported credentials will be those of the chained role.

When `credential-name-prefix` is also set, the chained credentials are exported under the same prefix.

AWS limits sessions obtained through role chaining to a maximum of one hour, even when `role-session-duration` is longer. Jobs that run for longer than that will hit expired credentials.

The `agent.buildkite.com:*` trust policy conditions and `session-tags` only apply to the entry role. The target role can only trust the entry role, so any pipeline that can assume the entry role can chain into any role the entry role is allowed to assume. To keep this scoped:

- Limit the entry role's `sts:AssumeRole` permission to the specific target role ARNs it needs.
- Have each target role trust only the entry role.

### `credential-process` (optional, boolean)

When `true`, the plugin does not export the assumed-role credentials as static environment variables. Instead it writes a self-contained [`credential_process`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html) helper script and an AWS config file referencing it, then exports `AWS_CONFIG_FILE` (and `AWS_SDK_LOAD_CONFIG=1`) so AWS SDKs and the AWS CLI pick it up.

AWS SDKs and the AWS CLI invoke the helper whenever credentials are needed and re-invoke it when the returned credentials approach expiry. Each invocation requests a fresh Buildkite OIDC token and assumes the role again, so the job keeps valid AWS credentials for its entire lifetime. This is useful for long-running jobs that would otherwise outlive a single role session — `AssumeRoleWithWebIdentity` sessions are capped at 12 hours, and static credentials exported at step start cannot be renewed.

```yaml
plugins:
  - aws-assume-role-with-web-identity#v1.8.1:
      role-arn: arn:aws:iam::111111111111:role/example-role
      role-session-duration: 43200
      credential-process: true
```

Notes:

- The plugin still performs its usual assume-role call up front, so configuration errors (bad role ARN, trust policy, or session tags) fail fast at step start rather than on the first AWS call.
- The helper runs wherever the build command runs, so `buildkite-agent` (with the job's `BUILDKITE_AGENT_ACCESS_TOKEN`), `aws`, and `jq` must be on `PATH` there — the same requirements the plugin's hook already has.
- Static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` variables are unset in this mode, because environment credentials take precedence over `credential_process`.
- The config is written for the active profile (`[default]`, or `[profile <name>]` if `AWS_PROFILE` is set).
- Cannot be combined with `credential-name-prefix`.
- With `chain-role-arn`, the chained `sts:AssumeRole` call happens inside the helper, so chained sessions (capped at one hour by AWS) are refreshed automatically as well.

### `hook` (optional, string)

The hook to run. Can be either `environment` (the default) or `pre-command`.

Useful for when using a plugin such as the `artifacts` plugin that runs as a
`pre-command` hook, and you need that to run with the pipeline role before then
assuming your IAM role like so:
```yaml
    plugins:
      - artifacts#v1.9.4:
          download: "out/*"
      - aws-assume-role-with-web-identity#v1.8.1:
          hook: pre-command
          role-arn: arn:aws:iam::111111111111:role/example-role
```

## IAM Role Trust Policies

AWS reads a subset of the Buildkite OIDC claims directly from the token, so a role's trust policy can restrict which Buildkite organizations and pipelines can assume it using `agent.buildkite.com:<claim>` condition keys. See [OIDC with AWS](https://buildkite.com/docs/pipelines/security/oidc/aws) in the Buildkite docs for a full walkthrough.

For example, given a Buildkite pipeline step like so:

```yaml
steps:
  - command: aws sts get-caller-identity
    plugins:
      - aws-assume-role-with-web-identity#v1.8.1:
          role-arn: arn:aws:iam::111111111111:role/example-role
```

The following trust policy on the IAM role will permit a Buildkite job to assume the role if the job belongs to the organization `ORG_SLUG` with the UUID `ORG_ID`, and the pipeline `PIPELINE_SLUG` with the UUID `PIPELINE_ID`:

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
                "StringLike": {
                    "agent.buildkite.com:sub": "organization:ORG_SLUG:pipeline:PIPELINE_SLUG:*"
                },
                "StringEquals": {
                    "agent.buildkite.com:aud": "sts.amazonaws.com",
                    "agent.buildkite.com:organization_slug": "ORG_SLUG",
                    "agent.buildkite.com:organization_id": "ORG_ID",
                    "agent.buildkite.com:pipeline_slug": "PIPELINE_SLUG",
                    "agent.buildkite.com:pipeline_id": "PIPELINE_ID"
                }
            }
        }
    ]
}
```

* [AWS requires a condition on `agent.buildkite.com:sub`](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc_secure-by-default.html) in every trust policy for a Buildkite OIDC provider.
* All conditions must match. To allow more than one value for a condition, list the values in an array, and any one of them can match. For example, this condition allows builds on either the `main` or `production` branch:

  ```json
  "agent.buildkite.com:build_branch": ["main", "production"]
  ```

* The `organization_id` and `pipeline_id` UUIDs never change and can't be reused by another organization or pipeline.
* The `organization_slug` and `pipeline_slug` conditions are optional, and make it easier to see which organization and pipeline the policy applies to. If you include them, renaming the organization or pipeline causes role assumption to fail until you update the policy.
* For restricting access to a set of IP addresses, see [Step 2](https://buildkite.com/docs/pipelines/security/oidc/aws#step-2-create-a-new-or-update-an-existing-iam-role-to-use-with-your-pipelines) of OIDC with AWS.
* For a complete list of supported condition keys, see [Restricting access with Buildkite OIDC claims](https://buildkite.com/docs/pipelines/security/oidc/aws#restricting-access-with-buildkite-oidc-claims).
* The `cluster_id` and `cluster_name` condition keys require [optional claims](https://buildkite.com/docs/agent/cli/reference/oidc#claims-optional-claims). See [Optional claims](#optional-claims).

### Optional claims

Optional claims, such as `cluster_id` and `cluster_name`, are only included in the OIDC token when requested. To request them, set the `BUILDKITE_OIDC_TOKEN_CLAIMS` environment variable on the step. The `buildkite-agent oidc request-token` command that this plugin runs reads this variable as its `--claim` option. Separate multiple claims with commas.

```yaml
steps:
  - label: ":aws: assume role with OIDC claim conditions"
    command: aws sts get-caller-identity
    env:
      BUILDKITE_OIDC_TOKEN_CLAIMS: cluster_id
    plugins:
      - aws-assume-role-with-web-identity#v1.8.1:
          role-arn: arn:aws:iam::123456789123:role/placeholder-role
```

Without these claims in the token, trust policies using `agent.buildkite.com:cluster_id` or `agent.buildkite.com:cluster_name` conditions will deny role assumption.

### Session tags

You don't need [`session-tags`](#session-tags-optional-array) to restrict which pipelines can assume a role. Use them when you need claim values in the role session, for example, in `aws:PrincipalTag/<claim>` conditions for attribute-based access control, or in AWS CloudTrail records. The role's trust policy must also allow `sts:TagSession`. See [Using AWS session tags](https://buildkite.com/docs/pipelines/security/oidc/aws#using-aws-session-tags) for details.

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

By default, the OIDC token that this plugin requests has the following audience and subject, which the trust policy below matches:
- Audience: `sts.amazonaws.com`, unless you set the plugin's [`audience`](#audience-optional-string) option
- Subject: `organization:<ORG_SLUG>:pipeline:<PIPELINE_SLUG>:ref:<REF>:commit:<BUILD_COMMIT>:step:<STEP_KEY>`, where `<REF>` is a Git ref such as `refs/heads/main`

In addition to the `aws_iam_openid_connect_provider` the role being assumed should have a trust policy that can be defined like so.
Be sure to replace the `<ORG_SLUG>`, `<ORG_ID>`, `<PIPELINE_SLUG>` and `<PIPELINE_ID>` placeholders.

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
      test     = "StringLike"
      variable = "agent.buildkite.com:sub"
      values   = ["organization:<ORG_SLUG>:pipeline:<PIPELINE_SLUG>:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "agent.buildkite.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "agent.buildkite.com:organization_slug"
      values   = ["<ORG_SLUG>"]
    }

    condition {
      test     = "StringEquals"
      variable = "agent.buildkite.com:organization_id"
      values   = ["<ORG_ID>"]
    }

    condition {
      test     = "StringEquals"
      variable = "agent.buildkite.com:pipeline_slug"
      values   = ["<PIPELINE_SLUG>"]
    }

    condition {
      test     = "StringEquals"
      variable = "agent.buildkite.com:pipeline_id"
      values   = ["<PIPELINE_ID>"]
    }
  }
}
```


## Compatibility

| Elastic Stack | Agent Stack K8s | Hosted (Mac) | Hosted (Linux) | Notes |
| :-----------: | :-------------: | :----: | :----: |:---- |
| ✅ | ❌ | ⚠️ | ⚠️ | *k8s stack* does not possess `aws` <br/> *Hosted agents* require AWS credentials on machine to perform `aws` command |

- ✅ Fully supported (all combinations of attributes have been tested to pass)
- ⚠️ Partially supported (some combinations cause errors/issues)
- ❌ Not supported

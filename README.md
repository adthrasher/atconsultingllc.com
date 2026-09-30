# AT Consulting LLC Website

Static marketing site for AT Consulting LLC (CAATE accreditation preparation consulting),
hosted on AWS as S3 + CloudFront + Route 53, provisioned with Terraform and deployed via
GitHub Actions.

## Local development

Preview the site locally with any static file server:

    python3 -m http.server 8000 --directory site

Then open http://localhost:8000/index.html.

## Validation tooling

    npm install
    npm run lint:html     # HTML lint via htmlhint
    npm run check:links   # broken link check via linkinator

## One-time setup (run once, by an account administrator)

### 0. (Optional) Create a local administrator IAM user

Everything below can be run by any sufficiently-privileged IAM principal, but if you'd rather
not use a broad "AdministratorAccess" user, here's a policy scoped to exactly what this
project's setup and `terraform apply` steps need. Replace `<AWS_ACCOUNT_ID>` with your account
ID throughout.

`atconsultingllc-admin-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBucketAndSiteBucket",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::atconsultingllc-terraform-state",
        "arn:aws:s3:::atconsultingllc-terraform-state/*",
        "arn:aws:s3:::atconsultingllc-com-site",
        "arn:aws:s3:::atconsultingllc-com-site/*"
      ]
    },
    {
      "Sid": "TerraformLockTable",
      "Effect": "Allow",
      "Action": "dynamodb:*",
      "Resource": "arn:aws:dynamodb:us-east-1:<AWS_ACCOUNT_ID>:table/atconsultingllc-terraform-locks"
    },
    {
      "Sid": "CloudFrontAndAcmAndRoute53",
      "Effect": "Allow",
      "Action": [
        "cloudfront:*",
        "acm:*",
        "route53:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GithubOidcProvider",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviders",
        "iam:TagOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider"
      ],
      "Resource": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    {
      "Sid": "GithubActionsRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::<AWS_ACCOUNT_ID>:role/atconsultingllc-terraform",
        "arn:aws:iam::<AWS_ACCOUNT_ID>:role/atconsultingllc-deploy",
        "arn:aws:iam::<AWS_ACCOUNT_ID>:role/atconsultingllc-preview-deploy"
      ]
    },
    {
      "Sid": "Identity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

Notes on scope:
- CloudFront, ACM, and Route53 require `Resource: "*"` above because those services don't
  support resource-level IAM restrictions for the create/list actions Terraform needs, and the
  hosted zone/certificate/distribution IDs don't exist yet on first apply. The `Action` list is
  still restricted to just these three services.
- S3, DynamoDB, and the three IAM roles above are restricted to this project's exact resource
  ARNs — this user can't touch any other bucket, table, or role in the account.

Create the user and attach the policy:

    aws iam create-user --user-name atconsultingllc-admin
    aws iam put-user-policy --user-name atconsultingllc-admin \
      --policy-name atconsultingllc-admin-policy \
      --policy-document file://atconsultingllc-admin-policy.json
    aws iam create-access-key --user-name atconsultingllc-admin

The last command prints an `AccessKeyId` and `SecretAccessKey` — save these, then run
`aws configure --profile atconsultingllc` and enter them when prompted (region `us-east-1`,
output format `json`). Use `--profile atconsultingllc` on every `aws`/`terraform` command
below, or `export AWS_PROFILE=atconsultingllc` for the session.

### 1. Bootstrap Terraform remote state

Terraform can't create its own backend, so these resources are created manually, once:

    aws s3api create-bucket --bucket atconsultingllc-terraform-state --region us-east-1
    aws s3api put-bucket-versioning --bucket atconsultingllc-terraform-state \
      --versioning-configuration Status=Enabled
    aws dynamodb create-table --table-name atconsultingllc-terraform-locks \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST --region us-east-1

### 2. Create GitHub OIDC-federated IAM roles

These roles let GitHub Actions authenticate to AWS via short-lived, workload-identity tokens
instead of long-lived access keys. Replace `<AWS_ACCOUNT_ID>`, `<GITHUB_ORG>`, and `<REPO_NAME>`
below with your actual values throughout.

#### a. Create the GitHub OIDC identity provider (skip if one already exists in this account)

Check first:

    aws iam list-open-id-connect-providers

If `token.actions.githubusercontent.com` isn't listed, create it:

    aws iam create-open-id-connect-provider \
      --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

(This provider is account-wide and shared across all repos/projects — only create it once
per AWS account.)

#### b. Terraform role (`AWS_TERRAFORM_ROLE_ARN`)

The `plan` job runs on `pull_request` (no `environment:`), so its OIDC token's `sub` claim is
`repo:<GITHUB_ORG>/<REPO_NAME>:pull_request`. The `apply` job declares `environment: production`,
so its `sub` claim becomes `repo:<GITHUB_ORG>/<REPO_NAME>:environment:production`. The trust
policy must allow both.

`terraform-role-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:<GITHUB_ORG>/<REPO_NAME>:pull_request",
            "repo:<GITHUB_ORG>/<REPO_NAME>:environment:production"
          ]
        }
      }
    }
  ]
}
```

`terraform-role-permissions.json` — the AWS provider's plan/refresh cycle reads many
auxiliary per-resource attributes (tags, bucket sub-configurations, etc.) whose IAM action
names don't line up neatly with wildcards like `s3:GetBucket*` (e.g. `s3:GetAccelerateConfiguration`
isn't covered by it), so an action-by-action list is a losing game of whack-a-mole in practice.
Instead, this grants full `Action` wildcards per service, scoped by `Resource` wherever AWS
supports it: S3 and DynamoDB are restricted to this project's exact bucket/table ARNs;
CloudFront, Route 53, and ACM don't support resource-level ARN restriction for most
create/list actions, so those sections necessarily use `Resource: "*"` (the risk is
still bounded by the `Action` being limited to just those 3 services):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBackend",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::atconsultingllc-terraform-state",
        "arn:aws:s3:::atconsultingllc-terraform-state/*"
      ]
    },
    {
      "Sid": "TerraformLockTable",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"],
      "Resource": "arn:aws:dynamodb:us-east-1:<AWS_ACCOUNT_ID>:table/atconsultingllc-terraform-locks"
    },
    {
      "Sid": "SiteBucketManagement",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::atconsultingllc-com-site",
        "arn:aws:s3:::atconsultingllc-com-site/*"
      ]
    },
    {
      "Sid": "CloudFrontManagement",
      "Effect": "Allow",
      "Action": "cloudfront:*",
      "Resource": "*"
    },
    {
      "Sid": "AcmManagement",
      "Effect": "Allow",
      "Action": "acm:*",
      "Resource": "*"
    },
    {
      "Sid": "Route53Management",
      "Effect": "Allow",
      "Action": "route53:*",
      "Resource": "*"
    }
  ]
}
```

Create the role:

    aws iam create-role --role-name atconsultingllc-terraform \
      --assume-role-policy-document file://terraform-role-trust-policy.json
    aws iam put-role-policy --role-name atconsultingllc-terraform \
      --policy-name terraform-permissions \
      --policy-document file://terraform-role-permissions.json

Store the resulting `Role.Arn` (from the `create-role` output, or `aws iam get-role --role-name
atconsultingllc-terraform --query Role.Arn`) as the repo secret `AWS_TERRAFORM_ROLE_ARN`.

#### c. Deploy role (`AWS_DEPLOY_ROLE_ARN`)

The `deploy` job also declares `environment: production`, so its `sub` claim is the same
`repo:<GITHUB_ORG>/<REPO_NAME>:environment:production` — the trust policy is identical in
shape to the Terraform role's, just scoped to that single claim:

`deploy-role-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<REPO_NAME>:environment:production"
        }
      }
    }
  ]
}
```

`deploy-role-permissions.json` — scoped to only the site bucket and, once known, the specific
CloudFront distribution:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SiteBucketSync",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::atconsultingllc-com-site",
        "arn:aws:s3:::atconsultingllc-com-site/*"
      ]
    },
    {
      "Sid": "CacheInvalidation",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::<AWS_ACCOUNT_ID>:distribution/*"
    }
  ]
}
```

After the first `terraform apply`, get the real distribution ID with
`terraform output cloudfront_distribution_id` and tighten the `CacheInvalidation` statement's
`Resource` to `arn:aws:cloudfront::<AWS_ACCOUNT_ID>:distribution/<DISTRIBUTION_ID>`.

Create the role the same way as above, using role name `atconsultingllc-deploy`, then store its
ARN as the repo secret `AWS_DEPLOY_ROLE_ARN`.

#### d. Preview deploy role (`AWS_PREVIEW_DEPLOY_ROLE_ARN`)

Pull request preview deployments (see "PR preview deployments" further below) use a third,
separate role — deliberately not the same role as production deploys — so that a
pull-request-triggered workflow run can never write outside its own preview path prefix.

This role's trust policy has no `environment:` condition (unlike the other two roles above),
because the `preview` workflow's jobs don't declare `environment:` — its `sub` claim is
`repo:<GITHUB_ORG>/<REPO_NAME>:pull_request`:

`preview-deploy-role-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_ORG>/<REPO_NAME>:pull_request"
        }
      }
    }
  ]
}
```

`preview-deploy-role-permissions.json` — scoped strictly to the `previews/` prefix of the site
bucket, plus invalidation on the existing distribution only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListPreviewsPrefixOnly",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::atconsultingllc-com-site",
      "Condition": {
        "StringLike": { "s3:prefix": "previews/*" }
      }
    },
    {
      "Sid": "PreviewsObjectAccess",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::atconsultingllc-com-site/previews/*"
    },
    {
      "Sid": "InvalidatePreviewPaths",
      "Effect": "Allow",
      "Action": "cloudfront:CreateInvalidation",
      "Resource": "arn:aws:cloudfront::<AWS_ACCOUNT_ID>:distribution/<DISTRIBUTION_ID>"
    }
  ]
}
```

Create the role:

    aws iam create-role --role-name atconsultingllc-preview-deploy \
      --assume-role-policy-document file://preview-deploy-role-trust-policy.json
    aws iam put-role-policy --role-name atconsultingllc-preview-deploy \
      --policy-name preview-deploy-permissions \
      --policy-document file://preview-deploy-role-permissions.json

Store the resulting ARN as the repo secret `AWS_PREVIEW_DEPLOY_ROLE_ARN`. Note that
`<DISTRIBUTION_ID>` in the permissions policy above isn't known until after the first
`terraform apply` — get it with `terraform output cloudfront_distribution_id` (see step 5 of
this setup section) and update the policy's `Resource` value accordingly (re-run the
`put-role-policy` command above with the corrected file).

#### e. Configure the `production` GitHub Environment

Both workflows reference a `production` GitHub Environment. This does two things: it gates
the `apply`/`deploy` jobs behind manual approval, and it's what makes their OIDC token's
`sub` claim become `repo:<GITHUB_ORG>/<REPO_NAME>:environment:production` — the exact value
the trust policies above check. **The environment name must be exactly `production`** to
match both `environment: production` in the workflow YAML and the trust policy conditions.

**Create it:**

1. In the repo, go to Settings → Environments → New environment.
2. Name it `production` (must match exactly — case-sensitive).

> **If you don't see a "Required reviewers" option:** this is a GitHub plan limitation, not a
> bug. Per [GitHub's docs](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
> environment protection rules (required reviewers, wait timer, etc.) are fully available on
> **public** repositories regardless of plan, but on **private** repositories they require
> **GitHub Pro** (individual accounts) or **GitHub Team/Enterprise** (organizations). On a
> private repo with a Free plan, you may be able to create the environment shell but won't see
> the reviewer/wait-timer protection-rule controls at all.
>
> Options if you're on a private Free-plan repo and don't want to upgrade:
> - **Make the repository public.** The earlier security review confirmed no secrets or
>   credentials are committed anywhere in this repo, so there's no code-level reason not to —
>   it's purely a business/branding decision. This unlocks full environment protection rules
>   for free.
> - **Upgrade to GitHub Pro** (individual account, low monthly cost) or have your organization
>   on **GitHub Team**, which unlocks environment protection rules on private repos.
> - **Substitute branch protection for environment protection.** Since both the `apply` job
>   (`terraform.yml`) and `deploy` job (`deploy.yml`) only trigger `on: push: branches: [main]`,
>   requiring a reviewed and approved pull request before anything can merge to `main`
>   (Settings → Branches → branch protection rule for `main` → "Require a pull request before
>   merging" + "Require approvals") achieves the same practical outcome — nothing reaches AWS
>   without a human approving it first — using a feature that's free on private repos at any
>   plan tier. You can still keep the `production` environment itself (even without reviewer
>   rules) since it's also what scopes the OIDC trust policy's `sub` claim and, if your plan
>   allows it, environment secrets.

**Configure protection rules on the environment:**

3. **Required reviewers** — check this box and add at least one user or team. Any workflow
   run that targets this environment (the `apply` job in `terraform.yml`, the `deploy` job in
   `deploy.yml`) will pause and wait for one of the listed reviewers to approve it in the
   Actions UI before the job's steps execute. This is what actually enforces the "someone
   looks at the Terraform plan before it's applied to real AWS resources" guarantee — without
   it, `apply` runs automatically and unattended on every merge to `main`.
4. **Wait timer** (optional) — adds a fixed delay (e.g. 5 minutes) before the job can start,
   giving a window to cancel a run even without a required reviewer. Not necessary if you've
   set required reviewers, but useful as a secondary safeguard.
5. **Deployment branches and tags** — restrict this to `Selected branches and tags` and add
   `main` only. This prevents a workflow run from an arbitrary branch or fork from ever being
   able to target the `production` environment (and therefore from ever assuming either IAM
   role, since the trust policy's `sub` condition is only satisfied when the job targets this
   environment). Both `terraform.yml`'s apply job and `deploy.yml`'s deploy job already run
   only `on: push: branches: [main]`, so this is defense-in-depth, not strictly required — but
   cheap to set and closes the gap if the trigger conditions are ever loosened later.

**Optional but recommended — use environment secrets instead of repository secrets:**

The setup steps above describe `AWS_TERRAFORM_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`,
`SITE_BUCKET_NAME`, and `CLOUDFRONT_DISTRIBUTION_ID` as plain repository secrets (Settings →
Secrets and variables → Actions → Repository secrets), which is simplest and matches what's
in the workflow YAML (`secrets.AWS_TERRAFORM_ROLE_ARN`, etc. resolve the same way regardless
of scope). For tighter scoping, add them instead as **environment secrets** on the
`production` environment itself (Settings → Environments → `production` → Environment
secrets). The workflow syntax doesn't change — `${{ secrets.NAME }}` resolves environment
secrets automatically when the job declares `environment: production`. The benefit: any other
workflow or job added to this repo later that does *not* target the `production` environment
will not be able to read these values at all, whereas repository secrets are visible to every
workflow in the repo by default.

**Note on the `plan` job in `terraform.yml`:** it intentionally does *not* declare
`environment:`, so it is never gated by these approval rules and can run unattended on every
pull request (its OIDC `sub` claim is `repo:<GITHUB_ORG>/<REPO_NAME>:pull_request`, matching
the first entry in the Terraform role's trust policy). This is by design — `terraform plan` is
read-only and safe to run automatically to give reviewers visibility into proposed changes;
only `terraform apply` and the actual S3 sync require manual approval.

### 3. Apply the infrastructure

Push a change under `infra/**` to `main` (or merge a PR) to trigger `.github/workflows/terraform.yml`,
which runs `terraform apply`. Alternatively, run locally:

    cd infra
    terraform init
    terraform apply

### 4. Configure the domain registrar

After the first successful apply, get the Route 53 name servers:

    cd infra
    terraform output route53_name_servers

Update your domain registrar's NS records for `atconsultingllc.com` to point to these name
servers.

### 5. Configure remaining GitHub repo secrets

After the first successful apply, get the S3 bucket name and CloudFront distribution ID:

    cd infra
    terraform output s3_bucket_name
    terraform output cloudfront_distribution_id

Store these as the repo secrets `SITE_BUCKET_NAME` and `CLOUDFRONT_DISTRIBUTION_ID` — used
by `.github/workflows/deploy.yml` and `.github/workflows/preview.yml`.

## Ongoing deployment

- Changes under `site/**` pushed to `main` trigger `.github/workflows/deploy.yml`, which
  lints HTML, checks links, syncs `site/` to S3, and invalidates the CloudFront cache.
- Changes under `infra/**` pushed to `main` trigger `.github/workflows/terraform.yml`, which
  plans on PRs (posting the plan as a PR comment) and applies on merge to `main`.

Note: the deploy workflow only triggers on changes under `site/**`. Immediately after the
first successful `terraform apply`, the S3 bucket is empty — push any small change under
`site/` (or re-push the current tree with an empty commit touching a file in `site/`) to
trigger the first deploy and populate the bucket.

## PR preview deployments

Pull requests that change files under `site/**` and target `main` automatically get a live
preview, via `.github/workflows/preview.yml`:

- On each push to the PR, the site is synced to `s3://<bucket>/previews/pr-<N>/` (the same
  bucket and CloudFront distribution as production, under a path prefix) and the cache for
  that path is invalidated. A bot comment on the PR is created or updated with the preview
  link: `https://atconsultingllc.com/previews/pr-<N>/index.html`.
- The link points directly at `index.html` rather than a clean directory URL — visiting the
  bare `.../previews/pr-<N>/` path (no filename) will 404, since CloudFront's
  `default_root_object` only applies to the true site root.
- When the PR is closed (merged or abandoned), the preview's objects are deleted from S3, its
  cache path is invalidated, and the bot comment is updated to say the preview was removed.
- Preview deploys use a separate, narrowly-scoped IAM role (`AWS_PREVIEW_DEPLOY_ROLE_ARN`, see
  step 2d above) that can only read/write/delete under the `previews/` prefix — it cannot
  modify the live production site.
- This only works for pull requests from branches within this repository. GitHub does not
  provide usable OIDC credentials to `pull_request`-triggered workflow runs from external
  forks, by design; such PRs will fail at the "Configure AWS credentials" step and will not
  get a preview.


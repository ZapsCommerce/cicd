# ZapsCommerce/cicd: shared CI/CD for every project

One deploy, health check and release process, used by version from any repository. New projects
start from **ZapsCommerce/cicd-template**, which already calls everything here. Why it works this
way: [docs/CICD_PLAYBOOK.md](docs/CICD_PLAYBOOK.md) ([PDF](docs/CICD_PLAYBOOK.pdf)).

| Piece | Call it as | Does |
|---|---|---|
| Deploy (reusable workflow) | `ZapsCommerce/cicd/.github/workflows/deploy-aws-static.yml@v1` | GitHub OIDC → `sam deploy` (every parameter written out) → S3 upload → CloudFront invalidation; outputs `url` |
| Health check (action) | `ZapsCommerce/cicd/smoke@v1` | Pages return 200; optional CSP header, API probe, apex → site redirect; retries while CloudFront settles |
| Release (action) | `ZapsCommerce/cicd/release@v1` | `mode: pre` tags `pre-vX.Y.Z` (rollback point); `mode: release` tags `vX.Y.Z`, moves `release`, deletes released `feat/` `fix/` `hotfix/` branches, posts a GitHub Release and a PR comment |

## Use it in a project

```yaml
# .github/workflows/deploy-prod.yml (excerpt; full file in cicd-template)
permissions:
  contents: read
  id-token: write

jobs:
  build:
    uses: ./.github/workflows/build.yml          # your build, uploads artifact "site"

  prod:
    needs: build
    uses: ZapsCommerce/cicd/.github/workflows/deploy-aws-static.yml@v1
    with:
      environment: production
      role-arn: arn:aws:iam::<account>:role/<deploy role>
      region: eu-west-2
      stack-name: my-site
      parameters: |
        DomainNames: "www.example.com,example.com"
        CertificateArn: "arn:aws:acm:us-east-1:<account>:certificate/<id>"
      ssm-parameters: |
        OriginVerifySecret=/my-site/origin-verify-secret
    secrets:
      parameter-secrets: ${{ secrets.STACK_PARAMETER_SECRETS }}

  health:
    needs: prod
    runs-on: ubuntu-latest
    steps:
      - uses: ZapsCommerce/cicd/smoke@v1
        with:
          url: ${{ needs.prod.outputs.url }}
          pages: "/ /about/ /pricing/"
          apex: example.com

  pre-release:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    permissions: { contents: write }
    steps:
      - uses: ZapsCommerce/cicd/release@v1
        with: { mode: pre }

  release:
    needs: [health, pre-release]
    if: ${{ !cancelled() && needs.health.result == 'success' }}
    runs-on: ubuntu-latest
    permissions: { contents: write, pull-requests: write }
    steps:
      - uses: ZapsCommerce/cicd/release@v1
        with: { mode: release }
```

### Deploy inputs

| Input | Default | |
|---|---|---|
| `environment` | required | GitHub environment; the AWS role trusts only this one |
| `role-arn`, `region`, `stack-name` | required | deploy role (cicd-template `aws/github-deploy-role.yaml`), AWS region, stack |
| `template-file` | `aws/template.yaml` | the stack must output `BucketName`, `DistributionId`, `SiteUrl` |
| `parameters` | empty | `Key: value` lines. Write **every** parameter, empty ones too: SAM keeps old values for missing ones |
| `ssm-parameters` | empty | `Key=/ssm/name` lines, read in the target account and masked |
| `artifact`, `static-dir` | `site`, `static` | build artifact name; folder of cache-busted assets (cached a year) |
| `tags` | `project=<stack-name>` | stack tags |
| secret `parameter-secrets` | none | `Key: "value"` lines for secret parameters |

Secrets are passed explicitly (not `secrets: inherit`), so callers in other orgs work too.

### Health check inputs

`url` (required), `pages` (`/`), `apex`, `require-csp` (`false`), `api-path`, `api-method` (`GET`),
`api-body`, `api-expect` (`200`), `tries` (`10`), `wait` (`15` seconds).

### Release inputs

`mode` (`pre` or `release`, required), `sha` (the pushed commit), `before` (the prod commit before
the push), `token` (`github.token`), `dry-run` (`false`). Versions: any `feat/` merged since the
last release → minor, otherwise patch; a major bump is a tag pushed by hand.

## Versions of this repository

| Pin | Who | Effect |
|---|---|---|
| `@v1` | projects in ZapsCommerce | get backward-compatible fixes automatically |
| `@v1.0.0` or a commit SHA | projects in other orgs, or anyone who wants to upgrade deliberately | never changes |

To release a change here: merge it into `main` (CI must be green), then **Actions → Tag version →
Run workflow** on `main` with the new version (`1.0.1` for a fix, `1.1.0` for a new input).
It creates `v1.0.1` and moves `v1`. Breaking changes (a removed or renamed input, changed
behaviour) get a new major version: `2.0.0` → `v2`, and projects move when they are ready.

## Working on this repository

- Branch from `main` (`feat/`, `fix/`), open a PR, CI runs the release-script tests, shell syntax,
  YAML parsing and the smoke action against a public page. Merge with a merge commit after the
  owner says "merge".
- Before a change to `release-after-deploy.sh`: add a test in `tests/test_release_script.py`.
- Never move a tag other than the major tag, and never delete a version tag: projects pin them.
- Nothing secret belongs here (the repository is public): no account ids, role ARNs, domains or
  keys. Those stay in each project.

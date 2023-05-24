# @KineticCafe/actions-dco

Enforce Developer Certificate of Origin (DCO) sign-off on pull requests.

## Example Usage

```yaml
name: DCO Check

on:
  - pull_request

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v1.0
```

## Inputs

- `repo-token`: The GitHub token for use with this. Defaults to `${{
github.token }}` and needs to have sufficient permissions to…

- `exclude-bots`: Bots to exclude from DCO sign-off requirements. Multiple bots
  may be specified by putting each entry on its own line or separating them with
  commas:

  ```yaml
  exclude-bots: |-
    dependabot[bot],renovate[bot]
    my[bot]
  ```

  If `false` is specified anywhere in the list, bot exclusion is disabled:

  ```yaml
  exclude-bots: dependabot[bot],renovate[bot],false
  ```

  The default list can be extended by specifying the special value `@default`:

  ```yaml
  exclude-bots: @default,my[bot]
  ```

  The default list currently includes:

  - `dependabot[bot]`
  - `renovate[bot]`

- `exclude-emails`: Emails to exclude from DCO sign-off requirements. Multiple
  email addresses may be specified by putting each entry on its own line or
  separating them with commas:

  ```yaml
  exclude-emails: |-
    person1@example.com
    person2@example.com,person3@example.com
  ```

  Contributors from entire email domains may be excluded from DCO sign-off by
  using `*@domain.com`:

  ```yaml
  exclude-emails: '*@example.com'
  ```

  No email addresses are excluded by default.

## Change the Code

Most toolkit and CI/CD operations involve async operations so the action is run in an async function.

```javascript
import * as core from '@actions/core';
...

async function run() {
  try {
      ...
  }
  catch (error) {
    core.setFailed(error.message);
  }
}

run()
```

See the [toolkit documentation](https://github.com/actions/toolkit/blob/master/README.md#packages) for the various packages.

## Publish to a distribution branch

Actions are run from GitHub repos so we will checkin the packed dist folder.

Then run [ncc](https://github.com/zeit/ncc) and push the results:

```bash
$ npm run package
$ git add dist
$ git commit -a -m "prod dependencies"
$ git push origin releases/v1
```

Note: We recommend using the `--license` option for ncc, which will create a license file for all of the production node modules used in your project.

Your action is now published! :rocket:

See the [versioning documentation](https://github.com/actions/toolkit/blob/master/docs/action-versioning.md)

## Validate

You can now validate the action by referencing `./` in a workflow in your repo (see [test.yml](.github/workflows/test.yml))

```yaml
uses: ./
with:
  milliseconds: 1000
```

See the [actions tab](https://github.com/actions/typescript-action/actions) for runs of this action! :rocket:

## Usage:

After testing you can [create a v1 tag](https://github.com/actions/toolkit/blob/master/docs/action-versioning.md) to reference the stable and latest V1 action

# @KineticCafe/actions-dco

Enforce the presence of commit sign-offs on pull requests, indicating that the
contributor to a project certifies that they are permitted to contribute to the
project. The sign-off line represents certification of the [Developer
Certificate of Origin][dco].

Bot user contributions are automatically exempted.

## Example Usage

```yaml
name: DCO Check

on:
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v1
```

## Inputs

- `repo-token`: The GitHub token for use with this action. It must have
  sufficient permissions to read pull request details.

  Default: `${{ github.token }}`

- `exempt-authors`: A whitespace separated list of email exemption patterns
  indicating an implied DCO sign-off (the contributors work for the company
  managing the project, for example). Permitted pattern formats are exact emails
  (`name@example.org`) or domain patterns (`@example.org`). Patterns that do not
  match this will be printed as warnings and ignored.

  `exempt-authors` are applied only for the commit _author_. The commit
  _committer_ cannot exempt other peoples' contributions.

  ```yaml
  name: DCO Check

  on:
  pull_request:

  jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: KineticCafe/actions-dco@v1
        with:
          exempt-authors: |
            joe@example.net
            @example.com
  ```

[dco]: https://developercertificate.org

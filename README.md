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

# voyager-codex

✨ GitHub Action to automatically review Pull Request changes using [CodeGen](https://www.codegen.com), posting inline comments with severity levels.

## 🚀 Features

- Inline comments for code additions and changes
- Sends code **blocks**, not just single lines
- Labels feedback by severity:
  - 🛑 CRITICAL
  - ⚠️ WARNING
  - ✅ INFO

## 🛠 Usage

```yaml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Code Review with Voyager
        uses: voyager-tech/voyager-codex@v1
        with:
          codegen_api_key: ${{ secrets.CODEGEN_API_KEY }}
          codegen_org_id: ${{ secrets.CODEGEN_ORG_ID }}

#!/bin/bash
set -e

git config --global --add safe.directory /github/workspace

CODEGEN_API_KEY=${INPUT_CODEGEN_API_KEY}
CODEGEN_ORG_ID=${INPUT_CODEGEN_ORG_ID}

if [[ -z "$CODEGEN_API_KEY" || -z "$CODEGEN_ORG_ID" ]]; then
  echo "❌ CODEGEN_API_KEY or CODEGEN_ORG_ID is not set."
  exit 1
fi

REPO=$(basename "$GITHUB_REPOSITORY")
OWNER=$(echo "$GITHUB_REPOSITORY" | cut -d'/' -f1)
PR_NUMBER=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")

git fetch origin "$GITHUB_BASE_REF" --depth=100 || {
  echo "⚠️ Failed to fetch $GITHUB_BASE_REF"
  exit 1
}

MERGE_BASE=$(git merge-base origin/"$GITHUB_BASE_REF" HEAD || true)
if [[ -z "$MERGE_BASE" ]]; then
  echo "⚠️ No merge base found. Using HEAD only for diff."
  git diff HEAD --unified=5 > patch.diff
else
  git diff "$MERGE_BASE"...HEAD --unified=5 > patch.diff
fi

if [[ ! -s patch.diff ]]; then
  echo "ℹ️ No changes to review."
  exit 0
fi

FILE=""
BLOCK=""
START_LINE=""

while IFS= read -r line; do
  if [[ $line =~ ^\+\+\+\ b\/(.*) ]]; then
    FILE="${BASH_REMATCH[1]}"
    BLOCK=""
    START_LINE=""
  elif [[ $line =~ ^@@\ \-(.*)\ \+(.*)\ @@ ]]; then
    ADD_LINE="${BASH_REMATCH[2]}"
    START_LINE=$(echo "$ADD_LINE" | cut -d',' -f1)
    BLOCK=""
  elif [[ $line =~ ^\+[^+]{1} ]]; then
    CLEAN_LINE=$(echo "$line" | cut -c 2-)
    BLOCK+="$CLEAN_LINE"$'\n'
  elif [[ $line =~ ^[^@+-] ]]; then
    BLOCK+="$line"$'\n'
  fi

  if [[ -n "$BLOCK" && -n "$FILE" && -n "$START_LINE" && -z "$line" ]]; then
    if [[ "$FILE" =~ \.(png|jpg|jpeg|gif|ico|svg|lock|md|json|yml|yaml|txt|csv|pdf|mp4|mp3)$ ]]; then
      continue
    fi

    echo "🔍 Reviewing block in $FILE:$START_LINE..."

    PROMPT="Analyze the following code block from $FILE. Identify any readability, maintainability, security or performance issues.
Classify each finding as:
🛑 CRITICAL – major bugs or security risks
⚠️ WARNING – bad practices or risky patterns
✅ INFO – minor improvements

Code:
$BLOCK"

    RESPONSE=$(curl -s -X POST "https://api.codegen.com/v1/organizations/$CODEGEN_ORG_ID/agent/run" \
      -H "Authorization: Bearer $CODEGEN_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"prompt\": $(jq -Rs <<< "$PROMPT") }")

    FEEDBACK=$(echo "$RESPONSE" | jq -r '.output // .result // .message // .choices[0].text // empty')

    if [[ -n "$FEEDBACK" ]]; then
      echo "💬 Commenting on $FILE:$START_LINE"
      gh api \
        -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        /repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
        -f body="$FEEDBACK" \
        -f commit_id="$GITHUB_SHA" \
        -f path="$FILE" \
        -f line="$START_LINE" \
        -f side="RIGHT"
    else
      echo "ℹ️ No feedback generated for $FILE:$START_LINE"
    fi

    BLOCK=""
  fi
done < patch.diff

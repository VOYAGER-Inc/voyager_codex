#!/bin/bash
set -e

git config --global --add safe.directory /github/workspace

CODEGEN_API_KEY=${INPUT_CODEGEN_API_KEY}
CODEGEN_ORG_ID=${INPUT_CODEGEN_ORG_ID}
GITHUB_TOKEN=${INPUT_GITHUB_TOKEN}

if [[ -z "$CODEGEN_API_KEY" ]]; then
  echo "❌ CODEGEN_API_KEY is not set."
  exit 1
fi

if [[ -z "$CODEGEN_ORG_ID" ]]; then
  echo "❌ CODEGEN_ORG_ID is not set."
  exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "❌ GITHUB_TOKEN is not set."
  exit 1
fi

OWNER=$(echo "$GITHUB_REPOSITORY" | cut -d'/' -f1)
REPO=$(basename "$GITHUB_REPOSITORY")
PR_NUMBER=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")

echo "📥 Fetching base branch: origin/$GITHUB_BASE_REF"
git fetch origin "$GITHUB_BASE_REF" --depth=1 || git fetch origin "$GITHUB_BASE_REF"
MERGE_BASE=$(git merge-base origin/"$GITHUB_BASE_REF" HEAD)

if [[ -z "$MERGE_BASE" ]]; then
  echo "❌ Failed to determine merge base between origin/$GITHUB_BASE_REF and HEAD."
  exit 1
fi

echo "🔁 Using merge base: $MERGE_BASE"
git diff "$MERGE_BASE"...HEAD --unified=5 > patch.diff
echo "📄 Generated patch diff:"
cat patch.diff

FILE=""
BLOCK=""
START_LINE=""

echo "🔍 Reading patch line-by-line..."
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ $line =~ ^\+\+\+\ b\/(.*) ]]; then
    FILE="${BASH_REMATCH[1]}"
    BLOCK=""
    START_LINE=""
    echo "📁 New file detected: $FILE"
  elif [[ $line =~ ^@@\ \-(.*)\ \+(.*)\ @@ ]]; then
    ADD_LINE="${BASH_REMATCH[2]}"
    START_LINE=$(echo "$ADD_LINE" | cut -d',' -f1)
    BLOCK=""
    echo "📌 Change block at line: $START_LINE"
  elif [[ $line =~ ^\+[^+]{1} ]]; then
    CLEAN_LINE=$(echo "$line" | cut -c 2-)
    BLOCK+="$CLEAN_LINE"$'\n'
  elif [[ $line =~ ^[^@+-] ]]; then
    BLOCK+="$line"$'\n'
  fi

  if [[ -n "$BLOCK" && -n "$FILE" && -n "$START_LINE" && ( -z "$line" || "$line" == "${EOF_MARKER:-}" ) ]]; then
    if [[ "$FILE" =~ \.(png|jpg|jpeg|gif|ico|svg|md|lock|json|yml|yaml|txt|map|snap|log)$ ]]; then
      BLOCK=""
      continue
    fi

    PROMPT="Analyze the following code block from $FILE. Identify any readability, maintainability, security or performance issues.
Classify each finding as:
🛑 CRITICAL – major bugs or security risks
⚠️ WARNING – bad practices or risky patterns
✅ INFO – minor improvements

Code:
$BLOCK"

    echo "📤 Sending to CodeGen API..."
    RESPONSE=$(curl -s -X POST "https://api.codegen.com/v1/organizations/$CODEGEN_ORG_ID/agent/run" \
      -H "Authorization: Bearer $CODEGEN_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"prompt\": $(jq -Rs <<< "$PROMPT") }")

    TRACE_ID=$(echo "$RESPONSE" | jq -r '.id')
    echo "📬 Trace ID: $TRACE_ID"
    echo "🔗 View progress: https://codegen.sh/agent/trace/$TRACE_ID"

    FEEDBACK=""
    for i in {1..3}; do
      sleep 2
      RESULT=$(curl -s -H "Authorization: Bearer $CODEGEN_API_KEY" \
        "https://api.codegen.com/v1/agent/trace/$TRACE_ID")

      FEEDBACK=$(echo "$RESULT" | jq -r '.output // .result // .message // .choices[0].text // empty')
      if [[ -n "$FEEDBACK" ]]; then
        break
      fi
    done

    if [[ -z "$FEEDBACK" ]]; then
      echo "⚠️ No valid feedback received from CodeGen."
    else
      gh api \
        -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        /repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
        -f body="$FEEDBACK" \
        -f commit_id="$GITHUB_SHA" \
        -f path="$FILE" \
        -f line="$START_LINE" \
        -f side="RIGHT" || echo "❌ Failed to post comment to $FILE:$START_LINE"
    fi

    BLOCK=""
  fi
done < patch.diff

# handle leftover block
if [[ -n "$BLOCK" && -n "$FILE" && -n "$START_LINE" ]]; then
  PROMPT="Analyze the following code block from $FILE. Identify any readability, maintainability, security or performance issues.
Classify each finding as:
🛑 CRITICAL – major bugs or security risks
⚠️ WARNING – bad practices or risky patterns
✅ INFO – minor improvements

Code:
$BLOCK"

  echo "📤 Sending final block to CodeGen API..."
  RESPONSE=$(curl -s -X POST "https://api.codegen.com/v1/organizations/$CODEGEN_ORG_ID/agent/run" \
    -H "Authorization: Bearer $CODEGEN_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": $(jq -Rs <<< "$PROMPT") }")

  TRACE_ID=$(echo "$RESPONSE" | jq -r '.id')
  echo "📬 Trace ID: $TRACE_ID"
  echo "🔗 View progress: https://codegen.sh/agent/trace/$TRACE_ID"

  FEEDBACK=""
  for i in {1..3}; do
    sleep 2
    RESULT=$(curl -s -H "Authorization: Bearer $CODEGEN_API_KEY" \
      "https://api.codegen.com/v1/agent/trace/$TRACE_ID")

    FEEDBACK=$(echo "$RESULT" | jq -r '.output // .result // .message // .choices[0].text // empty')
    if [[ -n "$FEEDBACK" ]]; then
      break
    fi
  done

  if [[ -z "$FEEDBACK" ]]; then
    echo "⚠️ No valid feedback received from CodeGen."
  else
    gh api \
      -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      /repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
      -f body="$FEEDBACK" \
      -f commit_id="$GITHUB_SHA" \
      -f path="$FILE" \
      -f line="$START_LINE" \
      -f side="RIGHT" || echo "❌ Failed to post final block comment"
  fi
fi

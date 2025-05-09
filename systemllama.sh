#!/usr/bin/env bash
# ollama_shell_assistant.sh
# Interactive shell assistant using Ollama Llama3.2 running on localhost
# Requirements: bash, curl, jq, patch

API_URL="http://localhost:11434/api/generate"
MODEL="llama3.2"

# Detect OS
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_NAME="$NAME"
  OS_VERSION="$VERSION_ID"
else
  OS_NAME="Unknown"
  OS_VERSION=""
fi

# Detect Desktop Environment
DESKTOP_ENVIRONMENT=${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-"Unknown"}}

# Function to call the AI API
function ask_ai() {
  local prompt_text="$1"
  local system_info="OS: $OS_NAME $OS_VERSION. Desktop: $DESKTOP_ENVIRONMENT."
  local instruction="Respond only with valid shell command(s). No explanations, no markdown, no formatting. Only the actual command line to execute. and never use snapd"
  local full_prompt="$system_info\n$instruction\nUser: $prompt_text\nAI:"
  local payload
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$full_prompt" \
    '{model: $model, prompt: $prompt, stream: false}')
  local raw
  raw=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "$payload")
  echo "$raw" | jq -r '.response' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d' | sed 's/```\|```//g'
}

# Execute and check success
function execute_with_check() {
  local command="$1"
  echo "Running: $command"
  echo ""
  output=$(eval "$command" 2>&1)
  status=$?
  echo "$output"
  return $status
}

# Retry until AI gives working command
function run_until_success() {
  local goal="$1"
  local attempted=()
  while true; do
    ai_cmds=$(ask_ai "$goal")
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      if printf '%s\n' "${attempted[@]}" | grep -qx "$cmd"; then
        continue
      fi
      attempted+=("$cmd")
      execute_with_check "$cmd"
      if [[ $? -eq 0 ]]; then
        echo ""
        echo "Task completed successfully."
        return 0
      else
        echo ""
        echo "Error detected. Asking AI for a fix..."
        ai_cmds=$(ask_ai "Command '$cmd' failed with: '$output'. Provide a new working shell command only to accomplish: $goal")
        break
      fi
    done <<< "$ai_cmds"
  done
}

# Main interactive loop
echo "Welcome to Ollama Shell Assistant! Type 'exit' to quit."
while true; do
  read -rp ">>> " user_input
  [[ "$user_input" == "exit" ]] && break
  if [[ "$user_input" =~ ^edit[[:space:]]+(.+) ]]; then
    file_path=${BASH_REMATCH[1]}
    if [[ -f "$file_path" ]]; then
      file_content=$(sed 's/"/\\"/g' "$file_path")
      diff_patch=$(ask_ai "Edit file $file_path. Content:\n$file_content. Provide a unified diff only.")
      echo "$diff_patch" | patch -p0
      echo "Applied patch to $file_path"
    else
      echo "File not found: $file_path"
    fi
    continue
  fi
  run_until_success "$user_input"
done
echo "Goodbye!"
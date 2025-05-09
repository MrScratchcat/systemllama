#!/usr/bin/env bash
# ollama_shell_assistant_zenity.sh
# Graphical shell assistant using Ollama with Zenity UI
# Requirements: zenity, curl, jq, patch

API_URL="http://localhost:11434/api/generate"
MODEL="llama3.2"
TMP_FILE=$(mktemp)

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
  local instruction="Respond only with valid shell command(s). No explanations, no markdown, no formatting. Only the actual command line to execute."
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
  echo "Running: $command" > "$TMP_FILE"
  output=$(eval "$command" 2>&1)
  status=$?
  echo "$output" >> "$TMP_FILE"
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
      
      # Zenity confirmation dialog
      zenity --question --title="Command Confirmation" --text="AI suggests command:\n\n<tt>$cmd</tt>\n\nExecute this command?" \
        --width=500 --height=200 --ok-label="Execute" --cancel-label="Skip"
      
      if [[ $? -ne 0 ]]; then
        zenity --info --title="Skipped" --text="Command skipped" --width=300 --height=100
        continue
      fi

      attempted+=("$cmd")
      execute_with_check "$cmd"
      
      if [[ $? -eq 0 ]]; then
        zenity --text-info --title="Command Output" --filename="$TMP_FILE" --width=800 --height=600
        zenity --info --title="Success" --text="Task completed successfully!" --width=300 --height=100
        return 0
      else
        zenity --text-info --title="Command Error" --filename="$TMP_FILE" --width=800 --height=600
        zenity --question --title="Error Detected" --text="Command failed. Ask AI for a fix?" \
          --width=400 --height=150 --ok-label="Retry" --cancel-label="Cancel"
        if [[ $? -ne 0 ]]; then
          return 1
        fi
        ai_cmds=$(ask_ai "Command '$cmd' failed with: '$output'. Provide a new working shell command only to accomplish: $goal")
        break
      fi
    done <<< "$ai_cmds"
  done
}

# Main Zenity interface
while true; do
  user_input=$(zenity --entry --title="Ollama Assistant" --text="Enter your command request:" \
    --width=500 --height=150 --ok-label="Submit" --cancel-label="Exit")
  
  [[ $? -ne 0 ]] && break
  
  if [[ "$user_input" =~ ^edit[[:space:]]+(.+) ]]; then
    file_path=${BASH_REMATCH[1]}
    if [[ -f "$file_path" ]]; then
      file_content=$(sed 's/"/\\"/g' "$file_path")
      diff_patch=$(ask_ai "Edit file $file_path. Content:\n$file_content. Provide a unified diff only.")
      echo "$diff_patch" | patch -p0
      zenity --info --title="Patch Applied" --text="Applied patch to $file_path" --width=300 --height=100
    else
      zenity --error --title="File Error" --text="File not found: $file_path" --width=300 --height=100
    fi
    continue
  fi
  
  run_until_success "$user_input"
done

rm "$TMP_FILE"
zenity --info --title="Goodbye" --text="Thank you for using Ollama Assistant!" --width=300 --height=100
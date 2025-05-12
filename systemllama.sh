#!/usr/bin/env bash
# ollama_shell_assistant_zenity.sh
# Graphical shell assistant using Ollama with Zenity UI
# Requirements: zenity, curl, jq
BASE_URL="http://localhost:11434"
TMP_FILE=$(mktemp)
PASSWORD=""
ERROR_HISTORY=""

# Detect installed models with parameter sizes
function detect_models() {
  local model_data
  model_data=$(curl -s "${BASE_URL}/api/tags")
  if [ $? -ne 0 ]; then
    zenity --error --text="Failed to connect to Ollama!\nEnsure it's running at ${BASE_URL}"
    exit 1
  fi
  echo "$model_data" | jq -r '.models[] |
    "\(.name)|\(.details.parameter_size // "unknown")|\(.details.quantization_level // "unknown")"'
}

# Model selection dialog with parameter info
function select_model() {
  local models=()
  while IFS="|" read -r name param_size quant; do
    models+=("$name" "${param_size} (${quant})")
  done < <(detect_models)
  [ ${#models[@]} -eq 0 ] && zenity --error --text="No models installed!" && exit 1
  zenity --list \
    --title="Select Ollama Model" \
    --text="Installed models with parameter sizes:" \
    --column="Model Name" --column="Parameters (Quantization)" \
    --width=800 --height=400 \
    "${models[@]}"
}

# Enhanced AI query function with strict validation
function ask_ai() {
  local prompt_text="$1"
  local model="$2"
  local system_info="OS: $OS_NAME $OS_VERSION. Desktop: $DESKTOP_ENVIRONMENT."
  
  # Conditional error context
  local error_section=""
  local progress_msg="🔄 Generating command..."
  if [ -n "$ERROR_HISTORY" ]; then
    error_section="Previous errors to avoid:\n${ERROR_HISTORY}\n"
    progress_msg="🔍 Analyzing previous errors..."
  fi
  
  local instruction="You are a Linux terminal expert. Respond ONLY with ONE valid bash command between triple backticks.
${error_section}
STRICT RULES:
1. Command must work on $OS_NAME
2. Use only installed core utilities
3. No explanations or comments
4. Format: \`\`\`command -flags args\`\`\`
5. Validate command syntax before responding"

  local payload
  payload=$(jq -n \
    --arg model "$model" \
    --arg prompt "${system_info}\n${instruction}\nTask: ${prompt_text}\nCommand:" \
    '{model: $model, prompt: $prompt, stream: false, options: {temperature: 0.1}}')
  
  zenity --progress --title="Processing" --text="$progress_msg" \
    --pulsate --no-cancel --width=300 2>/dev/null &
  ZENITY_PID=$!
  
  local raw
  raw=$(curl -s -X POST "${BASE_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$payload")
  
  kill $ZENITY_PID 2>/dev/null
  
  # Enhanced command extraction
  local ai_cmd=$(echo "$raw" | jq -r '.response' | \
    awk 'BEGIN{RS="```";FS="\n"} NR==2{gsub(/^[ \t]+|[ \t]+$/,"");print}' | \
    grep -m1 -E '^[a-zA-Z0-9_@-]+(\s+.*)?$')
  
  # Multi-stage validation
  if [[ -z "$ai_cmd" ]]; then
    zenity --error --title="Invalid Response" --text="No command detected in AI response" --width=300
    return 1
  fi
  
  if [[ "$ai_cmd" =~ ^\(.*\)$ ]]; then
    zenity --error --title="Invalid Format" --text="Subshell commands not allowed: $ai_cmd" --width=300
    return 1
  fi
  
  local base_cmd=$(echo "$ai_cmd" | awk '{print $1}')
  if ! type "$base_cmd" &> /dev/null; then
    zenity --error --title="Invalid Command" --text="Command not found: $base_cmd" --width=300
    return 1
  fi
  
  if ! bash -n <<< "$ai_cmd" 2>/dev/null; then
    zenity --error --title="Syntax Error" --text="Invalid command syntax:\n$ai_cmd" --width=300
    return 1
  fi
  
  echo "$ai_cmd"
}

# Secure execution with error capture
function execute_with_check() {
  local display_command="$1"
  local exec_command="$2"
  
  echo "Running: $display_command" > "$TMP_FILE"
  output=$(eval "$exec_command" 2>&1)
  status=$?
  
  # Sanitize and store error context
  if [ $status -ne 0 ]; then
    ERROR_HISTORY=$(echo "$output" | sed -E '
      s/(\/home\/)[^/]+/\1USERNAME/g;
      s/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[IP_REDACTED]/g;
      s/[pP]assword for .*:/[Authentication required]/g;
      s/sudo: [^ ]* //g;
      /^$/d
    ' | head -n 3)
  else
    ERROR_HISTORY=""
  fi
  
  echo "$output" >> "$TMP_FILE"
  return $status
}

# Main interaction loop
function run_until_success() {
  local goal="$1"
  local model="$2"
  local attempted=()
  ERROR_HISTORY=""
  
  while true; do
    ai_cmd=$(ask_ai "$goal" "$model")
    [ $? -ne 0 ] && continue

    # Create secure commands
    display_cmd=$(sed 's/sudo /sudo -S /g' <<< "$ai_cmd")
    if [[ "$ai_cmd" == *"sudo"* ]]; then
      exec_cmd="{ echo '$PASSWORD'; } | $display_cmd"
    else
      exec_cmd="$display_cmd"
    fi

    sanitized_cmd=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$display_cmd")
    
    # Confirmation dialog
    response=$(zenity --question \
      --title="Confirm Command" \
      --text="Model: $model\n\nSuggested command:\n<tt>$sanitized_cmd</tt>\n\nExecute?" \
      --ok-label="Execute" \
      --cancel-label="Skip" \
      --extra-button="Quit" \
      2>&1)
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
      : # Proceed
    else
      if echo "$response" | grep -q "Quit"; then
        rm "$TMP_FILE"
        exit 0
      else
        continue
      fi
    fi

    attempted+=("$display_cmd")
    execute_with_check "$display_cmd" "$exec_cmd"
    
    if [ $? -eq 0 ]; then
      zenity --text-info --title="Success" --filename="$TMP_FILE" --width=800 --height=600
      return 0
    else
      zenity --text-info --title="Error" --filename="$TMP_FILE" --width=800 --height=600
      zenity --question --text="Command failed. Retry with different approach?"
      [ $? -ne 0 ] && return 1
    fi
  done
}

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

# Main script execution
SELECTED_MODEL=$(select_model)
[ -z "$SELECTED_MODEL" ] && exit

# Get password securely
PASSWORD=$(zenity --password --title="Sudo Authentication" --text="Enter your sudo password (used securely if needed):")
[ $? -ne 0 ] && exit

while true; do
  user_input=$(zenity --entry \
    --title="Ollama Assistant (${SELECTED_MODEL})" \
    --text="Enter task description:" \
    --width=500 --height=150)
  [ $? -ne 0 ] && break
  
  if [[ "$user_input" == "switch model" ]]; then
    SELECTED_MODEL=$(select_model)
    continue
  fi
  
  run_until_success "$user_input" "$SELECTED_MODEL"
done

rm "$TMP_FILE"
zenity --info --title="Exit" --text="Session ended" --width=300

#!/usr/bin/env bash
# ollama_shell_assistant_zenity.sh
# Graphical shell assistant using Ollama with Zenity UI
# Requirements: zenity, curl, jq
BASE_URL="http://localhost:11434"
TMP_FILE=$(mktemp)

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

# Function to call the Ollama API with strict command formatting
function ask_ai() {
  local prompt_text="$1"
  local model="$2"
  local system_info="OS: $OS_NAME $OS_VERSION. Desktop: $DESKTOP_ENVIRONMENT."
  local instruction="Respond ONLY with a valid shell command between triple backticks. No explanations. Example: \`\`\`ls -la\`\`\`"

  local payload
  payload=$(jq -n \
    --arg model "$model" \
    --arg prompt "${system_info}\n${instruction}\nTask: ${prompt_text}\nCommand:" \
    '{model: $model, prompt: $prompt, stream: false, options: {temperature: 0.2}}')

  zenity --progress --title="Generating" --text="Using ${model}..." \
    --pulsate --no-cancel --auto-close 2>/dev/null &
  ZENITY_PID=$!

  local raw
  raw=$(curl -s -X POST "${BASE_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$payload")

  kill $ZENITY_PID 2>/dev/null

  # Extract and validate command
  local ai_cmd=$(echo "$raw" | jq -r '.response' | \
    sed -n 's/.*```\(.*\)```.*/\1/p' | \
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
    grep -vE '^(#|//|$)' | \
    head -1)

  # Validate command exists
  if [[ -z "$ai_cmd" ]]; then
    zenity --error --title="Invalid Response" --text="No valid command detected in AI response" --width=300
    return 1
  fi

  local base_cmd=$(echo "$ai_cmd" | awk '{print $1}')
  if ! type "$base_cmd" &> /dev/null; then
    zenity --error --title="Invalid Command" --text="Command not found: $base_cmd" --width=300
    return 1
  fi

  echo "$ai_cmd"
}

# Execute command with validation
function execute_with_check() {
  local command="$1"
  echo "Running: $command" > "$TMP_FILE"
  output=$(eval "$command" 2>&1)
  status=$?
  echo "$output" >> "$TMP_FILE"
  return $status
}

# Main interaction loop
function run_until_success() {
  local goal="$1"
  local model="$2"
  local attempted=()
  
  while true; do
    ai_cmd=$(ask_ai "$goal" "$model")
    [ $? -ne 0 ] && continue  # Skip invalid commands
    
    sanitized_cmd=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$ai_cmd")
    zenity --question --title="Confirm Command" \
      --text="Model: $model\n\nSuggested command:\n<tt>$sanitized_cmd</tt>\n\nExecute?" \
      --width=500 --height=200
    
    if [ $? -ne 0 ]; then 
      zenity --info --title="Skipped" --text="Command skipped" --width=300
      continue
    fi
    
    attempted+=("$ai_cmd")
    execute_with_check "$ai_cmd"
    
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

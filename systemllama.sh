#!/usr/bin/env bash
# ollama_shell_assistant_zenity.sh
# Graphical shell assistant using Ollama/DeepSeek with Zenity UI and chat memory
# Requirements: zenity, curl, jq

BASE_URL="http://localhost:11434"
DEEPSEEK_API_KEY=""  # Add your DeepSeek API key here
DEEPSEEK_URL="https://api.deepseek.com/v1/chat/completions"
DEEPSEEK_MODEL="deepseek-chat"
TMP_FILE=$(mktemp)
PASSWORD=""
HISTORY_FILE="${HOME}/.ollama_shell_history.json"
SESSION_HISTORY=()
CURRENT_MODEL=""

# Initialize chat history
initialize_history() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo '[]' > "$HISTORY_FILE"
    fi
}

# Add message to history
add_history() {
    local role="$1"
    local content="$2"
    local temp_file=$(mktemp)
    jq --arg role "$role" --arg content "$content" \
        '. += [{"role": $role, "content": $content}]' \
        "$HISTORY_FILE" > "$temp_file" && mv "$temp_file" "$HISTORY_FILE"
}

# Clear chat history
clear_history() {
    echo '[]' > "$HISTORY_FILE"
    zenity --info --text="Chat history cleared" --width=300
}

# Detect available models with API status
function detect_models() {
    initialize_history
    # Check Ollama models
    local ollama_models=$(curl -s "${BASE_URL}/api/tags" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$ollama_models" | jq -r '.models[] |
        "\(.name)|Ollama|\(.details.parameter_size // "unknown")|\(.details.quantization_level // "unknown")"'
    fi
    # Add DeepSeek if API key exists
    if [ -n "$DEEPSEEK_API_KEY" ]; then
        echo "DeepSeek AI|DeepSeek|API Access|v1.0"
    fi
}

# Model selection dialog with source information
function select_model() {
    local models=()
    while IFS="|" read -r name source param_size quant; do
        models+=("$name" "${source} - ${param_size} (${quant})")
    done < <(detect_models)
    [ ${#models[@]} -eq 0 ] && zenity --error --text="No models available!" && exit 1
    local selected=$(zenity --list \
        --title="Select AI Model" \
        --text="Available models:" \
        --column="Model Name" --column="Source and Details" \
        --width=800 --height=400 \
        "${models[@]}")
    echo "$selected"
}

# Unified AI query function with chat memory
function ask_ai() {
    local prompt_text="$1"
    local model="$2"
    local system_info="OS: $OS_NAME $OS_VERSION. Desktop: $DESKTOP_ENVIRONMENT."
    
    # Add user prompt to history
    add_history "user" "$prompt_text"
    
    local progress_msg="🔄 Generating command..."
    zenity --progress --title="Processing" --text="$progress_msg" \
        --pulsate --no-cancel --width=300 2>/dev/null &
    ZENITY_PID=$!
    
    local raw ai_cmd
    local history_messages=$(jq -c '.' "$HISTORY_FILE")
    
    # Common system message
    local system_message="You are a Linux terminal expert. Respond ONLY with ONE valid bash command between triple backticks.
STRICT RULES:
1. Command must work on $OS_NAME
2. Use only installed core utilities
3. No explanations or comments
4. Format: \`\`\`command -flags args\`\`\`
5. Validate command syntax before responding"
    
    if [[ "$model" == "DeepSeek AI" ]]; then
        # DeepSeek API Call with history
        local payload
        payload=$(jq -n \
            --arg model "$DEEPSEEK_MODEL" \
            --arg sys_msg "$system_message" \
            --argjson history "$history_messages" \
            '{
                model: $model,
                messages: [
                    {role: "system", content: $sys_msg},
                    $history[]
                ],
                temperature: 0.1
            }')
        
        raw=$(curl -s -X POST "$DEEPSEEK_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
            -d "$payload")
        
        if echo "$raw" | jq -e '.error' >/dev/null; then
            zenity --error --text="DeepSeek Error: $(echo "$raw" | jq -r '.error.message')"
            kill $ZENITY_PID 2>/dev/null
            return 1
        fi
        ai_cmd=$(echo "$raw" | jq -r '.choices[0].message.content' | \
            awk 'BEGIN{RS="```";FS="\n"} NR==2{gsub(/^[ \t]+|[ \t]+$/,"");print}')
    else
        # Ollama API Call with chat history
        local payload
        payload=$(jq -n \
            --arg model "$model" \
            --arg sys_msg "$system_message" \
            --argjson history "$history_messages" \
            '{
                model: $model,
                messages: [
                    {role: "system", content: $sys_msg},
                    $history[]
                ],
                stream: false,
                options: {temperature: 0.1}
            }')
        
        raw=$(curl -s -X POST "${BASE_URL}/api/chat" \
            -H "Content-Type: application/json" \
            -d "$payload")
        
        ai_cmd=$(echo "$raw" | jq -r '.message.content' | \
            awk 'BEGIN{RS="```";FS="\n"} NR==2{gsub(/^[ \t]+|[ \t]+$/,"");print}')
    fi
    
    kill $ZENITY_PID 2>/dev/null
    
    # Validation checks
    [[ -z "$ai_cmd" ]] && {
        zenity --error --title="Invalid Response" --text="No command detected in AI response" --width=300
        return 1
    }
    
    # Add AI response to history
    add_history "assistant" "$ai_cmd"
    
    echo "$ai_cmd"
}

# Secure execution with error capture and history logging
function execute_with_check() {
    local display_command="$1"
    local exec_command="$2"
    echo "Running: $display_command" > "$TMP_FILE"
    output=$(eval "$exec_command" 2>&1)
    status=$?
    
    if [ $status -ne 0 ]; then
        # Add error context to history
        error_context=$(echo "$output" | sed -E '
            s/(\/home\/)[^/]+/\1USERNAME/g;
            s/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[IP_REDACTED]/g;
            s/[pP]assword for .*:/[Authentication required]/g;
            s/sudo: [^ ]* //g;
            /^$/d' | head -n 3)
        add_history "user" "Command failed: $error_context Please suggest a new command."
    fi
    
    echo "$output" >> "$TMP_FILE"
    return $status
}

# Main interaction loop
function run_until_success() {
    local goal="$1"
    local model="$2"
    while true; do
        ai_cmd=$(ask_ai "$goal" "$model")
        [ $? -ne 0 ] && continue
        
        display_cmd=$(sed 's/sudo /sudo -S /g' <<< "$ai_cmd")
        if [[ "$ai_cmd" == _"sudo "_ ]]; then
            exec_cmd="{ echo '$PASSWORD'; } | $display_cmd 2>/dev/null"
        else
            exec_cmd="$display_cmd"
        fi
        
        sanitized_cmd=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$display_cmd")
        response=$(zenity --question \
            --title="Confirm Command" \
            --text="Model: $model\n\nSuggested command:\n<tt>$sanitized_cmd</tt>\n\nExecute?" \
            --ok-label="Execute" \
            --cancel-label="Skip" \
            --extra-button="Quit" \
            2>&1)
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            execute_with_check "$display_cmd" "$exec_cmd"
            if [ $? -eq 0 ]; then
                zenity --text-info --title="Success" --filename="$TMP_FILE" --width=800 --height=600
                return 0
            else
                zenity --text-info --title="Error" --filename="$TMP_FILE" --width=800 --height=600
                zenity --question --text="Command failed. Retry with different approach?" || return 1
            fi
        else
            [[ "$response" == _"Quit"_ ]] && { rm "$TMP_FILE"; exit 0; }
            continue
        fi
    done
}

# OS Detection
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
else
    OS_NAME="Unknown"
    OS_VERSION=""
fi

# Desktop Environment Detection
DESKTOP_ENVIRONMENT=${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-"Unknown"}}

# Main execution flow
initialize_history
SELECTED_MODEL=$(select_model)
[ -z "$SELECTED_MODEL" ] && exit 1
PASSWORD=$(zenity --password --title="Sudo Authentication" \
    --text="Enter your sudo password (used securely if needed):")
[ $? -ne 0 ] && exit 1

while true; do
    user_input=$(zenity --entry \
        --title="AI Assistant (${SELECTED_MODEL})" \
        --text="Enter task description:" \
        --width=500 --height=150)
    [ $? -ne 0 ] && break
    
    case "$user_input" in
        "switch model")
            NEW_MODEL=$(select_model)
            [ -n "$NEW_MODEL" ] && SELECTED_MODEL="$NEW_MODEL"
            continue
            ;;
        "clear history")
            clear_history
            continue
            ;;
        *)
            run_until_success "$user_input" "$SELECTED_MODEL"
            ;;
    esac
done

rm "$TMP_FILE"
zenity --info --title="Exit" --text="Session ended" --width=300

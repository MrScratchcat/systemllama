#!/usr/bin/env bash
# ollama_shell_assistant_zenity.sh
# Graphical shell assistant with robust command extraction
# Requirements: zenity, curl, jq, coreutils

BASE_URL="http://localhost:11434"
DEEPSEEK_API_KEY="sk-fa87bb4f80bd423e843c4041093f5b9f"
DEEPSEEK_URL="https://api.deepseek.com/v1/chat/completions"
DEEPSEEK_MODEL="deepseek-chat"
DEEPSEEK_REASONER_MODEL="deepseek-reasoner"  # Add the new DeepSeek Reasoner model
REASON_API_KEY=""
REASON_URL="https://api.reason.ai/v1/chat/completions"
REASON_MODEL="reason-chat"
TMP_FILE=$(mktemp)
PASSWORD=""
HISTORY_FILE="${HOME}/.ollama_shell_history.json"
OS_NAME=""
OS_VERSION=""
DESKTOP_ENVIRONMENT=""

# Ensure clean exit
cleanup_and_exit() {
    local exit_code=${1:-0}
    # Clean up temp files
    rm -f "$TMP_FILE" "$TMP_FILE.current" 2>/dev/null
    # Kill any running zenity processes started by this script
    pkill -P $$ zenity 2>/dev/null || true
    echo "Exiting with code $exit_code" >&2
    exit $exit_code
}

# Ensure immediate exit with any quit button - but allow returning to main prompt
quit_immediately() {
    local return_to_main=${1:-0}
    echo "QUIT BUTTON PRESSED" >&2
    
    # If we should return to main menu instead of exiting
    if [[ $return_to_main -eq 1 ]]; then
        echo "Returning to main prompt..." >&2
        return 1  # Return with error to break out of current function
    else
        # Otherwise do a hard exit
        echo "TERMINATING IMMEDIATELY" >&2
        # Clean up files before exiting
        rm -f "$TMP_FILE" "$TMP_FILE.current" 2>/dev/null
        # Kill all zenity processes
        pkill -9 zenity 2>/dev/null
        # Hard exit
        exec kill -9 $$
    fi
}

# Trap interrupts and termination signals
trap 'cleanup_and_exit 1' INT TERM

# Initialize chat history
initialize_history() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo '[]' > "$HISTORY_FILE"
    else
        if ! jq empty "$HISTORY_FILE" &>/dev/null; then
            echo "[]" > "$HISTORY_FILE"
            zenity --warning --text="Corrupted history file, starting fresh" --width=300
        fi
    fi
}

# Add message to history
add_history() {
    local role="$1"
    local content="$2"
    local temp_file=$(mktemp)
    content=$(jq -aRs . <<< "$content" | sed 's/^"//;s/"$//')
    jq --arg role "$role" --arg content "$content" \
        '. += [{"role": $role, "content": $content}]' \
        "$HISTORY_FILE" > "$temp_file" && mv "$temp_file" "$HISTORY_FILE"
}

# Load safe history
load_safe_history() {
    jq -c '.' "$HISTORY_FILE" 2>/dev/null || echo '[]'
}

# Clear history
clear_history() {
    echo '[]' > "$HISTORY_FILE"
    zenity --info --text="Chat history cleared" --width=300
}

# Detect models
detect_models() {
    initialize_history
    local ollama_models=$(curl -s "${BASE_URL}/api/tags" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$ollama_models" | jq -r '.models[] |
        "\(.name)|Ollama|\(.details.parameter_size // "unknown")|\(.details.quantization_level // "unknown")"'
    fi
    if [ -n "$DEEPSEEK_API_KEY" ]; then
        echo "DeepSeek AI|DeepSeek|API Access|v1.0"
        echo "DeepSeek Reasoner|DeepSeek|API Access|v1.0"  # Add the DeepSeek Reasoner model
    fi
    if [ -n "$REASON_API_KEY" ]; then
        echo "Reason AI|Reason|API Access|v1.0"
    fi
}

# Select model
select_model() {
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

# Enhanced command extraction with better debugging
extract_command() {
    local response="$1"
    
    # Debug raw response
    echo "DEBUG - Extracting command from: $response" >&2
    
    # Pre-clean the response to handle escapes before parsing
    response=$(echo "$response" | sed 's/\\n/ /g' | sed 's/\\\\/ /g' | sed 's/\\"/"/g')
    
    # Look for code blocks first - with enhanced debug output
    local command=$(echo "$response" | \
    {
        # Try bash code blocks first
        sed -n '/```bash/,/```/{//!p;}' 2>/dev/null ||
        sed -n '/```sh/,/```/{//!p;}' 2>/dev/null ||
        # Also try simple backtick blocks without language specification
        sed -n '/```$/,/```/{//!p;}' 2>/dev/null ||
        # Generic code blocks
        sed -n '/```/,/```/{//!p;}' 2>/dev/null ||
        # Command-like lines (quotes handled)
        grep -m1 -E '^[[:space:]]*(\x60|`)?[[:alnum:]]+(-[[:alnum:]]+)*(\s+[-[:alnum:]<>]+)*(\x60|`)?[[:space:]]*$' 2>/dev/null ||
        # Simple check for common commands
        grep -m1 -E '(apt|dnf|yum|pacman)[[:space:]]+(install|upgrade|remove|update)' 2>/dev/null
    })
    
    echo "DEBUG - Extracted from code blocks: '$command'" >&2
    
    # If no command found in code blocks, check if the entire response is a valid command
    if [[ -z "$command" ]]; then
        # Handle direct commands from model response (including those with && || | etc)
        if [[ "$response" =~ ^[[:space:]]*[[:alnum:]]+[[:space:]].*$ ]]; then
            # Check if it starts with a valid command format - now including angle brackets for placeholders
            command=$(echo "$response" | grep -E '^[[:space:]]*[[:alnum:]./]+([ ][[:alnum:]./_=:&|;><^$()*{}\[\]"'\''#~+,?!-]+)*[[:space:]]*$')
        fi
        
        # Special case for direct API response format
        if [[ -z "$command" && "$response" == *"message"*"content"* ]]; then
            # Try to extract from the message content field directly from JSON
            local extracted=$(echo "$response" | jq -r '.message.content' 2>/dev/null)
            # Remove escape sequences and backticks from the extracted content
            extracted=$(echo "$extracted" | sed 's/\\n/ /g' | sed 's/\\\\/ /g' | sed 's/\\"/"/g' | tr -d '`')
            echo "DEBUG - JSON extracted content: '$extracted'" >&2
            command="$extracted"
        fi
    fi
    
    # Clean the command without removing angle brackets for placeholders
    command=$(echo "$command" | \
    sed -E 's/(^[[:space:]]*[\x60`]?|[\x60`]?[[:space:]]*$)//g' | \
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')
    
    echo "DEBUG - Cleaned command: '$command'" >&2
    
    # Add auto-confirmation flags to commands that might prompt for input
    if [[ -n "$command" ]]; then
        # Package managers - now with more careful pattern matching to preserve placeholders
        if [[ "$command" =~ ^(sudo[[:space:]]+)?(apt(-get)?|dnf|yum|pacman)[[:space:]]+(install|remove|upgrade|update) ]] && ! [[ "$command" =~ -[[:alnum:]]*y ]]; then
            # For history commands and other dnf/yum subcommands, add -y at the end if not present
            if [[ "$command" =~ (history|list|info|search) ]] && ! [[ "$command" =~ -y$ ]]; then
                command="$command -y"
            else
                command=$(echo "$command" | sed -E 's/(apt(-get)?|dnf|yum)[[:space:]]+(install|remove|upgrade|update)/\1 -y \3/')
                command=$(echo "$command" | sed -E 's/pacman[[:space:]]+(install|remove|upgrade|update)/pacman --noconfirm \1/')
            fi
        fi
        
        # Also handle multiple commands with && or ||
        if [[ "$command" =~ (\&\&|\|\|) ]]; then
            # Process each part of the compound command
            command=$(echo "$command" | sed -E 's/(apt(-get)?|dnf|yum)[[:space:]]+(install|remove|upgrade|update)/\1 -y \3/g')
            command=$(echo "$command" | sed -E 's/pacman[[:space:]]+(install|remove|upgrade|update)/pacman --noconfirm \1/g')
        fi
        
        # Add -f (force) to cp/mv/rm if not present and seems like it might need it
        if [[ "$command" =~ ^(sudo[[:space:]]+)?(cp|mv|rm)[[:space:]]+ ]] && ! [[ "$command" =~ -[[:alnum:]]*f ]]; then
            # Only add if it seems to be copying over existing files or removing directories
            if [[ "$command" =~ (cp|mv)[[:space:]]+.+[[:space:]]+.+ ]] || [[ "$command" =~ rm[[:space:]]+(-r|--recursive) ]]; then
                command=$(echo "$command" | sed -E 's/(cp|mv|rm)([[:space:]]+)/\1 -f\2/')
            fi
        fi
    fi
    
    echo "$command"
}

# Validate sudo password
validate_sudo_password() {
    local password="$1"
    if [[ -z "$password" ]]; then
        return 1  # Empty password
    fi
    
    # Test password with a harmless command
    echo "$password" | sudo -S -k -v >/dev/null 2>&1
    return $?
}

# Ask AI with robust parsing
ask_ai() {
    local prompt_text="$1"
    local model="$2"
    local raw_response_file=$(mktemp)
    local ZENITY_PID=""
    
    # Define cleanup function to ensure Zenity is always killed
    cleanup() {
        if [[ -n "$ZENITY_PID" ]]; then
            kill $ZENITY_PID 2>/dev/null || true
            wait $ZENITY_PID 2>/dev/null || true
        fi
        [[ -f "$raw_response_file" ]] && rm -f "$raw_response_file"
    }
    
    # Set trap to ensure cleanup happens even on errors
    trap cleanup EXIT
    
    add_history "user" "$prompt_text"
    local history_messages=$(load_safe_history)
    
    # Dynamic system message with emphasis on auto-confirmation
    local system_message="You are a Linux terminal expert. Respond with ONE valid bash command between triple backticks.
STRICT RULES:
1. Command must work on $OS_NAME
2. Use only installed core utilities
3. Put command in \`\`\`bash block
4. ALWAYS include auto-confirmation flags where needed:
   - Use -y with apt, dnf, yum
   - Use --noconfirm with pacman
   - Use --force or -f when overwriting files
   - Use yes | command or echo 'y' | command for other prompts
5. NEVER suggest commands that will wait for user input
6. Validate syntax before responding"
    
    [[ "$model" == "DeepSeek AI" ]] && system_message+="\nDEEPSEEK FORMAT NOTE: Respond with command in \`\`\`bash blocks"
    [[ "$model" == "Reason AI" ]] && system_message+="\nREASON FORMAT NOTE: Respond with command in \`\`\`bash blocks"

    # Start progress dialog
    zenity --progress --title="Processing" --text="Generating command..." \
        --pulsate --no-cancel --width=300 2>/dev/null &
    ZENITY_PID=$!
    
    local raw=""
    if [[ "$model" == "DeepSeek AI" || "$model" == "DeepSeek Reasoner" ]]; then
        # DeepSeek API call - use different model name based on selection
        local deepseek_model_name="$DEEPSEEK_MODEL"
        [[ "$model" == "DeepSeek Reasoner" ]] && deepseek_model_name="$DEEPSEEK_REASONER_MODEL"
        
        local payload
        payload=$(jq -n \
            --arg model "$deepseek_model_name" \
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
        echo "$raw" > "$raw_response_file"
    elif [[ "$model" == "Reason AI" ]]; then
        # Reason AI API call
        local payload
        payload=$(jq -n \
            --arg model "$REASON_MODEL" \
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
        raw=$(curl -s -X POST "$REASON_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $REASON_API_KEY" \
            -d "$payload")
        echo "$raw" > "$raw_response_file"
    else
        # Ollama API call
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
        echo "$raw" > "$raw_response_file"
    fi

    # Debug: Log raw response
    echo "DEBUG - Raw API Response:" >&2
    jq . "$raw_response_file" >&2
    echo "-----------------------" >&2

    # Extract command content
    if [[ "$model" == "DeepSeek AI" || "$model" == "DeepSeek Reasoner" || "$model" == "Reason AI" ]]; then
        local response_content=$(jq -r '.choices[0].message.content' "$raw_response_file")
    else
        local response_content=$(jq -r '.message.content' "$raw_response_file")
    fi
    
    # Pre-clean response content to handle escape sequences
    response_content=$(echo "$response_content" | sed 's/\\n/ /g' | sed 's/\\r/ /g' | sed 's/\\t/ /g')
    
    ai_cmd=$(extract_command "$response_content")
    
    # Validation
    if [[ -z "$ai_cmd" || "$ai_cmd" =~ ^[[:space:]]*$ ]]; then
        echo "ERROR: Command extraction failed! Raw response appears valid but couldn't extract command." >&2
        zenity --question \
            --title="Command Extraction Failed" \
            --text="The AI provided a response, but command extraction failed.\n\nRaw response:\n<tt>$response_content</tt>\n\nWould you like to use this response anyway?" \
            --ok-label="Use Anyway" --cancel-label="Retry" \
            --width=600
        if [[ $? -eq 0 ]]; then
            # Use the raw response directly
            ai_cmd=$(echo "$response_content" | tr -d '`')
            echo "DEBUG - Using raw response: '$ai_cmd'" >&2
        else
            add_history "user" "Command extraction failed: $raw"
            return 1
        fi
    fi
    
    # Final sanitization - ensure no trailing escape sequences or extra characters
    ai_cmd=$(echo "$ai_cmd" | \
        sed 's/\\[nr]//g' | \
        sed 's/\\//g' | \
        sed 's/^sudo\s*/sudo /; s/\s\+/ /g' | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    # Always explicitly kill the zenity process before validating
    cleanup
    trap - EXIT  # Remove the trap since we've manually cleaned up
    
    # Validation
    if [[ -z "$ai_cmd" || "$ai_cmd" =~ ^[[:space:]]*$ ]]; then
        zenity --question \
            --title="Invalid Response" \
            --text="No valid command found. Show raw output?" \
            --ok-label="Show Raw" --cancel-label="Retry" \
            --width=400
        if [[ $? -eq 0 ]]; then
            zenity --text-info --title="Raw Response" \
                --filename=<(echo -e "Model: $model\nFull Response:\n$raw") \
                --width=800 --height=600
        fi
        add_history "user" "Invalid response received: $raw"
        return 1
    fi

    add_history "assistant" "$ai_cmd"
    echo "$ai_cmd"
}

# Execute command with timeout monitoring and ability to interrupt
execute_with_check() {
    local display_command="$1"
    local exec_command="$2"
    local output_file=$(mktemp)
    local timeout_seconds=30
    local cmd_pid
    
    echo "Running: $display_command" > "$TMP_FILE"
    
    # Start command in background
    eval "$exec_command" > "$output_file" 2>&1 &
    cmd_pid=$!
    
    # Monitor running command
    local time_elapsed=0
    local interrupted=0
    
    while kill -0 $cmd_pid 2>/dev/null; do
        sleep 1
        ((time_elapsed++))
        
        if [ $time_elapsed -eq $timeout_seconds ]; then
            # Capture current output
            cat "$output_file" > "$TMP_FILE.current"
            
            zenity --question \
                --title="Command Running for ${timeout_seconds}s" \
                --text="This command is taking longer than expected. What would you like to do?" \
                --ok-label="Show Output" \
                --cancel-label="Keep Waiting" \
                --width=400
                
            if [ $? -eq 0 ]; then
                # Show current output and ask for decision
                zenity --text-info --title="Current Output (Command Still Running)" \
                    --filename="$TMP_FILE.current" \
                    --width=800 --height=600 \
                    --ok-label="Continue" \
                    --extra-button="Terminate" \
                    --extra-button="Find Alternative"
                
                case $? in
                    0)  # Continue waiting
                        ;;
                    5)  # Terminate
                        kill $cmd_pid 2>/dev/null
                        interrupted=1
                        break
                        ;;
                    6)  # Find alternative
                        kill $cmd_pid 2>/dev/null
                        interrupted=2
                        break
                        ;;
                esac
            fi
        fi
    done
    
    # Wait for process to finish and get its status
    wait $cmd_pid 2>/dev/null
    status=$?
    
    # If we terminated the process, override the status
    if [ $interrupted -eq 1 ]; then
        echo "Command terminated by user after ${time_elapsed} seconds." >> "$TMP_FILE"
        cat "$output_file" >> "$TMP_FILE"
        rm -f "$output_file" "$TMP_FILE.current" 2>/dev/null
        return 2  # Special code for user termination
    elif [ $interrupted -eq 2 ]; then
        echo "User requested alternative approach after ${time_elapsed} seconds." >> "$TMP_FILE"
        cat "$output_file" >> "$TMP_FILE"
        add_history "user" "The previous command was taking too long (${time_elapsed}s). Current output: $(tail -n 5 "$output_file" | tr '\n' ' '). Please suggest a faster alternative that accomplishes the same task."
        rm -f "$output_file" "$TMP_FILE.current" 2>/dev/null
        return 3  # Special code for alternative request
    fi
    
    # Normal completion
    cat "$output_file" >> "$TMP_FILE"
    rm -f "$output_file" "$TMP_FILE.current" 2>/dev/null
    
    # Check for sudo password issues
    if grep -q "sudo: no password was provided\|sudo: a password is required\|incorrect password" "$TMP_FILE"; then
        echo "ERROR: Sudo authentication failed. Please check your password." >> "$TMP_FILE"
        return 4  # Special code for sudo password issues
    fi
    
    if [ $status -ne 0 ]; then
        error_context=$(cat "$TMP_FILE" | sed -E '
            s/(\/home\/)[^/]+/\1USERNAME/g;
            s/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[IP_REDACTED]/g;
            s/[pP]assword for .*:/[Authentication required]/g;
            s/sudo: [^ ]* //g;
            /^$/d' | tail -n 5)
        add_history "user" "Command failed: $error_context Please suggest a new command."
    fi
    
    return $status
}

# Main interaction flow
run_until_success() {
    local goal="$1"
    local model="$2"
    while true; do
        ai_cmd=$(ask_ai "$goal" "$model")
        [ $? -ne 0 ] && continue
        display_cmd=$(sed 's/sudo /sudo -S /g' <<< "$ai_cmd")
        if [[ "$display_cmd" =~ ^sudo[[:space:]] ]]; then
            exec_cmd="echo '$PASSWORD' | $display_cmd"
        else
            exec_cmd="$display_cmd"
        fi
        sanitized_cmd=$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$display_cmd")
        
        # More robust quit button handling
        zenity_output=$(zenity --question \
            --title="Confirm Command" \
            --text="Model: $model\n\nSuggested command:\n<tt>$sanitized_cmd</tt>\n\nExecute?" \
            --ok-label="Execute" \
            --cancel-label="Cancel" \
            --extra-button="Quit" \
            --width=400 2>&1)
        
        # Capture exit code IMMEDIATELY
        local zenity_result=$?
        echo "DEBUG: zenity command confirmation returned: $zenity_result (output: $zenity_output)" >&2
        
        # Extra careful handling of the quit button
        if [[ "$zenity_output" == *"Quit"* || $zenity_result -eq 5 ]]; then
            echo "QUIT BUTTON DETECTED! Breaking out completely" >&2
            # Kill any zenity processes immediately
            pkill -9 zenity >/dev/null 2>&1
            # Force exit from this function directly
            break  # Break out of the while loop
        elif [ $zenity_result -ne 0 ]; then
            # Cancel button pressed
            continue
        fi

        execute_with_check "$display_cmd" "$exec_cmd"
        exec_result=$?
        
        case $exec_result in
            0)  # Command succeeded
                zenity_result=$(zenity --text-info --title="Command Output" \
                    --filename="$TMP_FILE" \
                    --width=800 --height=600 \
                    --ok-label="Continue" 2>&1)
                exit_code=$?
                [[ $exit_code -eq 255 ]] && cleanup_and_exit 0
                return 0
                ;;
            2)  # User terminated command
                zenity_result=$(zenity --text-info --title="Command Terminated" \
                    --filename="$TMP_FILE" \
                    --width=800 --height=600 \
                    --ok-label="Understand" 2>&1)
                exit_code=$?
                [[ $exit_code -eq 255 ]] && cleanup_and_exit 0
                
                zenity_result=$(zenity --question \
                    --title="Next Step" \
                    --text="What would you like to do?" \
                    --ok-label="Try Again" \
                    --cancel-label="Cancel Task" \
                    --width=400 2>&1)
                exit_code=$?
                [[ $exit_code -eq 255 ]] && cleanup_and_exit 0
                [ $exit_code -eq 0 ] && continue || return 1
                ;;
            3)  # User requested alternative
                zenity_result=$(zenity --text-info --title="Requesting Alternative" \
                    --filename="$TMP_FILE" \
                    --width=800 --height=600 \
                    --ok-label="Find Alternative" 2>&1)
                exit_code=$?
                [[ $exit_code -eq 255 ]] && cleanup_and_exit 0
                continue
                ;;
            4)  # Sudo password issue
                zenity_result=$(zenity --text-info --title="Authentication Failed" \
                    --filename="$TMP_FILE" \
                    --width=800 --height=600 \
                    --ok-label="Retry" \
                    --extra-button="Quit" 2>&1)
                exit_code=$?
                
                # Handle exit codes explicitly
                if [[ $exit_code -eq 5 || $exit_code -eq 255 ]]; then
                    # Return to main prompt instead of exiting
                    echo "QUIT detected in auth dialog - returning to main prompt" >&2
                    return 1
                fi
                
                # Ask for new password with validation
                while true; do
                    NEW_PASSWORD=$(zenity --password --title="Sudo Authentication" \
                        --text="Enter your sudo password:")
                    if [ $? -ne 0 ]; then
                        break  # User cancelled
                    fi
                    
                    if validate_sudo_password "$NEW_PASSWORD"; then
                        PASSWORD="$NEW_PASSWORD"
                        break  # Valid password
                    else
                        zenity --error --text="Incorrect password. Please try again." --width=300
                    fi
                done
                continue
                ;;
            *)  # Command failed with error
                zenity_result=$(zenity --text-info --title="Command Failed" \
                    --filename="$TMP_FILE" \
                    --width=800 --height=600 \
                    --ok-label="Try Again" \
                    --extra-button="Quit" \
                    --extra-button="New Prompt" 2>&1)
                exit_code=$?
                
                echo "DEBUG: Command failed dialog returned: $exit_code" >&2
                
                case $exit_code in
                    0)  # Try Again
                        continue
                        ;;
                    5|255)  # Quit buttons - return to main prompt
                        echo "QUIT detected in error dialog - returning to main prompt" >&2
                        return 1
                        ;;
                    6)  # New Prompt - extra button 2
                        return 1
                        ;;
                    *)  # Any other code
                        echo "Unknown dialog return code: $exit_code, exiting" >&2
                        cleanup_and_exit 1
                        ;;
                esac
                ;;
        esac
    done
    
    # If we reached here via the break statement, we need to return to main prompt
    echo "Returning to main prompt after quit" >&2
    return 1
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

# Detect desktop environment
DESKTOP_ENVIRONMENT=${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-"Unknown"}}

# Initialize history
initialize_history

# Model selection
SELECTED_MODEL=$(select_model)
[ -z "$SELECTED_MODEL" ] && exit 1

# Password input with validation
while true; do
    PASSWORD=$(zenity --password --title="Sudo Authentication" \
        --text="Enter your sudo password (used securely if needed):")
    if [ $? -ne 0 ]; then
        cleanup_and_exit 0  # Use our clean exit function here too
    fi
    
    # Test if password works
    if validate_sudo_password "$PASSWORD"; then
        break  # Password is correct
    else
        zenity --error --text="Incorrect password. Please try again." --width=300
    fi
done

while true; do
    user_input=$(zenity --entry \
        --title="AI Assistant (${SELECTED_MODEL})" \
        --text="Enter task description:" \
        --width=500 --height=150)
    user_response_code=$?
    if [[ $user_response_code -ne 0 ]]; then
        echo "User canceled main prompt, exiting" >&2
        quit_immediately  # Immediate exit
    fi
    
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

cleanup_and_exit 0

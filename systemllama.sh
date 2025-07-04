#!/usr/bin/env bash
# ollama_shell_assistant_zenity.sh
# Graphical shell assistant with robust command extraction
# Requirements: zenity, curl, jq, coreutils, ddgr

# Initialize variables first
BASE_URL="http://localhost:11434"
DEEPSEEK_API_KEY=""
DEEPSEEK_URL="https://api.deepseek.com/v1/chat/completions"
DEEPSEEK_MODEL="deepseek-chat"
TMP_FILE=$(mktemp)
PASSWORD=""
HISTORY_FILE="${HOME}/.ollama_shell_history.json"
OS_NAME=""
OS_VERSION=""
DESKTOP_ENVIRONMENT=""
PACKAGE_MANAGER=""
OS_FAMILY=""
WEB_SEARCH_ENABLED=true
sites=10  # Number of sites to search max 11

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
    DESKTOP_ENVIRONMENT=$(echo "$XDG_CURRENT_DESKTOP" | tr '[:upper:]' '[:lower:]')
    # Try to detect package manager by checking what's available
    if command -v rpm-ostree >/dev/null 2>&1; then
        PACKAGE_MANAGER="rpm-ostree/flatpak"
        OS_FAMILY="atomic desktops"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
        OS_FAMILY="fedora"
    elif command -v apt >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
        OS_FAMILY="debian"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
        OS_FAMILY="arch"
    elif command -v zypper >/dev/null 2>&1; then    
        PACKAGE_MANAGER="zypper"
        OS_FAMILY="suse"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
        OS_FAMILY="redhat"
    elif command -v apk >/dev/null 2>&1; then
           PACKAGE_MANAGER="apk"
        OS_FAMILY="alpine"
    else
        PACKAGE_MANAGER="unknown"
        OS_FAMILY="unknown"
    fi
else
    OS_NAME="Unknown"
    OS_VERSION=""
    PACKAGE_MANAGER="unknown"
    OS_FAMILY="unknown"
fi

echo "Detected OS: $OS_NAME $OS_VERSION (Family: $OS_FAMILY, Package Manager: $PACKAGE_MANAGER)" >&2


# Check internet connectivity
check_internet() {
    if command -v curl >/dev/null 2>&1; then
        curl -s --connect-timeout 5 --max-time 10 "https://duckduckgo.com" >/dev/null 2>&1
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=10 "https://duckduckgo.com" >/dev/null 2>&1
        return $?
    else
        # Fallback to ping
        ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
        return $?
    fi
}

# Perform web search using ddgr
perform_web_search() {
    local query="$1"
    local search_results=""
    
    # Check if ddgr is available
    if ! command -v ddgr >/dev/null 2>&1; then
        echo "Web search disabled: ddgr not found" >&2
        return 1
    fi
    
    # Check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Web search disabled: python3 not found" >&2
        return 1
    fi
    
    # Check internet connectivity
    if ! check_internet; then
        echo "Web search disabled: No internet connection" >&2
        return 1
    fi
    
    echo "🔍 Performing web search for: $query" >&2
    
    # Perform search with ddgr using python3 - let it return all requested results
    search_results=$(python3 $(which ddgr) --np -x -n $sites "$query" 2>/dev/null)
    
    if [[ -n "$search_results" ]]; then
        echo "✓ Web search completed - found relevant results" >&2
        echo "$search_results"
        return 0
    else
        echo "⚠ No web search results found" >&2
        return 1
    fi
}

# Ensure clean exit
cleanup_and_exit() {
    local exit_code=${1:-0}
    # Clean up temp files
    rm -f "$TMP_FILE" "$TMP_FILE.current" 2>/dev/null
    # Kill any running zenity processes started by this script
    pkill -P $$ zenity 2>/dev/null || true
    
    # Delete history file on exit for privacy
    if [[ -f "$HISTORY_FILE" ]]; then
        echo "Cleaning up chat history..." >&2
        rm -f "$HISTORY_FILE" 2>/dev/null
    fi
    
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
        # Clean up files before exiting including history
        rm -f "$TMP_FILE" "$TMP_FILE.current" 2>/dev/null
        if [[ -f "$HISTORY_FILE" ]]; then
            echo "Cleaning up chat history..." >&2
            rm -f "$HISTORY_FILE" 2>/dev/null
        fi
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
    
    # Pre-clean the response to handle escapes and thinking tags
    response=$(echo "$response" | sed 's/\\n/ /g' | sed 's/\\\\/ /g' | sed 's/\\"/"/g')
    
    # Remove thinking tags and their content (handle multiline with proper regex)
    response=$(echo "$response" | sed ':a;s/<think>.*<\/think>//g;ta' | sed 's/<think>.*//g' | sed 's/<\/think>.*//g')
    
    # Also remove any remaining XML-like tags that might interfere
    response=$(echo "$response" | sed 's/<[^>]*>//g')
    
    echo "DEBUG - After removing thinking tags: $response" >&2
    
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
        # Command-like lines (quotes handled) - improved pattern
        grep -m1 -E '^[[:space:]]*[[:alnum:]]+[[:space:]]+[[:alnum:]._-]+' 2>/dev/null ||
        # Simple check for common commands
        grep -m1 -E '(rpm-ostree|apt|dnf|yum|pacman|sudo)[[:space:]]+(install|upgrade|remove|update)' 2>/dev/null
    })
    
    echo "DEBUG - Extracted from code blocks: '$command'" >&2
    
    # If no command found in code blocks, try to extract from the cleaned response
    if [[ -z "$command" ]]; then
        # Look for lines that start with common command patterns
        command=$(echo "$response" | grep -E '^[[:space:]]*(sudo[[:space:]]+)?(apt|dnf|yum|pacman|systemctl|service|mount|umount|cp|mv|rm|mkdir|chmod|chown|find|grep|sed|awk)[[:space:]]' | head -1)
        
        # If still nothing, try a broader pattern for any command-like structure
        if [[ -z "$command" ]]; then
            command=$(echo "$response" | grep -E '^[[:space:]]*[[:alnum:]./]+([[:space:]]+[-[:alnum:]._=:&|;><^$()*{}\[\]"'"'"'#~+,?!-]+)*[[:space:]]*$' | head -1)
        fi
        
        # Special case for direct API response format
        if [[ -z "$command" && "$response" == *"message"*"content"* ]]; then
            # Try to extract from the message content field directly from JSON
            local extracted=$(echo "$response" | jq -r '.message.content' 2>/dev/null)
            # Remove escape sequences and backticks from the extracted content
            extracted=$(echo "$extracted" | sed 's/\\n/ /g' | sed 's/\\\\/ /g' | sed 's/\\"/"/g' | tr -d '`')
            # Remove thinking tags from extracted content
            extracted=$(echo "$extracted" | sed ':a;s/<think>.*<\/think>//g;ta' | sed 's/<think>.*//g' | sed 's/<\/think>.*//g')
            echo "DEBUG - JSON extracted content: '$extracted'" >&2
            command="$extracted"
        fi
    fi
    
    # Clean the command without removing angle brackets for placeholders
    command=$(echo "$command" | \
    sed -E 's/(^[[:space:]]*[\x60`]?|[\x60`]?[[:space:]]*$)//g' | \
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')
    
    # If we still have a very long response, try to extract just the command part
    if [[ ${#command} -gt 200 ]]; then
        # Look for the actual command in the long response
        local short_cmd=$(echo "$command" | grep -oE '(sudo[[:space:]]+)?(apt|dnf|yum|pacman|systemctl)[[:space:]]+[[:alnum:]._-]+([[:space:]]+[-[:alnum:]._]+)*' | head -1)
        if [[ -n "$short_cmd" ]]; then
            command="$short_cmd"
        fi
    fi
    
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

# Check internet connectivity and update web search status
check_and_update_web_search() {
    if [[ "$WEB_SEARCH_ENABLED" == true ]]; then
        if ! check_internet; then
            echo "⚠ No internet connection detected - automatically disabling web search" >&2
            WEB_SEARCH_ENABLED=false
            return 1
        fi
    fi
    return 0
}

# Generate search term using AI
generate_search_term() {
    local prompt_text="$1"
    local model="$2"
    
    echo "🤖 Generating search term..." >&2
    echo "DEBUG: OS_NAME='$OS_NAME', OS_VERSION='$OS_VERSION', PACKAGE_MANAGER='$PACKAGE_MANAGER'" >&2
    
    # Create a search prompt with actual values substituted completely
    local search_prompt="Based on this user request: '$prompt_text'
Generate a detailed search query (5-12 words) for finding Linux terminal commands and solutions.

USER'S SYSTEM: $OS_NAME version $OS_VERSION (Package Manager: $PACKAGE_MANAGER)

CRITICAL REQUIREMENTS:
- For software installation: MUST include the EXACT OS name '$OS_NAME'
- Be VERY specific about the Linux distribution name
- Include the actual OS name, not just version numbers
- Do NOT use generic terms like 'fedora linux' when the OS name is '$OS_NAME'

EXAMPLES for this specific system ($OS_NAME):
- User: 'install firefox' → 'how to install firefox on $OS_NAME $OS_VERSION'
- User: 'install minecraft' → 'how to install minecraft on $OS_NAME'
- User: 'install docker' → 'how to install docker on $OS_NAME linux'
- User: 'install steam' → 'how to install steam on $OS_NAME'

REMEMBER: Always include '$OS_NAME' in the search query for software installation!

Respond with ONLY the search query using the actual OS name '$OS_NAME', no explanations."

    local search_term=""
    if [[ "$model" == "DeepSeek AI" || "$model" == "DeepSeek Reasoner" ]]; then
        # DeepSeek API call for search term
        local deepseek_model_name="$DEEPSEEK_MODEL"
        [[ "$model" == "DeepSeek Reasoner" ]] && deepseek_model_name="$DEEPSEEK_REASONER_MODEL"
        
        local payload
        payload=$(jq -n \
            --arg model "$deepseek_model_name" \
            --arg prompt "$search_prompt" \
            '{
                model: $model,
                messages: [
                    {role: "user", content: $prompt}
                ],
                temperature: 0.1,
                max_tokens: 100
            }')
        local response=$(curl -s -X POST "$DEEPSEEK_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
            -d "$payload")
        search_term=$(echo "$response" | jq -r '.choices[0].message.content' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    elif [[ "$model" == "Reason AI" ]]; then
        # Reason AI API call for search term
        local payload
        payload=$(jq -n \
            --arg model "$REASON_MODEL" \
            --arg prompt "$search_prompt" \
            '{
                model: $model,
                messages: [
                    {role: "user", content: $prompt}
                ],
                temperature: 0.1,
                max_tokens: 60
            }')
        local response=$(curl -s -X POST "$REASON_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $REASON_API_KEY" \
            -d "$payload")
        search_term=$(echo "$response" | jq -r '.choices[0].message.content' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Enhanced cleaning for Reason AI - remove thinking content more aggressively
        search_term=$(echo "$search_term" | sed '/think/,$d' | tail -n 1)
        echo "DEBUG - Reason AI search term after cleaning: '$search_term'" >&2
        
        # If we still have thinking content or the result is just "think", try alternative extraction
        if [[ "$search_term" == "think" || "$search_term" =~ think ]]; then
            echo "DEBUG - Detected 'think' content, attempting alternative extraction" >&2
            # Try to find lines that look like search queries
            search_term=$(echo "$response" | jq -r '.choices[0].message.content' | grep -E "how to|install.*on.*Bazzite|Bazzite.*install" | head -1)
            if [[ -z "$search_term" ]]; then
                # Last resort: look for the last meaningful line that's not thinking content
                search_term=$(echo "$response" | jq -r '.choices[0].message.content' | grep -v "think\|Let me\|Looking at\|The user" | grep -E "[a-zA-Z]+" | tail -1)
            fi
            echo "DEBUG - Alternative extraction result: '$search_term'" >&2
        fi
    else
        # Ollama API call for search term
        local payload
        payload=$(jq -n \
            --arg model "$model" \
            --arg prompt "$search_prompt" \
            '{
                model: $model,
                messages: [
                    {role: "user", content: $prompt}
                ],
                stream: false,
                options: {temperature: 0.1}
            }')
        local response=$(curl -s -X POST "${BASE_URL}/api/chat" \
            -H "Content-Type: application/json" \
            -d "$payload")
        search_term=$(echo "$response" | jq -r '.message.content' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
    
    # Clean and validate search term - enhanced for Reason AI
    # Remove any remaining thinking content that might have been missed
    search_term=$(echo "$search_term" | sed 's/think.*//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Extract only the last line if multiple lines (for Reason AI responses)
    search_term=$(echo "$search_term" | tail -n 1)
    # Clean special characters but preserve spaces and common punctuation
    search_term=$(echo "$search_term" | sed 's/[^a-zA-Z0-9 _-]//g' | tr -s ' ')
    
    # Enhanced fallback with explicit OS name handling
    if [[ -z "$search_term" || ${#search_term} -lt 3 ]]; then
        echo "⚠ AI search term generation failed, using explicit OS name fallback" >&2
        if [[ "$prompt_text" =~ install.*(firefox|chrome|steam|minecraft|discord|spotify|vlc|gimp|blender|vscode|code|atom|sublime) ]]; then
            local app_name=$(echo "$prompt_text" | grep -oE "(firefox|chrome|steam|minecraft|discord|spotify|vlc|gimp|blender|vscode|code|atom|sublime)" | head -1)
            # Always include the actual OS name
            search_term="how to install $app_name on $OS_NAME $OS_VERSION"
        elif [[ "$prompt_text" =~ install.* ]]; then
            search_term="how to install software on $OS_NAME $OS_VERSION"
        elif [[ "$prompt_text" =~ (service|driver|mount|package|systemd|firewall|network|audio|video|wifi|bluetooth) ]]; then
            search_term="$prompt_text $OS_NAME $OS_VERSION terminal"
        else
            search_term="$prompt_text $OS_NAME terminal command"
        fi
    else
        # Post-process the AI-generated search term to ensure it uses the correct OS name
        # Replace common generic terms with the actual OS name
        search_term=$(echo "$search_term" | sed "s/fedora linux/$OS_NAME/g")
        search_term=$(echo "$search_term" | sed "s/fedora/$OS_NAME/g")
        search_term=$(echo "$search_term" | sed "s/ubuntu/$OS_NAME/g")
        search_term=$(echo "$search_term" | sed "s/debian/$OS_NAME/g")
        search_term=$(echo "$search_term" | sed "s/arch linux/$OS_NAME/g")
        
        # Verify the search term includes the OS name, if not add it
        if [[ "$search_term" =~ install ]] && [[ ! "$search_term" =~ $OS_NAME ]]; then
            search_term=$(echo "$search_term" | sed "s/install \([a-zA-Z0-9]*\)/install \1 on $OS_NAME/")
        fi
        echo "✓ Generated search term: $search_term" >&2
    fi
    
    echo "$search_term"
}

# Ask AI with robust parsing and web search integration
ask_ai() {
    local prompt_text="$1"
    local model="$2"
    local raw_response_file=$(mktemp)
    local search_context=""
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
    
    # Check internet and update web search status before proceeding
    check_and_update_web_search
    
    # Perform web search if enabled
    if [[ "$WEB_SEARCH_ENABLED" == true ]]; then
        echo "🔍 AI will generate search term for your request..." >&2
        
        # Generate AI-powered search query
        local search_query=$(generate_search_term "$prompt_text" "$model")
        
        # Perform the search with AI-generated query
        local search_results=$(perform_web_search "$search_query")
        
        if [[ -n "$search_results" ]]; then
            search_context="=== Web Search Results for: $search_query ===\n$search_results\n\n"
            echo "✓ Web search completed - found relevant information" >&2
            
            # Show colored search results to user
            echo -e "\033[1;36m📋 Search results for '$search_query':\033[0m" >&2
            echo "$search_results" | while IFS= read -r line; do
                if [[ "$line" =~ ^[0-9]+\. ]]; then
                    # Title lines - bright yellow
                    echo -e "\033[1;33m$line\033[0m" >&2
                elif [[ "$line" =~ ^https?:// ]]; then
                    # URL lines - bright blue
                    echo -e "\033[1;34m$line\033[0m" >&2
                elif [[ -n "$line" ]]; then
                    # Description lines - light gray
                    echo -e "\033[0;37m$line\033[0m" >&2
                else
                    echo "$line" >&2
                fi
            done
            echo -e "\033[1;36m################\033[0m" >&2
        else
            echo "⚠ Web search completed but no results found for: $search_query" >&2
        fi
    else
        echo "ℹ️ Using AI knowledge for $OS_NAME commands (web search disabled)" >&2
    fi
    
    add_history "user" "$prompt_text"
    local history_messages=$(load_safe_history)
    
    # Enhanced system message focused on OS-specific knowledge
    local system_message="You are a Linux terminal expert. Respond with ONE valid bash command between triple backticks.
STRICT RULES:
1. Command must work on $OS_NAME (version $OS_VERSION) which uses $PACKAGE_MANAGER package manager
2. Use only installed core utilities
3. Put command in \`\`\`bash block
4. ALWAYS use the correct package manager for this system:
   - For $OS_NAME: Use $PACKAGE_MANAGER (NOT apt, NOT dnf, NOT pacman unless it's the correct one)
   - Use -y with apt, dnf, yum
   - Use --noconfirm with pacman
   - Use --force or -f when overwriting files
   - Use yes | command or echo 'y' | command for other prompts
5. NEVER suggest commands that will wait for user input
6. Validate syntax before responding
7. Consider the specific OS ($OS_NAME) and its package manager ($PACKAGE_MANAGER)
8. Use your knowledge of $OS_NAME best practices and current command syntax
9. CRITICAL: If this is Fedora/RedHat family, use 'dnf' not 'apt'
10. CRITICAL: If this is Ubuntu/Debian family, use 'apt' not 'dnf'
11. CRITICAL: If this is Arch family, use 'pacman' not 'apt' or 'dnf'
12. CRITICAL: If this is fedora silverblue/bazzite/aurora/bluefin , use 'rpm-ostree/flatpak' not 'apt' or 'dnf'
13. Never use sudo when installing a flatpak package,
14. never forget to use -y/--noconfirm when installing packages
15. For flatpak packages, use 'flatpak install --user' but on atomic desktops use like bazzite 'flatpak install --system' dont forget the -y at the end
16. You dont always need to use flatpak on atomic desktops, you can use rpm-ostree to install packages"
    
    # Add web search context if available
    if [[ -n "$search_context" ]]; then
        system_message+="\n\n🔍 WEB SEARCH CONTEXT:\n$search_context\nIMPORTANT: Use the above search results along with your knowledge to provide the most accurate command for $OS_NAME $OS_VERSION."
    fi
    
    [[ "$model" == "DeepSeek AI" ]] && system_message+="\nDEEPSEEK FORMAT NOTE: Respond with command in \`\`\`bash blocks"
    [[ "$model" == "DeepSeek Reasoner" ]] && system_message+="\nDEEPSEEK REASONER FORMAT NOTE: Respond with command in \`\`\`bash blocks"
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
    if [[ "$model" == "DeepSeek AI" || "$model" == "DeepSeek Reasoner" ]]; then
        local response_content=$(jq -r '.choices[0].message.content' "$raw_response_file")
    elif [[ "$model" == "Reason AI" ]]; then
        local response_content=$(jq -r '.choices[0].message.content' "$raw_response_file")
        # Special handling for Reason AI - remove thinking content more aggressively
        response_content=$(echo "$response_content" | sed '/think/,$d')
        # If that removed everything, try a different approach
        if [[ -z "$response_content" || "$response_content" =~ ^[[:space:]]*$ ]]; then
            response_content=$(jq -r '.choices[0].message.content' "$raw_response_file" | grep -v "think" | tail -n 5)
        fi
    else
        local response_content=$(jq -r '.message.content' "$raw_response_file")
    fi
    
    # Pre-clean response content to handle escape sequences and thinking tags
    response_content=$(echo "$response_content" | sed 's/\\n/ /g' | sed 's/\\r/ /g' | sed 's/\\t/ /g')
    # Remove thinking tags that cause markup parsing errors
    response_content=$(echo "$response_content" | sed 's/<think>.*<\/think>//g' | sed 's/<think>.*//g')
    
    ai_cmd=$(extract_command "$response_content")
    
    # Validation
    if [[ -z "$ai_cmd" || "$ai_cmd" =~ ^[[:space:]]*$ ]]; then
        echo "ERROR: Command extraction failed! Raw response appears valid but couldn't extract command." >&2
        
        # Clean response content for display (escape HTML characters properly)
        local display_content=$(echo "$response_content" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        
        zenity --question \
            --title="Command Extraction Failed" \
            --text="The AI provided a response, but command extraction failed.\n\nRaw response:\n<tt>$display_content</tt>\n\nWould you like to use this response anyway?" \
            --ok-label="Use Anyway" --cancel-label="Retry" \
            --extra-button="Quit" \
            --width=600
        
        local extraction_result=$?
        case $extraction_result in
            0)  # Use Anyway
                # Use the raw response directly, removing any remaining markup
                ai_cmd=$(echo "$response_content" | tr -d '`' | sed 's/<[^>]*>//g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                echo "DEBUG - Using cleaned raw response: '$ai_cmd'" >&2
                ;;
            1)  # Retry
                add_history "user" "Command extraction failed: $raw"
                return 1
                ;;
            5)  # Quit - return to main prompt
                echo "User chose to quit from command extraction dialog" >&2
                add_history "user" "Command extraction failed - user returned to main prompt"
                return 2  # Special return code to indicate quit
                ;;
            *)  # Any other code (window closed, etc.)
                add_history "user" "Command extraction failed: $raw"
                return 1
                ;;
        esac
    fi
    
    # Clean the command without removing angle brackets for placeholders
    ai_cmd=$(echo "$ai_cmd" | \
        sed -E 's/(^[[:space:]]*[\x60`]?|[\x60`]?[[:space:]]*$)//g' | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')
    
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
        local ai_result=$?
        
        # Handle different return codes from ask_ai
        case $ai_result in
            0)  # Success - continue with command execution
                ;;
            1)  # Retry - continue the loop
                continue
                ;;
            2)  # User quit from command extraction - return to main prompt
                echo "User quit from command extraction - returning to main prompt" >&2
                return 1
                ;;
            *)  # Any other error - continue the loop
                continue
                ;;
        esac
        
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
                    1)  # Cancel/Close button (X button or Escape)
                        echo "User cancelled command failed dialog - returning to main prompt" >&2
                        return 1
                        ;;
                    5)  # Quit button (extra-button 1)
                        echo "QUIT detected in error dialog - returning to main prompt" >&2
                        return 1
                        ;;
                    6)  # New Prompt button (extra-button 2)
                        echo "New Prompt requested - returning to main prompt" >&2
                        return 1
                        ;;
                    255) # Window closed
                        echo "Dialog window closed - returning to main prompt" >&2
                        return 1
                        ;;
                    *)  # Any other unknown code
                        echo "Unknown dialog return code: $exit_code, treating as cancel" >&2
                        return 1
                        ;;
                esac
                ;;
        esac
    done
    
    # If we reached here via the break statement, we need to return to main prompt
    echo "Returning to main prompt after quit" >&2
    return 1
}

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
    # Check internet connection and update web search status
    check_and_update_web_search
    
    # Enhanced title to show web search status more prominently
    title_text="AI Assistant (${SELECTED_MODEL})"
    if [[ "$WEB_SEARCH_ENABLED" == true ]]; then
        title_text+=" - 🔍 Web Search: ON"
    else
        if check_internet; then
            title_text+=" - 🔍 Web Search: OFF"
        else
            title_text+=" - ⚠ Web Search: OFF (No Internet)"
        fi
    fi
    
    user_input=$(zenity --entry \
        --title="$title_text" \
        --text="Enter task description:\n\nSpecial commands:\n• 'switch model' - Change AI model\n• 'clear history' - Clear chat history\n• 'toggle web search' - Enable/disable web search" \
        --width=600 --height=200)
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
        "toggle web search")
            if [[ "$WEB_SEARCH_ENABLED" == true ]]; then
                WEB_SEARCH_ENABLED=false
                zenity --info --text="🔍 Web search DISABLED\nThe AI will work without internet search." --width=400
            else
                if check_internet; then
                    WEB_SEARCH_ENABLED=true
                    zenity --info --text="🔍 Web search ENABLED\nThe AI will search DuckDuckGo for relevant information." --width=400
                else
                    zenity --warning --text="⚠ Cannot enable web search\nNo internet connection detected.\n\nPlease check your connection and try again." --width=400
                fi
            fi
            continue
            ;;
        *)
            run_until_success "$user_input" "$SELECTED_MODEL"
            ;;
    esac
done

cleanup_and_exit 0

#!/bin/bash
# Source: https://github.com/daniel3303/ClaudeCodeStatusLine
# Single line: Model | tokens | %used | %remain | think | 5h bar @reset | 7d bar @reset | extra

set -f  # disable globbing
VERSION="1.4.4"

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
purple='\033[38;2;167;139;250m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {v=sprintf(\"%.1f\",$num/1000000)+0; if(v==int(v)) printf \"%dm\",v; else printf \"%.1fm\",v}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Format number with commas (e.g., 134,938)
format_commas() {
    printf "%'d" "$1"
}

# Return color escape based on usage percentage
# Usage: usage_color <pct>
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# Return color escape for the context-window fill percentage. Deliberately tighter than
# usage_color: a filling context window degrades attention long before it is actually full.
# Usage: context_color <pct>
context_color() {
    local pct=$1
    if [ "$pct" -gt 50 ]; then echo "$red"
    elif [ "$pct" -gt 30 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# Resolve config directory: CLAUDE_CONFIG_DIR (set by alias) or default ~/.claude
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Return 0 (true) if $1 > $2 using semantic versioning
version_gt() {
    local a="${1#v}" b="${2#v}"
    local IFS='.'
    read -r a1 a2 a3 <<< "$a"
    read -r b1 b2 b3 <<< "$b"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -lt "$b1" ] 2>/dev/null && return 1
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -lt "$b2" ] 2>/dev/null && return 1
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    return 1
}
# ===== Extract data from JSON =====
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
model_name=$(echo "$model_name" | sed 's/ *(\([0-9.]*[kKmM]*\) context)/ \1/')  # "(1M context)" → "1M"

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Token usage
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi
pct_remain=$(( 100 - pct_used ))

used_comma=$(format_commas $current)
remain_comma=$(format_commas $(( size - current )))

settings_path="$claude_config_dir/settings.json"
effort_level=""
stdin_effort=$(echo "$input" | jq -r '.effort.level // empty' 2>/dev/null)
if [ -n "$stdin_effort" ]; then
    effort_level="$stdin_effort"
elif [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$settings_path" ]; then
    effort_val=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    [ -n "$effort_val" ] && effort_level="$effort_val"
fi
[ -z "$effort_level" ] && effort_level="medium"

# ===== Claude CLI version (cached, 1h TTL) =====
cli_version_cache="/tmp/claude/statusline-cli-version"
cli_version=""
cli_version_max_age=3600

if [ -f "$cli_version_cache" ]; then
    cv_mtime=$(stat -c %Y "$cli_version_cache" 2>/dev/null || stat -f %m "$cli_version_cache" 2>/dev/null)
    cv_now=$(date +%s)
    cv_age=$(( cv_now - cv_mtime ))
    if [ "$cv_age" -lt "$cli_version_max_age" ]; then
        cli_version=$(cat "$cli_version_cache" 2>/dev/null)
    fi
fi

if [ -z "$cli_version" ]; then
    cli_version=$(claude --version 2>/dev/null | awk '{print $1}')
    if [ -n "$cli_version" ]; then
        mkdir -p /tmp/claude 2>/dev/null
        echo "$cli_version" > "$cli_version_cache"
    fi
fi

# ===== Build per-segment output (assembled in custom order at the end) =====
seg_model="${blue}${model_name}${reset}"

# Tokens
pct_used_color=$(context_color "$pct_used")
seg_tokens="${orange}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${pct_used_color}${pct_used}%${reset}${dim})${reset}"

# Effort (level only, no "effort:" prefix)
case "$effort_level" in
    low)    seg_effort="${dim}${effort_level}${reset}" ;;
    medium) seg_effort="${orange}med${reset}" ;;
    high)   seg_effort="${green}${effort_level}${reset}" ;;
    xhigh)  seg_effort="${purple}${effort_level}${reset}" ;;
    max)    seg_effort="${red}${effort_level}${reset}" ;;
    *)      seg_effort="${green}${effort_level}${reset}" ;;
esac

# Git branch only (no directory name)
cwd=$(echo "$input" | jq -r '.cwd // empty')
seg_branch=""
if [ -n "$cwd" ]; then
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$git_branch" ]; then
        seg_branch="${green}${git_branch}${reset}"
        git_stat=$(git -C "${cwd}" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        [ -n "$git_stat" ] && seg_branch+=" ${dim}(${reset}${green}${git_stat%% *}${reset} ${red}${git_stat##* }${reset}${dim})${reset}"
    fi
fi

# ===== Cross-platform OAuth token resolution (from statusline.sh) =====
# Tries credential sources in order: env var → macOS Keychain → Linux creds file → GNOME Keyring
get_oauth_token() {
    local token=""

    # 1. Explicit env var override
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    # 2. macOS Keychain (Claude Code appends a SHA256 hash of CLAUDE_CONFIG_DIR to the service name)
    if command -v security >/dev/null 2>&1; then
        local keychain_svc="Claude Code-credentials"
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            local dir_hash
            dir_hash=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
            keychain_svc="Claude Code-credentials-${dir_hash}"
        fi
        local blob
        blob=$(security find-generic-password -s "$keychain_svc" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    # 3. Linux credentials file
    local creds_file="${claude_config_dir}/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    # 4. GNOME Keyring via secret-tool
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# ===== LINE 2 & 3: Usage limits with progress bars =====
# First, try to use rate_limits data provided directly by Claude Code in the JSON input.
# This is the most reliable source — no OAuth token or API call required.
builtin_five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
builtin_five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
builtin_seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
builtin_seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

use_builtin=false
if [ -n "$builtin_five_hour_pct" ] || [ -n "$builtin_seven_day_pct" ]; then
    use_builtin=true
fi

# Cache setup — shared across all Claude Code instances to avoid rate limits
claude_config_dir_hash=$(echo -n "$claude_config_dir" | shasum -a 256 2>/dev/null || echo -n "$claude_config_dir" | sha256sum 2>/dev/null)
claude_config_dir_hash=$(echo "$claude_config_dir_hash" | cut -c1-8)
cache_file="/tmp/claude/statusline-usage-cache-${claude_config_dir_hash}.json"
cache_max_age=60  # seconds between API calls
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""

# Always load cache — used as primary source for API path, and as fallback when builtin reports zero
if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt "$cache_max_age" ]; then
        needs_refresh=false
    fi
    usage_data=$(cat "$cache_file" 2>/dev/null)
fi

# When builtin values are all zero AND reset timestamps are missing, it likely indicates
# an API failure on Claude's side — fall through to cached data instead of displaying
# misleading 0%. Genuine zero responses (after a billing reset) still include valid
# resets_at timestamps, so we trust those.
effective_builtin=false
if $use_builtin; then
    # Trust builtin if any percentage is non-zero
    if { [ -n "$builtin_five_hour_pct" ] && [ "$(printf '%.0f' "$builtin_five_hour_pct" 2>/dev/null)" != "0" ]; } || \
       { [ -n "$builtin_seven_day_pct" ] && [ "$(printf '%.0f' "$builtin_seven_day_pct" 2>/dev/null)" != "0" ]; }; then
        effective_builtin=true
    fi
    # Also trust if reset timestamps are present — genuine zero responses include valid reset times
    if ! $effective_builtin; then
        if { [ -n "$builtin_five_hour_reset" ] && [ "$builtin_five_hour_reset" != "null" ] && [ "$builtin_five_hour_reset" != "0" ]; } || \
           { [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ] && [ "$builtin_seven_day_reset" != "0" ]; }; then
            effective_builtin=true
        fi
    fi
fi

# Refresh API cache when stale — runs regardless of builtin rate_limits because
# extra_usage is only exposed through the OAuth usage endpoint (not stdin JSON).
# Throttled to cache_max_age and stampede-locked via touch for shared panes.
if $needs_refresh; then
    touch "$cache_file"  # stampede lock: prevent parallel panes from fetching simultaneously
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 10 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        # Only cache valid usage responses (not error/rate-limit JSON)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
        fi
    fi
    # Remove the stampede sentinel if the fetch failed to produce valid JSON —
    # otherwise an empty cache file would suppress retries for a full cache_max_age window.
    [ -f "$cache_file" ] && [ ! -s "$cache_file" ] && rm -f "$cache_file"
fi

# Cross-platform ISO to epoch conversion
# Converts ISO 8601 timestamp (e.g. "2025-06-15T12:30:00Z" or "2025-06-15T12:30:00.123+00:00") to epoch seconds.
# Properly handles UTC timestamps and converts to local time.
iso_to_epoch() {
    local iso_str="$1"

    # Try GNU date first (Linux) — handles ISO 8601 format automatically
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    # BSD date (macOS) - handle various ISO 8601 formats
    local stripped="${iso_str%%.*}"          # Remove fractional seconds (.123456)
    stripped="${stripped%%Z}"                 # Remove trailing Z
    stripped="${stripped%%+*}"               # Remove timezone offset (+00:00)
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"  # Remove negative timezone offset

    # Check if timestamp is UTC (has Z or +00:00 or -00:00)
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        # For UTC timestamps, parse with timezone set to UTC
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# Format ISO reset time to compact local time
# Usage: format_reset_time <iso_string> <style: time|datetime|date>
format_reset_time() {
    local iso_str="$1"
    local style="$2"
    { [ -z "$iso_str" ] || [ "$iso_str" = "null" ]; } && return

    # Parse ISO datetime and convert to local time (cross-platform)
    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    # Format based on style
    # Try GNU date first (Linux), then BSD date (macOS)
    # Previous implementation piped BSD date through sed/tr, which always returned
    # exit code 0 from the last pipe stage, preventing the GNU date fallback from
    # ever executing on Linux.
    local formatted=""
    case "$style" in
        time)
            formatted=$(date -d "@$epoch" +"%H:%M" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            ;;
        datetime)
            formatted=$(date -d "@$epoch" +"%a %b %-d, %H:%M" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%a %b %-d, %H:%M" 2>/dev/null)
            ;;
        *)
            formatted=$(date -d "@$epoch" +"%b %-d" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    [ -n "$formatted" ] && echo "$formatted"
}

# Seconds remaining until a future epoch timestamp (floored at 0). Empty if invalid.
seconds_until() {
    local target="$1"
    { [ -z "$target" ] || [ "$target" = "null" ] || [ "$target" = "0" ]; } && return
    local now diff
    now=$(date +%s)
    diff=$(( target - now ))
    [ "$diff" -lt 0 ] && diff=0
    echo "$diff"
}

# Compact duration from a second count. Renders the two most significant units,
# dropping a trailing zero unit: "1d22h", "2d", "3h5m", "4h", "30m", "0m".
# Minutes are rounded up so a window with time left never reads as the next unit down.
format_duration() {
    local secs="$1"
    [ -z "$secs" ] && return
    local total_mins days hours mins
    total_mins=$(( (secs + 59) / 60 ))
    days=$(( total_mins / 1440 ))
    hours=$(( (total_mins % 1440) / 60 ))
    mins=$(( total_mins % 60 ))
    if [ "$days" -gt 0 ]; then
        if [ "$hours" -gt 0 ]; then echo "${days}d${hours}h"; else echo "${days}d"; fi
    elif [ "$hours" -gt 0 ]; then
        if [ "$mins" -gt 0 ]; then echo "${hours}h${mins}m"; else echo "${hours}h"; fi
    else
        echo "${mins}m"
    fi
}

sep=" ${dim}|${reset} "
# Separates a rate-limit percentage from its reset countdown: "42% · 30m"
dot=" ${dim}·${reset} "

# Rate-limit window lengths, needed to judge usage against how far the window has run.
five_hour_window_secs=18000    # 5 hours
seven_day_window_secs=604800   # 7 days

# Color a reset countdown by burn rate: extrapolate current usage to the end of the window.
# Spending the window's tokens evenly lands on 100%; under 80% of that pace is green,
# 80-120% is yellow, over 120% is red. Halfway through a window that works out to exactly
# under 40% used green, 40-60% yellow, over 60% red — and because the comparison is
# proportional rather than a fixed offset, it stays meaningful at both ends of the window.
# Compared as cross-multiplied integers (used/100 vs 0.8-1.2 x elapsed/window) so the
# verdict loses nothing to rounding.
# Usage: pace_color <seconds_left> <window_seconds> <used_pct>
pace_color() {
    local secs_left="$1" window="$2" used="$3"
    if [ -z "$secs_left" ] || [ -z "$used" ] || [ -z "$window" ] || [ "$window" -le 0 ]; then
        echo "$dim"
        return
    fi
    local elapsed=$(( window - secs_left ))
    # Nothing elapsed yet (or the window is longer than we assume): no pace to judge.
    if [ "$elapsed" -le 0 ]; then
        echo "$green"
        return
    fi
    if [ $(( used * window )) -lt $(( 80 * elapsed )) ]; then
        echo "$green"
    elif [ $(( used * window )) -gt $(( 120 * elapsed )) ]; then
        echo "$red"
    else
        echo "$yellow"
    fi
}

# Render extra_usage segment from API usage data (not available via stdin rate_limits).
# Appends to the global $out. No-op when data is missing or is_enabled is false.
render_extra_usage() {
    local data="$1"
    [ -z "$data" ] && return
    local enabled
    enabled=$(echo "$data" | jq -r '.extra_usage.is_enabled // false' 2>/dev/null)
    [ "$enabled" != "true" ] && return

    local pct used limit
    pct=$(echo "$data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
    used=$(echo "$data" | jq -r '.extra_usage.used_credits // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
    limit=$(echo "$data" | jq -r '.extra_usage.monthly_limit // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')

    if [ -n "$used" ] && [ -n "$limit" ] && [[ "$used" != *'$'* ]] && [[ "$limit" != *'$'* ]]; then
        local color
        color=$(usage_color "$pct")
        seg_extra="${white}extra${reset} ${color}\$${used}/\$${limit}${reset}"
    else
        seg_extra="${white}extra${reset} ${green}enabled${reset}"
    fi
}

if $effective_builtin; then
    # ---- Use rate_limits data provided directly by Claude Code in JSON input ----
    # resets_at values are Unix epoch integers in this source
    if [ -n "$builtin_five_hour_pct" ]; then
        five_hour_pct=$(printf "%.0f" "$builtin_five_hour_pct")
        five_hour_color=$(usage_color "$five_hour_pct")
        seg_5h="${five_hour_color}${five_hour_pct}%${reset}"
        fh_secs=$(seconds_until "$builtin_five_hour_reset")
        if [ -n "$fh_secs" ]; then
            fh_pace=$(pace_color "$fh_secs" "$five_hour_window_secs" "$five_hour_pct")
            seg_5h+="${dot}${fh_pace}$(format_duration "$fh_secs")${reset}"
        fi
    fi

    if [ -n "$builtin_seven_day_pct" ]; then
        seven_day_pct=$(printf "%.0f" "$builtin_seven_day_pct")
        seven_day_color=$(usage_color "$seven_day_pct")
        seg_7d="${seven_day_color}${seven_day_pct}%${reset}"
        sd_secs=$(seconds_until "$builtin_seven_day_reset")
        if [ -n "$sd_secs" ]; then
            sd_pace=$(pace_color "$sd_secs" "$seven_day_window_secs" "$seven_day_pct")
            seg_7d+="${dot}${sd_pace}$(format_duration "$sd_secs")${reset}"
        fi
    fi

    # Render extra_usage from API cache (stdin rate_limits doesn't expose it)
    render_extra_usage "$usage_data"

    # Cache builtin values so they're available as fallback when API is unavailable.
    # Convert epoch resets_at to ISO 8601 for compatibility with the API-format cache parser.
    # Preserve extra_usage from prior API response so we don't clobber it.
    _fh_reset_json="null"
    if [ -n "$builtin_five_hour_reset" ] && [ "$builtin_five_hour_reset" != "null" ] && [ "$builtin_five_hour_reset" != "0" ]; then
        _fh_iso=$(date -u -r "$builtin_five_hour_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                  date -u -d "@$builtin_five_hour_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
        [ -n "$_fh_iso" ] && _fh_reset_json="\"$_fh_iso\""
    fi
    _sd_reset_json="null"
    if [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ] && [ "$builtin_seven_day_reset" != "0" ]; then
        _sd_iso=$(date -u -r "$builtin_seven_day_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                  date -u -d "@$builtin_seven_day_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
        [ -n "$_sd_iso" ] && _sd_reset_json="\"$_sd_iso\""
    fi
    _extra_json=$(echo "$usage_data" | jq -c '.extra_usage // null' 2>/dev/null)
    [ -z "$_extra_json" ] && _extra_json="null"
    printf '{"five_hour":{"utilization":%s,"resets_at":%s},"seven_day":{"utilization":%s,"resets_at":%s},"extra_usage":%s}' \
        "${builtin_five_hour_pct:-0}" "$_fh_reset_json" \
        "${builtin_seven_day_pct:-0}" "$_sd_reset_json" \
        "$_extra_json" > "$cache_file" 2>/dev/null
elif [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
    # ---- Fall back: API-fetched usage data ----
    # ---- 5-hour (current) ----
    five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    five_hour_color=$(usage_color "$five_hour_pct")
    seg_5h="${five_hour_color}${five_hour_pct}%${reset}"
    fh_secs=$(seconds_until "$(iso_to_epoch "$five_hour_reset_iso")")
    if [ -n "$fh_secs" ]; then
        fh_pace=$(pace_color "$fh_secs" "$five_hour_window_secs" "$five_hour_pct")
        seg_5h+="${dot}${fh_pace}$(format_duration "$fh_secs")${reset}"
    fi

    # ---- 7-day (weekly) ----
    seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    seven_day_color=$(usage_color "$seven_day_pct")
    seg_7d="${seven_day_color}${seven_day_pct}%${reset}"
    sd_secs=$(seconds_until "$(iso_to_epoch "$seven_day_reset_iso")")
    if [ -n "$sd_secs" ]; then
        sd_pace=$(pace_color "$sd_secs" "$seven_day_window_secs" "$seven_day_pct")
        seg_7d+="${dot}${sd_pace}$(format_duration "$sd_secs")${reset}"
    fi

    render_extra_usage "$usage_data"
else
    # No valid usage data — show placeholders
    seg_5h="${dim}-${reset}"
    seg_7d="${dim}-${reset}"
fi

# ===== Update check (cached, 24h TTL) =====
# Set STATUSLINE_CHECK_UPDATES=false to disable the update check (no network calls).
update_line=""
if [ "${STATUSLINE_CHECK_UPDATES:-true}" != "false" ]; then
    version_cache_file="/tmp/claude/statusline-version-cache.json"
    version_cache_max_age=86400  # 24 hours

    version_needs_refresh=true
    version_data=""

    if [ -f "$version_cache_file" ]; then
        vc_mtime=$(stat -c %Y "$version_cache_file" 2>/dev/null || stat -f %m "$version_cache_file" 2>/dev/null)
        vc_now=$(date +%s)
        vc_age=$(( vc_now - vc_mtime ))
        if [ "$vc_age" -lt "$version_cache_max_age" ]; then
            version_needs_refresh=false
        fi
        version_data=$(cat "$version_cache_file" 2>/dev/null)
    fi

    if $version_needs_refresh; then
        touch "$version_cache_file" 2>/dev/null
        vc_response=$(curl -s --max-time 5 \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/daniel3303/ClaudeCodeStatusLine/releases/latest" 2>/dev/null)
        if [ -n "$vc_response" ] && echo "$vc_response" | jq -e '.tag_name' >/dev/null 2>&1; then
            version_data="$vc_response"
            echo "$vc_response" > "$version_cache_file"
        elif [ ! -s "$version_cache_file" ]; then
            rm -f "$version_cache_file" 2>/dev/null
        fi
    fi

    if [ -n "$version_data" ]; then
        latest_tag=$(echo "$version_data" | jq -r '.tag_name // empty')
        if [ -n "$latest_tag" ] && version_gt "$latest_tag" "$VERSION"; then
            update_line="\n${dim}Update available: ${latest_tag} → Tell Claude: \"Find my installed status bar and update it\"${reset}"
        fi
    fi
fi

# CLI version segment
if [ -n "$cli_version" ]; then
    seg_version="${orange}v${cli_version}${reset}"
fi

# ===== Assemble in custom order: model | tokens | effort | 5h | 7d | extra | branch | version =====
out=""
for s in "$seg_model" "$seg_tokens" "$seg_effort" "$seg_5h" "$seg_7d" "$seg_extra" "$seg_branch" "$seg_version"; do
    [ -z "$s" ] && continue
    if [ -z "$out" ]; then
        out="$s"
    else
        out+="${sep}${s}"
    fi
done

# Output
printf "%b" "$out$update_line"

exit 0

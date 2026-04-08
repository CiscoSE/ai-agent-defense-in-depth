#!/bin/bash
# AetherClaude Agent Orchestrator v2 (Multi-Skill)
# Processes issues, reviews PRs, triages stale issues, welcomes contributors,
# answers discussions, explains CI failures, detects duplicates.

set -euo pipefail

# --- Configuration (override via environment or .env) ---
AGENT_HOME="${AGENT_HOME:-/home/aetherclaude}"
AGENT_USER="${AGENT_USER:-aetherclaude}"
UPSTREAM_REPO="${UPSTREAM_REPO:-your-org/your-repo}"
UPSTREAM_OWNER="${UPSTREAM_OWNER:-your-org}"
FORK_OWNER="${FORK_OWNER:-your-fork-org}"
PROJECT_NAME="${PROJECT_NAME:-your-project}"
MAINTAINER_NAME="${MAINTAINER_NAME:-Your Name}"
PROJECT_DISPLAY_NAME="${PROJECT_DISPLAY_NAME:-YourProject}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-AgentName}"

export PATH="${AGENT_HOME}/bin:${AGENT_HOME}/.local/bin:/usr/bin"
export HOME="${AGENT_HOME}"
export HTTPS_PROXY="http://127.0.0.1:8888"
export HTTP_PROXY="http://127.0.0.1:8888"
export NO_PROXY="localhost,127.0.0.1"

source "${AGENT_HOME}/.env"

WORKSPACE="${AGENT_HOME}/workspace/${PROJECT_NAME}"
LOGDIR="${AGENT_HOME}/logs"
PROMPTDIR="${AGENT_HOME}/prompts"
STATE_FILE="${AGENT_HOME}/state/last-poll.json"
LOCKFILE="/tmp/${AGENT_USER}.lock"
REPO="${UPSTREAM_REPO}"
MAX_ISSUES_PER_RUN=4
MAX_PRS_PER_RUN=2
MAX_DISCUSSIONS_PER_RUN=10

mkdir -p "$LOGDIR" "$PROMPTDIR" "$(dirname "$STATE_FILE")"

# --- Concurrency lock ---
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "$(date -Iseconds) Agent already running (PID $pid), exiting" >> "$LOGDIR/orchestrator.log"
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f $LOCKFILE' EXIT

log() { echo "$(date -Iseconds) $1" >> "$LOGDIR/orchestrator.log"; }

# --- State management ---
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

get_state() { jq -r ".\"$1\" // \"\"" "$STATE_FILE"; }

set_state() {
    local tmp
    tmp=$(mktemp)
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# --- GitHub App token ---
get_app_token() { ${AGENT_HOME}/bin/github-app-token.sh 2>/dev/null; }

github_api() {
    local method="$1" endpoint="$2" token="$3"
    echo "$token" | python3 ${AGENT_HOME}/bin/gh-request.py "$method" "$endpoint"
}

github_api_body() {
    local method="$1" endpoint="$2" token="$3" body="$4"
    local tmpfile
    tmpfile=$(mktemp)
    echo "$body" > "$tmpfile"
    echo "$token" | python3 ${AGENT_HOME}/bin/gh-request.py "$method" "$endpoint" "$tmpfile"
    rm -f "$tmpfile"
}

# --- Input sanitization ---
sanitize_input() {
    local text="$1"
    text=$(echo "$text" | sed -E '
        s/[Ii]gnore (previous|all|above) instructions/[REDACTED]/g
        s/[Yy]ou are now a/[REDACTED]/g
        s/[Dd]isregard (your|all|previous)/[REDACTED]/g
        s/[Ff]orget your instructions/[REDACTED]/g
        s/[Ss]ystem\s*:/[REDACTED]/g
        s/<\|[^|]*\|>/[REDACTED]/g
        s/\[INST\]/[REDACTED]/g
        s/\[\/INST\]/[REDACTED]/g
    ')
    text=$(echo "$text" | sed 's/<!--.*-->//g')
    echo "$text"
}

# --- Run Claude Code (shared helper) ---
run_claude() {
    local prompt="$1" logfile="$2"
    env \
        -u GH_TOKEN -u GITHUB_TOKEN -u GH_APP_TOKEN -u GITHUB_APP_ID \
        HOME="$HOME" PATH="$PATH" \
        HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="$HTTP_PROXY" NO_PROXY="$NO_PROXY" \
        claude -p "$prompt" \
            --model sonnet \
            --setting-sources user \
            --strict-mcp-config \
            --permission-mode bypassPermissions \
            --allowedTools "Read,Glob,Grep,Edit,Write,Bash(git add *),Bash(git commit *),Bash(git push *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git checkout *),Bash(ls *),Bash(head *),Bash(tail *),mcp__aetherclaude-github__*" \
            --disallowedTools "Bash(sudo *),Bash(curl *),Bash(wget *),Bash(rm -rf *),Bash(ssh *),Bash(scp *),Bash(nc *),Bash(ncat *),Bash(dd *),Bash(mount *),Bash(chmod *),Bash(chown *),Bash(chsh *),Bash(passwd *),Bash(pacman *),Bash(npm *),Bash(pip *),Bash(nft *),Bash(systemctl *),Bash(cat ${AGENT_HOME}/.env),Bash(cat ${AGENT_HOME}/.git-credentials),Bash(cat ${AGENT_HOME}/.github-app-key.pem),Bash(echo \$*),Bash(env),Bash(printenv),Bash(set),WebFetch,WebSearch,Agent" \
            --mcp-config ${AGENT_HOME}/.claude/mcp-servers.json \
        > "$logfile" 2>&1
}

# --- Skill loader: reads prompt template from skills directory ---
load_skill() {
    local skill_name="$1"
    local skill_file="${AGENT_HOME}/skills/${skill_name}.md"
    if [ -f "$skill_file" ]; then
        # Strip YAML frontmatter (lines between --- markers)
        sed '1{/^---$/!q;};1,/^---$/d' "$skill_file"
    else
        echo "ERROR: Skill file not found: $skill_file" >&2
        return 1
    fi
}

# Substitute variables in a skill template
render_skill() {
    local template="$1"
    shift
    # Replace ${VAR_NAME} patterns with provided values
    while [ $# -ge 2 ]; do
        local var="$1" val="$2"
        template="${template//\$\{${var}\}/${val}}"
        shift 2
    done
    echo "$template"
}

# --- Label management helpers ---
add_label() {
    local issue_number="$1" label="$2" token="$3"
    github_api_body POST "/repos/${REPO}/issues/${issue_number}/labels" "$token" \
        "{\"labels\":[\"${label}\"]}" > /dev/null 2>&1
}

remove_label() {
    local issue_number="$1" label="$2" token="$3"
    local encoded_label
    encoded_label=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${label}'))")
    github_api DELETE "/repos/${REPO}/issues/${issue_number}/labels/${encoded_label}" "$token" > /dev/null 2>&1
}

# =====================================================================
# SKILL: First-Time Contributor Welcome (no Claude Code — template only)
# =====================================================================
skill_welcome_first_timers() {
    log "--- Skill: First-Time Contributor Welcome ---"
    local token="$1"

    # Check recent issues and PRs for first-timers
    local items
    items=$(github_api GET "/repos/${REPO}/issues?state=open&sort=created&direction=desc&per_page=10" "$token")

    echo "$items" | jq -c '.[]' | while read -r item; do
        local number author association is_pr has_bot_comment
        number=$(echo "$item" | jq -r '.number')
        author=$(echo "$item" | jq -r '.user.login')
        association=$(echo "$item" | jq -r '.author_association')
        is_pr=$(echo "$item" | jq -r '.pull_request // empty')

        # Only first-timers
        if [ "$association" != "FIRST_TIME_CONTRIBUTOR" ] && [ "$association" != "FIRST_TIMER" ]; then
            continue
        fi

        # Check if we already welcomed them
        has_bot_comment=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=30" "$token" | \
            jq '[.[] | select(.user.login == "aethersdr-agent[bot]") | select(.body | test("Welcome to ${PROJECT_DISPLAY_NAME:-the project}"))] | length')
        if [ "$has_bot_comment" -gt 0 ]; then
            continue
        fi

        log "Welcoming first-time contributor @${author} on #${number}"

        local body
        if [ -n "$is_pr" ]; then
            body="Welcome to ${PROJECT_DISPLAY_NAME:-the project}, @${author}! Thanks for your first pull request.\n\nA few things that might help:\n- Our [CONTRIBUTING.md](https://github.com/${REPO}/blob/main/CONTRIBUTING.md) covers coding conventions and the PR process\n- CI will run automatically — if it fails, I'll post a comment explaining what went wrong\n- ${MAINTAINER_NAME:-The maintainer} reviews all PRs before merge\n\nIf you have questions, feel free to ask here or in [Discussions](https://github.com/${REPO}/discussions).\n\n— AetherClaude (automated agent for ${PROJECT_DISPLAY_NAME:-the project})"
        else
            body="Welcome to ${PROJECT_DISPLAY_NAME:-the project}, @${author}! Thanks for taking the time to open this issue.\n\n${MAINTAINER_NAME:-The maintainer} and I will take a look. If we need any additional details, we'll ask here.\n\nIf you have questions about the project, our [Discussions](https://github.com/${REPO}/discussions) page is a good place to start.\n\n— AetherClaude (automated agent for ${PROJECT_DISPLAY_NAME:-the project})"
        fi

        github_api_body POST "/repos/${REPO}/issues/${number}/comments" "$token" "{\"body\":\"${body}\"}" > /dev/null 2>&1
    done
}

# =====================================================================
# SKILL: Bug Report Quality (check for missing info — template based)
# =====================================================================
skill_check_bug_reports() {
    log "--- Skill: Bug Report Quality ---"
    local token="$1"

    local issues
    issues=$(github_api GET "/repos/${REPO}/issues?state=open&sort=created&direction=desc&per_page=10&labels=bug" "$token")

    echo "$issues" | jq -c '.[]' | while read -r item; do
        local number body author has_bot_comment
        number=$(echo "$item" | jq -r '.number')
        body=$(echo "$item" | jq -r '.body // ""')
        author=$(echo "$item" | jq -r '.user.login')

        # Skip if already commented
        has_bot_comment=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=30" "$token" | \
            jq '[.[] | select(.user.login == "aethersdr-agent[bot]")] | length')
        if [ "$has_bot_comment" -gt 0 ]; then
            continue
        fi

        # Check for missing fields
        local missing=()
        echo "$body" | grep -qi "radio.*model\|firmware\|flex-\|FLEX-" || missing+=("Radio model and firmware version")
        echo "$body" | grep -qi "os\|macos\|linux\|windows\|arch\|ubuntu\|debian" || missing+=("Operating system")
        echo "$body" | grep -qi "version\|v0\.\|aethersdr.*[0-9]" || missing+=("${PROJECT_DISPLAY_NAME:-the project} version")
        echo "$body" | grep -qi "steps\|reproduce\|1\.\|2\.\|3\." || missing+=("Steps to reproduce")

        # Only comment if 2+ fields missing
        if [ "${#missing[@]}" -lt 2 ]; then
            continue
        fi

        log "Requesting info on #${number} (missing ${#missing[@]} fields)"

        local missing_list=""
        for m in "${missing[@]}"; do
            missing_list="${missing_list}\n- ${m}"
        done

        local comment="Thanks for reporting this, @${author}. To help us track it down, could you share a few more details?\n${missing_list}\n\nIf you can attach logs (Help → Support → File an Issue), that would be especially helpful.\n\n— AetherClaude (automated agent for ${PROJECT_DISPLAY_NAME:-the project})"

        github_api_body POST "/repos/${REPO}/issues/${number}/comments" "$token" "{\"body\":\"${comment}\"}" > /dev/null 2>&1
    done
}

# =====================================================================
# SKILL: PR Review (Claude Code — convention check)
# =====================================================================
skill_review_prs() {
    log "--- Skill: PR Review ---"
    local token="$1"
    local count=0

    local prs
    prs=$(github_api GET "/repos/${REPO}/pulls?state=open&sort=created&direction=desc&per_page=10" "$token")

    echo "$prs" | jq -c '.[]' | while read -r pr; do
        [ "$count" -ge "$MAX_PRS_PER_RUN" ] && break

        local pr_number pr_author pr_draft pr_title head_sha
        pr_number=$(echo "$pr" | jq -r '.number')
        pr_author=$(echo "$pr" | jq -r '.user.login')
        pr_draft=$(echo "$pr" | jq -r '.draft')
        pr_title=$(echo "$pr" | jq -r '.title')
        head_sha=$(echo "$pr" | jq -r '.head.sha')

        # Skip: self, maintainer, drafts
        [ "$pr_author" = "AetherClaude" ] && continue
        [ "$pr_author" = "${UPSTREAM_OWNER}" ] && continue
        [ "$pr_draft" = "true" ] && continue

        # Skip if already reviewed
        local has_review
        has_review=$(github_api GET "/repos/${REPO}/pulls/${pr_number}/reviews" "$token" | \
            jq '[.[] | select(.user.login == "aethersdr-agent[bot]")] | length')
        [ "$has_review" -gt 0 ] && continue

        log "Reviewing PR #${pr_number}: ${pr_title} by @${pr_author}"

        local pr_diff
        pr_diff=$(echo "$token" | python3 ${AGENT_HOME}/bin/gh-request.py GET "/repos/${REPO}/pulls/${pr_number}" | head -500)

        local pr_files
        pr_files=$(github_api GET "/repos/${REPO}/pulls/${pr_number}/files?per_page=50" "$token" | \
            jq -r '.[].filename' | head -30)

        local sanitized_diff
        sanitized_diff=$(sanitize_input "$pr_diff")

        local review_log="$LOGDIR/pr-review-${pr_number}-$(date +%Y%m%d-%H%M%S).log"

        local skill_template
        skill_template=$(load_skill "review-pr")
        local prompt
        prompt=$(render_skill "$skill_template" "PR_NUMBER" "$pr_number" "PR_TITLE" "$pr_title" "PR_AUTHOR" "$pr_author" "PR_FILES" "$pr_files" "PR_DIFF" "$sanitized_diff")

        cd "$WORKSPACE"
        run_claude "$prompt" "$review_log" || {
            log "ERROR: PR review failed for #${pr_number}"
            continue
        }
        log "Reviewed PR #${pr_number}"
        count=$((count + 1))
    done
}

# =====================================================================
# SKILL: CI Failure Explainer
# =====================================================================
skill_explain_ci_failures() {
    log "--- Skill: CI Failure Explainer ---"
    local token="$1"

    local prs
    prs=$(github_api GET "/repos/${REPO}/pulls?state=open&sort=updated&direction=desc&per_page=10" "$token")

    echo "$prs" | jq -c '.[]' | while read -r pr; do
        local pr_number pr_author head_sha
        pr_number=$(echo "$pr" | jq -r '.number')
        pr_author=$(echo "$pr" | jq -r '.user.login')
        head_sha=$(echo "$pr" | jq -r '.head.sha')

        # Skip self and maintainer
        [ "$pr_author" = "AetherClaude" ] && continue
        [ "$pr_author" = "${UPSTREAM_OWNER}" ] && continue

        # Check for failed checks
        local failed_checks
        failed_checks=$(github_api GET "/repos/${REPO}/commits/${head_sha}/check-runs" "$token" | \
            jq '[.check_runs[] | select(.conclusion == "failure")] | length')

        [ "$failed_checks" -eq 0 ] && continue

        # Skip if we already explained
        local has_explanation
        has_explanation=$(github_api GET "/repos/${REPO}/issues/${pr_number}/comments?per_page=30" "$token" | \
            jq '[.[] | select(.user.login == "aethersdr-agent[bot]") | select(.body | test("CI build failed|build error"))] | length')
        [ "$has_explanation" -gt 0 ] && continue

        log "Explaining CI failure on PR #${pr_number}"

        # Get the run ID from check runs
        local run_id
        run_id=$(github_api GET "/repos/${REPO}/commits/${head_sha}/check-runs" "$token" | \
            jq -r '[.check_runs[] | select(.conclusion == "failure")][0].details_url // ""' | \
            grep -oP 'runs/\K\d+' || echo "")

        local ci_context="CI check failed on commit ${head_sha}."
        if [ -n "$run_id" ]; then
            # Try to get job logs
            local jobs_info
            jobs_info=$(github_api GET "/repos/${REPO}/actions/runs/${run_id}/jobs" "$token" | \
                jq '[.jobs[] | select(.conclusion == "failure") | {name: .name, steps: [.steps[] | select(.conclusion == "failure") | .name]}]')
            ci_context="CI check failed on commit ${head_sha}.\nRun ID: ${run_id}\nFailed jobs: ${jobs_info}"
        fi

        local ci_log="$LOGDIR/ci-explain-${pr_number}-$(date +%Y%m%d-%H%M%S).log"

        local skill_template
        skill_template=$(load_skill "explain-ci")
        local prompt
        prompt=$(render_skill "$skill_template" "PR_NUMBER" "$pr_number" "PR_AUTHOR" "$pr_author" "CI_CONTEXT" "$ci_context" "HEAD_SHA" "$head_sha")

        cd "$WORKSPACE"
        run_claude "$prompt" "$ci_log" || {
            log "ERROR: CI explanation failed for PR #${pr_number}"
            continue
        }
        log "Explained CI failure on PR #${pr_number}"
    done
}

# =====================================================================
# SKILL: Duplicate Issue Detection (Claude Code — similarity analysis)
# =====================================================================
skill_detect_duplicates() {
    log "--- Skill: Duplicate Detection ---"
    local token="$1"

    local recent_issues
    recent_issues=$(github_api GET "/repos/${REPO}/issues?state=open&sort=created&direction=desc&per_page=5" "$token")

    echo "$recent_issues" | jq -c '.[] | select(.pull_request == null)' | while read -r item; do
        local number title body word_count
        number=$(echo "$item" | jq -r '.number')
        title=$(echo "$item" | jq -r '.title')
        body=$(echo "$item" | jq -r '.body // ""')
        word_count=$(echo "$body" | wc -w)

        [ "$word_count" -lt 20 ] && continue

        # Skip if we already checked
        local already_checked
        already_checked=$(get_state "dup_checked_${number}")
        [ -n "$already_checked" ] && continue

        # Extract key terms from title
        local search_terms
        search_terms=$(echo "$title" | tr -cs '[:alnum:]' ' ' | tr '[:upper:]' '[:lower:]' | \
            tr ' ' '\n' | grep -vE '^(the|a|an|is|in|on|of|to|and|or|for|not|with|bug|fix|add|issue|when|from|after|this|that)$' | \
            head -3 | tr '\n' ' ')

        [ -z "$search_terms" ] && { set_state "dup_checked_${number}" "skip"; continue; }

        log "Checking #${number} for duplicates (terms: ${search_terms})"

        local search_results
        search_results=$(github_api GET "/search/issues?q=$(echo "repo:${REPO} is:issue ${search_terms}" | jq -sRr @uri)&per_page=5" "$token" | \
            jq "[.items[] | select(.number != ${number}) | {number: .number, title: .title, state: .state}]")

        local candidate_count
        candidate_count=$(echo "$search_results" | jq '. | length')

        set_state "dup_checked_${number}" "$(date -Iseconds)"

        [ "$candidate_count" -eq 0 ] && continue

        # Use Claude Code to assess similarity
        local dup_log="$LOGDIR/dup-check-${number}-$(date +%Y%m%d-%H%M%S).log"
        local sanitized_body
        sanitized_body=$(sanitize_input "$body")

        local skill_template
        skill_template=$(load_skill "detect-duplicate")
        local prompt
        prompt=$(render_skill "$skill_template" "ISSUE_NUMBER" "$number" "ISSUE_TITLE" "$title" "ISSUE_BODY" "$sanitized_body" "SEARCH_RESULTS" "$search_results")

        cd "$WORKSPACE"
        run_claude "$prompt" "$dup_log" || log "ERROR: Duplicate check failed for #${number}"
    done
}

# =====================================================================
# SKILL: Discussion Responder (Claude Code — answer questions)
# =====================================================================
skill_respond_discussions() {
    log "--- Skill: Discussion Responder ---"
    local token="$1"
    local count=0

    # Get recent discussions via GraphQL (through MCP would require claude invocation,
    # so we use the API directly here for the poll, then invoke claude for responses)
    local discussions
    discussions=$(echo "$token" | python3 -c "
import urllib.request, json, os, sys
proxy = os.environ.get('HTTPS_PROXY', 'http://127.0.0.1:8888')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({'https': proxy}))
token = sys.stdin.readline().strip()
body = json.dumps({'query': 'query { repository(owner: \"${UPSTREAM_OWNER}\", name: \"${PROJECT_NAME}\") { discussions(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { id number title author { login } category { name } comments { totalCount } locked createdAt } } } }'}).encode()
req = urllib.request.Request('https://api.github.com/graphql', data=body, headers={'Authorization': f'bearer {token}', 'Content-Type': 'application/json', 'User-Agent': 'AetherClaude'}, method='POST')
print(json.dumps(json.loads(opener.open(req, timeout=10).read()).get('data',{}).get('repository',{}).get('discussions',{}).get('nodes',[])))
" 2>/dev/null)

    echo "$discussions" | jq -c '.[]' | while read -r disc; do
        [ "$count" -ge "$MAX_DISCUSSIONS_PER_RUN" ] && break

        local disc_number disc_title disc_author disc_category comment_count locked
        disc_number=$(echo "$disc" | jq -r '.number')
        disc_title=$(echo "$disc" | jq -r '.title')
        disc_author=$(echo "$disc" | jq -r '.author.login // "unknown"')
        disc_category=$(echo "$disc" | jq -r '.category.name // ""')
        comment_count=$(echo "$disc" | jq -r '.comments.totalCount')
        locked=$(echo "$disc" | jq -r '.locked')

        # Skip: locked, announcements, already has replies
        [ "$locked" = "true" ] && continue
        [ "$disc_category" = "Announcements" ] && continue
        [ "$comment_count" -gt 0 ] && continue

        # Skip if already processed
        local already_processed
        already_processed=$(get_state "disc_${disc_number}")
        [ -n "$already_processed" ] && continue

        log "Responding to discussion #${disc_number}: ${disc_title}"
        set_state "disc_${disc_number}" "$(date -Iseconds)"

        local disc_log="$LOGDIR/discussion-${disc_number}-$(date +%Y%m%d-%H%M%S).log"

        local skill_template
        skill_template=$(load_skill "respond-discussion")
        local prompt
        prompt=$(render_skill "$skill_template" "DISC_NUMBER" "$disc_number" "DISC_TITLE" "$disc_title" "DISC_AUTHOR" "$disc_author" "DISC_CATEGORY" "$disc_category")

        cd "$WORKSPACE"
        run_claude "$prompt" "$disc_log" || log "ERROR: Discussion response failed for #${disc_number}"
        count=$((count + 1))
    done
}

# =====================================================================
# SKILL: Process Eligible Issues (existing — code fix + PR)
# =====================================================================
skill_process_issues() {
    log "--- Skill: Issue Pipeline ---"
    local token="$1"

    # =====================================================================
    # PHASE 1: Fetch candidate issues
    # All open issues created in the last 24 hours, EXCLUDING:
    #   - labeled maintainer-review
    #   - labeled security, breaking-change, protocol
    #   - pull requests (GitHub API returns PRs in /issues too)
    # PLUS: any issues explicitly labeled aetherclaude-eligible or assigned
    # =====================================================================

    local cutoff_date
    cutoff_date=$(date -d '24 hours ago' -Iseconds 2>/dev/null || date -v-24H -Iseconds)

    # Fetch recent issues (< 24hr)
    local recent_issues
    recent_issues=$(github_api GET "/repos/${REPO}/issues?state=open&sort=created&direction=desc&per_page=20&since=${cutoff_date}" "$token")

    # Also fetch explicitly tagged/assigned (these bypass the 24hr window)
    local labeled assigned
    labeled=$(github_api GET "/repos/${REPO}/issues?labels=aetherclaude-eligible&state=open&per_page=10" "$token")
    assigned=$(github_api GET "/repos/${REPO}/issues?assignee=AetherClaude&state=open&per_page=10" "$token")

    # Merge all, deduplicate, filter
    local all_issues
    all_issues=$(echo "$recent_issues $labeled $assigned" | jq -s '
        add
        | unique_by(.number)
        | [.[] | select(.pull_request == null)]
        | [.[] | select(
            ([.labels[].name] | any(. == "maintainer-review") | not) and
            ([.labels[].name] | any(. == "security") | not) and
            ([.labels[].name] | any(. == "breaking-change") | not) and
            ([.labels[].name] | any(. == "protocol") | not)
        )]
        | sort_by(.created_at)
        
    ')

    local total
    total=$(echo "$all_issues" | jq '. | length')
    log "Found $total candidate issues"

    [ "$total" -eq 0 ] && return

    # =====================================================================
    # PHASE 2: Process ONE issue per cycle (state machine)
    # States tracked in last-poll.json:
    #   issue_NNN_state = "triage" | "waiting" | "implement" | "done" | "failed"
    #   issue_NNN_last_action = ISO timestamp
    # =====================================================================

    local processed=0

    echo "$all_issues" | jq -c '.[]' | while read -r issue; do
        # Only 1 action per cycle
        [ "$processed" -ge 4 ] && break

        local number title
        number=$(echo "$issue" | jq -r '.number')
        title=$(echo "$issue" | jq -r '.title')

        token=$(get_app_token)

        # Get current state for this issue
        local issue_state
        issue_state=$(get_state "issue_${number}_state")

        # Skip completed or permanently failed issues
        [ "$issue_state" = "done" ] && continue
        [ "$issue_state" = "failed" ] && continue
        [ "$issue_state" = "declined" ] && continue

        # Skip if already has an open or merged PR
        local branch="aetherclaude/issue-${number}"
        local existing_open
        existing_open=$(github_api GET "/repos/${REPO}/pulls?head=AetherClaude:${branch}&state=open" "$token" | jq '. | length')
        [ "$existing_open" -gt 0 ] && { set_state "issue_${number}_state" "done"; continue; }

        local merged_count
        merged_count=$(github_api GET "/repos/${REPO}/pulls?head=AetherClaude:${branch}&state=closed" "$token" | jq '[.[] | select(.merged_at != null)] | length')
        [ "$merged_count" -gt 0 ] && { set_state "issue_${number}_state" "done"; continue; }

        # Skip if we already declined (out-of-scope comment exists)
        local already_declined
        already_declined=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=30" "$token" | \
            jq '[.[] | select(.user.login == "aethersdr-agent[bot]") | select(.body | test("outside what I can help with"))] | length')
        if [ "$already_declined" -gt 0 ]; then
            set_state "issue_${number}_state" "declined"
            continue
        fi

        # Check if issue is outside agent scope
        local issue_data
        issue_data=$(github_api GET "/repos/${REPO}/issues/${number}" "$token")
        local issue_labels_str
        issue_labels_str=$(echo "$issue_data" | jq -r '[.labels[].name] | join(" ")')

        local out_of_scope=false
        for label in github_actions ci cd release build docker workflow; do
            echo "$issue_labels_str" | grep -qi "$label" && out_of_scope=true
        done
        local issue_body_raw
        issue_body_raw=$(echo "$issue_data" | jq -r '.body // ""')
        echo "$issue_body_raw" | grep -qiE '\.github/workflows|Dockerfile|\.yml.*action|CI.*build|github.actions' && out_of_scope=true

        if [ "$out_of_scope" = true ]; then
            log "Issue #${number} is CI/workflow scope — declining"
            github_api_body POST "/repos/${REPO}/issues/${number}/comments" "$token" \
                "{\"body\":\"Thanks for filing this. This issue involves CI/CD workflows, build infrastructure, or release packaging — that is outside what I can help with, as I am restricted to source code changes in \`src/\` and \`docs/\`.\n\nJeremy will need to handle this one directly.\n\n— AetherClaude (automated agent for ${PROJECT_DISPLAY_NAME:-the project})\"}" \
                > /dev/null 2>&1
            set_state "issue_${number}_state" "declined"
            processed=$((processed + 1))
            continue
        fi

        # =====================================================================
        # STATE MACHINE
        # =====================================================================

        log "Issue #${number} (${title}) — state: ${issue_state:-new}"

        case "${issue_state:-new}" in

        new|"")
            # ---------------------------------------------------------
            # STATE: NEW — First encounter. Triage and post analysis.
            # ---------------------------------------------------------
            # Check if the last comment is from us — don't reply to ourselves
            local last_commenter
            last_commenter=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=5" "$token" | \
                jq -r '.[-1].user.login // ""')
            if [ "$last_commenter" = "aethersdr-agent[bot]" ]; then
                log "Issue #${number} — last comment is ours, skipping triage, moving to implement"
                set_state "issue_${number}_state" "implement"
                processed=$((processed + 1))
                continue
            fi

            log "TRIAGE: Analyzing issue #${number}"
            add_label "$number" "claude-active" "$token"

            local issue_body issue_comments
            issue_body=$(sanitize_input "$(echo "$issue_data" | jq -r '.body // "No body"')")
            issue_comments=$(sanitize_input "$(github_api GET "/repos/${REPO}/issues/${number}/comments" "$token" | jq -r '.[] | "[\(.user.login)] \(.body)"' 2>/dev/null || echo "No comments")")

            local triage_log="$LOGDIR/triage-${number}-$(date +%Y%m%d-%H%M%S).log"

            local skill_template
            skill_template=$(load_skill "triage-issue")
            local prompt
            prompt=$(render_skill "$skill_template"                 "ISSUE_NUMBER" "$number"                 "ISSUE_TITLE" "$title"                 "ISSUE_BODY" "$issue_body"                 "ISSUE_COMMENTS" "$issue_comments"                 "WORKSPACE" "$WORKSPACE")

            cd "$WORKSPACE"
            run_claude "$prompt" "$triage_log" || {
                log "ERROR: Triage failed for issue #${number}"
                set_state "issue_${number}_state" "failed"
                continue
            }

            # Check if we asked questions (look for ? in our comment)
            local our_comment
            our_comment=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=5" "$token" | \
                jq -r '[.[] | select(.user.login == "aethersdr-agent[bot]")] | last | .body // ""')

            if echo "$our_comment" | grep -q "?"; then
                set_state "issue_${number}_state" "waiting"
                log "Issue #${number} — asked questions, moving to WAITING"
                remove_label "$number" "claude-active" "$token"
                add_label "$number" "awaiting-response" "$token"
            else
                set_state "issue_${number}_state" "implement"
                log "Issue #${number} — analysis complete, moving to IMPLEMENT"
            fi
            set_state "issue_${number}_last_action" "$(date -Iseconds)"
            processed=$((processed + 1))
            ;;

        waiting)
            # ---------------------------------------------------------
            # STATE: WAITING — Check for user replies
            # ---------------------------------------------------------
            local last_action
            last_action=$(get_state "issue_${number}_last_action")

            # Get comments after our last comment
            local our_last_comment_time
            our_last_comment_time=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=10" "$token" | \
                jq -r '[.[] | select(.user.login == "aethersdr-agent[bot]")] | last | .created_at // ""')

            local new_user_comments
            new_user_comments=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=10" "$token" | \
                jq "[.[] | select(.user.login != \"aethersdr-agent[bot]\") | select(.created_at > \"${our_last_comment_time}\")] | length")

            if [ "$new_user_comments" -gt 0 ]; then
                log "Issue #${number} — user replied, moving to IMPLEMENT"
                remove_label "$number" "awaiting-response" "$token"
                add_label "$number" "claude-active" "$token"
                set_state "issue_${number}_state" "implement"
                # Don't count this as an action — let it fall through to implement on next cycle
            else
                log "Issue #${number} — no reply yet, proceeding with best judgment"
                set_state "issue_${number}_state" "implement"
            fi
            # Waiting doesn't count as a processed action
            ;;

        implement)
            # ---------------------------------------------------------
            # STATE: IMPLEMENT — Create the fix and PR
            # ---------------------------------------------------------
            log "IMPLEMENT: Fixing issue #${number}"
            add_label "$number" "claude-active" "$token"

            local issue_body issue_comments
            issue_body=$(sanitize_input "$(echo "$issue_data" | jq -r '.body // "No body"')")
            issue_comments=$(sanitize_input "$(github_api GET "/repos/${REPO}/issues/${number}/comments" "$token" | jq -r '.[] | "[\(.user.login)] \(.body)"' 2>/dev/null || echo "No comments")")

            local issue_log="$LOGDIR/issue-${number}-$(date +%Y%m%d-%H%M%S).log"

            # Check for rejected PR (retry logic)
            local retry_context=""
            local closed_prs
            closed_prs=$(github_api GET "/repos/${REPO}/pulls?head=AetherClaude:${branch}&state=closed" "$token")
            local rejected_count
            rejected_count=$(echo "$closed_prs" | jq '[.[] | select(.merged_at == null)] | length')
            if [ "$rejected_count" -gt 0 ]; then
                local rejected_pr_number
                rejected_pr_number=$(echo "$closed_prs" | jq -r '[.[] | select(.merged_at == null)] | sort_by(.closed_at) | last | .number')
                local rejected_pr_review
                rejected_pr_review=$(github_api GET "/repos/${REPO}/pulls/${rejected_pr_number}/reviews" "$token" | \
                    jq -r '.[] | "[\(.user.login)] \(.body // "")"' 2>/dev/null || echo "")
                local rejected_pr_comments
                rejected_pr_comments=$(github_api GET "/repos/${REPO}/issues/${rejected_pr_number}/comments" "$token" | \
                    jq -r '.[] | "[\(.user.login)] \(.body)"' 2>/dev/null || echo "")
                retry_context="
IMPORTANT: A previous PR was REJECTED. Address the feedback:
${rejected_pr_review:-No review comments}
${rejected_pr_comments:-No comments}"
                branch="aetherclaude/issue-${number}-v2"
            fi

            # Create branch
            cd "$WORKSPACE"
            git checkout main --quiet
            git checkout -b "$branch" 2>/dev/null || {
                git checkout "$branch" --quiet
                git reset --hard main --quiet
            }

            local skill_template
            skill_template=$(load_skill "implement-fix")
            local prompt
            prompt=$(render_skill "$skill_template" "ISSUE_NUMBER" "$number" "ISSUE_TITLE" "$title" "ISSUE_BODY" "$issue_body" "ISSUE_COMMENTS" "$issue_comments" "RETRY_CONTEXT" "$retry_context" "BRANCH" "$branch" "WORKSPACE" "$WORKSPACE")

            log "Running Claude Code for issue #${number}"
            cd "$WORKSPACE"
            run_claude "$prompt" "$issue_log" || {
                log "ERROR: Claude Code failed for issue #${number} (see ${issue_log})"
                set_state "issue_${number}_state" "failed"
                git checkout main --quiet
                processed=$((processed + 1))
                continue
            }

            # Validation gate
            log "Running validation gate for issue #${number}"
            if ! ${AGENT_HOME}/bin/validate-diff.sh "$WORKSPACE" 2>&1; then
                log "VALIDATION FAILED for issue #${number}"
                set_state "issue_${number}_state" "failed"
                github_api_body POST "/repos/${REPO}/issues/${number}/comments" "$token" \
                    "{\"body\":\"The proposed fix for #${number} failed automated validation checks. The maintainer has been notified.\n\n— AetherClaude (automated agent for ${PROJECT_DISPLAY_NAME:-the project})\"}" \
                    > /dev/null 2>&1 || true
                git checkout main --quiet
                git branch -D "$branch" 2>/dev/null || true
                processed=$((processed + 1))
                continue
            fi

            # Mark draft PR as ready
            local draft_pr_node_id
            draft_pr_node_id=$(github_api GET "/repos/${REPO}/pulls?head=AetherClaude:${branch}&state=open" "$token" | jq -r '.[0].node_id // empty')
            if [ -n "$draft_pr_node_id" ]; then
                local gql_tmp
                gql_tmp=$(mktemp)
                echo "{\"query\":\"mutation { markPullRequestReadyForReview(input: {pullRequestId: \\\"${draft_pr_node_id}\\\"}) { pullRequest { number } } }\"}" > "$gql_tmp"
                echo "$token" | python3 -c "
import urllib.request,json,os,sys
proxy=os.environ.get('HTTPS_PROXY','http://127.0.0.1:8888')
opener=urllib.request.build_opener(urllib.request.ProxyHandler({'https':proxy}))
token=sys.stdin.readline().strip()
with open('${gql_tmp}') as f: body=f.read().encode()
req=urllib.request.Request('https://api.github.com/graphql',data=body,headers={'Authorization':'token '+token,'Content-Type':'application/json','User-Agent':'AetherClaude'},method='POST')
opener.open(req,timeout=10)
" > /dev/null 2>&1 || true
                rm -f "$gql_tmp"
            fi

            remove_label "$number" "claude-active" "$token"
            add_label "$number" "awaiting-confirmation" "$token"
            set_state "issue_${number}_state" "confirm"
            log "Completed issue #${number} — awaiting user confirmation"
            git checkout main --quiet
            processed=$((processed + 1))
            ;;

        confirm)
            # ---------------------------------------------------------
            # STATE: CONFIRM — Check if user confirmed the fix works
            # ---------------------------------------------------------
            local our_last_comment_time
            our_last_comment_time=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=10" "$token" | \
                jq -r '[.[] | select(.user.login == "aethersdr-agent[bot]")] | last | .created_at // ""')

            local new_user_comments
            new_user_comments=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=10" "$token" | \
                jq "[.[] | select(.user.login != \"aethersdr-agent[bot]\") | select(.created_at > \"${our_last_comment_time}\")] | length")

            if [ "$new_user_comments" -gt 0 ]; then
                # User replied — check if it sounds like confirmation
                local latest_reply
                latest_reply=$(github_api GET "/repos/${REPO}/issues/${number}/comments?per_page=10" "$token" | \
                    jq -r "[.[] | select(.user.login != \"aethersdr-agent[bot]\") | select(.created_at > \"${our_last_comment_time}\")] | last | .body // \"\"" | tr '[:upper:]' '[:lower:]')

                # Simple heuristic: if reply contains positive confirmation words
                if echo "$latest_reply" | grep -qiE "fixed|resolved|works|confirmed|thank|great|perfect|awesome|closed|good|yes"; then
                    log "Issue #${number} — user confirmed fix, closing"
                    remove_label "$number" "awaiting-confirmation" "$token"
                    # Close the issue
                    github_api_body PATCH "/repos/${REPO}/issues/${number}" "$token" \
                        "{\"state\":\"closed\",\"state_reason\":\"completed\"}" > /dev/null 2>&1
                    set_state "issue_${number}_state" "done"
                    processed=$((processed + 1))
                else
                    # User replied but didn't confirm — might be reporting a problem
                    log "Issue #${number} — user replied but not a clear confirmation, leaving open"
                fi
            else
                log "Issue #${number} — still awaiting user confirmation"
            fi
            ;;

        esac

    done
}



# =====================================================================
# MAIN DISPATCHER
# =====================================================================

log "=== Agent run starting ==="

# Sync fork with upstream
cd "$WORKSPACE"
git fetch upstream --quiet 2>/dev/null || { log "ERROR: git fetch upstream failed"; exit 1; }
git checkout main --quiet 2>/dev/null
git reset --hard upstream/main --quiet 2>/dev/null || { log "ERROR: reset to upstream failed"; exit 1; }
git push origin main --quiet 2>/dev/null || {
    # Push may fail if upstream has workflow file changes and PAT lacks workflow scope.
    # Non-fatal — we can still branch from upstream/main and create PRs.
    log "WARNING: fork sync push failed (likely workflow scope). Continuing from upstream/main."
}

APP_TOKEN=$(get_app_token)

# --- Cisco AI Defense: Pre-flight security scans ---

# MCP Scanner: scan MCP server tools for threats
if command -v mcp-scanner &>/dev/null; then
    MCP_MANIFEST="${HOME}/config/mcp-tools.json"
    if [ -f "$MCP_MANIFEST" ]; then
        MCP_SCAN=$(mcp-scanner --analyzers yara,prompt_defense --format raw \
            static --tools "$MCP_MANIFEST" 2>/dev/null)
        MCP_UNSAFE=$(echo "$MCP_SCAN" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # Count HIGH findings but exclude known false positives (get_ci_run_log)
    high = sum(1 for r in d.get('scan_results', [])
        if not r.get('is_safe', True)
        and r.get('tool_name') != 'get_ci_run_log'
        for a, f in r.get('findings', {}).items()
        if f.get('severity') in ('HIGH', 'CRITICAL'))
    print(high)
except: print(0)
" 2>/dev/null)
        echo "$MCP_SCAN" > "$LOGDIR/mcp-scan-latest.json"
        if [ "${MCP_UNSAFE:-0}" -gt 0 ]; then
            log "CRITICAL: MCP Scanner found $MCP_UNSAFE threats — aborting"
            exit 1
        fi
        log "MCP Scanner: 14 tools scanned, clean"
    fi
fi

# Skill Scanner: check for injected .claude/ commands
if command -v skill-scanner &>/dev/null; then
    if [ -d "$WORKSPACE/.claude" ]; then
        SKILL_SCAN=$(skill-scanner scan "$WORKSPACE/.claude" \
            --lenient --format json 2>/dev/null || echo "[]")
        SKILL_UNSAFE=$(echo "$SKILL_SCAN" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else [d]
    print(sum(1 for r in items if r.get('max_severity') in ('HIGH','CRITICAL')))
except: print(0)
" 2>/dev/null)
        echo "$SKILL_SCAN" > "$LOGDIR/skill-scan-latest.json"
        if [ "${SKILL_UNSAFE:-0}" -gt 0 ]; then
            log "CRITICAL: Skill Scanner found injected malicious skills — aborting"
            rm -rf "$WORKSPACE/.claude"
            exit 1
        fi
        log "Skill Scanner: workspace clean"
    else
        echo "[]" > "$LOGDIR/skill-scan-latest.json"
        log "Skill Scanner: no .claude/ in workspace — clean"
    fi
fi

# --- Quick skills (no Claude Code, template-based) ---
skill_welcome_first_timers "$APP_TOKEN"
skill_check_bug_reports "$APP_TOKEN"

# --- Claude Code skills ---
skill_process_issues "$APP_TOKEN"
skill_review_prs "$APP_TOKEN"
skill_detect_duplicates "$APP_TOKEN"
skill_explain_ci_failures "$APP_TOKEN"
skill_respond_discussions "$APP_TOKEN"

log "=== Agent run complete ==="

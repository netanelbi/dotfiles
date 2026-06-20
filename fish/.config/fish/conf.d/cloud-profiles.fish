# ─── gws + gcloud account/scope profiles ──────────────────────────────────────
# One config dir per (account + scope-set) so all profiles coexist and switching
# is instant with zero re-auth. See `cloud-profiles` for the summary table.
#
#   gws:    GOOGLE_WORKSPACE_CLI_CONFIG_DIR  picks the whole config dir
#   gcloud: CLOUDSDK_ACTIVE_CONFIG_NAME       picks a named configuration
#
# The RUN wrappers (gwsw/gwswa/gwsp/gcloudw/gcloudp) are POSIX scripts on PATH in
# ~/.local/bin so EVERY shell can call them (fish, bash, cron, scripts) — not
# fish functions. The interactive LOGIN/SETUP wrappers stay here as fish
# functions (you only run them by hand). Both set env per-invocation via `env`,
# so no global state is mutated and two shells can use different profiles at once.

# Scope sets (kept here so login wrappers and docs share one source of truth).
set -g __GWS_WORK_SCOPES "https://www.googleapis.com/auth/meetings.space.created,https://www.googleapis.com/auth/meetings.space.settings,https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/gmail.settings.basic,https://www.googleapis.com/auth/documents,https://www.googleapis.com/auth/presentations,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/tasks,https://www.googleapis.com/auth/contacts,https://www.googleapis.com/auth/chat.messages,https://www.googleapis.com/auth/chat.spaces,email,profile,openid"
set -g __GWS_ADMIN_SCOPES "https://www.googleapis.com/auth/admin.directory.customer,https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/admin.directory.group,https://www.googleapis.com/auth/admin.reports.audit.readonly,https://www.googleapis.com/auth/admin.reports.usage.readonly"
# Consumer-safe subset for @gmail (no Workspace-only Chat/Meet scopes).
set -g __GWS_PERSONAL_SCOPES "https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/gmail.settings.basic,https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/documents,https://www.googleapis.com/auth/presentations,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/tasks,https://www.googleapis.com/auth/contacts,email,profile,openid"

# Config dirs
set -g __GWS_DIR_WORK     "$HOME/.config/gws"          # existing default → work, normal scopes
set -g __GWS_DIR_ADMIN    "$HOME/.config/gws-admin"    # work account, + admin scopes
set -g __GWS_DIR_PERSONAL "$HOME/.config/gws-personal" # personal @gmail account

# Run wrappers (gwsw/gwswa/gwsp/gcloudw/gcloudp) live as PATH scripts in
# ~/.local/bin — not defined here, so they work from any shell.

# ─── gws login wrappers (open a browser, store creds in that profile's dir) ────
function gwsw-login  --description 'Authenticate work account (normal scopes)'
    env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$__GWS_DIR_WORK gws auth login --scopes "$__GWS_WORK_SCOPES"
end
function gwswa-login --description 'Authenticate work account WITH admin scopes'
    env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$__GWS_DIR_ADMIN gws auth login --scopes "$__GWS_WORK_SCOPES,$__GWS_ADMIN_SCOPES"
end
function gwsp-login  --description 'Authenticate personal account (run gwsp-setup first)'
    env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$__GWS_DIR_PERSONAL gws auth login --scopes "$__GWS_PERSONAL_SCOPES"
end

# One-time: configure a personal GCP project + OAuth client for the personal dir.
#   gwsp-setup --project YOUR_PERSONAL_PROJECT_ID    then:    gwsp-login
# Creates client_secret.json in the personal dir. Needed because the work
# client_secret belongs to the org-internal gwsccrop app, which a @gmail account
# can't consent to. Run gwsp-login afterwards for the consumer-safe scope set.
function gwsp-setup --description 'One-time: set up personal GCP OAuth client for gws'
    # CLOUDSDK_ACTIVE_CONFIG_NAME=personal so the gcloud calls `gws auth setup`
    # makes internally run as the personal account, not work.
    env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$__GWS_DIR_PERSONAL CLOUDSDK_ACTIVE_CONFIG_NAME=personal gws auth setup $argv
end

# ─── summary ──────────────────────────────────────────────────────────────────
function cloud-profiles --description 'Show gws/gcloud profile switching cheat sheet'
    printf '%s\n' \
        'gws profiles (run / login):' \
        '  gwsw    / gwsw-login     work account, normal scopes      ('$__GWS_DIR_WORK')' \
        '  gwswa   / gwswa-login    work account, + admin scopes      ('$__GWS_DIR_ADMIN')' \
        '  gwsp    / gwsp-login     personal @gmail                   ('$__GWS_DIR_PERSONAL')' \
        '           gwsp-setup      one-time personal OAuth client setup' \
        '  (plain `gws` == gwsw, since the default dir is the work profile)' \
        '' \
        'gcloud profiles:' \
        '  gcloudw                  work account   (config: default)' \
        '  gcloudp                  personal acct  (config: personal)' \
        '' \
        'Status:  gwsw auth status | gwswa auth status | gwsp auth status | gcloud auth list'
end

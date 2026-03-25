#!/usr/bin/env python3
"""Populate qa-quest.db with findings from the Quality Quest audit."""

import sqlite3
import sys
import os

DB_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "qa-quest.db")


def get_cat(conn, slug):
    return conn.execute("SELECT id FROM categories WHERE slug = ?", (slug,)).fetchone()[0]


def add(conn, cat_id, priority, title, description, file_path=None, files=None, exec_order=0, mutex_group=None):
    conn.execute(
        """INSERT INTO tasks (category_id, priority, title, description, file_path, files, exec_order, mutex_group, project)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'custyard')""",
        (cat_id, priority, title, description, file_path, files, exec_order, mutex_group),
    )


def main():
    conn = sqlite3.connect(DB_PATH)
    bugs = get_cat(conn, "bugs")
    frontend = get_cat(conn, "frontend")
    ux = get_cat(conn, "ux")
    security = get_cat(conn, "security")

    # ========================================================================
    # SECURITY — P1 (1 task)
    # ========================================================================
    add(conn, security, "P1",
        "Session fixation: session not regenerated after login",
        "SessionController.create does not call configure_session(renew: true) after authenticating the operator. "
        "An attacker who can set a session cookie before the victim logs in inherits the authenticated session. "
        "Fix: call configure_session(renew: true) in the create action after setting operator_id in the session.",
        file_path="lib/custyard_web/controllers/operator/session_controller.ex",
        exec_order=-10)

    # ========================================================================
    # BUGS — P1 (14 tasks)
    # ========================================================================

    # Atom table exhaustion vectors (7 locations in live code)
    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom in OrganizationsLive.update_form",
        "organizations_live.ex:73 — user-controlled 'field' param passed to String.to_existing_atom. "
        "Use a Map.has_key? check against @form_fields string list or an allowlist map instead.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom for tier in OrganizationsLive",
        "organizations_live.ex:111 — form_data.tier fed into String.to_existing_atom when saving. "
        "Replace with a case/Map lookup against known tier atoms.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom in ProjectsLive.update_form",
        "projects_live.ex:75 — same pattern as OrganizationsLive. User-supplied field name → atom. "
        "Use allowlist map %{\"title\" => :title, ...} instead.",
        file_path="lib/custyard_web/live/operator/projects_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom in ConversationLive.set_state",
        "conversation_live.ex:133 — user-supplied state string converted to atom. "
        "Use case or Map.fetch against known states [:new, :active, :resolved, :dormant].",
        file_path="lib/custyard_web/live/operator/conversation_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom for urgency in NewRequestLive",
        "new_request_live.ex:30 — portal user can supply arbitrary urgency param. "
        "Validate against [:normal, :elevated, :urgent] before converting.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom in SieveHeaderMapper (3 call sites)",
        "sieve_header_mapper.ex:97,111,115 — email header values from external mail converted to atoms. "
        "A crafted email with novel header values can exhaust the atom table. "
        "Use string matching or a lookup map for known sieve properties/values.",
        file_path="lib/custyard/email/sieve_header_mapper.ex",
        mutex_group="atom-exhaustion")

    add(conn, bugs, "P1",
        "Atom exhaustion: String.to_existing_atom in Settings.get_weights/get_neglect_thresholds",
        "settings.ex:59,75 — settings keys converted to atoms. Has rescue clause but still creates atoms "
        "before failing. Use allowlist approach instead of rescue-after-creation.",
        file_path="lib/custyard/settings.ex",
        mutex_group="atom-exhaustion")

    # Crash-on-failure patterns (Repo.insert!)
    add(conn, bugs, "P1",
        "Crash on failure: Repo.insert! in NewRequestLive message creation",
        "new_request_live.ex:43 — after inserting conversation (correctly with Repo.insert), the message "
        "is inserted with Repo.insert! which crashes the LiveView on validation failure. "
        "Use Repo.insert and handle {:error, changeset}.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex",
        mutex_group="insert-bang")

    add(conn, bugs, "P1",
        "Crash on failure: Repo.insert! in Email.Processor",
        "processor.ex:127 — message Repo.insert! in process_email. If message validation fails "
        "(e.g., missing body), the entire email processing pipeline crashes. Use Repo.insert.",
        file_path="lib/custyard/email/processor.ex",
        mutex_group="insert-bang")

    add(conn, bugs, "P1",
        "Crash on failure: Repo.insert! in Conversations.create_message!",
        "conversations.ex:221 — public API function that always raises. Either rename to make bang "
        "semantics explicit and add a non-bang version, or switch to {:ok, _}/{:error, _}.",
        file_path="lib/custyard/conversations.ex",
        mutex_group="insert-bang")

    add(conn, bugs, "P1",
        "Crash on failure: Repo.insert! in Settings module",
        "settings.ex:201 — settings initialization uses Repo.insert! which crashes on constraint "
        "violation (e.g., duplicate key). Use Repo.insert with on_conflict handling.",
        file_path="lib/custyard/settings.ex",
        mutex_group="insert-bang")

    add(conn, bugs, "P1",
        "Crash on startup: Repo.insert! in Application.start",
        "application.ex:106 — app startup code uses Repo.insert!. If the seed data already exists "
        "or constraints are violated, the entire application fails to start. "
        "Use upsert/on_conflict or Repo.insert with error handling.",
        file_path="lib/custyard/application.ex",
        mutex_group="insert-bang")

    # Auth/access gaps
    add(conn, bugs, "P1",
        "Webhook endpoint has no authentication or rate limiting",
        "POST /api/webhook/inbound accepts any request with no auth check, no HMAC signature "
        "verification, and no rate limiting. An attacker can spam fake emails into the system. "
        "Add webhook secret verification and rate limiting.",
        file_path="lib/custyard_web/controllers/webhook_controller.ex",
        exec_order=-5)

    add(conn, bugs, "P1",
        "Operator ConversationLive: no org-scoping (IDOR)",
        "conversation_live.ex mount loads conversation by ID with no check that it belongs to the "
        "operator's org. Any authenticated operator can view/modify any conversation by changing the URL ID. "
        "Add org-scoping check in mount.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex",
        exec_order=-5)

    # ========================================================================
    # BUGS — P2 (26 tasks)
    # ========================================================================

    add(conn, bugs, "P2",
        "PortalAuth plug defined but not wired into portal routes",
        "PortalAuth validates org_token and returns 404 for invalid tokens, but the portal scope "
        "in router.ex doesn't pipe through it. Portal LiveViews call Helpers.get_organization instead, "
        "which raises on invalid tokens (info disclosure). Wire PortalAuth into the portal pipeline.",
        file_path="lib/custyard_web/router.ex",
        files="lib/custyard_web/plugs/portal_auth.ex;lib/custyard_web/router.ex")

    add(conn, bugs, "P2",
        "Custom domain plug: host header not validated against allowlist",
        "custom_domain.ex does Repo.get_by(Organization, custom_domain: host) using the raw Host header. "
        "While not directly exploitable for injection (Ecto parameterizes), it allows scanning for valid "
        "custom domains. Consider logging suspicious lookups and rate-limiting.",
        file_path="lib/custyard_web/plugs/custom_domain.ex")

    add(conn, bugs, "P2",
        "Email HTML injection: message body rendered without sanitization",
        "If email body contains HTML/script tags, it may be rendered unsafely in operator views. "
        "While HEEx auto-escapes in templates, check all raw/Phoenix.HTML.raw usage in conversation views.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, bugs, "P2",
        "LMTP server: error responses leak internal hostnames and paths",
        "LMTP error responses include internal server details (hostname, module paths) that aid "
        "reconnaissance. Sanitize error messages to return generic SMTP codes without internal info.",
        file_path="lib/custyard/email/lmtp_server.ex")

    add(conn, bugs, "P2",
        "Parser resource exhaustion: no size limits on email parsing",
        "Email parser accepts arbitrarily large messages without size checks. A large attachment or "
        "deeply nested MIME structure could consume excessive memory. Add size limits.",
        file_path="lib/custyard/email/parser.ex")

    add(conn, bugs, "P2",
        "Release.setup_operator may fail silently or crash",
        "If the Release module's operator setup function encounters an existing operator or invalid "
        "data, the error handling path is incomplete. Verify all branches return useful results.",
        file_path="lib/custyard/release.ex")

    add(conn, bugs, "P2",
        "Org creation crashes when only Name field is filled",
        "Browser testing: submitting the org creation form with only the Name field filled and all "
        "others empty crashes the LiveView. The changeset validation should catch missing fields "
        "before reaching the insert path.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, bugs, "P2",
        "Webhook returns 500 on empty JSON body",
        "POST /api/webhook/inbound with {} or empty body returns a 500 instead of a 422. "
        "The Processor.process function doesn't handle nil/empty params gracefully.",
        file_path="lib/custyard_web/controllers/webhook_controller.ex",
        files="lib/custyard_web/controllers/webhook_controller.ex;lib/custyard/email/processor.ex")

    add(conn, bugs, "P2",
        "Invalid portal token shows Ecto.NoResultsError with stack trace",
        "Visiting /p/invalid-token exposes an Ecto.NoResultsError with file paths and line numbers. "
        "Wire PortalAuth plug or add proper error handling in portal LiveViews.",
        file_path="lib/custyard_web/live/portal/helpers.ex",
        files="lib/custyard_web/live/portal/helpers.ex;lib/custyard_web/router.ex")

    add(conn, bugs, "P2",
        "Portal requests created with no customer identification",
        "NewRequestLive creates conversations with sender_email 'portal@{domain}' — all portal "
        "requests appear as from 'Unknown'. Add optional name/email fields to the portal form.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex")

    add(conn, bugs, "P2",
        "Processor.process assumes all required map keys exist",
        "Email processor accesses parsed.from, parsed.body etc. without checking for nil. "
        "Malformed webhook payloads will cause KeyError/FunctionClauseError.",
        file_path="lib/custyard/email/processor.ex")

    add(conn, bugs, "P2",
        "Conversations.update_conversation does not validate state transitions",
        "Any state can transition to any other state. Add a state machine guard to prevent "
        "invalid transitions like resolved → new.",
        file_path="lib/custyard/conversations.ex")

    add(conn, bugs, "P2",
        "PubSub broadcast in NewRequestLive uses generic topic",
        "Broadcasting to 'conversations' topic means all connected operators receive all conversation "
        "events regardless of org. Should be scoped to 'conversations:org:{org_id}'.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex",
        files="lib/custyard_web/live/portal/new_request_live.ex;lib/custyard_web/live/operator/attention_queue_live.ex")

    add(conn, bugs, "P2",
        "Scoring.calculate_and_cache may raise on missing conversation",
        "If conversation is deleted between creation and scoring, the function will crash. "
        "Add nil check or rescue.",
        file_path="lib/custyard/scoring.ex")

    add(conn, bugs, "P2",
        "Email processor Repo.update! in maybe_reactivate",
        "processor.ex maybe_reactivate uses Repo.update! which crashes on failure. "
        "Use Repo.update with error handling.",
        file_path="lib/custyard/email/processor.ex")

    add(conn, bugs, "P2",
        "Email processor Repo.update! in last_customer_action_at update",
        "processor.ex:133-134 uses Repo.update! for timestamp update. Replace with Repo.update.",
        file_path="lib/custyard/email/processor.ex")

    add(conn, bugs, "P2",
        "ConversationLive.mount pattern matches {:ok, updated} without error branch",
        "conversation_live.ex:20 — state transition in mount uses {:ok, _} = pattern. "
        "If update fails, crash occurs during mount. Add error handling.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, bugs, "P2",
        "Portal LiveViews don't scope conversations to org",
        "Portal ConversationLive should verify the conversation belongs to the current org. "
        "Without this check a user with one org token could access conversations from another org "
        "by manipulating the request ID in the URL.",
        file_path="lib/custyard_web/live/portal/conversation_live.ex")

    add(conn, bugs, "P2",
        "OrganizationsLive save_organization missing required field validation",
        "The save handler builds attrs from form_data but doesn't validate that required fields "
        "(name, tier) are present before calling changeset. Empty strings pass through.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, bugs, "P2",
        "Settings.get returns default on any exception (masks errors)",
        "Settings module rescues all errors and returns defaults, masking configuration bugs "
        "that should be surfaced during development.",
        file_path="lib/custyard/settings.ex")

    add(conn, bugs, "P2",
        "LMTP loop detection hostname regex not anchored",
        "lmtp_server.ex hostname matching in loop detection uses unanchored regex, which could "
        "match substrings of other hostnames and produce false positives.",
        file_path="lib/custyard/email/lmtp_server.ex")

    add(conn, bugs, "P2",
        "No CSRF protection on webhook endpoint",
        "The /api scope only plugs :accepts json, no CSRF token check. While expected for API "
        "endpoints, this combined with no auth means the endpoint is fully open.",
        file_path="lib/custyard_web/router.ex")

    add(conn, bugs, "P2",
        "ConversationLive handle_info for PubSub doesn't verify conversation ownership",
        "The handle_info callback for conversation updates reloads any conversation by ID "
        "without checking it belongs to the operator's scope.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, bugs, "P2",
        "No input length validation on form fields across LiveViews",
        "Form inputs for subject, body, name, domain etc. have no maxlength attributes or "
        "server-side length validation. Extremely long inputs could cause memory issues.",
        files="lib/custyard_web/live/portal/new_request_live.ex;lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, bugs, "P2",
        "Project form allows empty organization_id",
        "ProjectsLive save_project passes organization_id from form without validating it's a "
        "valid org reference. Empty string or non-existent ID would cause a constraint error.",
        file_path="lib/custyard_web/live/operator/projects_live.ex")

    add(conn, bugs, "P2",
        "Conversation state displayed as raw atom in UI",
        "States like :new, :active, :resolved are rendered as atoms rather than human-friendly "
        "labels. Minor but visible to operators.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    # ========================================================================
    # BUGS — P3 (24 tasks)
    # ========================================================================

    add(conn, bugs, "P3",
        "Conversations context has both create_message and create_message! — clarify API",
        "Having both bang and non-bang versions is fine but callers should consistently use the "
        "non-bang version for user-facing operations. Audit all callers.",
        file_path="lib/custyard/conversations.ex")

    add(conn, bugs, "P3",
        "Seeds file uses Repo.insert! — fails on re-run",
        "priv/repo/seeds.exs:30 uses Repo.insert! which crashes if seeds are run twice. "
        "Use upsert or ignore-on-conflict.",
        file_path="priv/repo/seeds.exs")

    add(conn, bugs, "P3",
        "Email parser should validate Content-Type before processing",
        "Parser processes any Content-Type without checking for expected MIME types first.",
        file_path="lib/custyard/email/parser.ex")

    add(conn, bugs, "P3",
        "LMTP TLS: verify certificate validation settings",
        "Ensure LMTP server TLS configuration validates certificates properly and doesn't accept "
        "self-signed certs in production.",
        file_path="lib/custyard/email/lmtp_server.ex")

    add(conn, bugs, "P3",
        "Scoring module should document weight formula",
        "Score calculation uses weights from settings but the formula isn't documented. "
        "Add @moduledoc or inline comments explaining the algorithm.",
        file_path="lib/custyard/scoring.ex")

    add(conn, bugs, "P3",
        "Organization changeset: domain field not validated as domain format",
        "Organization.changeset casts :domain but doesn't validate format. "
        "Invalid domains like 'not a domain' would be accepted.",
        file_path="lib/custyard/organization.ex")

    add(conn, bugs, "P3",
        "Conversation.state_changeset doesn't validate allowed states",
        "The state changeset accepts any atom as a state value. Should validate against "
        "the known state enum.",
        file_path="lib/custyard/conversation.ex")

    add(conn, bugs, "P3",
        "Message changeset: source field not validated against enum",
        "Message.changeset casts :source but doesn't validate it's one of [:email, :portal, :operator]. "
        "Invalid sources would be silently accepted.",
        file_path="lib/custyard/message.ex")

    add(conn, bugs, "P3",
        "Missing index on conversations.organization_id",
        "If not already present, add an index for org-scoped queries in the attention queue.",
        file_path="priv/repo/migrations/")

    add(conn, bugs, "P3",
        "Missing index on messages.conversation_id",
        "Query performance for loading conversation messages. Check if index exists.",
        file_path="priv/repo/migrations/")

    add(conn, bugs, "P3",
        "Email processor: detect_urgency uses simple string matching",
        "The urgency detection in processor.ex is naive — String.downcase + contains? check. "
        "Could produce false positives on common words. Consider improving or documenting limitations.",
        file_path="lib/custyard/email/processor.ex")

    add(conn, bugs, "P3",
        "Settings module: @default_weights should match DB schema keys",
        "If default weight keys drift from the actual score_weights keys in the DB, the rescue "
        "clause hides the mismatch. Add a compile-time check or test.",
        file_path="lib/custyard/settings.ex")

    add(conn, bugs, "P3",
        "Release module should log setup actions",
        "Setup functions should use Logger to record what they did for operational visibility.",
        file_path="lib/custyard/release.ex")

    add(conn, bugs, "P3",
        "Application.start: seed data should use a migration or dedicated seed module",
        "Inline Repo operations in start/2 make the boot path fragile. Move to a proper seed module.",
        file_path="lib/custyard/application.ex")

    add(conn, bugs, "P3",
        "Organizations context: verify_custom_domain DNS lookup has no timeout",
        "DNS lookup could hang indefinitely. Add a timeout to the resolution call.",
        file_path="lib/custyard/organizations.ex")

    add(conn, bugs, "P3",
        "NeglectReportLive: verify query efficiency for large conversation sets",
        "The neglect report may scan all conversations. Ensure proper indexing and pagination.",
        file_path="lib/custyard_web/live/operator/neglect_report_live.ex")

    add(conn, bugs, "P3",
        "Test factory uses Repo.insert! — consider returning {:ok, _} tuples",
        "Factory functions all use Repo.insert! which gives poor error messages on setup failures. "
        "Not critical but would improve DX.",
        file_path="test/support/factory.ex")

    add(conn, bugs, "P3",
        "Email processor: no deduplication for message_id",
        "If the same email is received twice (e.g., retry), a duplicate message is created. "
        "Add a unique constraint on message_id and handle conflicts.",
        file_path="lib/custyard/email/processor.ex")

    add(conn, bugs, "P3",
        "ConversationLive add_note handler is a no-op",
        "conversation_live.ex:121 — handle_event('add_note') just returns {:noreply, socket}. "
        "Either implement or remove the dead handler.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, bugs, "P3",
        "Conversation changeset: last_customer_action_at should default to now",
        "If not set explicitly, conversations may have nil timestamps which break sorting in "
        "the attention queue.",
        file_path="lib/custyard/conversation.ex")

    add(conn, bugs, "P3",
        "Portal helpers: raise on missing org is poor UX",
        "helpers.ex:23 raises RuntimeError on missing org for custom domains. "
        "Should return a user-friendly error page instead.",
        file_path="lib/custyard_web/live/portal/helpers.ex")

    add(conn, bugs, "P3",
        "LMTP: charset handling for non-UTF8 emails",
        "Verify that non-UTF8 encoded emails (ISO-8859-1, etc.) are properly transcoded "
        "before storage. Mojibake in conversation views is a poor experience.",
        file_path="lib/custyard/email/lmtp_server.ex")

    add(conn, bugs, "P3",
        "PubSub topic naming inconsistency",
        "Some broadcasts use 'conversations' (plural) and some use 'conversation:{id}'. "
        "Standardize naming convention.",
        files="lib/custyard_web/live/operator/conversation_live.ex;lib/custyard_web/live/portal/new_request_live.ex")

    add(conn, bugs, "P3",
        "Task model: due_at field validation",
        "Conversation tasks should validate due_at is in the future and is a valid datetime.",
        file_path="lib/custyard/task.ex")

    # ========================================================================
    # FRONTEND — P1 (15 tasks)
    # ========================================================================

    add(conn, frontend, "P1",
        "OrganizationsLive: replace String.to_existing_atom with allowlist map",
        "Replace the atom conversion pattern in update_form with a compile-time map: "
        "%{\"name\" => :name, \"domain\" => :domain, ...}. Apply to both the field handler (L73) "
        "and the tier handler (L111).",
        file_path="lib/custyard_web/live/operator/organizations_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, frontend, "P1",
        "ProjectsLive: replace String.to_existing_atom with allowlist map",
        "Same pattern as OrganizationsLive. Convert the field lookup (L75) to use a map.",
        file_path="lib/custyard_web/live/operator/projects_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, frontend, "P1",
        "ConversationLive: replace String.to_existing_atom with state validation",
        "Replace atom conversion at L133 with case on known states. "
        "E.g., case state do \"active\" -> :active; \"resolved\" -> :resolved; ... end.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, frontend, "P1",
        "NewRequestLive: validate urgency against known values before atom conversion",
        "Replace String.to_existing_atom at L30 with: "
        "Map.get(%{\"normal\" => :normal, \"elevated\" => :elevated, \"urgent\" => :urgent}, urgency, :normal).",
        file_path="lib/custyard_web/live/portal/new_request_live.ex",
        mutex_group="atom-exhaustion")

    add(conn, frontend, "P1",
        "NewRequestLive: Repo.insert! on message creation can crash LiveView",
        "L43: replace Repo.insert!() with Repo.insert() and handle error case. "
        "On failure, set flash error and stay on form.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex",
        mutex_group="insert-bang")

    add(conn, frontend, "P1",
        "ConversationLive mount: handle update failure in state transition",
        "L20: {:ok, updated} = ... crashes if update fails. "
        "Wrap in case and handle {:error, _} by keeping existing conversation.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P1",
        "AttentionQueueLive: verify error handling for empty/failed queries",
        "If the attention queue query returns an error or the scoring cache is empty, "
        "the LiveView should show an empty state rather than crash.",
        file_path="lib/custyard_web/live/operator/attention_queue_live.ex")

    add(conn, frontend, "P1",
        "SettingsLive: verify form submission error handling",
        "Settings LiveView should handle validation errors gracefully, showing field-level "
        "errors rather than crashing on invalid weight/threshold values.",
        file_path="lib/custyard_web/live/operator/settings_live.ex")

    add(conn, frontend, "P1",
        "Portal ConversationLive: handle missing/deleted conversation",
        "If a portal user navigates to a deleted conversation, the LiveView should show a "
        "friendly message rather than an Ecto.NoResultsError.",
        file_path="lib/custyard_web/live/portal/conversation_live.ex")

    add(conn, frontend, "P1",
        "Portal ProjectLive: handle missing project gracefully",
        "Same pattern — Repo.get! in mount should be replaced with Repo.get + redirect.",
        file_path="lib/custyard_web/live/portal/project_live.ex")

    add(conn, frontend, "P1",
        "Custom domain views: portal_path incompatible with custom domains",
        "Portal views that build URLs using portal_path may generate incorrect paths when "
        "accessed via custom domain. Verify all navigate/patch calls in portal LiveViews.",
        files="lib/custyard_web/live/portal/conversation_live.ex;lib/custyard_web/live/portal/request_list_live.ex;lib/custyard_web/live/portal/helpers.ex")

    add(conn, frontend, "P1",
        "OrganizationsLive: save_organization crashes on changeset error",
        "If Org changeset returns error (e.g., duplicate domain), the handler should show "
        "flash error, not crash. Verify the update/insert path handles {:error, changeset}.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, frontend, "P1",
        "ProjectsLive: save_project crashes on changeset error",
        "Same pattern as organizations — verify save_project handles {:error, changeset}.",
        file_path="lib/custyard_web/live/operator/projects_live.ex")

    add(conn, frontend, "P1",
        "ConversationLive add_task: verify error handling for task creation",
        "The add_task handler should handle validation failures (missing title, past due date) "
        "gracefully rather than crashing.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P1",
        "HomeLive: bare page with no navigation or content",
        "HomeLive renders at / but provides no navigation to operator or portal areas. "
        "Either redirect to operator login or provide a landing page with links.",
        file_path="lib/custyard_web/live/home_live.ex")

    # ========================================================================
    # FRONTEND — P2 (33 tasks)
    # ========================================================================

    add(conn, frontend, "P2",
        "Submit buttons missing phx-disable-with across all forms",
        "Only 1 occurrence of phx-disable-with found in core_components.ex. All form submit "
        "buttons in LiveViews should have phx-disable-with to prevent double-submit.",
        files="lib/custyard_web/live/portal/new_request_live.ex;lib/custyard_web/live/operator/organizations_live.ex;lib/custyard_web/live/operator/projects_live.ex;lib/custyard_web/live/operator/conversation_live.ex;lib/custyard_web/live/operator/settings_live.ex")

    add(conn, frontend, "P2",
        "Missing label for= associations in OrganizationsLive form",
        "Labels use <label> but without for= attributes tied to input IDs. "
        "Screen readers can't associate labels with fields.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, frontend, "P2",
        "Missing label for= associations in ProjectsLive form",
        "Same a11y issue as OrganizationsLive — labels not connected to inputs.",
        file_path="lib/custyard_web/live/operator/projects_live.ex")

    add(conn, frontend, "P2",
        "Missing label for= associations in SettingsLive form",
        "Weight and threshold inputs need proper label associations.",
        file_path="lib/custyard_web/live/operator/settings_live.ex")

    add(conn, frontend, "P2",
        "Missing label for= associations in NewRequestLive form",
        "Portal form labels not connected to inputs via for= attribute.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex")

    add(conn, frontend, "P2",
        "Missing label for= associations in ConversationLive reply form",
        "Reply/note text areas need associated labels for a11y.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "Operator nav: Projects link missing from sidebar/nav",
        "Browser testing confirmed /operator/projects exists and works but has no link in "
        "the operator navigation. Add to the nav component.",
        files="lib/custyard_web/live/operator/attention_queue_live.ex;lib/custyard_web/components/layouts/")

    add(conn, frontend, "P2",
        "No confirmation dialog before Mark Resolved action",
        "Clicking 'Mark resolved' immediately changes state with no undo. "
        "Add a phx-confirm or modal confirmation.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "No Reopen action for resolved conversations",
        "Once a conversation is resolved, there's no UI to reopen it. "
        "Add a 'Reopen' button that transitions state back to :active.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "Duplicate component definitions across modules",
        "Multiple LiveView modules define similar helper components (status badges, form fields). "
        "Extract to shared components in core_components.ex or a dedicated component module.",
        files="lib/custyard_web/live/operator/conversation_live.ex;lib/custyard_web/live/operator/attention_queue_live.ex;lib/custyard_web/live/operator/organizations_live.ex;lib/custyard_web/live/operator/projects_live.ex;lib/custyard_web/components/core_components.ex")

    add(conn, frontend, "P2",
        "AttentionQueueLive: no empty state when no conversations exist",
        "When there are zero conversations, the page should show a helpful empty state message "
        "rather than just an empty table/list.",
        file_path="lib/custyard_web/live/operator/attention_queue_live.ex")

    add(conn, frontend, "P2",
        "Portal RequestListLive: no empty state message",
        "Portal request list shows nothing when org has no conversations. Add empty state.",
        file_path="lib/custyard_web/live/portal/request_list_live.ex")

    add(conn, frontend, "P2",
        "Portal ProjectsListLive: no empty state for organizations without projects",
        "Show a message like 'No projects yet' when the project list is empty.",
        file_path="lib/custyard_web/live/portal/projects_list_live.ex")

    add(conn, frontend, "P2",
        "NeglectReportLive: missing loading state",
        "If the report takes time to compute, show a loading indicator rather than blank screen.",
        file_path="lib/custyard_web/live/operator/neglect_report_live.ex")

    add(conn, frontend, "P2",
        "OrganizationsLive: no loading state during save",
        "Save operation should show a loading/saving indicator. Without it, users may click "
        "repeatedly (especially without phx-disable-with).",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, frontend, "P2",
        "ConversationLive: reply form should clear after send",
        "Verify the reply_text and note_text assigns are cleared after successful send.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "ConversationLive: message timestamps not formatted for locale",
        "Message timestamps should be displayed in a human-friendly format, not raw ISO 8601.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "Portal views: no breadcrumb or back navigation",
        "Portal users can navigate into a conversation but have no breadcrumb trail or "
        "back button to return to the request list.",
        files="lib/custyard_web/live/portal/conversation_live.ex;lib/custyard_web/live/portal/project_live.ex")

    add(conn, frontend, "P2",
        "Color inputs: primary/secondary color fields should be color pickers",
        "OrganizationsLive has text inputs for colors. Use <input type='color'> for better UX.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, frontend, "P2",
        "Form validation feedback: no inline error messages",
        "When form fields are invalid, there's no visible error message next to the field. "
        "Add phx-feedback-for and error display components.",
        files="lib/custyard_web/live/operator/organizations_live.ex;lib/custyard_web/live/operator/projects_live.ex")

    add(conn, frontend, "P2",
        "Portal conversation: no indication of urgency level",
        "The portal conversation view doesn't display the urgency level set during creation.",
        file_path="lib/custyard_web/live/portal/conversation_live.ex")

    add(conn, frontend, "P2",
        "Operator nav: active route not highlighted",
        "Navigation links don't indicate which page the operator is currently on.",
        files="lib/custyard_web/components/layouts/")

    add(conn, frontend, "P2",
        "ConversationLive: task list has no visual priority/status indicators",
        "Tasks listed in a conversation should show their status and due date visually.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "AttentionQueueLive: no pagination for large conversation lists",
        "With many conversations, the attention queue renders everything. Add pagination or "
        "virtual scrolling.",
        file_path="lib/custyard_web/live/operator/attention_queue_live.ex")

    add(conn, frontend, "P2",
        "SettingsLive: no visual feedback on successful save",
        "After saving settings, there's no flash message or visual confirmation.",
        file_path="lib/custyard_web/live/operator/settings_live.ex")

    add(conn, frontend, "P2",
        "Portal forms: subject and body inputs missing maxlength attribute",
        "HTML inputs should have maxlength to prevent extremely long submissions client-side.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex")

    add(conn, frontend, "P2",
        "OrganizationsLive: org list has no search/filter",
        "With many organizations, operators need a way to filter the list.",
        file_path="lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, frontend, "P2",
        "Textarea in NewRequestLive uses non-standard resize handling",
        "The textarea has resize-none class. Consider allowing vertical resize for "
        "long descriptions.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex")

    add(conn, frontend, "P2",
        "ConversationLive: internal notes not visually distinguished from replies",
        "Internal notes should have a distinct visual style (background color, icon) to prevent "
        "operators from confusing notes with customer-visible replies.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "ProjectLive: project detail view may be sparse",
        "Portal project view should show associated conversations/requests for context.",
        file_path="lib/custyard_web/live/portal/project_live.ex")

    add(conn, frontend, "P2",
        "Missing ARIA roles on interactive elements",
        "Buttons used for state changes, modal toggles, and tab-like navigation lack "
        "appropriate ARIA roles and labels.",
        files="lib/custyard_web/live/operator/conversation_live.ex;lib/custyard_web/live/operator/organizations_live.ex")

    add(conn, frontend, "P2",
        "Focus management: modals and forms don't trap focus",
        "When org edit form or task form opens, focus should move to the first field "
        "and trap within the form for keyboard users.",
        files="lib/custyard_web/live/operator/organizations_live.ex;lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, frontend, "P2",
        "Keyboard navigation: no visible focus indicators",
        "Default browser focus rings may be suppressed by Tailwind reset. "
        "Ensure focus:ring styles are applied to all interactive elements.",
        files="lib/custyard_web/live/portal/new_request_live.ex;lib/custyard_web/live/operator/organizations_live.ex")

    # ========================================================================
    # FRONTEND — P3 (35 tasks)
    # ========================================================================

    p3_frontend_tasks = [
        ("Extract status badge component from ConversationLive",
         "Status badges (new/active/resolved/dormant) are defined inline. Extract to a "
         "shared component.",
         "lib/custyard_web/live/operator/conversation_live.ex"),
        ("Extract urgency badge component",
         "Urgency display is duplicated. Create a shared urgency badge component.",
         "lib/custyard_web/live/operator/attention_queue_live.ex"),
        ("Extract org tier badge component",
         "Tier badges appear in multiple views. Consolidate.",
         "lib/custyard_web/live/operator/organizations_live.ex"),
        ("Extract form input component with label and error display",
         "Create a reusable form input component that handles label, input, and error message.",
         "lib/custyard_web/components/core_components.ex"),
        ("Extract datetime formatting helper",
         "Timestamp formatting appears in multiple LiveViews. Create a shared helper.",
         "lib/custyard_web/live/operator/conversation_live.ex"),
        ("Portal layout: add org branding (name, colors) to portal views",
         "Portal views should use org primary_color and display the org name.",
         "lib/custyard_web/live/portal/"),
        ("Portal layout: favicon from org branding",
         "Custom domain portals should serve the org's branding, not default favicon.",
         "lib/custyard_web/live/portal/"),
        ("ConversationLive: long message bodies not truncated in list view",
         "In the attention queue, long subjects/preview text should be truncated.",
         "lib/custyard_web/live/operator/attention_queue_live.ex"),
        ("Responsive design: operator views not tested on small screens",
         "Verify operator LiveViews work on tablet-sized screens. Add responsive breakpoints.",
         "lib/custyard_web/live/operator/"),
        ("Responsive design: portal views need mobile optimization",
         "Portal is customer-facing and likely accessed on mobile. Test and fix responsive layout.",
         "lib/custyard_web/live/portal/"),
        ("Dark mode: no dark mode support",
         "Add dark mode variant classes for operator interface.",
         "lib/custyard_web/live/operator/"),
        ("OrganizationsLive: logo upload preview",
         "The logo upload form should show a preview of the uploaded image.",
         "lib/custyard_web/live/operator/organizations_live.ex"),
        ("ConversationLive: add message sender avatar/initials",
         "Messages should show sender identity visually (avatar or initials circle).",
         "lib/custyard_web/live/operator/conversation_live.ex"),
        ("AttentionQueueLive: add sort options (by urgency, age, score)",
         "Operators should be able to sort the attention queue by different criteria.",
         "lib/custyard_web/live/operator/attention_queue_live.ex"),
        ("NeglectReportLive: add export/download option",
         "Allow operators to export the neglect report as CSV.",
         "lib/custyard_web/live/operator/neglect_report_live.ex"),
        ("Portal: add conversation status filter",
         "Portal users should be able to filter requests by status (open/resolved).",
         "lib/custyard_web/live/portal/request_list_live.ex"),
        ("Consistent use of data-testid attributes",
         "Some views have comprehensive test IDs, others have none. Standardize.",
         "lib/custyard_web/live/"),
        ("Error boundary: add LiveView error boundary to prevent full-page crashes",
         "A component error shouldn't take down the entire page. Add error boundaries.",
         "lib/custyard_web/"),
        ("Loading skeletons for LiveView async operations",
         "Replace blank loading states with skeleton loaders for better perceived performance.",
         "lib/custyard_web/live/"),
        ("ConversationLive: add auto-scroll to newest message",
         "When new messages arrive via PubSub, the view should scroll to the latest message.",
         "lib/custyard_web/live/operator/conversation_live.ex"),
        ("Portal ConversationLive: add typing indicator or message status",
         "Portal users should see that their message was received.",
         "lib/custyard_web/live/portal/conversation_live.ex"),
        ("Clean up unused CSS classes",
         "Audit for Tailwind classes that aren't actually applied or are redundant.",
         "lib/custyard_web/"),
        ("Consistent spacing and padding across views",
         "Some views use py-8 px-4, others use different spacing. Standardize.",
         "lib/custyard_web/live/"),
        ("Add page titles to all LiveViews",
         "Verify all LiveViews set :page_title for browser tab display.",
         "lib/custyard_web/live/"),
        ("OrganizationsLive: inline edit should have cancel confirmation",
         "If user has unsaved changes and clicks cancel, warn before discarding.",
         "lib/custyard_web/live/operator/organizations_live.ex"),
        ("Portal: add request creation confirmation page",
         "After submitting a request, show a confirmation with the request ID.",
         "lib/custyard_web/live/portal/new_request_live.ex"),
        ("ConversationLive: add keyboard shortcut for reply (Ctrl+Enter)",
         "Power users should be able to submit replies with keyboard shortcut.",
         "lib/custyard_web/live/operator/conversation_live.ex"),
        ("Consistent button styles across operator views",
         "Some buttons use bg-indigo-600, others may use different styles. Use core_components button.",
         "lib/custyard_web/live/operator/"),
        ("Portal: show org contact info or help text",
         "Portal pages should show the org's support contact information.",
         "lib/custyard_web/live/portal/"),
        ("SettingsLive: group related settings visually",
         "Weight settings and threshold settings should be in distinct visual sections.",
         "lib/custyard_web/live/operator/settings_live.ex"),
        ("Add tooltip or help text for score weights",
         "Operators may not know what each weight means. Add help text.",
         "lib/custyard_web/live/operator/settings_live.ex"),
        ("ConversationLive: show conversation age/duration",
         "Display how long ago the conversation was created and time since last action.",
         "lib/custyard_web/live/operator/conversation_live.ex"),
        ("Optimize PubSub: reduce unnecessary re-renders",
         "Handle_info for PubSub events should only re-render if data actually changed.",
         "lib/custyard_web/live/operator/attention_queue_live.ex"),
        ("Add meta tags for portal pages (SEO/social)",
         "Portal pages accessible via custom domain should have proper meta tags.",
         "lib/custyard_web/live/portal/"),
        ("Flash messages: auto-dismiss after timeout",
         "Flash messages should auto-dismiss after 5 seconds with a progress bar.",
         "lib/custyard_web/components/layouts/"),
    ]

    for title, desc, path in p3_frontend_tasks:
        add(conn, frontend, "P3", title, desc, file_path=path)

    # ========================================================================
    # UX — P1 (1 task)
    # ========================================================================

    add(conn, ux, "P1",
        "Home page (/) has zero navigation to any functional area",
        "The root path renders HomeLive with no links to operator login, portal, or any "
        "useful destination. Users who land here are stuck. Either redirect to operator "
        "login or provide a proper landing page.",
        file_path="lib/custyard_web/live/home_live.ex",
        exec_order=-3)

    # ========================================================================
    # UX — P2 (3 tasks)
    # ========================================================================

    add(conn, ux, "P2",
        "No visual feedback when conversation state changes",
        "State changes (mark resolved, set active) happen silently. Add a flash message or "
        "visual transition to confirm the action.",
        file_path="lib/custyard_web/live/operator/conversation_live.ex")

    add(conn, ux, "P2",
        "Operator workflow: no bulk actions for conversations",
        "Operators handling many conversations need bulk operations (select multiple, "
        "mark all resolved, assign to project).",
        file_path="lib/custyard_web/live/operator/attention_queue_live.ex")

    add(conn, ux, "P2",
        "Portal: no indication of expected response time",
        "After submitting a request, portal users have no idea when to expect a response. "
        "Show SLA or expected response time based on org tier.",
        file_path="lib/custyard_web/live/portal/new_request_live.ex")

    # ========================================================================
    # UX — P3 (4 tasks)
    # ========================================================================

    add(conn, ux, "P3",
        "Operator onboarding: no guided setup for new installations",
        "A new Custyard deployment has no guided setup. Consider a setup wizard that "
        "creates the first org and configures basic settings.",
        file_path="lib/custyard/release.ex")

    add(conn, ux, "P3",
        "Portal: no search functionality for past requests",
        "Customers with many requests need a way to search by subject or keyword.",
        file_path="lib/custyard_web/live/portal/request_list_live.ex")

    add(conn, ux, "P3",
        "Operator dashboard: no metrics or summary statistics",
        "Operators would benefit from seeing conversation counts, avg response time, "
        "and neglect score distribution at a glance.",
        file_path="lib/custyard_web/live/operator/attention_queue_live.ex")

    add(conn, ux, "P3",
        "No keyboard shortcuts documentation or help panel",
        "If keyboard shortcuts exist, they need to be discoverable. Add a ? shortcut "
        "or help panel listing available shortcuts.",
        file_path="lib/custyard_web/live/operator/")

    conn.commit()
    conn.close()

    # Verify counts
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute("""
        SELECT c.slug, t.priority, COUNT(*)
        FROM tasks t JOIN categories c ON t.category_id = c.id
        GROUP BY c.slug, t.priority
        ORDER BY c.slug, t.priority
    """).fetchall()

    total = 0
    print("\nTask DB populated:")
    print(f"{'Category':<12} {'Priority':<8} {'Count':>5}")
    print("-" * 28)
    for slug, pri, cnt in rows:
        print(f"{slug:<12} {pri:<8} {cnt:>5}")
        total += cnt
    print("-" * 28)
    print(f"{'Total':<21} {total:>5}")
    conn.close()


if __name__ == "__main__":
    main()

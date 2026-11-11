CREATE TABLE "organizations" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" TEXT NOT NULL,
  "domain" TEXT,
  "tier" TEXT DEFAULT 'standard' NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id),
  identity_kind TEXT NOT NULL DEFAULT 'manual' CHECK(identity_kind IN ('domain','email','manual')),
  identity_value TEXT NOT NULL
);

CREATE TABLE "contacts" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "organization_id" INTEGER NOT NULL ,
  "email" TEXT NOT NULL,
  "name" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "email_status" TEXT DEFAULT 'valid' NOT NULL,
  "email_status_at" TEXT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT contacts_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "messages" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "thread_id" INTEGER NOT NULL ,
  "source" TEXT NOT NULL,
  "sender_email" TEXT,
  "body" TEXT NOT NULL,
  "is_internal_note" INTEGER DEFAULT false NOT NULL,
  "message_id" TEXT,
  "in_reply_to" TEXT,
  "inserted_at" TEXT NOT NULL,
  "origin" TEXT,
  "lettermint_message_id" TEXT,
  "updated_at" TEXT,
  "delivery_status" TEXT,
  "deleted_at" TEXT,
  "deleted_by_staff_id" INTEGER ,
  "provider_delivery_id" TEXT,
  "inbound_channel_id" INTEGER ,
  "to_addresses" TEXT DEFAULT '[]',
  "cc_addresses" TEXT DEFAULT '[]',
  "reply_to" TEXT,
  "authentication" TEXT,
  "spam_score" NUMERIC,
  "triage_class" TEXT,
  "html_body" TEXT,
  "forwarded_by_staff_id" INTEGER ,
  "forwarded_by_email" TEXT,
  "delivery_failure_kind" TEXT,
  "delivery_error_code" TEXT,
  "delivery_attempted_at" TEXT,
  "delivery_payload_hash" TEXT,
  "delivery_recipients_locked" INTEGER DEFAULT false NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT messages_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE CASCADE,
  CONSTRAINT messages_deleted_by_staff_id_fkey FOREIGN KEY (tenant_id,deleted_by_staff_id) REFERENCES staff_accounts(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT messages_inbound_channel_id_fkey FOREIGN KEY (tenant_id,inbound_channel_id) REFERENCES inbound_channels(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT messages_forwarded_by_staff_id_fkey FOREIGN KEY (tenant_id,forwarded_by_staff_id) REFERENCES staff_accounts(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "projects" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "title" TEXT NOT NULL,
  "description" TEXT,
  "start_date" TEXT,
  "target_completion_date" TEXT,
  "portal_visible" INTEGER DEFAULT true NOT NULL,
  "organization_id" INTEGER ,
  "thread_id" INTEGER ,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "project_type" TEXT DEFAULT 'customer' NOT NULL,
  "tags" TEXT DEFAULT '[]',
  "is_template" INTEGER DEFAULT false NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id),
  CONSTRAINT projects_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT projects_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "settings" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "score_weights" TEXT NOT NULL,
  "neglect_thresholds" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "sieve_header_mappings" TEXT DEFAULT ('{}'),
  "intake_config" TEXT DEFAULT ('{}'),
  "branding" TEXT DEFAULT ('{}'),
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE
);

CREATE TABLE "inbound_route_webhooks" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "inbound_route_id" INTEGER NOT NULL CONSTRAINT "inbound_route_webhooks_inbound_route_id_fkey" REFERENCES "inbound_routes"("id") ON DELETE CASCADE,
  "lettermint_webhook_id" TEXT,
  "endpoint_url" TEXT,
  "purpose" TEXT NOT NULL,
  "enabled" INTEGER DEFAULT true NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL
);

CREATE TABLE "threads" (
  id INTEGER PRIMARY KEY,
  organization_id INTEGER ,
  contact_id INTEGER ,
  project_id INTEGER ,
  subject TEXT NOT NULL,
  state TEXT DEFAULT 'new' NOT NULL,
  urgency TEXT DEFAULT 'normal' NOT NULL,
  source TEXT DEFAULT 'email',
  cached_score INTEGER DEFAULT 0 NOT NULL,
  last_staff_action_at TEXT,
  last_customer_action_at TEXT,
  snoozed_until TEXT,
  last_neglect_notification TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  "intake_source_key" TEXT,
  "inbound_channel_id" INTEGER ,
  "suspect" INTEGER DEFAULT false NOT NULL,
  "language" TEXT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id),
  CONSTRAINT threads_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT threads_contact_id_fkey FOREIGN KEY (tenant_id,contact_id) REFERENCES contacts(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT threads_project_id_fkey FOREIGN KEY (tenant_id,project_id) REFERENCES projects(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT threads_inbound_channel_id_fkey FOREIGN KEY (tenant_id,inbound_channel_id) REFERENCES inbound_channels(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "audit_events" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "thread_id" INTEGER ,
  "event_type" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "message_id" TEXT,
  "payload" TEXT,
  "organization_id" INTEGER ,
  "project_id" INTEGER ,
  "inserted_at" TEXT NOT NULL,
  tenant_id INTEGER REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT audit_events_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT audit_events_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT audit_events_project_id_fkey FOREIGN KEY (tenant_id,project_id) REFERENCES projects(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT audit_events_tenant_required CHECK(tenant_id IS NOT NULL OR (thread_id IS NULL AND organization_id IS NULL AND project_id IS NULL AND event_type IN ('instance_admin_created','instance_admin_removed','installation_configured')))
);

CREATE TABLE "staff_accounts" (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL,
  password_hash TEXT,
  login_token TEXT,
  login_token_expires_at TEXT,
  role TEXT DEFAULT 'agent' NOT NULL,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  "session_claim" TEXT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  CHECK(role IN ('admin','agent'))
);

CREATE TABLE "prospects" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "thread_id" INTEGER NOT NULL ,
  "access_token_hash" TEXT NOT NULL,
  "email" TEXT,
  "notify_on_reply" INTEGER DEFAULT false NOT NULL,
  "email_captured_at" TEXT,
  "revoked_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT prospects_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE CASCADE
);

CREATE TABLE "intake_sources" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "key" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "mode" TEXT DEFAULT 'active' NOT NULL,
  "headline" TEXT,
  "intro_copy" TEXT,
  "questions" TEXT DEFAULT '[]',
  "enabled" INTEGER DEFAULT true NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "link_title" TEXT,
  "link_url" TEXT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id)
);

CREATE TABLE "slugs" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'claimed'
    CHECK (status IN ('claimed','confirmed','provisioned')),
  email TEXT NULL,
  thread_id INTEGER NULL ,
  organization_id INTEGER NULL ,
  confirmation_token_hash TEXT NULL,
  expires_at TEXT NULL,
  confirmed_at TEXT NULL,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CHECK ((status = 'provisioned') = (organization_id IS NOT NULL)),
  CONSTRAINT slugs_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT slugs_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "acknowledgment_organization_bindings" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "source" TEXT NOT NULL,
  "source_organization_id" TEXT NOT NULL,
  "organization_id" INTEGER NOT NULL ,
  "inserted_at" TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT acknowledgment_organization_bindings_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "acknowledgments" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "schema_version" INTEGER NOT NULL,
  "source" TEXT NOT NULL,
  "submission_id" TEXT NOT NULL,
  "source_organization_id" TEXT NOT NULL,
  "actor_id" TEXT NOT NULL,
  "actor_role" TEXT NOT NULL,
  "actor_type" TEXT NOT NULL,
  "statement_key" TEXT NOT NULL,
  "statement_version" TEXT NOT NULL,
  "statement_hash" TEXT NOT NULL,
  "acknowledged_at" TEXT NOT NULL,
  "statement_text" TEXT NOT NULL,
  "received_at" TEXT NOT NULL,
  "organization_id" INTEGER NOT NULL ,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT acknowledgments_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "message_attachments" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "message_id" INTEGER NOT NULL ,
  "filename" TEXT,
  "content_type" TEXT,
  "sniffed_type" TEXT,
  "size" INTEGER,
  "sha256" TEXT,
  "storage_path" TEXT,
  "content_id" TEXT,
  "state" TEXT NOT NULL,
  "skip_reason" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "position" INTEGER,
  "descriptor_hash" TEXT,
  "processing_token" TEXT,
  "processing_expires_at" TEXT,
  "batch_processing_token" TEXT,
  "batch_processing_expires_at" TEXT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT message_attachments_message_id_fkey FOREIGN KEY (tenant_id,message_id) REFERENCES messages(tenant_id,id) ON DELETE CASCADE
);

CREATE TABLE "message_recipient_statuses" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "message_id" INTEGER NOT NULL ,
  "address" TEXT NOT NULL,
  "role" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "status_at" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT message_recipient_statuses_message_id_fkey FOREIGN KEY (tenant_id,message_id) REFERENCES messages(tenant_id,id) ON DELETE CASCADE
);

CREATE TABLE "tenants" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  logo_url TEXT,
  primary_color TEXT,
  secondary_color TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','suspended'))
);

CREATE TABLE "inbound_routes" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "lettermint_route_id" TEXT,
  "callback_token" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "source" TEXT DEFAULT 'lettermint' NOT NULL,
  "from_address" TEXT,
  "lettermint_route_domain" TEXT,
  "lettermint_inbound_address" TEXT,
  "lettermint_custom_domain" TEXT,
  "lettermint_custom_domain_verified_at" TEXT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id),
  "lettermint_webhook_id" TEXT,
  "webhook_secret_ciphertext" TEXT,
  "webhook_verified_at" TEXT
);

CREATE TABLE "inbound_channels" (
  sending_domain TEXT,
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "inbound_route_id" INTEGER NOT NULL ,
  "public_address" TEXT NOT NULL,
  "display_name" TEXT,
  "ingress_local" TEXT NOT NULL,
  "ingress_token" TEXT NOT NULL,
  "previous_ingress_token" TEXT,
  "previous_token_expires_at" TEXT,
  "ingress_kind" TEXT DEFAULT 'forward' NOT NULL,
  "provider" TEXT,
  "state" TEXT DEFAULT 'draft' NOT NULL,
  "reply_from" TEXT DEFAULT 'public_address' NOT NULL,
  "sending_domain_status" TEXT,
  "sending_domain_checked_at" TEXT,
  "verification_code" TEXT,
  "verification_link" TEXT,
  "verification_captured_at" TEXT,
  "verification_expires_at" TEXT,
  "verified_at" TEXT,
  "last_received_at" TEXT,
  "quiet_after_hours" INTEGER DEFAULT 72 NOT NULL,
  "quiet_notified_at" TEXT,
  "paused_at" TEXT,
  "revoked_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "archive_copy" INTEGER DEFAULT false NOT NULL,
  "attachment_limit_mb" INTEGER DEFAULT 10 NOT NULL,
  "imap_host" TEXT,
  "imap_port" INTEGER,
  "imap_username" TEXT,
  "imap_password_ciphertext" TEXT,
  "imap_folder" TEXT,
  "imap_uid_validity" INTEGER,
  "imap_last_uid" INTEGER,
  "imap_last_polled_at" TEXT,
  "imap_last_error" TEXT,
  "imap_consecutive_failures" INTEGER DEFAULT 0 NOT NULL,
  "imap_auth_failures" INTEGER DEFAULT 0 NOT NULL,
  "imap_message_attempts" INTEGER DEFAULT 0 NOT NULL,
  "imap_auth_failed_at" TEXT,
  "attention_bonus" INTEGER DEFAULT 0 NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id),
  default_organization_id INTEGER ,
  default_project_id INTEGER ,
  default_label_id INTEGER ,
  CONSTRAINT inbound_channels_inbound_route_id_fkey FOREIGN KEY (tenant_id,inbound_route_id) REFERENCES inbound_routes(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT inbound_channels_default_organization_id_fkey FOREIGN KEY (tenant_id,default_organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT inbound_channels_default_project_id_fkey FOREIGN KEY (tenant_id,default_project_id) REFERENCES projects(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT inbound_channels_default_label_id_fkey FOREIGN KEY (tenant_id,default_label_id) REFERENCES labels(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "inbound_channel_rejections" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "inbound_route_id" INTEGER NOT NULL ,
  "inbound_channel_id" INTEGER ,
  "organization_id" INTEGER ,
  "sender_email" TEXT,
  "recipient" TEXT,
  "subject" TEXT,
  "classification" TEXT NOT NULL,
  "provider_delivery_id" TEXT,
  "inserted_at" TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id),
  CONSTRAINT inbound_channel_rejections_inbound_route_id_fkey FOREIGN KEY (tenant_id,inbound_route_id) REFERENCES inbound_routes(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT inbound_channel_rejections_inbound_channel_id_fkey FOREIGN KEY (tenant_id,inbound_channel_id) REFERENCES inbound_channels(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT inbound_channel_rejections_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "email_connections" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "tenant_id" INTEGER NOT NULL CONSTRAINT "email_connections_tenant_id_fkey" REFERENCES "tenants"("id") ON DELETE CASCADE,
  "project_id" TEXT,
  "project_token_ciphertext" TEXT,
  "team_token_ciphertext" TEXT,
  "status_webhook_id" TEXT,
  "status_secret_ciphertext" TEXT,
  "status_callback_token" TEXT NOT NULL,
  "project_checked_at" TEXT,
  "project_check_status" TEXT DEFAULT 'unchecked' NOT NULL,
  "sending_checked_at" TEXT,
  "sending_check_status" TEXT DEFAULT 'unchecked' NOT NULL,
  "last_signed_inbound_at" TEXT,
  "last_reply_accepted_at" TEXT,
  "last_reply_delivered_at" TEXT,
  "last_status_event_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  "default_channel_id" INTEGER ,
  "latest_received_thread_id" INTEGER ,
  "last_returning_reply_at" TEXT,
  "reply_evidence_after_message_id" INTEGER DEFAULT 0 NOT NULL,
  CONSTRAINT email_connections_default_channel_id_fkey FOREIGN KEY (tenant_id,default_channel_id) REFERENCES inbound_channels(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT email_connections_latest_received_thread_id_fkey FOREIGN KEY (tenant_id,latest_received_thread_id) REFERENCES threads(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "labels" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "tenant_id" INTEGER NOT NULL CONSTRAINT "labels_tenant_id_fkey" REFERENCES "tenants"("id") ON DELETE CASCADE,
  "name" TEXT NOT NULL,
  "normalized_name" TEXT NOT NULL,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL
);

CREATE TABLE "thread_labels" (
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  thread_id INTEGER NOT NULL,
  label_id INTEGER NOT NULL,
  inserted_at TEXT NOT NULL,
  PRIMARY KEY (thread_id,label_id),
  CONSTRAINT thread_labels_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE CASCADE,
  CONSTRAINT thread_labels_label_id_fkey FOREIGN KEY (tenant_id,label_id) REFERENCES labels(tenant_id,id) ON DELETE CASCADE
);

CREATE TABLE "tasks" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "thread_id" INTEGER ,
  "project_id" INTEGER ,
  "organization_id" INTEGER ,
  "title" TEXT NOT NULL,
  "state" TEXT DEFAULT 'open' NOT NULL,
  "portal_visible" INTEGER DEFAULT false NOT NULL,
  "due_at" TEXT,
  "inserted_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  CONSTRAINT tasks_thread_id_fkey FOREIGN KEY (tenant_id,thread_id) REFERENCES threads(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT tasks_project_id_fkey FOREIGN KEY (tenant_id,project_id) REFERENCES projects(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT tasks_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT
);

CREATE TABLE "instance_admins" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL,
  password_hash TEXT,
  login_token TEXT,
  login_token_expires_at TEXT,
  session_claim TEXT NOT NULL,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE "tenant_hosts" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  hostname TEXT NOT NULL,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE "portal_credentials" (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  organization_id INTEGER NOT NULL ,
  contact_id INTEGER ,
  token_hash TEXT NOT NULL,
  revoked_at TEXT,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CONSTRAINT portal_credentials_organization_id_fkey FOREIGN KEY (tenant_id,organization_id) REFERENCES organizations(tenant_id,id) ON DELETE RESTRICT,
  CONSTRAINT portal_credentials_contact_id_fkey FOREIGN KEY (tenant_id,contact_id) REFERENCES contacts(tenant_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX acknowledgments_tenant_id_id_index ON acknowledgments(tenant_id,id);

CREATE UNIQUE INDEX intake_sources_tenant_id_id_index ON intake_sources(tenant_id,id);

CREATE UNIQUE INDEX organizations_tenant_id_id_index ON organizations(tenant_id,id);

CREATE UNIQUE INDEX audit_events_tenant_id_id_index ON audit_events(tenant_id,id);

CREATE UNIQUE INDEX acknowledgment_organization_bindings_tenant_id_id_index ON acknowledgment_organization_bindings(tenant_id,id);

CREATE UNIQUE INDEX message_attachments_tenant_id_id_index ON message_attachments(tenant_id,id);

CREATE UNIQUE INDEX prospects_tenant_id_id_index ON prospects(tenant_id,id);

CREATE UNIQUE INDEX threads_tenant_id_id_index ON threads(tenant_id,id);

CREATE UNIQUE INDEX email_connections_tenant_id_id_index ON email_connections(tenant_id,id);

CREATE UNIQUE INDEX staff_accounts_tenant_id_id_index ON staff_accounts(tenant_id,id);

CREATE UNIQUE INDEX portal_credentials_tenant_id_id_index ON portal_credentials(tenant_id,id);

CREATE UNIQUE INDEX inbound_routes_tenant_id_id_index ON inbound_routes(tenant_id,id);

CREATE UNIQUE INDEX tenant_hosts_tenant_id_id_index ON tenant_hosts(tenant_id,id);

CREATE UNIQUE INDEX tasks_tenant_id_id_index ON tasks(tenant_id,id);

CREATE UNIQUE INDEX slugs_tenant_id_id_index ON slugs(tenant_id,id);

CREATE UNIQUE INDEX messages_tenant_id_id_index ON messages(tenant_id,id);

CREATE UNIQUE INDEX settings_tenant_id_id_index ON settings(tenant_id,id);

CREATE UNIQUE INDEX message_recipient_statuses_tenant_id_id_index ON message_recipient_statuses(tenant_id,id);

CREATE UNIQUE INDEX inbound_channels_tenant_id_id_index ON inbound_channels(tenant_id,id);

CREATE UNIQUE INDEX contacts_tenant_id_id_index ON contacts(tenant_id,id);

CREATE UNIQUE INDEX projects_tenant_id_id_index ON projects(tenant_id,id);

CREATE UNIQUE INDEX labels_tenant_id_id_index ON labels(tenant_id,id);

CREATE UNIQUE INDEX inbound_channel_rejections_tenant_id_id_index ON inbound_channel_rejections(tenant_id,id);

CREATE INDEX "contacts_organization_id_index" ON "contacts" ("organization_id");

CREATE INDEX "messages_thread_id_index" ON "messages" ("thread_id");

CREATE INDEX "projects_organization_id_index" ON "projects" ("organization_id");

CREATE INDEX "projects_thread_id_index" ON "projects" ("thread_id");

CREATE INDEX "projects_project_type_index" ON "projects" ("project_type");

CREATE INDEX "projects_is_template_index" ON "projects" ("is_template") WHERE is_template = true;

CREATE UNIQUE INDEX "contacts_email_organization_id_index" ON "contacts" ("email", "organization_id");

CREATE INDEX "inbound_route_webhooks_inbound_route_id_index" ON "inbound_route_webhooks" ("inbound_route_id");

CREATE UNIQUE INDEX "inbound_route_webhooks_inbound_route_id_purpose_index" ON "inbound_route_webhooks" ("inbound_route_id", "purpose");

CREATE INDEX "threads_organization_id_index" ON "threads" ("organization_id");

CREATE INDEX "threads_state_index" ON "threads" ("state");

CREATE INDEX "threads_cached_score_index" ON "threads" ("cached_score");

CREATE INDEX "threads_project_id_index" ON "threads" ("project_id");

CREATE INDEX "threads_source_index" ON "threads" ("source");

CREATE INDEX "audit_events_thread_id_index" ON "audit_events" ("thread_id");

CREATE INDEX "audit_events_organization_id_index" ON "audit_events" ("organization_id");

CREATE INDEX "audit_events_message_id_index" ON "audit_events" ("message_id");

CREATE INDEX "audit_events_inserted_at_index" ON "audit_events" ("inserted_at");

CREATE INDEX "staff_accounts_role_index" ON "staff_accounts" ("role");

CREATE UNIQUE INDEX "staff_accounts_login_token_index" ON "staff_accounts" ("login_token");

CREATE INDEX "threads_intake_source_key_index" ON "threads" ("intake_source_key");

CREATE UNIQUE INDEX "prospects_thread_id_index" ON "prospects" ("thread_id");

CREATE UNIQUE INDEX "prospects_access_token_hash_index" ON "prospects" ("access_token_hash");

CREATE UNIQUE INDEX "slugs_organization_id_index" ON "slugs" ("organization_id") WHERE organization_id IS NOT NULL;

CREATE UNIQUE INDEX "slugs_thread_id_index" ON "slugs" ("thread_id") WHERE thread_id IS NOT NULL;

CREATE UNIQUE INDEX "slugs_confirmation_token_hash_index" ON "slugs" ("confirmation_token_hash") WHERE confirmation_token_hash IS NOT NULL;

CREATE INDEX "slugs_email_index" ON "slugs" ("email");

CREATE INDEX "slugs_status_expires_at_index" ON "slugs" ("status", "expires_at");

CREATE INDEX "messages_deleted_by_staff_id_index" ON "messages" ("deleted_by_staff_id");

CREATE INDEX "messages_message_id_index" ON "messages" ("message_id");

CREATE INDEX "acknowledgments_organization_id_received_at_index" ON "acknowledgments" ("organization_id", "received_at");

CREATE UNIQUE INDEX "staff_accounts_session_claim_index" ON "staff_accounts" ("session_claim");

CREATE INDEX "messages_lettermint_message_id_index" ON "messages" ("lettermint_message_id") WHERE lettermint_message_id IS NOT NULL;

CREATE INDEX "threads_inbound_channel_id_index" ON "threads" ("inbound_channel_id");

CREATE INDEX "messages_forwarded_by_staff_id_index" ON "messages" ("forwarded_by_staff_id");

CREATE INDEX "message_attachments_message_id_index" ON "message_attachments" ("message_id");

CREATE INDEX "message_attachments_sha256_index" ON "message_attachments" ("sha256");

CREATE UNIQUE INDEX "message_attachments_message_id_position_index" ON "message_attachments" ("message_id", "position");

CREATE UNIQUE INDEX "message_recipient_statuses_message_id_address_index" ON "message_recipient_statuses" ("message_id", "address");

CREATE UNIQUE INDEX tenants_slug_index ON tenants(slug);

CREATE UNIQUE INDEX organizations_tenant_id_domain_index ON organizations(tenant_id,domain) WHERE domain IS NOT NULL AND domain != '';

CREATE INDEX threads_tenant_id_index ON threads(tenant_id);

CREATE INDEX intake_sources_tenant_id_index ON intake_sources(tenant_id);

CREATE UNIQUE INDEX "inbound_routes_callback_token_index" ON "inbound_routes" ("callback_token");

CREATE INDEX "inbound_routes_source_index" ON "inbound_routes" ("source");

CREATE INDEX inbound_routes_tenant_id_index ON inbound_routes(tenant_id);

CREATE UNIQUE INDEX "inbound_channels_ingress_token_index" ON "inbound_channels" ("ingress_token");

CREATE UNIQUE INDEX "inbound_channels_previous_ingress_token_index" ON "inbound_channels" ("previous_ingress_token") WHERE previous_ingress_token IS NOT NULL;

CREATE UNIQUE INDEX "inbound_channels_inbound_route_id_public_address_index" ON "inbound_channels" ("inbound_route_id", "public_address");

CREATE INDEX "inbound_channels_state_index" ON "inbound_channels" ("state");

CREATE INDEX inbound_channels_tenant_id_index ON inbound_channels(tenant_id);

CREATE INDEX "inbound_channel_rejections_inbound_route_id_inserted_at_index" ON "inbound_channel_rejections" ("inbound_route_id", "inserted_at");

CREATE INDEX "inbound_channel_rejections_inbound_channel_id_index" ON "inbound_channel_rejections" ("inbound_channel_id");

CREATE INDEX "inbound_channel_rejections_inserted_at_index" ON "inbound_channel_rejections" ("inserted_at");

CREATE INDEX inbound_channel_rejections_tenant_id_index ON inbound_channel_rejections(tenant_id);

CREATE UNIQUE INDEX "email_connections_tenant_id_index" ON "email_connections" ("tenant_id");

CREATE UNIQUE INDEX "email_connections_status_callback_token_index" ON "email_connections" ("status_callback_token");

CREATE UNIQUE INDEX "labels_tenant_id_normalized_name_index" ON "labels" ("tenant_id", "normalized_name");

CREATE INDEX "thread_labels_label_id_index" ON "thread_labels" ("label_id");

CREATE INDEX "tasks_thread_id_index" ON "tasks" ("thread_id");

CREATE INDEX "tasks_project_id_index" ON "tasks" ("project_id");

CREATE INDEX "tasks_organization_id_index" ON "tasks" ("organization_id");

CREATE INDEX "tasks_state_due_at_thread_id_index" ON "tasks" ("state", "due_at", "thread_id");

CREATE INDEX projects_tenant_id_index ON projects(tenant_id);

CREATE UNIQUE INDEX organizations_tenant_id_identity_kind_identity_value_index ON organizations(tenant_id,identity_kind,identity_value);

CREATE UNIQUE INDEX settings_tenant_id_index ON settings(tenant_id);

CREATE UNIQUE INDEX staff_accounts_tenant_id_email_index ON staff_accounts(tenant_id,email);

CREATE UNIQUE INDEX instance_admins_email_index ON instance_admins(email);

CREATE UNIQUE INDEX tenant_hosts_hostname_index ON tenant_hosts(hostname);

CREATE UNIQUE INDEX portal_credentials_token_hash_index ON portal_credentials(token_hash);

CREATE UNIQUE INDEX messages_tenant_id_message_id_index ON messages(tenant_id,message_id) WHERE message_id IS NOT NULL;

CREATE UNIQUE INDEX messages_tenant_id_provider_delivery_id_index ON messages(tenant_id,provider_delivery_id) WHERE provider_delivery_id IS NOT NULL;

CREATE UNIQUE INDEX slugs_tenant_id_slug_index ON slugs(tenant_id,slug);

CREATE UNIQUE INDEX intake_sources_tenant_id_key_index ON intake_sources(tenant_id,key);

CREATE UNIQUE INDEX acknowledgments_tenant_id_source_submission_id_index ON acknowledgments(tenant_id,source,submission_id);

CREATE UNIQUE INDEX acknowledgment_organization_bindings_tenant_id_source_source_organization_id_index ON acknowledgment_organization_bindings(tenant_id,source,source_organization_id);

CREATE TABLE acknowledgment_integrations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  url_ciphertext TEXT NOT NULL,
  queue TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT false,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX acknowledgment_integrations_tenant_id_index ON acknowledgment_integrations(tenant_id);

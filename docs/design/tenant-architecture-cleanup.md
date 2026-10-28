# Tenant architecture cleanup

Status: implementation in progress. This plan supersedes legacy organization ownership and compatibility requirements. The database will be reset only after checks pass.

## Ownership and language

The instance operator installs and maintains Custyard. Instance admins manage tenant lifecycle and provisioning, with separate credentials and no implicit customer access. A tenant owns a workspace, staff, actual registered hostnames, settings, support channels, customers, projects, tasks, threads, messages and integrations. A customer is an organization, including an individual identified by their email address. Staff access customer records through their tenant membership.

## Hostnames and routes

Register every actual hostname in a globally unique tenant host registry. One tenant can explicitly claim the installation hostname, so a single tenant installation needs no wildcard DNS or TLS. Reject unknown hosts. Resolve the hostname independently on HTTP and LiveView connections.

Use `/admin` for instance administration, `/app` for tenant work, `/app/settings/{workspace,staff,email,intake,workflow,integrations}` for tenant settings, and `/intake/:key`, `/threads/:token`, `/portal/:token`, `/claims/:token` for public access. Delete the `/operator` namespace. UI terms are Instance admin, Staff, Customer and Thread.

## Authentication and permissions

Extract shared authentication primitives before splitting instance admins and tenant staff. Staff roles are admin and agent, with mandatory tenant ownership and tenant-unique email. Separate session cookies, signing salts and LiveView session endpoints for administration and tenant work. Host-only cookies use matching path restrictions. A Phoenix Scope is the first argument to tenant context operations; public credentials and integrations establish narrow scopes independently. Request parameters never establish authority.

## Customer and settings cleanup

Remove organization-owned branding, hosting, provider configuration, staff membership and teams. Tenant settings own branding, workflow scoring, neglect thresholds, intake behavior, email configuration and integrations. Replace organization intake_key with identity_kind (domain, email, manual) and identity_value, unique within a tenant. Manual identities use generated identifiers. Unresolved anonymous/internal work has a null customer; delete the unmatched organization concept.

## Email channels and routing

Channels and provider routes belong to tenants. Retain enterprise and project addresses as routing hints: default_organization_id, default_project_id and default_label_id. Resolve an existing thread first, then a known sender relationship. Apply hints only to a new thread with unresolved customer identity; a project hint must agree with the resolved customer. Never override an existing thread or known sender identity. Group new business senders by domain and personal senders by email, displaying the sender name. Use standard email headers and conservative subject fallback.

## Data isolation and credentials

Require tenant_id on tenant records, including messages. Uniqueness for RFC message IDs and provider delivery IDs is per tenant. Audit events carry tenant_id, nullable only for installation events. Prefix stored attachments with tenant identity. Enforce same-tenant relationships with composite foreign keys and referenced unique (tenant_id,id) keys. Remove default tenant IDs and global fallback reads.

Customer portal credentials have mandatory tenant/customer, optional contact attribution, hashed tokens and independent revocation. Thread credentials remain restricted to one thread. Claim slugs are tenant-local customer labels, never tenant hosting authorities.

## Lifecycle and abuse controls

Tenants are active or suspended. Suspension blocks staff sessions, public access, new inbound messages and outbound work. Reject inbound requests with HTTP 403 and tenant audit; continue accepting delivery status for previous sends. Resuming does not replay rejected input. Rate-limit by tenant and IP, with an installation abuse ceiling. Setup remains reachable before customer email configuration; system authentication mail is separate. A reset invalidates every existing login, portal, thread and claim link.

## Implementation and commit sequence

1. Save this plan and extract shared authentication primitives.
2. Replace migration history with a fresh schema baseline and tenant constraints.
3. Separate accounts, scopes, hostname resolution, sessions and lifecycle.
4. Move settings/email/integration ownership and implement routing hints.
5. Implement credentials, tenant storage/audit/exports/retention and rate limits.
6. Replace routes, UI wording, generated URLs and documentation.
7. Verify tenant boundaries and remove obsolete code and tests.
8. Commit mechanical Conversation to Thread, remaining operator names, and Custyard.Task to Custyard.WorkItem separately from behavior changes.
9. After checks pass, reset, seed, configure and verify the email round trip.

## Required checks

Exercise duplicate email addresses and duplicate RFC/provider IDs across tenants; same-tenant composite foreign key rejection; correct sender/thread precedence over hints; isolated admin/staff cookies and LiveView sessions; unknown-host rejection; independent portal credential revocation; suspended inbound rejection and audit; status callbacks during suspension; setup before support configuration; tenant-local rate limits; public credential isolation; and a full inbound/reply/returning-reply flow. Report local checks separately from live provider delivery evidence.

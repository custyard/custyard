# planning/service-platform-sdd-v0.2-status.md

Planning & Implementation State

Key Files

Planning Artifacts:
- planning/service-platform-sdd-v0.2.md - Complete SDD with US-1 through US-11 specs
- planning/operator-wireframe.jsx - Interactive operator interface prototype
- planning/portal-wireframe.jsx - Client portal prototype
- planning/*.png (6 files) - Implementation screenshots from Mar 22

Core Implementation:
- lib/custyard/conversations.ex - Conversation CRUD, state transitions
- lib/custyard/scoring.ex - Composite scoring algorithm
- lib/custyard/email/processor.ex - RFC 5322 parsing, threading
- lib/custyard_web/live/operator/*.ex - Attention queue, neglect report, org/project management
- lib/custyard_web/live/portal/*.ex - Customer portal with requests, projects, admin toggle

Implementation Status

┌──────────────┬─────────────────────────────────────────┬────────┐
│  User Story  │                 Feature                 │ Status │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-1 to US-3 │ Email ingestion, threading, state model │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-4         │ Tasks with due dates                    │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-5         │ Attention queue with composite scoring  │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-6         │ Neglect alerts                          │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-7         │ Customer portal                         │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-8         │ White-label branding                    │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-9         │ Organization unified timeline           │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-10        │ Projects with templates                 │ Done   │
├──────────────┼─────────────────────────────────────────┼────────┤
│ US-11        │ Internal projects                       │ Done   │
└──────────────┴─────────────────────────────────────────┴────────┘

MVP Complete - 288 tests across 49 files, all user stories implemented.

What's Next (Not Yet Built)

1. [#10](https://github.com/onetimesecret/custyard/issues/10) Email Infrastructure - IMAP polling or LMTP delivery integration (code ready, needs MTA hookup)
2. [#11](https://github.com/onetimesecret/custyard/issues/11) Production Deployment - Containerfile exists but untested
3. [#12](https://github.com/onetimesecret/custyard/issues/12) Team Support - Multi-operator roles and permissions
4. [#13](https://github.com/onetimesecret/custyard/issues/13) Webhook Ingestion - Controller exists, needs full integration
5. [#14](https://github.com/onetimesecret/custyard/issues/14) Encryption at Rest - Architecture defined, using SQLite for MVP

Recent Commits (Last 5)

- 2ac290e - Mailer, organizations context, projects LiveView
- 796ea06 - Claude Code CI workflows
- 3d11867 - QA tools (credo, dialyxir, sobelow)
- 7f6bd76 - MVP complete (US-4 through US-11)
- 86fac9b - LiveView refactor to Conversations context

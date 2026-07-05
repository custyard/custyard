Based on the schemas:

Request = Conversation (same thing, "request" is portal-facing terminology)

Organization
├── Contacts (customers)
├── Conversations (support requests)
│   ├── Messages
│   ├── Tasks (can be attached to a conversation)
│   └── belongs_to Project (optional)
├── Projects (group related work)
│   ├── Tasks (can be attached to a project)
│   ├── Conversations (linked to this project)
│   └── InboundRoutes
└── Tasks (can exist at org level too)

Task ownership is flexible - a task needs at least one of:
- organization_id (org-level task)
- conversation_id (task tied to a support request)
- project_id (task tied to a project)

Project ↔ Conversation:
- A project can have one "primary" conversation (e.g., the initial onboarding request)
- A project has many conversations (all conversations linked to it)
- A conversation optionally belongs_to a project

Internal vs Customer projects:
- Customer projects have an organization_id
- Internal projects have project_type: :internal, no org, not portal-visible

So tasks can live on conversations (created from conversation detail page) OR on projects (the new UI we just built). The
conversation-based tasks are good for "reply to customer by Friday" while project-based tasks are better for milestone
tracking.

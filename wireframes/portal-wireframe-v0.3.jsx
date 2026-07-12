import { useState } from "react";

// ─── Mock Data ──────────────────────────────────────────────────────────────
//
// DATA MODEL RELATIONSHIPS (from SDD §4):
//
// - A Project contains Tasks (its work plan, often from a template).
// - A Request (Conversation) is a communication thread about a topic.
// - A Request can spawn Tasks (work that emerged from the conversation).
// - A Task can belong to a Project AND be linked to a Request.
//   The project is where it's tracked; the request is where it was discussed.
// - A Request can be linked to a Project (conversations.project_id FK).
//
// The mock data below tells one coherent story to demonstrate all of these:
//
// "SSO Configuration" project has 7 tasks from its template.
// Request #3 ("Add auth.acme-eu.com for SSO") is linked to that project.
// Task "Configure SAML endpoint for EU domain" exists in the project AND
// is surfaced on request #3 (same task entity, visible in both places).
// Request #1 (TLS error) is standalone — no project link.
// Request #2 (page lockdown) is standalone — no project link.

const CURRENT_USER = {
  name: "Jane Smith",
  email: "jane@acme.com",
  initials: "JS",
};

const MOCK_ORG = {
  name: "Acme Corp",
  logoLetter: "A",
  primaryColor: "#4f46e5",
};

// ── Shared task references (same entity appears in project and on request) ──

const TASK_SAML_ENDPOINT = {
  id: "t5",
  title: "Configure SAML endpoint for EU domain",
  state: "in_progress",
  due: "Jan 22",
  requestId: 3, // linked to request #3
  requestTitle: "Add auth.acme-eu.com for SSO",
};

const TASK_UAT = {
  id: "t6",
  title: "User acceptance testing",
  state: "open",
  due: "Jan 25",
  requestId: null,
};

const TASK_GOLIVE = {
  id: "t7",
  title: "Go-live and monitoring",
  state: "open",
  due: "Jan 28",
  requestId: null,
};

// ── Projects ────────────────────────────────────────────────────────────────

const MOCK_PROJECTS = [
  {
    id: "p1",
    title: "SSO Configuration",
    description: "Set up SAML SSO for primary and EU domains",
    startedAt: "Jan 15",
    tasks: [
      { id: "t1", title: "Collect DNS records", state: "done", due: "Jan 16", requestId: null },
      { id: "t2", title: "Configure SSL certificates", state: "done", due: "Jan 17", requestId: null },
      { id: "t3", title: "Set up SAML IdP connection", state: "done", due: "Jan 18", requestId: null },
      { id: "t4", title: "Test SSO login flow", state: "done", due: "Jan 20", requestId: null },
      TASK_SAML_ENDPOINT,
      TASK_UAT,
      TASK_GOLIVE,
    ],
  },
  {
    id: "p2",
    title: "Portal Customization",
    description: "White-label branding and custom domain setup",
    startedAt: "Feb 1",
    tasks: [
      { id: "t8", title: "Upload logo and set brand colors", state: "done", due: "Feb 2", requestId: null },
      { id: "t9", title: "Configure custom domain CNAME", state: "done", due: "Feb 3", requestId: null },
      { id: "t10", title: "DNS propagation and TLS provisioning", state: "done", due: "Feb 5", requestId: null },
      { id: "t11", title: "Verify portal renders on custom domain", state: "done", due: "Feb 6", requestId: null },
    ],
  },
];

// ── Requests (Conversations) ────────────────────────────────────────────────

const MOCK_REQUESTS = [
  {
    id: 1,
    title: "TLS security error — site appears down",
    state: "active",
    urgency: "urgent",
    filedAt: "2 hours ago",
    filedBy: "Jane Smith",
    project: null, // standalone, no project
    lastUpdate: "Checking the certificate chain now. Initial check shows the cert is valid but there may be an intermediate cert issue.",
    lastUpdateBy: "Service Team",
    lastUpdateTime: "1h ago",
    messages: [
      { author: "Jane Smith", role: "contact", time: "2h ago", body: "Hi — it looks like the site is down. We're getting a TLS security error when trying to access portal.acme.com. Any way to get that back up? Is it something on our end?" },
      { author: "Jane Smith", role: "contact", time: "1h 30m ago", body: "Update: our IT team says DNS looks fine on our end. The cert might be expired?" },
      { author: "Service Team", role: "operator", time: "1h ago", body: "Looking into this now. Checking the certificate chain and will update shortly. Initial check shows the cert is valid but there may be an intermediate cert issue." },
    ],
    tasks: [
      { id: "t20", title: "Investigate TLS certificate chain", state: "in_progress", requestId: 1 },
      { id: "t21", title: "Apply fix and verify", state: "open", requestId: 1 },
    ],
  },
  {
    id: 2,
    title: "Lock down page A, leave page B public",
    state: "active",
    urgency: "normal",
    filedAt: "1 day ago",
    filedBy: "Jane Smith",
    project: null,
    lastUpdate: "Two options: IP-based allowlisting or requiring login for page A while page B remains public.",
    lastUpdateBy: "Service Team",
    lastUpdateTime: "4h ago",
    messages: [
      { author: "Jane Smith", role: "contact", time: "1d ago", body: "Is it possible to lock down page A, but leave page B available for anyone to access? Can that be done by IP address or does it require authentication?" },
      { author: "Service Team", role: "operator", time: "4h ago", body: "This is possible. We can do it by authentication requirement per route. Two options: IP-based allowlisting (simpler but less flexible), or requiring login for page A while page B remains public. Which approach fits better?" },
    ],
    tasks: [],
  },
  {
    id: 3,
    title: "Add auth.acme-eu.com for SSO",
    state: "active",
    urgency: "normal",
    filedAt: "3 days ago",
    filedBy: "Mike Torres",
    project: { id: "p1", title: "SSO Configuration" }, // linked to project
    lastUpdate: "SAML metadata received. Working on configuration.",
    lastUpdateBy: "Service Team",
    lastUpdateTime: "4h ago",
    messages: [
      { author: "Mike Torres", role: "contact", time: "3d ago", body: "We need to add auth.acme-eu.com as an additional domain for SSO. Same SAML config as the primary domain." },
      { author: "Service Team", role: "operator", time: "3d ago", body: "Got it. I'll need the SAML metadata XML for the new domain. Can you export that from your IdP?" },
      { author: "Mike Torres", role: "contact", time: "2d ago", body: "Here's the metadata. [attachment: saml-metadata-eu.xml]" },
      { author: "Service Team", role: "operator", time: "4h ago", body: "SAML metadata received. Working on configuration. Will need to verify certificate coverage for the new domain first." },
      { author: "Mike Torres", role: "contact", time: "30m ago", body: "Any update on this? We're planning to roll out the EU portal next week." },
    ],
    // This task is the SAME entity as TASK_SAML_ENDPOINT in the project.
    // It appears here because it's linked to this conversation.
    tasks: [
      TASK_SAML_ENDPOINT,
    ],
  },
];

const MOCK_RESOLVED = [
  {
    id: 10,
    title: "Reset admin password for portal",
    state: "resolved",
    urgency: "normal",
    filedAt: "2 weeks ago",
    filedBy: "Jane Smith",
    project: null,
    lastUpdate: "Password reset complete. New credentials sent securely.",
    lastUpdateBy: "Service Team",
    lastUpdateTime: "2 weeks ago",
    messages: [],
    tasks: [],
  },
];

// ─── Shared Components ──────────────────────────────────────────────────────

function StateBadge({ state }) {
  const styles = {
    active: "bg-emerald-50 text-emerald-700 border border-emerald-200",
    waiting: "bg-amber-50 text-amber-700 border border-amber-200",
    resolved: "bg-gray-50 text-gray-500 border border-gray-200",
    new: "bg-blue-50 text-blue-700 border border-blue-200",
  };
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full ${styles[state] || styles.resolved}`}>
      {state}
    </span>
  );
}

function UrgencyIndicator({ urgency }) {
  if (urgency === "normal") return null;
  const color = urgency === "urgent" ? "text-red-600" : "text-orange-500";
  return (
    <span className={`text-xs font-medium ${color} flex items-center gap-1`}>
      <span className={`w-1.5 h-1.5 rounded-full ${urgency === "urgent" ? "bg-red-500" : "bg-orange-400"}`} />
      {urgency}
    </span>
  );
}

function TaskStateDot({ state }) {
  const colors = {
    done: "bg-emerald-400",
    in_progress: "bg-blue-400",
    open: "bg-gray-300",
  };
  return <span className={`inline-block w-2 h-2 rounded-full flex-shrink-0 ${colors[state]}`} />;
}

function ProgressBar({ tasks }) {
  const done = tasks.filter((t) => t.state === "done").length;
  const inProgress = tasks.filter((t) => t.state === "in_progress").length;
  const total = tasks.length;
  if (total === 0) return null;
  return (
    <div className="w-full bg-gray-100 rounded-full h-1.5">
      <div className="flex h-1.5 rounded-full overflow-hidden">
        <div className="bg-emerald-400 transition-all" style={{ width: `${(done / total) * 100}%` }} />
        <div className="bg-blue-400 transition-all" style={{ width: `${(inProgress / total) * 100}%` }} />
      </div>
    </div>
  );
}

// Small inline icon for cross-references
function ProjectIcon() {
  return (
    <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2" />
    </svg>
  );
}

function ConversationIcon() {
  return (
    <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z" />
    </svg>
  );
}

// ─── Project badge on request cards ─────────────────────────────────────────
// Shows which project a request belongs to. Clickable to navigate.

function ProjectBadge({ project, onClick }) {
  if (!project) return null;
  return (
    <button
      className="inline-flex items-center gap-1 text-xs text-indigo-600 bg-indigo-50 border border-indigo-100 rounded-full px-2 py-0.5 hover:bg-indigo-100 transition-colors"
      onClick={(e) => {
        e.stopPropagation();
        if (onClick) onClick(project);
      }}
    >
      <ProjectIcon />
      {project.title}
    </button>
  );
}

// ─── Conversation link on project tasks ─────────────────────────────────────
// Shows which request a task is being discussed in.

function RequestLink({ requestTitle, onClick }) {
  if (!requestTitle) return null;
  return (
    <button
      className="inline-flex items-center gap-1 text-xs text-gray-500 hover:text-indigo-600 transition-colors"
      onClick={(e) => {
        e.stopPropagation();
        if (onClick) onClick();
      }}
      title={`Discussed in: ${requestTitle}`}
    >
      <ConversationIcon />
    </button>
  );
}

// ─── Portal Chrome (Nav) ────────────────────────────────────────────────────

function PortalNav({ activeTab, onTabChange }) {
  return (
    <div className="bg-white border-b border-gray-200 px-5 py-3 flex items-center">
      <div className="flex items-center gap-2.5">
        <div
          className="w-8 h-8 rounded-lg flex items-center justify-center text-white text-sm font-semibold"
          style={{ backgroundColor: MOCK_ORG.primaryColor }}
        >
          {MOCK_ORG.logoLetter}
        </div>
        <span className="font-semibold text-gray-900">{MOCK_ORG.name}</span>
      </div>

      <div className="flex items-center gap-1 ml-8">
        {["requests", "projects"].map((tab) => (
          <button
            key={tab}
            className={`text-sm px-3 py-1.5 rounded-md transition-colors ${
              activeTab === tab
                ? "bg-gray-100 text-gray-900 font-medium"
                : "text-gray-500 hover:text-gray-700 hover:bg-gray-50"
            }`}
            onClick={() => onTabChange(tab)}
          >
            {tab.charAt(0).toUpperCase() + tab.slice(1)}
          </button>
        ))}
      </div>

      <div className="ml-auto flex items-center gap-2">
        <div className="w-7 h-7 rounded-full bg-gray-100 flex items-center justify-center">
          <span className="text-xs font-medium text-gray-500">{CURRENT_USER.initials}</span>
        </div>
        <span className="text-sm text-gray-500">{CURRENT_USER.name}</span>
      </div>
    </div>
  );
}

// ─── Task Row ───────────────────────────────────────────────────────────────
// Shared component for rendering a task consistently everywhere it appears.
// Shows cross-reference link when relevant (conversation icon on project tasks,
// project icon on request tasks).

function TaskRow({ task, context, onNavigateRequest, compact }) {
  const isDone = task.state === "done";
  return (
    <div className={`flex items-center gap-2.5 ${compact ? "py-1" : "px-2 py-2 rounded"} ${isDone ? "opacity-50" : ""}`}>
      <TaskStateDot state={task.state} />
      <span className={`text-sm flex-1 ${isDone ? "line-through text-gray-400" : "text-gray-800"}`}>
        {task.title}
      </span>
      {/* Cross-reference: show conversation icon if task is discussed in a request */}
      {context === "project" && task.requestId && (
        <RequestLink
          requestTitle={task.requestTitle}
          onClick={() => onNavigateRequest && onNavigateRequest(task.requestId)}
        />
      )}
      {/* Show state label on conversation tasks, date on project tasks */}
      {context === "request" && !isDone && (
        <span className="text-xs text-gray-400 capitalize flex-shrink-0">{task.state.replace("_", " ")}</span>
      )}
      {context === "project" && task.due && (
        <span className="text-xs text-gray-400 flex-shrink-0">{task.due}</span>
      )}
    </div>
  );
}

// ─── Request Card ───────────────────────────────────────────────────────────

function RequestCard({ request, onClick, onNavigateProject }) {
  return (
    <div
      className="bg-white border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors cursor-pointer"
      onClick={() => onClick(request)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 mb-0.5 flex-wrap">
            <span className="font-medium text-gray-900 text-sm">{request.title}</span>
            <UrgencyIndicator urgency={request.urgency} />
          </div>
          <div className="flex items-center gap-2 mt-0.5">
            <span className="text-xs text-gray-400">
              {request.filedBy} · {request.filedAt}
            </span>
            {/* Project cross-reference */}
            {request.project && (
              <ProjectBadge project={request.project} onClick={onNavigateProject} />
            )}
          </div>
        </div>
        <StateBadge state={request.state} />
      </div>

      {request.lastUpdate && (
        <div className="mt-2.5 text-sm text-gray-600 bg-gray-50 rounded-md px-3 py-2">
          <span className="text-xs text-gray-400">{request.lastUpdateBy} · {request.lastUpdateTime}: </span>
          <span className="text-gray-600">{request.lastUpdate}</span>
        </div>
      )}

      {request.tasks.length > 0 && (
        <div className="mt-2 flex items-center gap-3 flex-wrap">
          <span className="text-xs text-gray-400">Tasks</span>
          {request.tasks.map((t) => (
            <div key={t.id} className="flex items-center gap-1.5">
              <TaskStateDot state={t.state} />
              <span className="text-xs text-gray-500">{t.title}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ─── Requests List ──────────────────────────────────────────────────────────

function RequestsView({ onSelectRequest, onNewRequest, onNavigateProject }) {
  const [showResolved, setShowResolved] = useState(false);

  return (
    <div className="max-w-2xl mx-auto px-4 py-6">
      <div className="flex items-center justify-between mb-5">
        <div>
          <h1 className="text-lg font-semibold text-gray-900">Requests</h1>
          <p className="text-sm text-gray-400 mt-0.5">{MOCK_REQUESTS.length} open</p>
        </div>
        <button
          className="text-white text-sm px-4 py-2 rounded-lg hover:opacity-90 transition-opacity"
          style={{ backgroundColor: MOCK_ORG.primaryColor }}
          onClick={onNewRequest}
        >
          New request
        </button>
      </div>

      <div className="space-y-2">
        {MOCK_REQUESTS.map((r) => (
          <RequestCard
            key={r.id}
            request={r}
            onClick={onSelectRequest}
            onNavigateProject={onNavigateProject}
          />
        ))}
      </div>

      <div className="mt-6 pt-4 border-t border-gray-100">
        <button
          className="text-sm text-gray-400 hover:text-gray-600 transition-colors"
          onClick={() => setShowResolved(!showResolved)}
        >
          {showResolved ? "Hide" : "Show"} resolved ({MOCK_RESOLVED.length})
        </button>
        {showResolved && (
          <div className="space-y-2 mt-3">
            {MOCK_RESOLVED.map((r) => (
              <RequestCard key={r.id} request={r} onClick={onSelectRequest} onNavigateProject={onNavigateProject} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Conversation Detail ────────────────────────────────────────────────────

function ConversationView({ request, onBack, onNavigateProject }) {
  const [replyText, setReplyText] = useState("");

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="border-b border-gray-200 px-5 py-3 bg-white">
        <div className="max-w-2xl mx-auto">
          <div className="flex items-center gap-3">
            <button className="text-sm text-gray-400 hover:text-gray-600" onClick={onBack}>
              ←
            </button>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2 flex-wrap">
                <span className="font-medium text-gray-900 text-sm">{request.title}</span>
                <StateBadge state={request.state} />
                <UrgencyIndicator urgency={request.urgency} />
              </div>
              <div className="flex items-center gap-2 mt-0.5">
                <span className="text-xs text-gray-400">
                  Opened by {request.filedBy} · {request.filedAt}
                </span>
                {/* Project context: subtle but present */}
                {request.project && (
                  <ProjectBadge project={request.project} onClick={onNavigateProject} />
                )}
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto bg-gray-50">
        <div className="max-w-2xl mx-auto px-4 py-4 space-y-3">
          {request.messages.map((msg, i) => (
            <div key={i} className={`flex ${msg.role === "contact" ? "justify-end" : "justify-start"}`}>
              <div
                className={`max-w-lg rounded-lg px-4 py-3 ${
                  msg.role === "contact"
                    ? "bg-white border border-gray-200"
                    : "bg-indigo-50 border border-indigo-100"
                }`}
              >
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-xs font-medium text-gray-700">{msg.author}</span>
                  <span className="text-xs text-gray-400">{msg.time}</span>
                </div>
                <div className="text-sm text-gray-800 leading-relaxed">{msg.body}</div>
              </div>
            </div>
          ))}
        </div>

        {/* Tasks on this request */}
        {request.tasks.length > 0 && (
          <div className="max-w-2xl mx-auto px-4 pb-4">
            <div className="bg-white border border-gray-200 rounded-lg p-3">
              <div className="text-xs text-gray-400 uppercase tracking-wide mb-2 font-medium">Tasks</div>
              <div className="space-y-1">
                {request.tasks.map((t) => (
                  <TaskRow key={t.id} task={t} context="request" compact />
                ))}
              </div>
              {/* If tasks belong to a project, show that context */}
              {request.project && (
                <div className="mt-2 pt-2 border-t border-gray-100">
                  <button
                    className="inline-flex items-center gap-1 text-xs text-gray-400 hover:text-indigo-600 transition-colors"
                    onClick={() => onNavigateProject && onNavigateProject(request.project)}
                  >
                    <ProjectIcon />
                    <span>View all tasks in {request.project.title}</span>
                  </button>
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {/* Reply input */}
      <div className="border-t border-gray-200 p-4 bg-white">
        <div className="max-w-2xl mx-auto">
          <div className="flex gap-2">
            <div className="flex-1 relative">
              <textarea
                className="w-full border border-gray-200 rounded-lg px-3 py-2.5 text-sm resize-none focus:outline-none focus:ring-1 focus:ring-gray-300 focus:border-gray-300"
                rows={2}
                placeholder="Write a reply..."
                value={replyText}
                onChange={(e) => setReplyText(e.target.value)}
              />
              <div className="absolute bottom-2 right-2 flex items-center gap-1">
                <button className="text-gray-300 hover:text-gray-500 p-1" title="Attach file">
                  <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.585a6 6 0 108.486 8.486L20.5 13" />
                  </svg>
                </button>
              </div>
            </div>
            <button
              className="self-end text-white text-sm px-4 py-2.5 rounded-lg hover:opacity-90 transition-opacity"
              style={{ backgroundColor: MOCK_ORG.primaryColor }}
            >
              Reply
            </button>
          </div>
          <div className="text-xs text-gray-400 mt-1.5">
            Replying as {CURRENT_USER.name}
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── New Request Form ───────────────────────────────────────────────────────

function NewRequestForm({ onSubmit, onCancel }) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");

  return (
    <div className="max-w-2xl mx-auto px-4 py-6">
      <div className="flex items-center justify-between mb-5">
        <h2 className="text-lg font-semibold text-gray-900">New request</h2>
        <button className="text-sm text-gray-400 hover:text-gray-600" onClick={onCancel}>
          Cancel
        </button>
      </div>
      <div className="bg-white border border-gray-200 rounded-lg p-5 space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1.5">Subject</label>
          <input
            className="w-full border border-gray-200 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-1 focus:ring-gray-300"
            placeholder="Brief description of what you need"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1.5">Details</label>
          <textarea
            className="w-full border border-gray-200 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-1 focus:ring-gray-300"
            rows={6}
            placeholder="Context, what you're seeing, what you need..."
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>
        <div>
          <label className="block text-sm text-gray-500 mb-1.5">Attachments</label>
          <div className="border border-dashed border-gray-200 rounded-lg p-6 text-center text-sm text-gray-400 hover:border-gray-300 transition-colors cursor-pointer">
            Drop files here or click to browse
          </div>
        </div>
        <div className="flex items-center justify-between pt-2">
          <span className="text-xs text-gray-400">
            Filing as {CURRENT_USER.name}
          </span>
          <button
            className="text-white text-sm px-5 py-2.5 rounded-lg hover:opacity-90 transition-opacity"
            style={{ backgroundColor: MOCK_ORG.primaryColor }}
            onClick={() => onSubmit({ title, description })}
          >
            Submit
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Projects List ──────────────────────────────────────────────────────────

function ProjectsView({ onSelectProject }) {
  const active = MOCK_PROJECTS.filter((p) => p.tasks.some((t) => t.state !== "done"));
  const completed = MOCK_PROJECTS.filter((p) => p.tasks.every((t) => t.state === "done"));

  return (
    <div className="max-w-2xl mx-auto px-4 py-6">
      <h1 className="text-lg font-semibold text-gray-900 mb-5">Projects</h1>

      {active.length > 0 && (
        <div className="mb-6">
          <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-2">In progress</div>
          <div className="space-y-2">
            {active.map((p) => {
              const done = p.tasks.filter((t) => t.state === "done").length;
              const next = p.tasks.find((t) => t.state !== "done");
              return (
                <div
                  key={p.id}
                  className="bg-white border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors cursor-pointer"
                  onClick={() => onSelectProject(p)}
                >
                  <div className="flex items-start justify-between mb-2">
                    <div>
                      <div className="font-medium text-gray-900 text-sm">{p.title}</div>
                      <div className="text-xs text-gray-400 mt-0.5">{p.description}</div>
                    </div>
                    <span className="text-xs text-gray-500 whitespace-nowrap ml-3">
                      {done}/{p.tasks.length}
                    </span>
                  </div>
                  <ProgressBar tasks={p.tasks} />
                  {next && (
                    <div className="text-xs text-gray-500 mt-2">
                      Next: {next.title}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {completed.length > 0 && (
        <div>
          <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-2">Completed</div>
          <div className="space-y-2">
            {completed.map((p) => (
              <div
                key={p.id}
                className="bg-white border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors cursor-pointer opacity-60"
                onClick={() => onSelectProject(p)}
              >
                <div className="flex items-center justify-between">
                  <div className="font-medium text-gray-900 text-sm">{p.title}</div>
                  <span className="text-xs text-gray-400">{p.tasks.length}/{p.tasks.length}</span>
                </div>
                <ProgressBar tasks={p.tasks} />
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Project Detail ─────────────────────────────────────────────────────────
// Tasks are the same entity as tasks on requests. When a task has a linked
// request, a small conversation icon appears to indicate it's being discussed
// in a specific conversation thread.

function ProjectDetail({ project, onBack, onNavigateRequest }) {
  const done = project.tasks.filter((t) => t.state === "done").length;
  const linkedRequests = project.tasks
    .filter((t) => t.requestId)
    .map((t) => ({ id: t.requestId, title: t.requestTitle }));
  // dedupe
  const uniqueRequests = linkedRequests.filter(
    (r, i) => linkedRequests.findIndex((lr) => lr.id === r.id) === i
  );

  return (
    <div className="max-w-2xl mx-auto px-4 py-6">
      <div className="flex items-center gap-3 mb-5">
        <button className="text-sm text-gray-400 hover:text-gray-600" onClick={onBack}>
          ←
        </button>
        <div>
          <h2 className="text-lg font-semibold text-gray-900">{project.title}</h2>
          <p className="text-sm text-gray-400">{project.description}</p>
        </div>
      </div>

      {/* Related requests: shows which conversations are linked to this project */}
      {uniqueRequests.length > 0 && (
        <div className="mb-4">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-xs text-gray-400">Related requests:</span>
            {uniqueRequests.map((r) => (
              <button
                key={r.id}
                className="inline-flex items-center gap-1 text-xs text-indigo-600 bg-indigo-50 border border-indigo-100 rounded-full px-2 py-0.5 hover:bg-indigo-100 transition-colors"
                onClick={() => onNavigateRequest && onNavigateRequest(r.id)}
              >
                <ConversationIcon />
                {r.title}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="bg-white border border-gray-200 rounded-lg p-5">
        <div className="flex items-center justify-between mb-3">
          <span className="text-sm text-gray-500">Started {project.startedAt}</span>
          <span className="text-sm font-medium text-gray-700">{done} of {project.tasks.length} complete</span>
        </div>
        <ProgressBar tasks={project.tasks} />
        <div className="mt-4 space-y-1">
          {project.tasks.map((t) => (
            <TaskRow
              key={t.id}
              task={t}
              context="project"
              onNavigateRequest={(reqId) => onNavigateRequest && onNavigateRequest(reqId)}
            />
          ))}
        </div>
      </div>

      {/* Wireframe annotation explaining the cross-references */}
      <div className="mt-4 bg-gray-100 border border-gray-200 rounded-lg p-3 text-xs text-gray-500 italic">
        <span className="font-medium not-italic text-gray-600">Wireframe note:</span> Tasks are a single entity.
        The <span className="inline-flex items-center gap-0.5 not-italic"><ConversationIcon /> icon</span> on
        "Configure SAML endpoint for EU domain" indicates this task is also being discussed in a request thread.
        Clicking navigates to that conversation.
      </div>
    </div>
  );
}

// ─── Login ──────────────────────────────────────────────────────────────────

function LoginScreen({ onLogin }) {
  const [email, setEmail] = useState("jane@acme.com");
  const [password, setPassword] = useState("");

  return (
    <div className="h-screen flex items-center justify-center bg-gray-50">
      <div className="w-full max-w-sm">
        <div className="bg-white border border-gray-200 rounded-xl p-6 shadow-sm">
          <div className="text-center mb-6">
            <div
              className="w-12 h-12 rounded-xl mx-auto mb-3 flex items-center justify-center text-white text-lg font-semibold"
              style={{ backgroundColor: MOCK_ORG.primaryColor }}
            >
              {MOCK_ORG.logoLetter}
            </div>
            <h1 className="text-lg font-semibold text-gray-900">{MOCK_ORG.name}</h1>
            <p className="text-sm text-gray-500 mt-1">Sign in to continue</p>
          </div>
          <div className="space-y-3">
            <div>
              <label className="block text-sm text-gray-600 mb-1">Email</label>
              <input
                className="w-full border border-gray-200 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-1 focus:ring-gray-300"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>
            <div>
              <label className="block text-sm text-gray-600 mb-1">Password</label>
              <input
                className="w-full border border-gray-200 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-1 focus:ring-gray-300"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Enter password"
              />
            </div>
            <button
              className="w-full text-white text-sm py-2.5 rounded-lg hover:opacity-90 transition-opacity font-medium"
              style={{ backgroundColor: MOCK_ORG.primaryColor }}
              onClick={() => onLogin(email)}
            >
              Sign in
            </button>
          </div>
        </div>
        <div className="text-center mt-3 text-xs text-gray-400 italic">
          White-label: customer sees their branding, not platform branding.
          SSO button appears here when configured.
        </div>
      </div>
    </div>
  );
}

// ─── Root ───────────────────────────────────────────────────────────────────

export default function PortalWireframe() {
  const [view, setView] = useState("login");
  const [activeTab, setActiveTab] = useState("requests");
  const [selectedRequest, setSelectedRequest] = useState(null);
  const [selectedProject, setSelectedProject] = useState(null);

  const handleLogin = () => setView("home");

  if (view === "login") {
    return <LoginScreen onLogin={handleLogin} />;
  }

  const handleTabChange = (tab) => {
    setActiveTab(tab);
    setView("home");
    setSelectedRequest(null);
    setSelectedProject(null);
  };

  // Cross-navigation: request → project
  const navigateToProject = (projectRef) => {
    const project = MOCK_PROJECTS.find((p) => p.id === projectRef.id);
    if (project) {
      setSelectedProject(project);
      setActiveTab("projects");
      setView("projectDetail");
    }
  };

  // Cross-navigation: project task → request
  const navigateToRequest = (requestId) => {
    const request = MOCK_REQUESTS.find((r) => r.id === requestId);
    if (request) {
      setSelectedRequest(request);
      setActiveTab("requests");
      setView("conversation");
    }
  };

  return (
    <div className="h-screen flex flex-col bg-gray-50 font-sans">
      <PortalNav activeTab={activeTab} onTabChange={handleTabChange} />

      <div className="flex-1 overflow-y-auto">
        {view === "home" && activeTab === "requests" && (
          <RequestsView
            onSelectRequest={(req) => {
              setSelectedRequest(req);
              setView("conversation");
            }}
            onNewRequest={() => setView("newRequest")}
            onNavigateProject={navigateToProject}
          />
        )}

        {view === "home" && activeTab === "projects" && (
          <ProjectsView
            onSelectProject={(proj) => {
              setSelectedProject(proj);
              setView("projectDetail");
            }}
          />
        )}

        {view === "conversation" && selectedRequest && (
          <ConversationView
            request={selectedRequest}
            onBack={() => {
              setView("home");
              setActiveTab("requests");
            }}
            onNavigateProject={navigateToProject}
          />
        )}

        {view === "newRequest" && (
          <NewRequestForm
            onSubmit={() => {
              setView("home");
              setActiveTab("requests");
            }}
            onCancel={() => {
              setView("home");
              setActiveTab("requests");
            }}
          />
        )}

        {view === "projectDetail" && selectedProject && (
          <ProjectDetail
            project={selectedProject}
            onBack={() => {
              setView("home");
              setActiveTab("projects");
            }}
            onNavigateRequest={navigateToRequest}
          />
        )}
      </div>

      {/* Wireframe annotation bar */}
      <div className="bg-gray-800 text-gray-400 text-xs px-5 py-2 flex items-center gap-3 flex-wrap">
        <span className="text-gray-500 font-medium">v0.3 wireframe</span>
        <span className="text-gray-600">|</span>
        <span>Tasks are one entity, visible on both requests and projects</span>
        <span className="text-gray-600">|</span>
        <span>Cross-references are clickable (project badge on request #3, conversation icon on project task)</span>
        <span className="text-gray-600">|</span>
        <span>No internal notes visible</span>
      </div>
    </div>
  );
}

import { useState } from "react";

const MOCK_REQUESTS = [
  {
    id: 1,
    title: "TLS security error — site appears down",
    state: "active",
    urgency: "urgent",
    filedAt: "2 hours ago",
    lastUpdate: "Looking into this now. Checking the certificate chain and will update shortly.",
    lastUpdateBy: "operator",
    lastUpdateTime: "1h ago",
    messages: [
      { author: "You", role: "contact", time: "2h ago", body: "Hi — it looks like the site is down. We're getting a TLS security error when trying to access portal.acme.com. Any way to get that back up? Is it something on our end?" },
      { author: "You", role: "contact", time: "1h 30m ago", body: "Update: our IT team says DNS looks fine on our end. The cert might be expired?" },
      { author: "Service Team", role: "operator", time: "1h ago", body: "Looking into this now. Checking the certificate chain and will update shortly. Initial check shows the cert is valid but there may be an intermediate cert issue." },
    ],
    tasks: [
      { title: "Investigate TLS certificate chain", state: "in_progress" },
      { title: "Apply fix and verify", state: "open" },
    ],
  },
  {
    id: 2,
    title: "Lock down page A, leave page B public",
    state: "active",
    urgency: "normal",
    filedAt: "1 day ago",
    lastUpdate: "This is possible. We can do it by authentication requirement per route. Let me outline the options.",
    lastUpdateBy: "operator",
    lastUpdateTime: "4h ago",
    messages: [
      { author: "You", role: "contact", time: "1d ago", body: "Is it possible to lock down page A, but leave page B available for anyone to access? Can that be done by IP address or does it require authentication?" },
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
    lastUpdate: "SAML metadata received. Working on configuration.",
    lastUpdateBy: "operator",
    lastUpdateTime: "4h ago",
    messages: [
      { author: "Mike Torres", role: "contact", time: "3d ago", body: "We need to add auth.acme-eu.com as an additional domain for SSO. Same SAML config as the primary domain." },
      { author: "Service Team", role: "operator", time: "3d ago", body: "Got it. I'll need the SAML metadata XML for the new domain. Can you export that from your IdP?" },
      { author: "Mike Torres", role: "contact", time: "2d ago", body: "Here's the metadata. [attachment: saml-metadata-eu.xml]" },
      { author: "Service Team", role: "operator", time: "4h ago", body: "SAML metadata received. Working on configuration. Will need to verify certificate coverage for the new domain first." },
      { author: "Mike Torres", role: "contact", time: "30m ago", body: "Any update on this? We're planning to roll out the EU portal next week." },
    ],
    tasks: [
      { title: "Configure SAML endpoint for EU domain", state: "open" },
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
    lastUpdate: "Password reset complete. New credentials sent securely.",
    lastUpdateBy: "operator",
    lastUpdateTime: "2 weeks ago",
    messages: [],
    tasks: [],
  },
];

const MOCK_PROJECT = {
  title: "SSO Configuration",
  startedAt: "Jan 15",
  tasks: [
    { title: "Collect DNS records", state: "done", due: "Jan 16" },
    { title: "Configure SSL certificates", state: "done", due: "Jan 17" },
    { title: "Set up SAML IdP connection", state: "done", due: "Jan 18" },
    { title: "Test SSO login flow", state: "done", due: "Jan 20" },
    { title: "Configure SAML metadata", state: "in_progress", due: "Jan 22" },
    { title: "User acceptance testing", state: "open", due: "Jan 25" },
    { title: "Go-live and monitoring", state: "open", due: "Jan 28" },
  ],
};

function StateBadge({ state }) {
  const colors = {
    active: "bg-green-100 text-green-700",
    waiting: "bg-yellow-100 text-yellow-700",
    resolved: "bg-gray-100 text-gray-500",
    new: "bg-blue-100 text-blue-700",
  };
  return (
    <span className={`text-xs px-2 py-0.5 rounded ${colors[state] || "bg-gray-100 text-gray-500"}`}>
      {state}
    </span>
  );
}

function UrgencyBadge({ urgency }) {
  if (urgency === "normal") return null;
  const colors = {
    elevated: "bg-orange-100 text-orange-700",
    urgent: "bg-red-100 text-red-700",
  };
  return (
    <span className={`text-xs px-2 py-0.5 rounded font-medium ${colors[urgency]}`}>
      {urgency}
    </span>
  );
}

function TaskStateDot({ state }) {
  const colors = {
    done: "bg-green-400",
    in_progress: "bg-blue-400",
    open: "bg-gray-300",
  };
  return <span className={`inline-block w-2.5 h-2.5 rounded-full ${colors[state]}`} />;
}

function RequestCard({ request, onClick }) {
  return (
    <div
      className="bg-white border border-gray-200 rounded-lg p-4 hover:shadow-sm transition-shadow cursor-pointer"
      onClick={() => onClick(request)}
    >
      <div className="flex items-start justify-between mb-1">
        <span className="font-medium text-gray-900 text-sm">{request.title}</span>
        <div className="flex items-center gap-1.5 flex-shrink-0 ml-2">
          <UrgencyBadge urgency={request.urgency} />
          <StateBadge state={request.state} />
        </div>
      </div>
      <div className="text-xs text-gray-400 mb-2">Filed {request.filedAt}</div>
      {request.lastUpdate && (
        <div className="text-sm text-gray-600 bg-gray-50 rounded p-2">
          <span className="text-xs text-gray-400">Last update ({request.lastUpdateTime}): </span>
          {request.lastUpdate}
        </div>
      )}
      {request.tasks.length > 0 && (
        <div className="mt-2 flex items-center gap-2">
          <span className="text-xs text-gray-400">Tasks:</span>
          {request.tasks.map((t, i) => (
            <div key={i} className="flex items-center gap-1">
              <TaskStateDot state={t.state} />
              <span className="text-xs text-gray-500">{t.title}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function ConversationView({ request, onBack }) {
  const [replyText, setReplyText] = useState("");

  return (
    <div className="flex flex-col h-full">
      <div className="border-b border-gray-200 px-4 py-3 flex items-center gap-3 bg-white">
        <button className="text-sm text-gray-500 hover:text-gray-700" onClick={onBack}>
          ← Back
        </button>
        <span className="font-medium text-gray-900">{request.title}</span>
        <StateBadge state={request.state} />
        <UrgencyBadge urgency={request.urgency} />
      </div>

      <div className="flex-1 overflow-y-auto bg-gray-50">
        <div className="max-w-2xl mx-auto p-4 space-y-3">
          {request.messages.map((msg, i) => (
            <div
              key={i}
              className={`flex ${msg.role === "contact" ? "justify-end" : "justify-start"}`}
            >
              <div
                className={`max-w-md rounded-lg px-4 py-2.5 ${
                  msg.role === "contact"
                    ? "bg-indigo-50 border border-indigo-100"
                    : "bg-white border border-gray-200"
                }`}
              >
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-xs font-medium text-gray-700">{msg.author}</span>
                  <span className="text-xs text-gray-400">{msg.time}</span>
                </div>
                <div className="text-sm text-gray-800">{msg.body}</div>
              </div>
            </div>
          ))}
        </div>

        {/* Tasks visible to portal */}
        {request.tasks.length > 0 && (
          <div className="max-w-2xl mx-auto px-4 pb-4">
            <div className="bg-white border border-gray-200 rounded-lg p-3">
              <div className="text-xs text-gray-400 uppercase tracking-wide mb-2">Related tasks</div>
              <div className="space-y-1.5">
                {request.tasks.map((t, i) => (
                  <div key={i} className="flex items-center gap-2">
                    <TaskStateDot state={t.state} />
                    <span className="text-sm text-gray-700">{t.title}</span>
                    <span className="text-xs text-gray-400 capitalize ml-auto">{t.state.replace("_", " ")}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}
      </div>

      <div className="border-t border-gray-200 p-3 bg-white">
        <div className="max-w-2xl mx-auto flex gap-2">
          <input
            className="flex-1 border border-gray-300 rounded px-3 py-2 text-sm"
            placeholder="Write a reply..."
            value={replyText}
            onChange={(e) => setReplyText(e.target.value)}
          />
          <button className="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700 flex items-center gap-1">
            Reply
          </button>
        </div>
      </div>
    </div>
  );
}

function NewRequestForm({ onSubmit, onCancel }) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [urgency, setUrgency] = useState("normal");

  return (
    <div className="max-w-2xl mx-auto p-4">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold text-gray-900">New Request</h2>
        <button className="text-sm text-gray-500 hover:text-gray-700" onClick={onCancel}>
          Cancel
        </button>
      </div>
      <div className="bg-white border border-gray-200 rounded-lg p-4 space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Title</label>
          <input
            className="w-full border border-gray-300 rounded px-3 py-2 text-sm"
            placeholder="Brief description of your request"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Description</label>
          <textarea
            className="w-full border border-gray-300 rounded px-3 py-2 text-sm"
            rows={5}
            placeholder="Details, context, what you need..."
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Urgency <span className="text-gray-400 font-normal">(optional)</span>
          </label>
          <div className="flex gap-2">
            {["normal", "elevated", "urgent"].map((u) => (
              <button
                key={u}
                className={`text-sm px-3 py-1.5 rounded border ${
                  urgency === u
                    ? "border-indigo-500 bg-indigo-50 text-indigo-700"
                    : "border-gray-200 text-gray-500 hover:bg-gray-50"
                }`}
                onClick={() => setUrgency(u)}
              >
                {u}
              </button>
            ))}
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Attachment <span className="text-gray-400 font-normal">(optional)</span>
          </label>
          <div className="border border-dashed border-gray-300 rounded p-4 text-center text-sm text-gray-400">
            Drop a file here or click to browse
          </div>
        </div>
        <div className="flex justify-end">
          <button
            className="bg-indigo-600 text-white text-sm px-6 py-2 rounded hover:bg-indigo-700"
            onClick={() => onSubmit({ title, description, urgency })}
          >
            Submit Request
          </button>
        </div>
      </div>
      <div className="mt-3 text-xs text-gray-400 text-center">
        Only title and description are required. Everything else is optional.
      </div>
    </div>
  );
}

function ProjectView({ project, onBack }) {
  const done = project.tasks.filter((t) => t.state === "done").length;
  const total = project.tasks.length;

  return (
    <div className="max-w-2xl mx-auto p-4">
      <div className="flex items-center gap-3 mb-4">
        <button className="text-sm text-gray-500 hover:text-gray-700" onClick={onBack}>
          ← Back
        </button>
        <h2 className="text-lg font-semibold text-gray-900">{project.title}</h2>
      </div>
      <div className="bg-white border border-gray-200 rounded-lg p-4">
        <div className="flex items-center justify-between mb-3">
          <span className="text-sm text-gray-500">Started {project.startedAt}</span>
          <span className="text-sm font-medium text-gray-700">{done} of {total} complete</span>
        </div>
        <div className="w-full bg-gray-200 rounded-full h-2 mb-4">
          <div
            className="bg-indigo-500 h-2 rounded-full transition-all"
            style={{ width: `${(done / total) * 100}%` }}
          />
        </div>
        <div className="space-y-2">
          {project.tasks.map((t, i) => (
            <div
              key={i}
              className={`flex items-center gap-3 p-2 rounded ${
                t.state === "done" ? "opacity-60" : ""
              }`}
            >
              <TaskStateDot state={t.state} />
              <span className={`text-sm ${t.state === "done" ? "line-through text-gray-400" : "text-gray-800"}`}>
                {t.title}
              </span>
              {t.due && (
                <span className="text-xs text-gray-400 ml-auto">Due: {t.due}</span>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function LoginScreen({ onLogin }) {
  const [email, setEmail] = useState("jane@acme.com");
  const [password, setPassword] = useState("");

  return (
    <div className="h-screen flex items-center justify-center bg-gray-50">
      <div className="w-full max-w-sm">
        <div className="bg-white border border-gray-200 rounded-lg p-6">
          <div className="text-center mb-6">
            <div className="w-12 h-12 bg-indigo-100 rounded-lg mx-auto mb-3 flex items-center justify-center">
              <span className="text-indigo-600 text-lg font-bold">A</span>
            </div>
            <h1 className="text-lg font-semibold text-gray-900">Acme Corp Portal</h1>
            <p className="text-sm text-gray-500 mt-1">Sign in to view your requests</p>
          </div>
          <div className="space-y-3">
            <div>
              <label className="block text-sm text-gray-600 mb-1">Email</label>
              <input
                className="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>
            <div>
              <label className="block text-sm text-gray-600 mb-1">Password</label>
              <input
                className="w-full border border-gray-300 rounded px-3 py-2 text-sm"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Enter password"
              />
            </div>
            <button
              className="w-full bg-indigo-600 text-white text-sm py-2 rounded hover:bg-indigo-700"
              onClick={() => onLogin(email)}
            >
              Sign In
            </button>
          </div>
        </div>
        <div className="text-center mt-3 text-xs text-gray-400">
          White-label: customer sees their own branding, not platform branding
        </div>
      </div>
    </div>
  );
}

export default function PortalWireframe() {
  const [view, setView] = useState("login"); // login | home | conversation | newRequest | project
  const [selectedRequest, setSelectedRequest] = useState(null);
  const [isAdmin, setIsAdmin] = useState(false);
  const [showResolved, setShowResolved] = useState(false);

  const handleLogin = () => setView("home");

  if (view === "login") {
    return <LoginScreen onLogin={handleLogin} />;
  }

  return (
    <div className="h-screen flex flex-col bg-gray-50 font-sans">
      {/* Portal nav */}
      <div className="bg-white border-b border-gray-200 px-4 py-2.5 flex items-center gap-4">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 bg-indigo-100 rounded flex items-center justify-center">
            <span className="text-indigo-600 text-xs font-bold">A</span>
          </div>
          <span className="font-semibold text-gray-900 text-sm">Acme Corp</span>
        </div>
        <div className="flex items-center gap-3 ml-4">
          <button
            className={`text-sm ${view === "home" || view === "newRequest" ? "text-indigo-600 font-medium" : "text-gray-500"}`}
            onClick={() => setView("home")}
          >
            My Requests
          </button>
          <button
            className={`text-sm ${view === "project" ? "text-indigo-600 font-medium" : "text-gray-500"}`}
            onClick={() => {
              setView("project");
            }}
          >
            Projects
          </button>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <label className="flex items-center gap-1.5 text-xs text-gray-400">
            <input
              type="checkbox"
              checked={isAdmin}
              onChange={(e) => setIsAdmin(e.target.checked)}
              className="rounded"
            />
            Admin view (all org conversations)
          </label>
          <span className="text-xs text-gray-400">jane@acme.com</span>
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto">
        {view === "home" && (
          <div className="max-w-2xl mx-auto p-4">
            <div className="flex items-center justify-between mb-4">
              <h1 className="text-lg font-semibold text-gray-900">
                {isAdmin ? "All Organization Requests" : "My Requests"}
              </h1>
              <button
                className="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
                onClick={() => setView("newRequest")}
              >
                + New Request
              </button>
            </div>

            <div className="text-sm font-medium text-gray-500 mb-2">
              Open ({MOCK_REQUESTS.length})
            </div>
            <div className="space-y-2 mb-6">
              {MOCK_REQUESTS.map((r) => (
                <RequestCard
                  key={r.id}
                  request={r}
                  onClick={(req) => {
                    setSelectedRequest(req);
                    setView("conversation");
                  }}
                />
              ))}
            </div>

            {/* Project preview */}
            <div className="text-sm font-medium text-gray-500 mb-2">Active Projects (1)</div>
            <div
              className="bg-white border border-gray-200 rounded-lg p-4 hover:shadow-sm cursor-pointer mb-6"
              onClick={() => setView("project")}
            >
              <div className="font-medium text-gray-900 text-sm">{MOCK_PROJECT.title}</div>
              <div className="text-xs text-gray-400 mt-0.5">
                Started {MOCK_PROJECT.startedAt} · {MOCK_PROJECT.tasks.filter((t) => t.state === "done").length} of {MOCK_PROJECT.tasks.length} tasks complete
              </div>
              <div className="w-full bg-gray-200 rounded-full h-1.5 mt-2">
                <div
                  className="bg-indigo-500 h-1.5 rounded-full"
                  style={{
                    width: `${
                      (MOCK_PROJECT.tasks.filter((t) => t.state === "done").length /
                        MOCK_PROJECT.tasks.length) *
                      100
                    }%`,
                  }}
                />
              </div>
              <div className="text-xs text-gray-500 mt-1.5">
                Next: {MOCK_PROJECT.tasks.find((t) => t.state !== "done")?.title}
              </div>
            </div>

            {/* Resolved */}
            <button
              className="text-sm text-gray-400 hover:text-gray-600"
              onClick={() => setShowResolved(!showResolved)}
            >
              {showResolved ? "Hide" : "Show"} resolved ({MOCK_RESOLVED.length})
            </button>
            {showResolved && (
              <div className="space-y-2 mt-2">
                {MOCK_RESOLVED.map((r) => (
                  <RequestCard key={r.id} request={r} onClick={() => {}} />
                ))}
              </div>
            )}
          </div>
        )}

        {view === "conversation" && selectedRequest && (
          <ConversationView
            request={selectedRequest}
            onBack={() => setView("home")}
          />
        )}

        {view === "newRequest" && (
          <NewRequestForm
            onSubmit={() => setView("home")}
            onCancel={() => setView("home")}
          />
        )}

        {view === "project" && (
          <ProjectView project={MOCK_PROJECT} onBack={() => setView("home")} />
        )}
      </div>

      {/* Footer annotation */}
      <div className="bg-gray-800 text-gray-400 text-xs px-4 py-2 flex gap-4">
        <span>Wireframe: Client Portal</span>
        <span>|</span>
        <span>Toggle "Admin view" to see scoping difference</span>
        <span>|</span>
        <span>Click requests to see conversation thread</span>
        <span>|</span>
        <span>No internal notes visible here</span>
      </div>
    </div>
  );
}

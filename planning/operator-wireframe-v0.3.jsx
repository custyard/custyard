import { useState } from "react";

// ─── Mock Data ──────────────────────────────────────────────────────────────
//
// CONSISTENCY WITH PORTAL WIREFRAME:
//
// The Acme Corp conversations here use identical titles, contacts, and task
// names as the portal wireframe. The operator sees additional data the portal
// doesn't: internal notes, scores, neglect status, non-portal-visible tasks,
// and conversations from other orgs.
//
// Task "Configure SAML endpoint for EU domain" is the same entity in both
// wireframes. Here it shows its project association and portal visibility.
// Conversation #3 links to the SSO Configuration project, same as the portal.

// ── Projects (same data as portal, plus operator-only fields) ───────────────

const MOCK_PROJECTS = [
  {
    id: "p1",
    title: "SSO Configuration",
    description: "Set up SAML SSO for primary and EU domains",
    org: "Acme Corp",
    orgTier: "enterprise",
    startedAt: "Jan 15",
    portalVisible: true,
    tasks: [
      { id: "t1", title: "Collect DNS records", state: "done", due: "Jan 16", portalVisible: true, conversationId: null },
      { id: "t2", title: "Configure SSL certificates", state: "done", due: "Jan 17", portalVisible: true, conversationId: null },
      { id: "t3", title: "Set up SAML IdP connection", state: "done", due: "Jan 18", portalVisible: true, conversationId: null },
      { id: "t4", title: "Test SSO login flow", state: "done", due: "Jan 20", portalVisible: true, conversationId: null },
      { id: "t5", title: "Configure SAML endpoint for EU domain", state: "in_progress", due: "Jan 22", portalVisible: true, conversationId: 3, conversationTitle: "Add auth.acme-eu.com for SSO" },
      { id: "t6", title: "User acceptance testing", state: "open", due: "Jan 25", portalVisible: true, conversationId: null },
      { id: "t7", title: "Go-live and monitoring", state: "open", due: "Jan 28", portalVisible: true, conversationId: null },
    ],
    linkedConversations: [
      { id: 3, title: "Add auth.acme-eu.com for SSO", state: "active" },
    ],
  },
  {
    id: "p2",
    title: "Portal Customization",
    description: "White-label branding and custom domain setup",
    org: "Acme Corp",
    orgTier: "enterprise",
    startedAt: "Feb 1",
    portalVisible: true,
    tasks: [
      { id: "t8", title: "Upload logo and set brand colors", state: "done", due: "Feb 2", portalVisible: true, conversationId: null },
      { id: "t9", title: "Configure custom domain CNAME", state: "done", due: "Feb 3", portalVisible: true, conversationId: null },
      { id: "t10", title: "DNS propagation and TLS provisioning", state: "done", due: "Feb 5", portalVisible: false, conversationId: null },
      { id: "t11", title: "Verify portal renders on custom domain", state: "done", due: "Feb 6", portalVisible: true, conversationId: null },
    ],
    linkedConversations: [],
  },
  {
    id: "p3",
    title: "Redis 8 Upgrade Testing",
    description: "Verify compatibility of internal tooling with Redis 8",
    org: null, // internal project, no org
    orgTier: null,
    startedAt: "Mar 10",
    portalVisible: false,
    isInternal: true,
    tags: ["oss-library", "infrastructure"],
    tasks: [
      { id: "t30", title: "Run test suite against Redis 8 RC", state: "done", due: "Mar 12", portalVisible: false, conversationId: null },
      { id: "t31", title: "Validate key migration patterns", state: "in_progress", due: "Mar 18", portalVisible: false, conversationId: null },
      { id: "t32", title: "Update deployment configs", state: "open", due: "Mar 25", portalVisible: false, conversationId: null },
    ],
    linkedConversations: [],
  },
];

// ── Conversations ───────────────────────────────────────────────────────────

const MOCK_CONVERSATIONS = [
  {
    id: 1,
    org: "Acme Corp",
    orgTier: "enterprise",
    contact: "Jane Smith",
    title: "TLS security error — site appears down", // matches portal
    state: "new",
    urgency: "urgent",
    tags: ["incident", "tls"],
    project: null, // standalone
    lastOperatorAction: null,
    idleHours: 2,
    messageCount: 3,
    neglect: "warning",
    score: 94,
    scoreBreakdown: { idle: 22, state: 30, tier: 20, urgency: 15, velocity: 7 },
    snoozedUntil: null,
    messages: [
      { author: "Jane Smith", role: "contact", source: "email", time: "10:14 AM", body: "Hi — it looks like the site is down. We're getting a TLS security error when trying to access portal.acme.com. Any way to get that back up? Is it something on our end?" },
      { author: "Jane Smith", role: "contact", source: "email", time: "10:32 AM", body: "Update: our IT team says DNS looks fine on our end. The cert might be expired?" },
      { author: "System", role: "system", source: "system", time: "10:33 AM", body: "Urgency auto-elevated: keyword match on 'down'" },
    ],
    tasks: [
      { id: "t20", title: "Investigate TLS certificate chain", state: "in_progress", portalVisible: true, projectId: null },
      { id: "t21", title: "Apply fix and verify", state: "open", portalVisible: true, projectId: null },
    ],
    relatedConversations: [
      { id: 3, title: "Add auth.acme-eu.com for SSO", state: "active" },
    ],
  },
  {
    id: 2,
    org: "Acme Corp",
    orgTier: "enterprise",
    contact: "Jane Smith",
    title: "Lock down page A, leave page B public", // matches portal
    state: "active",
    urgency: "normal",
    tags: ["question", "access-control"],
    project: null,
    lastOperatorAction: "4h ago",
    idleHours: 4,
    messageCount: 2,
    neglect: null,
    score: 48,
    scoreBreakdown: { idle: 13, state: 15, tier: 20, urgency: 0, velocity: 0 },
    snoozedUntil: null,
    messages: [
      { author: "Jane Smith", role: "contact", source: "portal", time: "Yesterday 8:12 AM", body: "Is it possible to lock down page A, but leave page B available for anyone to access? Can that be done by IP address or does it require authentication?" },
      { author: "You", role: "operator", source: "email", time: "Yesterday 12:30 PM", body: "This is possible. We can do it by authentication requirement per route. Two options: IP-based allowlisting (simpler but less flexible), or requiring login for page A while page B remains public. Which approach fits better?" },
    ],
    tasks: [],
    relatedConversations: [
      { id: 1, title: "TLS security error — site appears down", state: "new" },
      { id: 3, title: "Add auth.acme-eu.com for SSO", state: "active" },
    ],
  },
  {
    id: 3,
    org: "Acme Corp",
    orgTier: "enterprise",
    contact: "Mike Torres",
    title: "Add auth.acme-eu.com for SSO", // matches portal
    state: "active",
    urgency: "normal",
    tags: ["config", "sso"],
    project: { id: "p1", title: "SSO Configuration" }, // linked to project
    lastOperatorAction: "4h ago",
    idleHours: 4,
    messageCount: 5,
    neglect: null,
    score: 61,
    scoreBreakdown: { idle: 18, state: 15, tier: 20, urgency: 0, velocity: 8 },
    snoozedUntil: null,
    messages: [
      { author: "Mike Torres", role: "contact", source: "email", time: "Mon 2:00 PM", body: "We need to add auth.acme-eu.com as an additional domain for SSO. Same SAML config as the primary domain." },
      { author: "You", role: "operator", source: "email", time: "Mon 3:15 PM", body: "Got it. I'll need the SAML metadata XML for the new domain. Can you export that from your IdP?" },
      { author: "Mike Torres", role: "contact", source: "email", time: "Tue 9:00 AM", body: "Here's the metadata. [attachment: saml-metadata-eu.xml]" },
      { author: "You", role: "operator", source: "internal", time: "Tue 10:00 AM", body: "[Internal note] Need to check if the current cert covers *.acme-eu.com or if we need a new one." },
      { author: "You", role: "operator", source: "email", time: "Today 6:30 AM", body: "SAML metadata received. Working on configuration. Will need to verify certificate coverage for the new domain first." },
      { author: "Mike Torres", role: "contact", source: "email", time: "Today 8:30 AM", body: "Any update on this? We're planning to roll out the EU portal next week." },
    ],
    // Same task entity as in the project. portalVisible matches what the portal shows.
    tasks: [
      { id: "t22", title: "Verify cert coverage for acme-eu.com", state: "open", portalVisible: false, projectId: null },
      { id: "t5", title: "Configure SAML endpoint for EU domain", state: "in_progress", portalVisible: true, projectId: "p1", projectTitle: "SSO Configuration" },
    ],
    relatedConversations: [
      { id: 1, title: "TLS security error — site appears down", state: "new" },
    ],
  },
  {
    id: 4,
    org: "Widgets Inc",
    orgTier: "standard",
    contact: "Bob Chen",
    title: "Custom CSV export for quarterly report",
    state: "new",
    urgency: "normal",
    tags: ["feature-request"],
    project: null,
    lastOperatorAction: null,
    idleHours: 26,
    messageCount: 1,
    neglect: "critical",
    score: 82,
    scoreBreakdown: { idle: 35, state: 30, tier: 10, urgency: 0, velocity: 0, neglect: 7 },
    snoozedUntil: null,
    messages: [
      { author: "Bob Chen", role: "contact", source: "portal", time: "Yesterday 8:12 AM", body: "We need to generate a quarterly summary export in CSV format. The current export only does monthly. Can we get a quarterly option added?" },
    ],
    tasks: [],
    relatedConversations: [],
  },
  {
    id: 5,
    org: "NovaTech",
    orgTier: "standard",
    contact: "Sara Lin",
    title: "Update form help text to new copy",
    state: "waiting",
    urgency: "normal",
    tags: ["config", "content"],
    project: null,
    lastOperatorAction: "2d ago",
    idleHours: 48,
    messageCount: 4,
    neglect: null,
    score: 12,
    scoreBreakdown: { idle: 5, state: 0, tier: 10, urgency: 0, velocity: 0 },
    snoozedUntil: null,
    messages: [
      { author: "Sara Lin", role: "contact", source: "email", time: "Last Wed", body: 'Can you update the help text on the registration form? New copy: "Enter your organization email address. Personal email addresses (gmail, yahoo, etc.) are not accepted."' },
      { author: "You", role: "operator", source: "email", time: "Last Thu", body: "Sure. Which form — the main registration or the invite flow?" },
      { author: "Sara Lin", role: "contact", source: "email", time: "Last Fri", body: "Both, actually. But the main registration is higher priority." },
      { author: "You", role: "operator", source: "email", time: "Last Fri", body: "Got it. I'll update the main registration form first. Need to check with you on the invite flow wording since it's slightly different context. I'll send a screenshot when the first one is done." },
    ],
    tasks: [
      { id: "t23", title: "Update registration form help text", state: "in_progress", portalVisible: true, projectId: null },
      { id: "t24", title: "Update invite flow help text", state: "open", portalVisible: true, projectId: null },
    ],
    relatedConversations: [],
  },
  {
    id: 6,
    org: "Meridian Health",
    orgTier: "enterprise",
    contact: "Dr. Anika Patel",
    title: "Data residency question — EU patient records",
    state: "active",
    urgency: "elevated",
    tags: ["compliance", "data-residency"],
    project: null,
    lastOperatorAction: "1h ago",
    idleHours: 1,
    messageCount: 2,
    neglect: null,
    score: 55,
    scoreBreakdown: { idle: 8, state: 15, tier: 20, urgency: 7, velocity: 5 },
    snoozedUntil: null,
    messages: [
      { author: "Dr. Anika Patel", role: "contact", source: "portal", time: "Today 9:00 AM", body: "We need to confirm that EU patient records are stored exclusively in the EU region. Our compliance team is asking for documentation. Can you provide a data residency attestation?" },
      { author: "You", role: "operator", source: "internal", time: "Today 9:45 AM", body: "[Internal note] Check current DB region config for Meridian. They're on the Frankfurt cluster. Need to verify backup replication doesn't cross to US." },
    ],
    tasks: [],
    relatedConversations: [],
  },
];

const SNOOZE_OPTIONS = ["1h", "4h", "1d", "3d"];

// ─── Shared Components ──────────────────────────────────────────────────────
// Visual treatment matches the portal wireframe: pill badges, small dots,
// same color semantics.

function StateBadge({ state }) {
  const styles = {
    new: "bg-blue-50 text-blue-700 border border-blue-200",
    active: "bg-emerald-50 text-emerald-700 border border-emerald-200",
    waiting: "bg-amber-50 text-amber-700 border border-amber-200",
    dormant: "bg-gray-100 text-gray-600 border border-gray-200",
    resolved: "bg-gray-50 text-gray-500 border border-gray-200",
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

function NeglectBadge({ level }) {
  if (!level) return null;
  const styles = {
    warning: "bg-amber-50 text-amber-800 border border-amber-200",
    critical: "bg-red-50 text-red-800 border border-red-200",
  };
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${styles[level]}`}>
      {level === "critical" ? "neglected" : "aging"}
    </span>
  );
}

function TierBadge({ tier }) {
  if (!tier) return null;
  const styles = {
    enterprise: "bg-purple-50 text-purple-700 border border-purple-200",
    standard: "bg-gray-50 text-gray-600 border border-gray-200",
    basic: "bg-gray-50 text-gray-400 border border-gray-200",
  };
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full ${styles[tier]}`}>
      {tier}
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

function EyeIcon() {
  return (
    <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
    </svg>
  );
}

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

// ─── Score Breakdown ────────────────────────────────────────────────────────

function ScoreBreakdown({ breakdown }) {
  const entries = Object.entries(breakdown);
  const total = entries.reduce((s, [, v]) => s + v, 0);
  return (
    <div className="p-2.5 bg-gray-50 rounded-lg text-xs space-y-1.5">
      <div className="font-medium text-gray-600 mb-1">Score breakdown</div>
      {entries.map(([key, val]) => (
        <div key={key} className="flex items-center gap-2">
          <span className="w-16 text-gray-500">{key}</span>
          <div className="flex-1 bg-gray-200 rounded-full h-1.5">
            <div
              className="bg-indigo-400 h-1.5 rounded-full"
              style={{ width: `${Math.min((val / (total || 1)) * 100, 100)}%` }}
            />
          </div>
          <span className="w-6 text-right text-gray-600 tabular-nums">{val}</span>
        </div>
      ))}
    </div>
  );
}

// ─── Queue Card ─────────────────────────────────────────────────────────────

function QueueCard({ convo, onSelect, onSnooze, onNavigateProject }) {
  const [showScore, setShowScore] = useState(false);
  const [showSnooze, setShowSnooze] = useState(false);

  const borderColor = convo.neglect === "critical"
    ? "border-l-red-400"
    : convo.neglect === "warning"
    ? "border-l-amber-400"
    : "border-l-transparent";

  return (
    <div
      className={`bg-white border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors cursor-pointer border-l-4 ${borderColor}`}
      onClick={() => onSelect(convo)}
    >
      <div className="flex items-start justify-between mb-1">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-semibold text-gray-900 text-sm">{convo.org}</span>
          <TierBadge tier={convo.orgTier} />
          <NeglectBadge level={convo.neglect} />
        </div>
        <span className="text-xs text-gray-400 flex-shrink-0">
          {convo.idleHours < 24 ? `${convo.idleHours}h ago` : `${Math.floor(convo.idleHours / 24)}d ago`}
        </span>
      </div>
      <div className="text-xs text-gray-500 mb-1">{convo.contact}</div>
      <div className="flex items-center gap-2 mb-2 flex-wrap">
        <span className="text-sm text-gray-800">{convo.title}</span>
        {convo.project && (
          <ProjectBadge project={convo.project} onClick={onNavigateProject} />
        )}
      </div>
      <div className="flex items-center gap-1.5 flex-wrap">
        <StateBadge state={convo.state} />
        <UrgencyIndicator urgency={convo.urgency} />
        {convo.tags.map((t) => (
          <span key={t} className="text-xs px-1.5 py-0.5 bg-gray-100 text-gray-500 rounded-full">{t}</span>
        ))}
        <span className="text-xs text-gray-400 ml-auto tabular-nums">{convo.messageCount} msg</span>
        <span className="text-xs text-gray-400 tabular-nums">score {convo.score}</span>
      </div>
      <div className="flex items-center gap-2 mt-3">
        <button
          className="text-xs text-gray-400 hover:text-gray-600 px-2 py-1 rounded hover:bg-gray-50 transition-colors"
          onClick={(e) => { e.stopPropagation(); setShowScore(!showScore); }}
        >
          {showScore ? "Hide score" : "Why this rank?"}
        </button>
        <div className="relative">
          <button
            className="text-xs text-gray-400 hover:text-gray-600 px-2 py-1 rounded hover:bg-gray-50 transition-colors"
            onClick={(e) => { e.stopPropagation(); setShowSnooze(!showSnooze); }}
          >
            Snooze
          </button>
          {showSnooze && (
            <div className="absolute top-full left-0 mt-1 bg-white border border-gray-200 rounded-lg shadow-lg z-10 p-1">
              {SNOOZE_OPTIONS.map((opt) => (
                <button
                  key={opt}
                  className="block w-full text-left text-xs px-3 py-1.5 hover:bg-gray-50 rounded"
                  onClick={(e) => { e.stopPropagation(); onSnooze(convo.id, opt); setShowSnooze(false); }}
                >
                  {opt}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
      {showScore && <div className="mt-2"><ScoreBreakdown breakdown={convo.scoreBreakdown} /></div>}
    </div>
  );
}

// ─── Message Bubble ─────────────────────────────────────────────────────────

function MessageBubble({ msg }) {
  const isOperator = msg.role === "operator";
  const isSystem = msg.role === "system";
  const isInternal = msg.source === "internal";

  if (isSystem) {
    return (
      <div className="flex justify-center my-2">
        <span className="text-xs text-gray-400 bg-gray-100 px-3 py-1 rounded-full">{msg.body}</span>
      </div>
    );
  }

  return (
    <div className={`flex ${isOperator ? "justify-end" : "justify-start"} mb-3`}>
      <div
        className={`max-w-lg rounded-lg px-4 py-3 ${
          isInternal
            ? "bg-amber-50 border border-amber-200"
            : isOperator
            ? "bg-indigo-50 border border-indigo-100"
            : "bg-white border border-gray-200"
        }`}
      >
        <div className="flex items-center gap-2 mb-1">
          <span className={`text-xs font-medium ${isOperator ? "text-indigo-700" : "text-gray-700"}`}>
            {msg.author}
          </span>
          {isInternal && (
            <span className="text-xs bg-amber-200 text-amber-800 px-1.5 py-0.5 rounded-full">internal</span>
          )}
          {msg.source !== "internal" && msg.source !== "system" && (
            <span className="text-xs text-gray-400">via {msg.source}</span>
          )}
          <span className="text-xs text-gray-400 ml-auto">{msg.time}</span>
        </div>
        <div className="text-sm text-gray-800 leading-relaxed">{msg.body}</div>
      </div>
    </div>
  );
}

// ─── Conversation Detail ────────────────────────────────────────────────────
// Two-panel: messages on left, metadata/actions on right.
// The right panel shows project context, tasks with project and visibility
// indicators, related conversations, and the score breakdown.

function ConversationDetail({ convo, onBack, onStateChange, onNavigateProject }) {
  const [noteText, setNoteText] = useState("");
  const [replyText, setReplyText] = useState("");

  return (
    <div className="flex h-full">
      {/* Left: message thread */}
      <div className="flex-1 flex flex-col min-w-0">
        <div className="border-b border-gray-200 px-5 py-3 bg-white flex items-center gap-3">
          <button className="text-sm text-gray-400 hover:text-gray-600" onClick={onBack}>
            ←
          </button>
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="font-medium text-gray-900 text-sm">{convo.title}</span>
              <StateBadge state={convo.state === "new" ? "active" : convo.state} />
              <UrgencyIndicator urgency={convo.urgency} />
            </div>
            {convo.project && (
              <div className="mt-0.5">
                <ProjectBadge project={convo.project} onClick={onNavigateProject} />
              </div>
            )}
          </div>
        </div>

        <div className="flex-1 overflow-y-auto px-5 py-4 bg-gray-50 space-y-1">
          {convo.messages.map((msg, i) => (
            <MessageBubble key={i} msg={msg} />
          ))}
        </div>

        <div className="border-t border-gray-200 p-3 space-y-2 bg-white">
          <div className="flex gap-2">
            <input
              className="flex-1 border border-gray-200 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-300"
              placeholder="Reply to customer..."
              value={replyText}
              onChange={(e) => setReplyText(e.target.value)}
            />
            <button className="bg-indigo-600 text-white text-sm px-4 py-2 rounded-lg hover:bg-indigo-700 transition-colors">
              Send
            </button>
          </div>
          <div className="flex gap-2">
            <input
              className="flex-1 border border-amber-200 bg-amber-50 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-amber-300"
              placeholder="Internal note (not visible to customer)..."
              value={noteText}
              onChange={(e) => setNoteText(e.target.value)}
            />
            <button className="bg-amber-500 text-white text-sm px-4 py-2 rounded-lg hover:bg-amber-600 transition-colors">
              Note
            </button>
          </div>
        </div>
      </div>

      {/* Right: metadata panel */}
      <div className="w-72 border-l border-gray-200 bg-white overflow-y-auto">
        <div className="p-4 space-y-5">
          {/* Organization */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-1.5">Organization</div>
            <button className="text-sm text-indigo-600 hover:text-indigo-700 font-medium">{convo.org}</button>
            <div className="mt-1"><TierBadge tier={convo.orgTier} /></div>
          </div>

          {/* Contact */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-1.5">Contact</div>
            <div className="text-sm text-gray-800">{convo.contact}</div>
          </div>

          {/* Project link */}
          {convo.project && (
            <div>
              <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-1.5">Project</div>
              <ProjectBadge project={convo.project} onClick={onNavigateProject} />
            </div>
          )}

          {/* State actions */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-2">Actions</div>
            <div className="space-y-1.5">
              {convo.state !== "waiting" && (
                <button
                  className="w-full text-left text-sm px-3 py-1.5 rounded-lg bg-amber-50 hover:bg-amber-100 text-amber-800 border border-amber-200 transition-colors"
                  onClick={() => onStateChange(convo.id, "waiting")}
                >
                  Waiting on customer
                </button>
              )}
              {convo.state !== "resolved" && (
                <button
                  className="w-full text-left text-sm px-3 py-1.5 rounded-lg bg-emerald-50 hover:bg-emerald-100 text-emerald-800 border border-emerald-200 transition-colors"
                  onClick={() => onStateChange(convo.id, "resolved")}
                >
                  Mark resolved
                </button>
              )}
              {convo.state === "resolved" && (
                <button
                  className="w-full text-left text-sm px-3 py-1.5 rounded-lg bg-blue-50 hover:bg-blue-100 text-blue-800 border border-blue-200 transition-colors"
                  onClick={() => onStateChange(convo.id, "active")}
                >
                  Reopen
                </button>
              )}
            </div>
          </div>

          {/* Tasks with project and visibility indicators */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-2">
              Tasks ({convo.tasks.length})
            </div>
            {convo.tasks.length === 0 ? (
              <div className="text-xs text-gray-400">No tasks yet</div>
            ) : (
              <div className="space-y-2">
                {convo.tasks.map((t) => (
                  <div key={t.id} className="flex items-start gap-2">
                    <TaskStateDot state={t.state} />
                    <div className="flex-1 min-w-0">
                      <div className="text-sm text-gray-700">{t.title}</div>
                      <div className="flex items-center gap-2 mt-0.5">
                        {t.portalVisible && (
                          <span className="inline-flex items-center gap-0.5 text-xs text-gray-400" title="Visible in portal">
                            <EyeIcon /> portal
                          </span>
                        )}
                        {t.projectId && (
                          <span className="inline-flex items-center gap-0.5 text-xs text-indigo-500" title={`Part of ${t.projectTitle}`}>
                            <ProjectIcon /> {t.projectTitle}
                          </span>
                        )}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
            <button className="mt-2 text-xs text-indigo-600 hover:text-indigo-700">+ Add task</button>
          </div>

          {/* Tags */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-1.5">Tags</div>
            <div className="flex flex-wrap gap-1">
              {convo.tags.map((t) => (
                <span key={t} className="text-xs px-1.5 py-0.5 bg-gray-100 text-gray-600 rounded-full">{t}</span>
              ))}
              <button className="text-xs text-indigo-600 px-1">+</button>
            </div>
          </div>

          {/* Related conversations */}
          {convo.relatedConversations.length > 0 && (
            <div>
              <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-1.5">
                Other open ({convo.org})
              </div>
              <div className="space-y-1.5">
                {convo.relatedConversations.map((rc) => (
                  <div key={rc.id} className="text-xs text-gray-600 flex items-center gap-1.5">
                    <StateBadge state={rc.state} />
                    <span className="truncate">{rc.title}</span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Score */}
          <ScoreBreakdown breakdown={convo.scoreBreakdown} />
        </div>
      </div>
    </div>
  );
}

// ─── Neglect Report ─────────────────────────────────────────────────────────

function NeglectReport({ conversations, onSelect, onBack }) {
  const neglected = conversations.filter((c) => c.neglect);
  const grouped = {};
  neglected.forEach((c) => {
    if (!grouped[c.org]) grouped[c.org] = [];
    grouped[c.org].push(c);
  });

  return (
    <div className="max-w-3xl mx-auto p-4">
      <div className="flex items-center gap-3 mb-4">
        <button className="text-sm text-gray-400 hover:text-gray-600" onClick={onBack}>
          ←
        </button>
        <h2 className="text-lg font-semibold text-gray-900">Neglect Report</h2>
        <span className="text-sm text-gray-400">{neglected.length} items past threshold</span>
      </div>
      {Object.entries(grouped).map(([org, items]) => (
        <div key={org} className="mb-5">
          <div className="text-sm font-medium text-gray-700 mb-2">{org}</div>
          <div className="space-y-2">
            {items.map((c) => (
              <div
                key={c.id}
                className="bg-white border border-gray-200 rounded-lg p-3 cursor-pointer hover:border-gray-300 transition-colors flex items-center gap-3"
                onClick={() => onSelect(c)}
              >
                <NeglectBadge level={c.neglect} />
                <span className="text-sm text-gray-800 flex-1">{c.title}</span>
                <span className="text-xs text-gray-400">
                  {c.idleHours < 24 ? `${c.idleHours}h` : `${Math.floor(c.idleHours / 24)}d`} idle
                </span>
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

// ─── Projects View (Operator) ───────────────────────────────────────────────
// The operator sees all projects including internal ones. Projects show their
// org association and linked conversations.

function ProjectsView({ onSelectProject }) {
  const customerProjects = MOCK_PROJECTS.filter((p) => !p.isInternal);
  const internalProjects = MOCK_PROJECTS.filter((p) => p.isInternal);

  return (
    <div className="max-w-3xl mx-auto p-4">
      <h1 className="text-lg font-semibold text-gray-900 mb-5">Projects</h1>

      {customerProjects.length > 0 && (
        <div className="mb-6">
          <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-2">Customer projects</div>
          <div className="space-y-2">
            {customerProjects.map((p) => {
              const done = p.tasks.filter((t) => t.state === "done").length;
              const allDone = p.tasks.every((t) => t.state === "done");
              const next = p.tasks.find((t) => t.state !== "done");
              return (
                <div
                  key={p.id}
                  className={`bg-white border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors cursor-pointer ${allDone ? "opacity-60" : ""}`}
                  onClick={() => onSelectProject(p)}
                >
                  <div className="flex items-start justify-between mb-1">
                    <div>
                      <div className="flex items-center gap-2">
                        <span className="font-medium text-gray-900 text-sm">{p.title}</span>
                        {p.portalVisible && (
                          <span className="inline-flex items-center gap-0.5 text-xs text-gray-400">
                            <EyeIcon />
                          </span>
                        )}
                      </div>
                      <div className="text-xs text-gray-400 mt-0.5">{p.org} · {p.description}</div>
                    </div>
                    <span className="text-xs text-gray-500 tabular-nums">{done}/{p.tasks.length}</span>
                  </div>
                  <ProgressBar tasks={p.tasks} />
                  {next && (
                    <div className="text-xs text-gray-500 mt-2">Next: {next.title}</div>
                  )}
                  {p.linkedConversations.length > 0 && (
                    <div className="flex items-center gap-1.5 mt-2">
                      <ConversationIcon />
                      <span className="text-xs text-gray-400">
                        {p.linkedConversations.length} linked request{p.linkedConversations.length > 1 ? "s" : ""}
                      </span>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}

      {internalProjects.length > 0 && (
        <div>
          <div className="text-xs text-gray-400 uppercase tracking-wide font-medium mb-2">Internal projects</div>
          <div className="space-y-2">
            {internalProjects.map((p) => {
              const done = p.tasks.filter((t) => t.state === "done").length;
              const next = p.tasks.find((t) => t.state !== "done");
              return (
                <div
                  key={p.id}
                  className="bg-white border border-gray-200 rounded-lg p-4 hover:border-gray-300 transition-colors cursor-pointer"
                  onClick={() => onSelectProject(p)}
                >
                  <div className="flex items-start justify-between mb-1">
                    <div>
                      <div className="font-medium text-gray-900 text-sm">{p.title}</div>
                      <div className="text-xs text-gray-400 mt-0.5">{p.description}</div>
                      {p.tags && (
                        <div className="flex gap-1 mt-1">
                          {p.tags.map((t) => (
                            <span key={t} className="text-xs px-1.5 py-0.5 bg-gray-100 text-gray-500 rounded-full">{t}</span>
                          ))}
                        </div>
                      )}
                    </div>
                    <span className="text-xs text-gray-500 tabular-nums">{done}/{p.tasks.length}</span>
                  </div>
                  <ProgressBar tasks={p.tasks} />
                  {next && (
                    <div className="text-xs text-gray-500 mt-2">Next: {next.title}</div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Project Detail (Operator) ──────────────────────────────────────────────
// Shows all tasks with conversation links and portal visibility indicators.

function ProjectDetail({ project, onBack, onNavigateConversation }) {
  const done = project.tasks.filter((t) => t.state === "done").length;

  return (
    <div className="max-w-3xl mx-auto p-4">
      <div className="flex items-center gap-3 mb-5">
        <button className="text-sm text-gray-400 hover:text-gray-600" onClick={onBack}>
          ←
        </button>
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-lg font-semibold text-gray-900">{project.title}</h2>
            {project.portalVisible && (
              <span className="inline-flex items-center gap-0.5 text-xs text-gray-400">
                <EyeIcon /> portal-visible
              </span>
            )}
          </div>
          <p className="text-sm text-gray-400">
            {project.org ? `${project.org} · ` : "Internal · "}{project.description}
          </p>
        </div>
      </div>

      {/* Linked conversations */}
      {project.linkedConversations.length > 0 && (
        <div className="mb-4">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-xs text-gray-400">Linked requests:</span>
            {project.linkedConversations.map((c) => (
              <button
                key={c.id}
                className="inline-flex items-center gap-1 text-xs text-indigo-600 bg-indigo-50 border border-indigo-100 rounded-full px-2 py-0.5 hover:bg-indigo-100 transition-colors"
                onClick={() => onNavigateConversation && onNavigateConversation(c.id)}
              >
                <ConversationIcon />
                {c.title}
                <StateBadge state={c.state} />
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
        <div className="mt-4 space-y-1.5">
          {project.tasks.map((t) => (
            <div
              key={t.id}
              className={`flex items-start gap-2.5 px-2 py-2 rounded ${t.state === "done" ? "opacity-50" : ""}`}
            >
              <TaskStateDot state={t.state} />
              <div className="flex-1 min-w-0">
                <span className={`text-sm ${t.state === "done" ? "line-through text-gray-400" : "text-gray-800"}`}>
                  {t.title}
                </span>
                <div className="flex items-center gap-2 mt-0.5">
                  {t.portalVisible && (
                    <span className="inline-flex items-center gap-0.5 text-xs text-gray-400">
                      <EyeIcon /> portal
                    </span>
                  )}
                  {t.conversationId && (
                    <button
                      className="inline-flex items-center gap-0.5 text-xs text-indigo-500 hover:text-indigo-700 transition-colors"
                      onClick={() => onNavigateConversation && onNavigateConversation(t.conversationId)}
                    >
                      <ConversationIcon /> {t.conversationTitle}
                    </button>
                  )}
                </div>
              </div>
              {t.due && (
                <span className="text-xs text-gray-400 flex-shrink-0">{t.due}</span>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── Root ───────────────────────────────────────────────────────────────────

export default function OperatorWireframe() {
  const [view, setView] = useState("queue");
  const [selectedConvo, setSelectedConvo] = useState(null);
  const [selectedProject, setSelectedProject] = useState(null);
  const [conversations, setConversations] = useState(MOCK_CONVERSATIONS);
  const [snoozed, setSnoozed] = useState([]);
  const [filter, setFilter] = useState("all");
  const [showFilters, setShowFilters] = useState(false);

  const visibleConvos = conversations
    .filter((c) => !snoozed.includes(c.id))
    .filter((c) => filter === "all" || c.state === filter)
    .sort((a, b) => b.score - a.score);

  const handleSelect = (convo) => {
    setSelectedConvo(convo);
    setView("detail");
  };

  const handleSnooze = (id) => {
    setSnoozed([...snoozed, id]);
  };

  const handleStateChange = (id, newState) => {
    setConversations(conversations.map((c) => (c.id === id ? { ...c, state: newState } : c)));
    setView("queue");
  };

  const navigateToProject = (projectRef) => {
    const project = MOCK_PROJECTS.find((p) => p.id === projectRef.id);
    if (project) {
      setSelectedProject(project);
      setView("projectDetail");
    }
  };

  const navigateToConversation = (convoId) => {
    const convo = conversations.find((c) => c.id === convoId);
    if (convo) {
      setSelectedConvo(convo);
      setView("detail");
    }
  };

  const activeNav = view === "queue" || view === "detail" ? "queue"
    : view === "neglect" ? "neglect"
    : view === "projects" || view === "projectDetail" ? "projects"
    : "queue";

  return (
    <div className="h-screen flex flex-col bg-gray-50 font-sans">
      {/* Top nav */}
      <div className="bg-white border-b border-gray-200 px-5 py-3 flex items-center gap-4">
        <span className="font-bold text-gray-900 text-sm tracking-tight">Custyard</span>
        <div className="flex items-center gap-1 ml-4">
          {[
            { key: "queue", label: "Attention Queue", view: "queue" },
            { key: "neglect", label: "Neglect Report", view: "neglect" },
            { key: "projects", label: "Projects", view: "projects" },
          ].map((item) => (
            <button
              key={item.key}
              className={`text-sm px-3 py-1.5 rounded-md transition-colors ${
                activeNav === item.key
                  ? "bg-gray-100 text-gray-900 font-medium"
                  : "text-gray-500 hover:text-gray-700 hover:bg-gray-50"
              }`}
              onClick={() => setView(item.view)}
            >
              {item.label}
            </button>
          ))}
          <button className="text-sm px-3 py-1.5 rounded-md text-gray-500 hover:text-gray-700 hover:bg-gray-50 transition-colors">
            Organizations
          </button>
          <button className="text-sm px-3 py-1.5 rounded-md text-gray-500 hover:text-gray-700 hover:bg-gray-50 transition-colors">
            Settings
          </button>
        </div>
        <div className="ml-auto flex items-center gap-3">
          {snoozed.length > 0 && (
            <span className="text-xs text-gray-400">{snoozed.length} snoozed</span>
          )}
          <span className="text-xs text-gray-400 tabular-nums">{visibleConvos.length} in queue</span>
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-hidden">
        {view === "queue" && (
          <div className="h-full overflow-y-auto">
            <div className="max-w-3xl mx-auto p-4">
              <div className="flex items-center justify-between mb-3">
                <h1 className="text-lg font-semibold text-gray-900">What needs attention</h1>
                <button
                  className="text-xs text-gray-400 hover:text-gray-600"
                  onClick={() => setShowFilters(!showFilters)}
                >
                  {showFilters ? "Hide filters" : "Filters"}
                </button>
              </div>
              {showFilters && (
                <div className="flex gap-1.5 mb-3">
                  {["all", "new", "active", "waiting", "dormant"].map((f) => (
                    <button
                      key={f}
                      className={`text-xs px-2.5 py-1 rounded-full transition-colors ${
                        filter === f
                          ? "bg-indigo-50 text-indigo-700 border border-indigo-200"
                          : "bg-gray-100 text-gray-500 hover:bg-gray-200 border border-transparent"
                      }`}
                      onClick={() => setFilter(f)}
                    >
                      {f}
                    </button>
                  ))}
                </div>
              )}
              <div className="space-y-2">
                {visibleConvos.map((c) => (
                  <QueueCard
                    key={c.id}
                    convo={c}
                    onSelect={handleSelect}
                    onSnooze={handleSnooze}
                    onNavigateProject={navigateToProject}
                  />
                ))}
                {visibleConvos.length === 0 && (
                  <div className="text-center text-gray-400 py-12">
                    Nothing needs attention right now.
                  </div>
                )}
              </div>
            </div>
          </div>
        )}

        {view === "detail" && selectedConvo && (
          <ConversationDetail
            convo={selectedConvo}
            onBack={() => setView("queue")}
            onStateChange={handleStateChange}
            onNavigateProject={navigateToProject}
          />
        )}

        {view === "neglect" && (
          <NeglectReport
            conversations={conversations}
            onSelect={handleSelect}
            onBack={() => setView("queue")}
          />
        )}

        {view === "projects" && (
          <ProjectsView onSelectProject={(p) => { setSelectedProject(p); setView("projectDetail"); }} />
        )}

        {view === "projectDetail" && selectedProject && (
          <ProjectDetail
            project={selectedProject}
            onBack={() => setView("projects")}
            onNavigateConversation={navigateToConversation}
          />
        )}
      </div>

      {/* Wireframe annotation */}
      <div className="bg-gray-800 text-gray-400 text-xs px-5 py-2 flex items-center gap-3 flex-wrap">
        <span className="text-gray-500 font-medium">v0.3 wireframe</span>
        <span className="text-gray-600">|</span>
        <span>Conversation titles and task names match portal wireframe exactly</span>
        <span className="text-gray-600">|</span>
        <span>Tasks show project + portal-visibility indicators</span>
        <span className="text-gray-600">|</span>
        <span>Internal notes (amber) never visible in portal</span>
        <span className="text-gray-600">|</span>
        <span>Cross-nav: project badges and conversation links are clickable</span>
      </div>
    </div>
  );
}

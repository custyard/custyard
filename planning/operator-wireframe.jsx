import { useState } from "react";

const MOCK_CONVERSATIONS = [
  {
    id: 1,
    org: "Acme Corp",
    orgTier: "enterprise",
    contact: "Jane Smith",
    title: "TLS security error — site appears down",
    state: "new",
    urgency: "urgent",
    tags: ["incident", "tls"],
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
    tasks: [],
    relatedConversations: [
      { id: 99, title: "SSO configuration for SAML", state: "waiting" },
      { id: 100, title: "Update help text on settings page", state: "active" },
    ],
  },
  {
    id: 2,
    org: "Widgets Inc",
    orgTier: "standard",
    contact: "Bob Chen",
    title: "Can we lock down page A but leave page B public?",
    state: "new",
    urgency: "normal",
    tags: ["question", "access-control"],
    lastOperatorAction: null,
    idleHours: 26,
    messageCount: 1,
    neglect: "critical",
    score: 82,
    scoreBreakdown: { idle: 35, state: 30, tier: 10, urgency: 0, velocity: 0, neglectBonus: 7 },
    snoozedUntil: null,
    messages: [
      { author: "Bob Chen", role: "contact", source: "portal", time: "Yesterday 8:12 AM", body: "Is it possible to lock down page A, but leave page B available for anyone to access? Can that be done by IP address or does it require authentication?" },
    ],
    tasks: [],
    relatedConversations: [],
  },
  {
    id: 3,
    org: "Acme Corp",
    orgTier: "enterprise",
    contact: "Mike Torres",
    title: "Add new domain for SSO authentication",
    state: "active",
    urgency: "normal",
    tags: ["config", "sso"],
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
      { author: "Mike Torres", role: "contact", source: "email", time: "Today 8:30 AM", body: "Any update on this? We're planning to roll out the EU portal next week." },
    ],
    tasks: [
      { id: 1, title: "Verify cert coverage for acme-eu.com", state: "open", portalVisible: false },
      { id: 2, title: "Configure SAML endpoint for EU domain", state: "open", portalVisible: true },
    ],
    relatedConversations: [
      { id: 1, title: "TLS security error — site appears down", state: "new" },
    ],
  },
  {
    id: 4,
    org: "NovaTech",
    orgTier: "standard",
    contact: "Sara Lin",
    title: "Update form help text to new copy",
    state: "waiting",
    urgency: "normal",
    tags: ["config", "content"],
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
      { id: 3, title: "Update registration form help text", state: "in_progress", portalVisible: true },
      { id: 4, title: "Update invite flow help text", state: "open", portalVisible: true },
    ],
    relatedConversations: [],
  },
  {
    id: 5,
    org: "Meridian Health",
    orgTier: "enterprise",
    contact: "Dr. Anika Patel",
    title: "Data residency question — EU patient records",
    state: "active",
    urgency: "elevated",
    tags: ["compliance", "data-residency"],
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

function NeglectBadge({ level }) {
  if (!level) return null;
  const colors = {
    warning: "bg-amber-100 text-amber-800 border-amber-300",
    critical: "bg-red-100 text-red-800 border-red-300",
  };
  return (
    <span className={`text-xs px-1.5 py-0.5 rounded border ${colors[level]}`}>
      {level === "critical" ? "NEGLECTED" : "aging"}
    </span>
  );
}

function StateBadge({ state }) {
  const colors = {
    new: "bg-blue-100 text-blue-800",
    active: "bg-green-100 text-green-800",
    waiting: "bg-yellow-100 text-yellow-800",
    dormant: "bg-gray-100 text-gray-600",
    resolved: "bg-gray-100 text-gray-400",
  };
  return (
    <span className={`text-xs px-1.5 py-0.5 rounded ${colors[state]}`}>
      {state}
    </span>
  );
}

function UrgencyBadge({ urgency }) {
  if (urgency === "normal") return null;
  const colors = {
    elevated: "bg-orange-100 text-orange-800",
    urgent: "bg-red-100 text-red-800",
  };
  return (
    <span className={`text-xs px-1.5 py-0.5 rounded font-medium ${colors[urgency]}`}>
      {urgency}
    </span>
  );
}

function TierBadge({ tier }) {
  const colors = {
    enterprise: "text-purple-700 bg-purple-50",
    standard: "text-gray-600 bg-gray-50",
    basic: "text-gray-400 bg-gray-50",
  };
  return (
    <span className={`text-xs px-1.5 py-0.5 rounded ${colors[tier]}`}>
      {tier}
    </span>
  );
}

function ScoreBreakdown({ breakdown }) {
  const entries = Object.entries(breakdown);
  const total = entries.reduce((s, [, v]) => s + v, 0);
  return (
    <div className="mt-2 p-2 bg-gray-50 rounded text-xs space-y-1">
      <div className="font-medium text-gray-700 mb-1">Score breakdown</div>
      {entries.map(([key, val]) => (
        <div key={key} className="flex items-center gap-2">
          <span className="w-20 text-gray-500">{key}</span>
          <div className="flex-1 bg-gray-200 rounded-full h-1.5">
            <div
              className="bg-indigo-400 h-1.5 rounded-full"
              style={{ width: `${(val / total) * 100}%` }}
            />
          </div>
          <span className="w-6 text-right text-gray-600">{val}</span>
        </div>
      ))}
    </div>
  );
}

function QueueCard({ convo, onSelect, onSnooze }) {
  const [showScore, setShowScore] = useState(false);
  const [showSnooze, setShowSnooze] = useState(false);

  const borderColor = convo.neglect === "critical"
    ? "border-l-red-500"
    : convo.neglect === "warning"
    ? "border-l-amber-400"
    : "border-l-transparent";

  return (
    <div
      className={`bg-white border border-gray-200 rounded-lg p-4 hover:shadow-md transition-shadow cursor-pointer border-l-4 ${borderColor}`}
      onClick={() => onSelect(convo)}
    >
      <div className="flex items-start justify-between mb-1">
        <div className="flex items-center gap-2">
          <span className="font-semibold text-gray-900">{convo.org}</span>
          <TierBadge tier={convo.orgTier} />
          <NeglectBadge level={convo.neglect} />
        </div>
        <span className="text-sm text-gray-400">
          {convo.idleHours < 24 ? `${convo.idleHours}h ago` : `${Math.floor(convo.idleHours / 24)}d ago`}
        </span>
      </div>
      <div className="text-sm text-gray-500 mb-1">{convo.contact}</div>
      <div className="text-sm text-gray-800 mb-2">{convo.title}</div>
      <div className="flex items-center gap-2 flex-wrap">
        <StateBadge state={convo.state} />
        <UrgencyBadge urgency={convo.urgency} />
        {convo.tags.map((t) => (
          <span key={t} className="text-xs px-1.5 py-0.5 bg-gray-100 text-gray-500 rounded">{t}</span>
        ))}
        <span className="text-xs text-gray-400 ml-auto">{convo.messageCount} msg</span>
        <span className="text-xs text-gray-400">score: {convo.score}</span>
      </div>
      <div className="flex items-center gap-2 mt-3">
        <button
          className="text-xs text-gray-500 hover:text-gray-700 px-2 py-1 rounded hover:bg-gray-100"
          onClick={(e) => {
            e.stopPropagation();
            setShowScore(!showScore);
          }}
        >
          {showScore ? "Hide score" : "Why this rank?"}
        </button>
        <div className="relative">
          <button
            className="text-xs text-gray-500 hover:text-gray-700 px-2 py-1 rounded hover:bg-gray-100"
            onClick={(e) => {
              e.stopPropagation();
              setShowSnooze(!showSnooze);
            }}
          >
            Snooze
          </button>
          {showSnooze && (
            <div className="absolute top-full left-0 mt-1 bg-white border border-gray-200 rounded shadow-lg z-10 p-1">
              {SNOOZE_OPTIONS.map((opt) => (
                <button
                  key={opt}
                  className="block w-full text-left text-xs px-3 py-1.5 hover:bg-gray-100 rounded"
                  onClick={(e) => {
                    e.stopPropagation();
                    onSnooze(convo.id, opt);
                    setShowSnooze(false);
                  }}
                >
                  {opt}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
      {showScore && <ScoreBreakdown breakdown={convo.scoreBreakdown} />}
    </div>
  );
}

function MessageBubble({ msg }) {
  const isOperator = msg.role === "operator";
  const isSystem = msg.role === "system";
  const isInternal = msg.source === "internal";

  if (isSystem) {
    return (
      <div className="flex justify-center my-2">
        <span className="text-xs text-gray-400 bg-gray-50 px-3 py-1 rounded-full">{msg.body}</span>
      </div>
    );
  }

  return (
    <div className={`flex ${isOperator ? "justify-end" : "justify-start"} mb-3`}>
      <div
        className={`max-w-lg rounded-lg px-4 py-2.5 ${
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
            <span className="text-xs bg-amber-200 text-amber-800 px-1.5 py-0.5 rounded">internal note</span>
          )}
          <span className="text-xs text-gray-400">
            {msg.source !== "internal" && msg.source !== "system" ? `via ${msg.source}` : ""}
          </span>
          <span className="text-xs text-gray-400 ml-auto">{msg.time}</span>
        </div>
        <div className="text-sm text-gray-800">{msg.body}</div>
      </div>
    </div>
  );
}

function ConversationDetail({ convo, onBack, onStateChange }) {
  const [noteText, setNoteText] = useState("");
  const [replyText, setReplyText] = useState("");

  return (
    <div className="flex h-full">
      {/* Left: message thread */}
      <div className="flex-1 flex flex-col min-w-0">
        <div className="border-b border-gray-200 px-4 py-3 flex items-center gap-3">
          <button
            className="text-sm text-gray-500 hover:text-gray-700"
            onClick={onBack}
          >
            ← Queue
          </button>
          <span className="font-semibold text-gray-900">{convo.title}</span>
          <StateBadge state={convo.state === "new" ? "active" : convo.state} />
        </div>

        <div className="flex-1 overflow-y-auto px-4 py-4 bg-gray-50 space-y-1">
          {convo.messages.map((msg, i) => (
            <MessageBubble key={i} msg={msg} />
          ))}
        </div>

        <div className="border-t border-gray-200 p-3 space-y-2">
          <div className="flex gap-2">
            <input
              className="flex-1 border border-gray-300 rounded px-3 py-2 text-sm"
              placeholder="Reply to customer..."
              value={replyText}
              onChange={(e) => setReplyText(e.target.value)}
            />
            <button className="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700">
              Send
            </button>
          </div>
          <div className="flex gap-2">
            <input
              className="flex-1 border border-amber-300 bg-amber-50 rounded px-3 py-2 text-sm"
              placeholder="Internal note (not visible to customer)..."
              value={noteText}
              onChange={(e) => setNoteText(e.target.value)}
            />
            <button className="bg-amber-500 text-white text-sm px-4 py-2 rounded hover:bg-amber-600">
              Note
            </button>
          </div>
        </div>
      </div>

      {/* Right: metadata panel */}
      <div className="w-72 border-l border-gray-200 bg-white overflow-y-auto">
        <div className="p-4 space-y-4">
          {/* Organization */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide mb-1">Organization</div>
            <button className="text-sm text-indigo-600 hover:underline font-medium">{convo.org}</button>
            <div className="mt-1">
              <TierBadge tier={convo.orgTier} />
            </div>
          </div>

          {/* Contact */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide mb-1">Contact</div>
            <div className="text-sm text-gray-800">{convo.contact}</div>
          </div>

          {/* State actions */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide mb-2">Actions</div>
            <div className="space-y-1.5">
              <button
                className="w-full text-left text-sm px-3 py-1.5 rounded bg-yellow-50 hover:bg-yellow-100 text-yellow-800 border border-yellow-200"
                onClick={() => onStateChange(convo.id, "waiting")}
              >
                Waiting on customer
              </button>
              <button
                className="w-full text-left text-sm px-3 py-1.5 rounded bg-green-50 hover:bg-green-100 text-green-800 border border-green-200"
                onClick={() => onStateChange(convo.id, "resolved")}
              >
                Mark resolved
              </button>
            </div>
          </div>

          {/* Tasks */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide mb-2">
              Tasks ({convo.tasks.length})
            </div>
            {convo.tasks.length === 0 ? (
              <div className="text-xs text-gray-400">No tasks yet</div>
            ) : (
              <div className="space-y-1">
                {convo.tasks.map((t) => (
                  <div key={t.id} className="flex items-start gap-2 text-sm">
                    <span className={`mt-0.5 w-2 h-2 rounded-full flex-shrink-0 ${
                      t.state === "done" ? "bg-green-400" : t.state === "in_progress" ? "bg-blue-400" : "bg-gray-300"
                    }`} />
                    <span className="text-gray-700">{t.title}</span>
                    {t.portalVisible && (
                      <span className="text-xs text-gray-400 ml-auto" title="Visible in portal">👁</span>
                    )}
                  </div>
                ))}
              </div>
            )}
            <button className="mt-2 text-xs text-indigo-600 hover:underline">+ Add task</button>
          </div>

          {/* Tags */}
          <div>
            <div className="text-xs text-gray-400 uppercase tracking-wide mb-1">Tags</div>
            <div className="flex flex-wrap gap-1">
              {convo.tags.map((t) => (
                <span key={t} className="text-xs px-1.5 py-0.5 bg-gray-100 text-gray-600 rounded">{t}</span>
              ))}
              <button className="text-xs text-indigo-600">+</button>
            </div>
          </div>

          {/* Related conversations */}
          {convo.relatedConversations.length > 0 && (
            <div>
              <div className="text-xs text-gray-400 uppercase tracking-wide mb-1">
                Other open ({convo.org})
              </div>
              <div className="space-y-1">
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

function NeglectReport({ conversations, onSelect, onBack }) {
  const neglected = conversations.filter((c) => c.neglect);
  const grouped = {};
  neglected.forEach((c) => {
    if (!grouped[c.org]) grouped[c.org] = [];
    grouped[c.org].push(c);
  });

  return (
    <div className="p-4">
      <div className="flex items-center gap-3 mb-4">
        <button className="text-sm text-gray-500 hover:text-gray-700" onClick={onBack}>
          ← Queue
        </button>
        <h2 className="text-lg font-semibold text-gray-900">Neglect Report</h2>
        <span className="text-sm text-gray-400">{neglected.length} items past threshold</span>
      </div>
      {Object.entries(grouped).map(([org, items]) => (
        <div key={org} className="mb-4">
          <div className="text-sm font-medium text-gray-700 mb-2">{org}</div>
          <div className="space-y-2">
            {items.map((c) => (
              <div
                key={c.id}
                className="bg-white border border-gray-200 rounded p-3 cursor-pointer hover:shadow-sm flex items-center gap-3"
                onClick={() => onSelect(c)}
              >
                <NeglectBadge level={c.neglect} />
                <span className="text-sm text-gray-800">{c.title}</span>
                <span className="text-xs text-gray-400 ml-auto">
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

export default function OperatorWireframe() {
  const [view, setView] = useState("queue"); // queue | detail | neglect
  const [selectedConvo, setSelectedConvo] = useState(null);
  const [conversations, setConversations] = useState(MOCK_CONVERSATIONS);
  const [snoozed, setSnoozed] = useState([]);
  const [filter, setFilter] = useState("all");
  const [showFilters, setShowFilters] = useState(false);

  const visibleConvos = conversations
    .filter((c) => !snoozed.includes(c.id))
    .filter((c) => {
      if (filter === "all") return true;
      return c.state === filter;
    })
    .sort((a, b) => b.score - a.score);

  const handleSelect = (convo) => {
    setSelectedConvo(convo);
    setView("detail");
  };

  const handleSnooze = (id, duration) => {
    setSnoozed([...snoozed, id]);
  };

  const handleStateChange = (id, newState) => {
    setConversations(
      conversations.map((c) => (c.id === id ? { ...c, state: newState } : c))
    );
    setView("queue");
  };

  return (
    <div className="h-screen flex flex-col bg-gray-100 font-sans">
      {/* Top nav */}
      <div className="bg-white border-b border-gray-200 px-4 py-2 flex items-center gap-4">
        <span className="font-bold text-gray-900 text-sm tracking-tight">Service Platform</span>
        <span className="text-gray-300">|</span>
        <button
          className={`text-sm ${view === "queue" ? "text-indigo-600 font-medium" : "text-gray-500 hover:text-gray-700"}`}
          onClick={() => setView("queue")}
        >
          Attention Queue
        </button>
        <button
          className={`text-sm ${view === "neglect" ? "text-indigo-600 font-medium" : "text-gray-500 hover:text-gray-700"}`}
          onClick={() => setView("neglect")}
        >
          Neglect Report
        </button>
        <button className="text-sm text-gray-500 hover:text-gray-700">Organizations</button>
        <button className="text-sm text-gray-500 hover:text-gray-700">Settings</button>
        <div className="ml-auto flex items-center gap-2">
          {snoozed.length > 0 && (
            <span className="text-xs text-gray-400">{snoozed.length} snoozed</span>
          )}
          <span className="text-xs text-gray-400">
            {visibleConvos.length} items
          </span>
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
                  className="text-xs text-gray-500 hover:text-gray-700"
                  onClick={() => setShowFilters(!showFilters)}
                >
                  {showFilters ? "Hide filters" : "Filters"}
                </button>
              </div>
              {showFilters && (
                <div className="flex gap-2 mb-3">
                  {["all", "new", "active", "waiting", "dormant"].map((f) => (
                    <button
                      key={f}
                      className={`text-xs px-2.5 py-1 rounded ${
                        filter === f
                          ? "bg-indigo-100 text-indigo-700"
                          : "bg-gray-100 text-gray-500 hover:bg-gray-200"
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
          />
        )}

        {view === "neglect" && (
          <NeglectReport
            conversations={conversations}
            onSelect={handleSelect}
            onBack={() => setView("queue")}
          />
        )}
      </div>

      {/* Footer annotation */}
      <div className="bg-gray-800 text-gray-400 text-xs px-4 py-2 flex gap-4">
        <span>Wireframe: Operator Interface</span>
        <span>|</span>
        <span>Click queue items to open conversation detail</span>
        <span>|</span>
        <span>"Why this rank?" expands score breakdown</span>
        <span>|</span>
        <span>Snooze removes from queue temporarily</span>
      </div>
    </div>
  );
}

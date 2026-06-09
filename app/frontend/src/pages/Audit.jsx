// app/frontend/src/pages/Audit.jsx
//
// Hits the serverless audit stack: API Gateway → Lambda → DynamoDB.
// GET  /events  → returns up to 50 items via a DynamoDB Scan
// POST /events  → puts a new audit row

import { useEffect, useState } from "react";
import { auditApi } from "../api";

const emptyEvent = {
  entity_type: "patient",
  entity_id:   "",
  action:      "viewed",
  actor:       "demo-user",
};

export default function Audit() {
  const [events, setEvents] = useState([]);
  const [form, setForm] = useState(emptyEvent);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const configured = auditApi.configured();

  async function refresh() {
    if (!configured) return;
    setLoading(true);
    try {
      const data = await auditApi.list();
      const items = (data.items || []).slice().sort((a, b) =>
        (b.ts || "").localeCompare(a.ts || "")
      );
      setEvents(items);
      setError("");
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { refresh(); }, []);

  async function submit(e) {
    e.preventDefault();
    try {
      await auditApi.create(form);
      setForm({ ...emptyEvent });
      refresh();
    } catch (err) {
      setError(String(err));
    }
  }

  function actionClass(action) {
    const a = (action || "").toLowerCase();
    if (a.includes("create") || a.includes("add"))     return "badge badge-completed";
    if (a.includes("delete") || a.includes("cancel"))  return "badge badge-cancelled";
    if (a.includes("update") || a.includes("edit"))    return "badge badge-default";
    return "badge badge-scheduled";
  }

  return (
    <>
      <section className="card hero">
        <div className="card-body">
          <span className="eyebrow">Serverless &middot; Audit log</span>
          <h2 className="hero-title">Audit events</h2>
          <p className="hero-lead">
            A second serverless flow that writes structured audit rows to a
            DynamoDB table via API Gateway and Lambda. Each event captures who
            did what to which entity, with a server-generated UUID and ISO
            timestamp.
          </p>
        </div>
      </section>

      {!configured && (
        <section className="card scope">
          <div className="card-body">
            <h3 className="section-heading">Audit API URL not configured</h3>
            <p className="muted">
              The build did not receive <code>VITE_AUDIT_API_URL</code>.
              The page will stay empty until the CI workflow injects it from
              the <code>serverless-audit</code> Terraform output.
            </p>
          </div>
        </section>
      )}

      <section className="card">
        <div className="card-header">
          <h3 className="card-title">Record an event</h3>
        </div>
        <div className="card-body">
          {error && <p className="error">{error}</p>}

          <form onSubmit={submit} className="form-row">
            <input
              className="input"
              required
              placeholder="entity_type"
              value={form.entity_type}
              onChange={(e) => setForm({ ...form, entity_type: e.target.value })}
            />
            <input
              className="input"
              required
              placeholder="entity_id"
              value={form.entity_id}
              onChange={(e) => setForm({ ...form, entity_id: e.target.value })}
            />
            <input
              className="input"
              required
              placeholder="action"
              value={form.action}
              onChange={(e) => setForm({ ...form, action: e.target.value })}
            />
            <input
              className="input"
              required
              placeholder="actor"
              value={form.actor}
              onChange={(e) => setForm({ ...form, actor: e.target.value })}
            />
            <div className="form-action">
              <button type="submit" className="btn" disabled={!configured}>
                Record
              </button>
            </div>
          </form>
        </div>
      </section>

      <section className="card">
        <div className="card-header">
          <h3 className="card-title">Recent events</h3>
          <div className="header-actions">
            <span className="card-count">{events.length} shown</span>
            <button
              type="button"
              className="btn-secondary"
              onClick={refresh}
              disabled={loading || !configured}
            >
              {loading ? "Loading..." : "Refresh"}
            </button>
          </div>
        </div>
        <div className="card-body">
          {events.length === 0 ? (
            <div className="empty">
              {configured
                ? "No audit events recorded yet."
                : "Audit API URL not configured."}
            </div>
          ) : (
            <ul className="list">
              {events.map((ev) => (
                <li key={ev.event_id} className="list-item">
                  <span className={actionClass(ev.action)}>{ev.action}</span>
                  <div className="item-body">
                    <div className="item-body-row">
                      <span className="item-primary">
                        {ev.entity_type} <span className="muted">#{ev.entity_id}</span>
                      </span>
                      <span className="item-secondary">by {ev.actor}</span>
                    </div>
                    <span className="item-secondary timestamp">
                      {ev.ts}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </>
  );
}

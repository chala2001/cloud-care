// app/frontend/src/api.js

// Main API (FastAPI on EC2, behind CloudFront /api/*).
// "" = same origin → CloudFront routes /api/* to the ALB.
const BASE = import.meta.env.VITE_API_URL ?? "";

// Serverless APIs are NOT routed through CloudFront — they're hit directly
// at their API Gateway URLs. Empty fallback so dev mode doesn't crash.
const CONTACT_BASE = import.meta.env.VITE_CONTACT_API_URL ?? "";
const AUDIT_BASE   = import.meta.env.VITE_AUDIT_API_URL   ?? "";

async function jsonFetch(url, options = {}) {
  const res = await fetch(url, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

function req(path, options) {
  return jsonFetch(`${BASE}/api${path}`, options);
}

export const api = {
  listPatients:      ()  => req("/patients"),
  createPatient:     (p) => req("/patients", { method: "POST", body: JSON.stringify(p) }),
  listAppointments:  ()  => req("/appointments"),
  createAppointment: (a) => req("/appointments", { method: "POST", body: JSON.stringify(a) }),
};

export const contactApi = {
  configured: () => Boolean(CONTACT_BASE),
  send: (payload) =>
    jsonFetch(`${CONTACT_BASE}/contact`, {
      method: "POST",
      body: JSON.stringify(payload),
    }),
};

export const auditApi = {
  configured: () => Boolean(AUDIT_BASE),
  list: () => jsonFetch(`${AUDIT_BASE}/events`),
  create: (payload) =>
    jsonFetch(`${AUDIT_BASE}/events`, {
      method: "POST",
      body: JSON.stringify(payload),
    }),
};

// app/frontend/src/api.js
const BASE = import.meta.env.VITE_API_URL ?? ""; // "" = same origin (production via CloudFront)

async function req(path, options) {
  const res = await fetch(`${BASE}/api${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

export const api = {
  listPatients: () => req("/patients"),
  createPatient: (p) => req("/patients", { method: "POST", body: JSON.stringify(p) }),
  listAppointments: () => req("/appointments"),
  createAppointment: (a) => req("/appointments", { method: "POST", body: JSON.stringify(a) }),
};

# 14 — The Application: React Frontend

> **Goal of this doc:** build a small **React** single-page app for CloudCare —
> list and add patients, list and book appointments — that talks to the FastAPI
> backend. We run it locally against the API, then produce a **production build**
> (a folder of static files). Serving that globally via **S3 + CloudFront** is
> Phase 5. This completes **Phase 4 — The Application**.

⏱️ Time: ~75 minutes. 💰 Cost: **$0** — local dev and a static build, no AWS.

---

## 1. Where the frontend fits

```
   Browser ──► React SPA (static HTML/JS/CSS)
                   │  fetch() calls to /patients, /appointments
                   ▼
              CloudCare API  (FastAPI on the EC2 app tier, Doc 13)
                   │
                   ▼
                 RDS PostgreSQL
```

The frontend is **just static files** — there's no server-side rendering. The
browser downloads the JS bundle, which then calls the API over HTTP. That's why we
can host it on S3 + CloudFront (Phase 5) instead of a server: static files are
cheap, infinitely scalable, and cache beautifully at the edge.

> 🧠 **SPA + API = clean separation.** The frontend and backend are independent:
> different repos-folders, different deploy targets, different scaling stories. The
> only contract between them is the JSON API. This decoupling is why we could swap
> the backend host (laptop → EC2) in Doc 13 without touching the frontend.

---

## 2. Tooling

| Tool | Why |
|------|-----|
| **React** | The industry-standard SPA library. |
| **Vite** | Fast dev server + bundler; `npm run build` emits a static `dist/`. |
| **fetch** | Built into the browser — no extra HTTP library needed for this size. |

You need **Node.js 18+** (`node --version`). If missing on Ubuntu:
`sudo apt-get install -y nodejs npm` (or use nvm for a current version).

---

## 3. Folder layout

```
app/frontend/
├── index.html
├── package.json
├── vite.config.js
├── .env.example          # VITE_API_URL
└── src/
    ├── main.jsx          # mounts React into the page
    ├── api.js            # the API client (one place that knows the base URL)
    └── App.jsx           # the whole UI
```

---

## 4. `package.json`

```json
{
  "name": "cloudcare-frontend",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.1",
    "vite": "^5.4.8"
  }
}
```

## 5. `vite.config.js` and `index.html`

```js
// app/frontend/vite.config.js
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
});
```

```html
<!-- app/frontend/index.html -->
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>CloudCare HMS</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
```

---

## 6. `.env.example` — the one config knob

The frontend needs to know **where the API is**. Locally that's
`http://localhost:8000`; against the deployed stack it's your ALB's DNS name.
Vite exposes any variable prefixed `VITE_` to the browser code.

```text
# app/frontend/.env.example  (copy to .env.local; .env.local is gitignored)
VITE_API_URL=http://localhost:8000
```

> 🧠 **Why an env var, not a hardcoded URL?** Same build philosophy as the backend:
> the code is environment-agnostic. For local dev it points at localhost; for the
> real deploy you rebuild with `VITE_API_URL=http://<alb-dns>`. (In Phase 5,
> CloudFront will route `/api/*` to the ALB so the frontend can just call same-origin
> paths — we'll revisit this then.)

---

## 7. `src/api.js` — the API client

```jsx
// app/frontend/src/api.js
const BASE = import.meta.env.VITE_API_URL || "http://localhost:8000";

async function req(path, options) {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    throw new Error(`${res.status}: ${await res.text()}`);
  }
  return res.status === 204 ? null : res.json();
}

export const api = {
  listPatients: () => req("/patients"),
  createPatient: (p) => req("/patients", { method: "POST", body: JSON.stringify(p) }),
  listAppointments: () => req("/appointments"),
  createAppointment: (a) => req("/appointments", { method: "POST", body: JSON.stringify(a) }),
};
```

> 🧠 **One place knows the URL.** Every component imports `api` and never sees the
> base URL or fetch details. If the API contract changes, you fix it here once.

---

## 8. `src/main.jsx`

```jsx
// app/frontend/src/main.jsx
import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App.jsx";

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
```

## 9. `src/App.jsx` — the UI

```jsx
// app/frontend/src/App.jsx
import { useEffect, useState } from "react";
import { api } from "./api";

export default function App() {
  const [patients, setPatients] = useState([]);
  const [appointments, setAppointments] = useState([]);
  const [error, setError] = useState("");

  const emptyPatient = { full_name: "", date_of_birth: "", phone: "" };
  const emptyAppt = { patient_id: "", scheduled_for: "", reason: "" };
  const [patient, setPatient] = useState(emptyPatient);
  const [appt, setAppt] = useState(emptyAppt);

  async function refresh() {
    try {
      setPatients(await api.listPatients());
      setAppointments(await api.listAppointments());
      setError("");
    } catch (e) {
      setError(String(e));
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  async function addPatient(e) {
    e.preventDefault();
    try {
      await api.createPatient(patient);
      setPatient(emptyPatient);
      refresh();
    } catch (e) {
      setError(String(e));
    }
  }

  async function bookAppointment(e) {
    e.preventDefault();
    try {
      await api.createAppointment({ ...appt, patient_id: Number(appt.patient_id) });
      setAppt(emptyAppt);
      refresh();
    } catch (e) {
      setError(String(e));
    }
  }

  return (
    <main style={{ fontFamily: "system-ui", maxWidth: 720, margin: "2rem auto", padding: "0 1rem" }}>
      <h1>CloudCare HMS</h1>
      {error && <p style={{ color: "crimson" }}>{error}</p>}

      <section>
        <h2>Patients</h2>
        <form onSubmit={addPatient} style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input required placeholder="Full name" value={patient.full_name}
            onChange={(e) => setPatient({ ...patient, full_name: e.target.value })} />
          <input required type="date" value={patient.date_of_birth}
            onChange={(e) => setPatient({ ...patient, date_of_birth: e.target.value })} />
          <input required placeholder="Phone" value={patient.phone}
            onChange={(e) => setPatient({ ...patient, phone: e.target.value })} />
          <button type="submit">Add patient</button>
        </form>
        <ul>
          {patients.map((p) => (
            <li key={p.id}>#{p.id} — {p.full_name} ({p.phone})</li>
          ))}
        </ul>
      </section>

      <section>
        <h2>Appointments</h2>
        <form onSubmit={bookAppointment} style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input required type="number" placeholder="Patient id" value={appt.patient_id}
            onChange={(e) => setAppt({ ...appt, patient_id: e.target.value })} />
          <input required type="datetime-local" value={appt.scheduled_for}
            onChange={(e) => setAppt({ ...appt, scheduled_for: e.target.value })} />
          <input required placeholder="Reason" value={appt.reason}
            onChange={(e) => setAppt({ ...appt, reason: e.target.value })} />
          <button type="submit">Book</button>
        </form>
        <ul>
          {appointments.map((a) => (
            <li key={a.id}>#{a.id} — patient {a.patient_id}: {a.reason} [{a.status}]</li>
          ))}
        </ul>
      </section>
    </main>
  );
}
```

> 🧠 **The data flow:** `useEffect` loads data on first render; each form submit
> POSTs then calls `refresh()` to re-fetch. It's deliberately simple — no state
> library, no router — because the goal is to demonstrate the *full stack working
> end to end*, not to teach advanced React.

---

## 10. Run it locally against the API

Make sure the backend is running (Doc 12: `docker compose up` in `app/backend/`,
serving on `:8000`). Then, in `app/frontend/`:

```bash
npm install         # install React + Vite (first time only)
npm run dev         # starts Vite dev server, usually on http://localhost:5173
```

Open **http://localhost:5173**:

- Add a patient → it appears in the list (written to Postgres via the API).
- Note the patient's `#id`, book an appointment for it → it appears below.

> 🧠 **CORS:** the browser calls `:8000` from a page served on `:5173` — a
> cross-origin request. It works because the backend enabled CORS in Doc 12
> (`allow_origins=["*"]`). If you saw a CORS error, that middleware is why we added
> it. In production you'd restrict the allowed origin to your real frontend URL.

---

## 11. Point the frontend at the deployed API (optional)

If your Phase 2–3 + Doc 13 stack is currently up, you can run the local frontend
against the **real** cloud backend:

```bash
# Get the ALB DNS from the compute stack:
ALB=$(cd ../../terraform/compute && terraform output -raw alb_dns_name)

# Run the dev server with the API pointed at the ALB:
VITE_API_URL="http://$ALB" npm run dev
```

Now the React app you're viewing locally is reading and writing the **RDS
database in AWS**, through the ALB and the private EC2 app tier. The full system,
front to back.

---

## 12. Production build (what Phase 5 will host)

```bash
npm run build       # emits app/frontend/dist/ — plain static files
npm run preview     # optional: serve dist/ locally to sanity-check it
```

`dist/` is what we'll upload to **S3** and serve through **CloudFront** in Phase 5.
For the build that goes to production, bake in the API URL at build time:

```bash
VITE_API_URL="http://<your-alb-or-cloudfront-domain>" npm run build
```

> 🧠 **Static build = the whole app in a folder.** `dist/` has an `index.html` and
> hashed JS/CSS bundles. There's no Node server to run — any static host (S3,
> CloudFront, Netlify…) can serve it. That portability is the point of an SPA.

> 💡 Add `app/frontend/node_modules/` and `app/frontend/dist/` to `.gitignore` if
> they aren't already covered — the Phase 0 `.gitignore` already ignores
> `node_modules/`, `dist/`, and `build/`.

---

## ✅ Checkpoint — end of Phase 4 🎉

You've built the full application. You should now have:

- [ ] `app/backend/` — the FastAPI API (Doc 12), running in Docker, deployable to
      EC2 (Doc 13).
- [ ] `app/frontend/` — a React SPA that lists/creates patients and appointments.
- [ ] The SPA working locally against the backend (and optionally against the live
      ALB).
- [ ] A production `dist/` build ready to host.

And you can explain, from memory:

- Why the frontend is static files and the backend is a separate API (SPA + API
  decoupling).
- How `VITE_API_URL` keeps the build environment-agnostic.
- What CORS is and why the backend needed it.
- The full request path: browser → (CloudFront, Phase 5) → ALB → EC2 → RDS.

> 💰 **Before you stop:** if the cloud stack is up, tear down the costly parts —
> `terraform destroy` in `terraform/compute/` and `terraform/database/`. Leave
> only `network/` and `bootstrap/`. Local dev (Docker, Vite) costs nothing.

**Tell me when you've reached this checkpoint**, and I'll write **Phase 5 —
Content Delivery**: hosting this `dist/` build on **S3**, fronting it with
**CloudFront** (global HTTPS CDN), and routing `/api/*` to the ALB so the whole
app is served from one domain.

Next: **Phase 5 — Content Delivery** (doc 15, written when you reach this
checkpoint).

# 14 — The Application: React Frontend

> **Goal of this doc:** build a small **React** single-page app for CloudCare —
> list and add patients, list and book appointments — that talks to the FastAPI
> backend. We run it locally against the API, then produce a **production build**
> (a folder of static files). Serving that globally via **S3 + CloudFront** is
> Phase 5. This completes **Phase 4 — The Application**.

⏱️ Time: ~75 minutes. 💰 Cost: **$0** — local dev and a static build, no AWS.

---

## 0. Beginner read-me first — vocabulary in one place

This doc switches from Python to **JavaScript + React**. New vocabulary card.

| Word | Plain-English meaning |
|---|---|
| **SPA** (Single-Page Application) | A web app where one HTML page loads, then JavaScript updates the UI in place. No full-page reloads between "views." |
| **React** | A JS library for building UIs as **components** (functions that return HTML-like markup). |
| **JSX** | The HTML-like syntax inside React functions (`<div>Hello {name}</div>`). Compiled to regular JS at build time. |
| **Component** | A reusable UI piece — in this doc, the whole `App` is one component. |
| **State** | Data a component holds that, when changed, re-renders the UI. Set with `useState`. |
| **Hook** | A React function whose name starts with `use…` (e.g. `useState`, `useEffect`). They let function components remember state and run side effects. |
| **`useState`** | A hook that adds a piece of state to a component. Returns `[value, setterFunction]`. |
| **`useEffect`** | A hook that runs code **after the component renders** (e.g. fetch data on first load). |
| **Vite** | A modern JS build tool — fast dev server, single command to produce a production bundle. |
| **npm** | Node's package manager — installs JS libraries listed in `package.json`. |
| **Bundle** | One (or a few) compressed JS files that contain all your code + dependencies, ready to ship to the browser. |
| **`dist/`** | Vite's output folder: the bundled static site ready to deploy. |
| **Static site** | A site that's just HTML/CSS/JS files — no server-side rendering. Any file host can serve it. |
| **`fetch`** | The browser's built-in HTTP client. Returns a `Promise`. |
| **`async/await`** | JavaScript syntax for working with Promises sequentially, like normal code. |
| **CORS** (Cross-Origin Resource Sharing) | A browser security rule: a page loaded from `origin A` can't call API at `origin B` unless `B` returns headers saying it's OK. (The FastAPI middleware in Doc 12 does that.) |
| **Origin** | The combination `<scheme>://<host>:<port>` of a URL — e.g. `http://localhost:5173`. Two URLs are "same-origin" only if all three match. |
| **`import.meta.env.VITE_*`** | How Vite exposes env vars to the browser code. Only variables prefixed `VITE_` are bundled in. |
| **Build-time env var** | A value **baked into the bundle** at `npm run build`. You can't change it after the build without rebuilding. |
| **`StrictMode`** | A React dev-only wrapper that runs each render twice to surface bugs. Off in production builds. |
| **Same-origin** (CloudFront pattern) | When the frontend and `/api/*` are served from the **same** hostname via CloudFront → no CORS needed. We move to this in Phase 5. |

Now the architecture.

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

### Mental model: who does what when a user clicks "Add patient"

```
1. Browser already has the React bundle loaded (downloaded once).
2. User fills the form. React updates its in-memory state (no network call yet).
3. User clicks "Add patient" → React's onSubmit handler runs.
4. The handler calls api.createPatient(...).
5. api.js's fetch() sends an HTTPS POST to the API.
6. The API writes to RDS, returns the new row as JSON.
7. The handler then calls refresh() → another fetch() → GET /patients.
8. React receives the new list and re-renders the <ul>.
```

The page **never reloads**. That's the "S" in SPA. Each piece of dynamic data is
fetched as JSON; the UI re-renders without a round-trip-page-redraw.

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

### Why Vite (not Create-React-App or webpack directly)

| Tool | Status today |
|---|---|
| **Vite** ✅ | The current default. Fast (uses native ES modules in dev); simple config. |
| Create-React-App | Effectively abandoned. Anything new should use Vite. |
| Webpack (direct) | Powerful but heavy config. Vite uses Rollup under the hood for production builds. |
| Next.js / Remix | Full frameworks with server-side rendering. Overkill for a static SPA. |

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

### What each file's job is

| File | One-line purpose |
|---|---|
| `index.html` | The single HTML page the browser loads. Has a `<div id="root">` and one `<script>` tag. |
| `package.json` | Lists the project's npm dependencies + run scripts. |
| `vite.config.js` | Vite's config — for us, just "enable React JSX". |
| `.env.example` | Template showing the one env var (`VITE_API_URL`). |
| `src/main.jsx` | Entry point. Imports React and mounts `<App />` into the `#root` div. |
| `src/api.js` | All `fetch()` calls live here. Single source of truth for API URL + error handling. |
| `src/App.jsx` | The whole UI — state, forms, lists, event handlers. |

> 🧠 **`src/` convention.** All source code lives in `src/`; everything outside is
> config or output. Vite knows to look here.

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

### Walk-through — what every field means

| Field | Meaning |
|---|---|
| `name` | The project's name (only matters if published to npm — we don't). |
| `private: true` | Refuses to publish accidentally to the public npm registry. Safety net. |
| `type: "module"` | Tells Node "this project uses ES modules (`import`)", not the legacy CommonJS (`require`). |
| `scripts.dev` | `npm run dev` runs Vite's dev server. |
| `scripts.build` | `npm run build` produces the production bundle in `dist/`. |
| `scripts.preview` | `npm run preview` serves `dist/` locally so you can sanity-check the production build before deploying. |
| `dependencies` | Libraries needed **at runtime** (shipped in the bundle). React + React-DOM. |
| `devDependencies` | Libraries needed **only during development/build**. Vite + the React plugin. |

### What `^18.3.1` means (semver caret)

| Notation | Meaning |
|---|---|
| `18.3.1` | exactly this version |
| `~18.3.1` | any `18.3.x` (patch updates only) |
| `^18.3.1` | any `18.x.x` ≥ `18.3.1` (minor + patch updates) |
| `>=18.0.0 <19.0.0` | explicit range |

The caret strikes a balance: get bug-fixes automatically, but never a major
version that might break your code. `npm install` resolves the actual installed
version into `package-lock.json` for reproducibility.

---

## 5. `vite.config.js` and `index.html`

```js
// app/frontend/vite.config.js
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
});
```

| Line | Meaning |
|---|---|
| `import { defineConfig } from "vite"` | A helper from Vite that gives type hints in editors. Doesn't change behavior. |
| `import react from "@vitejs/plugin-react"` | The Vite plugin that adds React-specific transforms (JSX compilation, fast refresh). |
| `export default defineConfig({ plugins: [react()] })` | Export the config: a single plugin, the React one. Everything else uses Vite's defaults. |

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

| Line | Meaning |
|---|---|
| `<!doctype html>` | Standard HTML5 doctype. |
| `<meta charset="UTF-8" />` | Tells the browser the file is UTF-8 (so emoji and non-ASCII work). |
| `<meta name="viewport" ...>` | Mobile-friendly default scaling. |
| `<title>CloudCare HMS</title>` | The browser tab text. |
| `<div id="root"></div>` | **Empty container.** React mounts the entire UI into this div. |
| `<script type="module" src="/src/main.jsx"></script>` | Load the JS entry point as an **ES module** — modern import system. In dev, Vite serves this directly; in production, Vite swaps in the bundled path. |

This is the **entire** static HTML the browser ever sees. Everything else is
JavaScript rendering into `#root`.

---

## 6. `.env.example` — the one config knob

The frontend needs to know **where the API is**. Locally that's
`http://localhost:8000`; against the deployed stack it's your ALB's DNS name.
Vite exposes any variable prefixed `VITE_` to the browser code.

```text
# app/frontend/.env.example  (copy to .env.local; .env.local is gitignored)
VITE_API_URL=http://localhost:8000
```

### The `VITE_` prefix rule

Only env vars whose name **starts with `VITE_`** are exposed to the browser
code via `import.meta.env`. This is a safety feature: it prevents your shell
env vars (like `DATABASE_PASSWORD` from another project) from accidentally
ending up in a public JS bundle. You opt-in by naming the var `VITE_X`.

### Build-time vs runtime env vars

> 🧠 **Build-time only.** Unlike the backend (where env vars are read at
> container start), the frontend's env vars are **baked into the bundle at
> `npm run build`**. To point a built site at a different API, you must
> **rebuild**. This is fundamental to how SPAs work — the JS is already in the
> user's browser; you can't change it without re-deploying.

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

### Walk-through — line by line

#### The base URL

```js
const BASE = import.meta.env.VITE_API_URL || "http://localhost:8000";
```

| Piece | Meaning |
|---|---|
| `import.meta.env.VITE_API_URL` | Vite-injected env var. Whatever value was set at build/dev time. |
| `\|\| "http://localhost:8000"` | **Fallback** if the env var is empty/undefined. Lets you `npm run dev` without setting anything. |
| `const BASE = ...` | A constant for the whole module. |

#### The fetch wrapper

```js
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
```

| Piece | Meaning |
|---|---|
| `async function req(path, options)` | Async function (returns a Promise). Takes a relative path (e.g. `/patients`) and optional fetch options. |
| `await fetch(`${BASE}${path}`, { ... })` | Send the HTTP request. `await` pauses until the response arrives. |
| `headers: { "Content-Type": "application/json" }` | Always tell the API we send JSON. |
| `...options` | **Spread operator** — merge in any caller-supplied options (e.g. `method: "POST", body: ...`). Caller can override `headers` too. |
| `if (!res.ok)` | `res.ok` is `true` for 2xx statuses. Otherwise we throw, so callers can catch and show errors. |
| `throw new Error(`${res.status}: ${await res.text()}`)` | Build a useful error message. `await res.text()` reads the body as a string. |
| `res.status === 204 ? null : res.json()` | `204 No Content` has no body to parse. Otherwise parse JSON. |

#### The exported API surface

```js
export const api = {
  listPatients: () => req("/patients"),
  createPatient: (p) => req("/patients", { method: "POST", body: JSON.stringify(p) }),
  listAppointments: () => req("/appointments"),
  createAppointment: (a) => req("/appointments", { method: "POST", body: JSON.stringify(a) }),
};
```

Each method is an **arrow function** (`() => …`) that calls `req`. The
component imports `api` and calls `api.createPatient(...)` — clean, readable,
no `fetch` details bleeding into UI code.

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

| Line | Meaning |
|---|---|
| `import React from "react"` | Bring in React itself. |
| `import { createRoot } from "react-dom/client"` | The React 18 way to mount a React app into the DOM. |
| `import App from "./App.jsx"` | Bring in our root component (we'll write it next). |
| `createRoot(document.getElementById("root"))` | "Use the `<div id='root'>` from index.html as my React root." |
| `.render(<React.StrictMode><App /></React.StrictMode>)` | Render `App` inside `StrictMode`. |

### What `React.StrictMode` does

A development-only wrapper. In dev mode it **runs each render twice** to
help you spot side effects that aren't safe to run more than once. **Not** in
production. Often surprises beginners ("why does my console.log appear twice?")
— that's why.

---

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

### State (the `useState` calls)

```jsx
const [patients, setPatients] = useState([]);
const [appointments, setAppointments] = useState([]);
const [error, setError] = useState("");
const [patient, setPatient] = useState(emptyPatient);
const [appt, setAppt] = useState(emptyAppt);
```

| Line | Meaning |
|---|---|
| `useState(initialValue)` | A React hook. Returns `[value, setter]`. The component re-renders whenever `setter` is called. |
| `const [patients, setPatients] = useState([])` | **Destructuring** the returned pair. `patients` starts as `[]`; `setPatients(newValue)` updates it and triggers a re-render. |

We have 5 state variables: the two lists, an error message, and the two
in-progress form objects.

### Effects (the `useEffect` call)

```jsx
useEffect(() => {
  refresh();
}, []);
```

| Piece | Meaning |
|---|---|
| `useEffect(fn, deps)` | Run `fn` **after** the component renders. Re-run when any value in `deps` changes. |
| `[]` (empty deps array) | "**Only on first render.**" This is the canonical "load data on mount" pattern. |

So as soon as the component appears, we kick off `refresh()` to populate the lists.

### The `refresh` function

```jsx
async function refresh() {
  try {
    setPatients(await api.listPatients());
    setAppointments(await api.listAppointments());
    setError("");
  } catch (e) {
    setError(String(e));
  }
}
```

| Line | Meaning |
|---|---|
| `async function refresh()` | Async function — uses `await`. |
| `setPatients(await api.listPatients())` | Fetch the list and store it in state → triggers a re-render of the `<ul>`. |
| `setAppointments(await api.listAppointments())` | Same for appointments. |
| `setError("")` | Clear any prior error on success. |
| `catch (e) setError(String(e))` | On failure (network error, 4xx, 5xx), capture the message to display. |

### The submit handlers

```jsx
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
```

| Line | Meaning |
|---|---|
| `e.preventDefault()` | **Stop the browser's default form behavior** (which is to reload the page on submit). |
| `await api.createPatient(patient)` | POST the current form data. |
| `setPatient(emptyPatient)` | Reset the form fields to empty. |
| `refresh()` | Re-fetch the list so the new patient appears. |

`bookAppointment` follows the same pattern, with one extra detail:

```jsx
await api.createAppointment({ ...appt, patient_id: Number(appt.patient_id) });
```

| Piece | Meaning |
|---|---|
| `{ ...appt, patient_id: Number(appt.patient_id) }` | Spread the appointment fields, then **override** `patient_id` with the **numeric** version. HTML inputs always give you strings; the API expects a number. |

### The JSX (return value)

JSX looks like HTML but is JavaScript. Key features used here:

| Feature | Example | Meaning |
|---|---|---|
| Tags | `<main>...</main>` | Just like HTML. |
| Self-closing | `<input ... />` | Must close even void tags. |
| Inline styles | `style={{ color: "crimson" }}` | An **object** (camelCase keys). Note the double braces: outer `{}` = JSX expression, inner `{}` = the object literal. |
| Expressions | `{patients.length}` | Anything in `{ }` is JS. |
| Conditional | `{error && <p>...</p>}` | If `error` is truthy, render the `<p>`. JS short-circuit. |
| Lists | `{patients.map((p) => <li key={p.id}>...)</li>)}` | Map array → array of elements. Each needs a **unique `key`** so React can efficiently diff. |
| Event handlers | `onSubmit={addPatient}` | Pass the function reference (not a string). |
| Controlled inputs | `value={patient.phone}` + `onChange={...}` | The component "controls" the input value — single source of truth in state. |

### The "controlled component" pattern

```jsx
<input value={patient.phone}
       onChange={(e) => setPatient({ ...patient, phone: e.target.value })} />
```

Every keystroke triggers `onChange`, which updates state, which re-renders the
input with the new value. State **is** the form data. This is the canonical
React way to handle forms.

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

### What each command does

| Command | Meaning |
|---|---|
| `npm install` | Read `package.json`, download every dep + its deps into `node_modules/`. Slow the first time (~30s); fast on subsequent runs. Creates/updates `package-lock.json` (the pinned exact versions for reproducible installs). |
| `npm run dev` | Run the `"dev"` script from `package.json` — i.e., `vite`. Vite starts a dev server with **hot module replacement** (HMR): edit a file, browser updates instantly without losing state. |

### Open the page

Open **http://localhost:5173**:

- Add a patient → it appears in the list (written to Postgres via the API).
- Note the patient's `#id`, book an appointment for it → it appears below.

### CORS in action

> 🧠 **CORS:** the browser calls `:8000` from a page served on `:5173` — a
> cross-origin request. It works because the backend enabled CORS in Doc 12
> (`allow_origins=["*"]`). If you saw a CORS error, that middleware is why we added
> it. In production you'd restrict the allowed origin to your real frontend URL.

The mechanics:
1. Browser makes a "preflight" `OPTIONS` request to `:8000` before the real
   POST.
2. FastAPI's `CORSMiddleware` returns headers like
   `Access-Control-Allow-Origin: *`.
3. Browser sees the green light, sends the real request.

Disable the middleware in `main.py` and the same code throws a CORS error in
the browser console. That's how you know CORS is the issue.

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

### What this proves

You're now running a **local browser** rendering a **local React dev server**
that fetches from a **real ALB in AWS** → routed to a **private EC2 in app
subnets** → talking to **RDS in db subnets**. The full system, front to back,
exercised end-to-end without redeploying anything.

Then you can `Ctrl-C` the dev server and run plain `npm run dev` again to go
back to localhost.

---

## 12. Production build (what Phase 5 will host)

```bash
npm run build       # emits app/frontend/dist/ — plain static files
npm run preview     # optional: serve dist/ locally to sanity-check it
```

### What `npm run build` produces

Vite runs in production mode:
1. **Compiles JSX** to plain JS.
2. **Bundles** all your code + node_module deps into a small number of files.
3. **Tree-shakes** unused code (e.g. unused React APIs).
4. **Minifies** (removes whitespace, shortens variable names).
5. **Hash-busts filenames**: `dist/assets/index-a3f1b2c.js`. The hash changes
   when the content changes — that's how caching works correctly later.
6. **Inlines small assets** (tiny images become base64 data URIs).
7. Drops the `StrictMode` double-render and dev-only warnings.

You end up with something like:
```
dist/
├── index.html                       (~500 B — references the hashed JS/CSS)
├── assets/
│   ├── index-a3f1b2c.css            (~10 KB)
│   └── index-9d8e7f6.js             (~150 KB minified)
└── vite.svg                          (favicon — optional)
```

That's it. **No Node server.** Any HTTP server can serve this folder.

### Baking in the API URL at build time

For the build that goes to production, bake in the API URL at build time:

```bash
VITE_API_URL="http://<your-alb-or-cloudfront-domain>" npm run build
```

This value is **frozen into the bundle**. To change it later, you must rebuild.
That's why Phase 5 uses a CloudFront trick: serve the frontend at the same host
as the API (`/api/*` routes to ALB, `/*` to S3), so the frontend just calls
**same-origin** paths and `VITE_API_URL` can be an empty string.

> 🧠 **Static build = the whole app in a folder.** `dist/` has an `index.html` and
> hashed JS/CSS bundles. There's no Node server to run — any static host (S3,
> CloudFront, Netlify…) can serve it. That portability is the point of an SPA.

> 💡 Add `app/frontend/node_modules/` and `app/frontend/dist/` to `.gitignore` if
> they aren't already covered — the Phase 0 `.gitignore` already ignores
> `node_modules/`, `dist/`, and `build/`.

---

## 13. Plain-English summary (what you just built)

If asked to explain Phase 4 part 3:

1. **A React SPA** at `app/frontend/` — two forms (add patient, book
   appointment) and two lists, all in a single `App.jsx` component.
2. **State + effects via hooks**: `useState` holds the lists and form data;
   `useEffect([])` fetches on first render; each submit POSTs then calls
   `refresh()` to re-fetch.
3. **All API calls live in `api.js`** — one place that knows the base URL and
   handles JSON + errors. Components stay pure UI.
4. **Vite** is the build tool: `npm run dev` for hot-reload dev, `npm run
   build` for a static `dist/` ready to host.
5. **`VITE_API_URL`** is baked into the bundle at build time, so the same code
   targets localhost in dev and the ALB (or CloudFront same-origin paths) in
   prod.
6. **CORS** is what lets the localhost:5173 page call localhost:8000 — handled
   by the FastAPI middleware in Doc 12.
7. Verified by running locally against both the **local backend** (Compose) and
   optionally the **live ALB**, then producing a `dist/` ready for Phase 5.

---

## 14. Interview soundbites

- **SPA + API decoupling** — *"Frontend and backend are completely separate:
  different repos-folders, different deploy targets, different scaling stories.
  The only contract is the JSON API. Replace the backend host and the
  frontend doesn't change — that's the value of the split."*

- **Why a CDN-hosted static site** — *"The whole frontend is HTML + JS + CSS
  files. Hosting it on S3 + CloudFront means infinite scale, near-zero cost,
  and global low-latency delivery via edge caching. We'd never put an
  always-on server behind static assets."*

- **Build-time vs runtime env vars** — *"Backend env vars are read at container
  start — same image, different env. Frontend env vars are baked into the
  bundle at build time — change one and you must rebuild and reupload. SPAs
  are immutable by nature once deployed."*

- **CORS in two sentences** — *"Browsers refuse to let a page call a
  different-origin API unless that API explicitly returns
  `Access-Control-Allow-Origin` headers. Our FastAPI middleware adds those for
  the lab; production would whitelist only the real frontend origin."*

- **Same-origin via CloudFront** — *"Phase 5 routes `/api/*` and `/*` from one
  CloudFront distribution — frontend to S3, API path to ALB. That makes the
  whole site same-origin, so the browser doesn't see CORS, and the frontend
  can ship with an empty `VITE_API_URL` (just call `/api/...`)."*

- **`useEffect` with `[]`** — *"Empty dependency array means 'run once on
  mount.' It's the canonical 'load initial data' pattern for function
  components. A non-empty array would re-run when any listed value changes."*

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
- The difference between build-time env vars (frontend) and runtime env vars (backend).

> 💰 **Before you stop:** if the cloud stack is up, tear down the costly parts —
> `terraform destroy` in `terraform/compute/` and `terraform/database/`. Leave
> only `network/` and `bootstrap/`. Local dev (Docker, Vite) costs nothing.

**Tell me when you've reached this checkpoint**, and I'll write **Phase 5 —
Content Delivery**: hosting this `dist/` build on **S3**, fronting it with
**CloudFront** (global HTTPS CDN), and routing `/api/*` to the ALB so the whole
app is served from one domain.

Next: **Phase 5 — Content Delivery** (doc 15, written when you reach this
checkpoint).

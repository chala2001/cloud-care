# 12 — The Application: FastAPI Backend (build & run locally)

> **Goal of this doc:** write the **CloudCare backend** — a small but real FastAPI
> service (patients + appointments, a `/health` endpoint) backed by PostgreSQL —
> and run it **entirely on your laptop** with Docker Compose. No AWS, no cost. By
> the end you have a working API and a Docker image ready to deploy to the EC2 app
> tier in [Doc 13](13-application-deploy-to-ec2.md).

⏱️ Time: ~90 minutes. 💰 Cost: **$0** — this is all local.

This begins **Phase 4 — The Application** (docs 12–14). We *finally* write code
that runs on the infrastructure you've built. We build it locally first because
debugging on your laptop is 10× faster than debugging on a private EC2 instance.

---

## 0. Beginner read-me first — vocabulary in one place

This doc switches from Terraform to **Python + Docker**. New vocabulary card.

| Word | Plain-English meaning |
|---|---|
| **API** | A set of HTTP endpoints (URLs) other programs call to do things. Our API has `/health`, `/patients`, `/appointments`. |
| **Backend** | The server-side code that holds business logic + talks to the database. (Frontend = the UI in the browser, Phase 5.) |
| **FastAPI** | A modern Python web framework. Define functions with type hints; FastAPI builds the routes, validation, and docs for you. |
| **Uvicorn** | The actual HTTP server that runs FastAPI. FastAPI = the framework; uvicorn = the engine. |
| **ORM** (Object-Relational Mapper) | A library that lets you work with database rows as Python objects (a `Patient` class) instead of writing SQL by hand. |
| **SQLAlchemy** | The most popular Python ORM. We use its 2.0 typed style. |
| **Pydantic** | Python data-validation library based on type hints. FastAPI uses it to validate request bodies and shape responses. |
| **psycopg2-binary** | The driver that lets Python talk to PostgreSQL over the network. |
| **boto3** | The official AWS SDK for Python. Locally unused; on AWS, used to fetch the DB password from Secrets Manager. |
| **Container** | A lightweight, isolated process that bundles an app **with all its dependencies** (Python version, libraries) — runs identically anywhere Docker runs. |
| **Image** | The static "snapshot" Docker runs as a container. Built from a `Dockerfile`. |
| **Dockerfile** | A recipe: "start from base image X, install Y, copy in Z, run command W". `docker build` turns it into an image. |
| **Docker Compose** | A tool to define and run **multiple containers together** for local dev (e.g. api + database). One YAML file = one stack. |
| **Layer (Docker)** | Each Dockerfile step adds a layer to the image. Docker caches unchanged layers so rebuilds are fast. |
| **Environment variable** | Config passed to a process at startup (`DB_HOST=...`). Different in dev vs prod, but the code doesn't change. |
| **Twelve-Factor App** | An industry methodology for cloud apps. One core rule: **read config from the environment, not from files baked into the code.** |
| **Connection pool** | A reusable set of open DB connections so each request doesn't pay the cost of opening a fresh one. SQLAlchemy manages this automatically. |
| **Session (DB)** | A short-lived transactional context for one request. Open at request start, close at request end. |
| **Dependency injection (FastAPI)** | FastAPI's pattern for passing shared resources (like a DB session) into route functions via `Depends(...)`. |
| **CORS** | Cross-Origin Resource Sharing — browser security rule about which origins may call your API. Needed when the frontend lives at a different domain. |
| **Migration** | A versioned change to the DB schema (add table, add column). Tools like **Alembic** track them. We use `create_all` instead (good for labs, bad for prod). |
| **`/health` endpoint** | A cheap, dependency-free URL the load balancer pings to decide if this instance is alive. |

Now the architecture.

---

## 1. What we're building and why these tools

A minimal Hospital Management System slice: **patients** and their
**appointments**, plus a health check the load balancer can poll.

| Tool | What it is | Why we chose it |
|------|------------|-----------------|
| **FastAPI** | A modern Python web framework | Fast, type-hinted, auto-generates interactive API docs at `/docs`. Light enough for a free `t2.micro`. |
| **SQLAlchemy** | Python ORM (object ↔ table mapper) | Write Python classes, not raw SQL; works with Postgres. |
| **Pydantic** | Data validation from type hints | FastAPI uses it to validate requests and shape responses. |
| **psycopg2** | PostgreSQL driver | How Python talks to Postgres. |
| **Docker** | Container packaging | The same image runs identically on your laptop and on EC2 — "works on my machine" solved. |
| **Docker Compose** | Run multi-container locally | Spins up the API **and** a throwaway Postgres together for local dev. |

### The complete dev → production journey

```
   Your laptop                              EC2 (Phase 2 ASG)
   ───────────                              ─────────────────
   docker-compose.yml                       Launch Template user_data:
     ├─ api  (this image)         ── 13 ──►   docker pull <ECR>
     └─ db   (local Postgres)                 docker run  <image>
                                              └─ reads DB creds from Secrets Manager
                                              └─ connects to RDS Postgres (Phase 3)
```

The **same Docker image** runs both. The only thing that changes is where the
DB lives — and that's just env vars.

> 🧠 **Why containerize?** A container bundles the app *and* its exact dependencies
> (Python version, libraries) into one image. The instance doesn't need Python or
> pip set up — it just runs the image. This is what makes the Phase 2 launch
> template so simple later. Interview phrasing: "We ship a Docker image so the
> runtime is identical everywhere and deploys are reproducible."

---

## 2. The folder layout

We put the backend under `app/backend/` (the repo's `app/` dir already exists):

```
app/backend/
├── app/
│   ├── __init__.py
│   ├── config.py       # reads settings from environment variables
│   ├── database.py     # SQLAlchemy engine + session + get_db dependency
│   ├── models.py       # ORM models: Patient, Appointment
│   ├── schemas.py      # Pydantic request/response shapes
│   └── main.py         # the FastAPI app + routes
├── requirements.txt
├── Dockerfile
├── docker-compose.yml  # local dev: api + postgres
└── .env.example        # template for local env vars
```

### What each Python file does

| File | One-line purpose |
|---|---|
| `__init__.py` | Empty file; tells Python "this folder is a package" so imports like `from app.config import settings` work. |
| `config.py` | Reads env vars → builds the `DATABASE_URL`. Nothing else. |
| `database.py` | Sets up SQLAlchemy engine + connection pool + `get_db()` dependency. |
| `models.py` | The ORM classes that map to DB tables (`Patient`, `Appointment`). |
| `schemas.py` | The Pydantic classes the **API** speaks (request bodies + response shapes). Separate from `models.py` on purpose. |
| `main.py` | The FastAPI app, middleware, and route handlers. |

### Why "models" and "schemas" are different files

This trips beginners — same data, two classes, two files? Yes, on purpose:

- **`models.py` (SQLAlchemy)** = the **storage** shape (tables, columns,
  relationships, timestamps).
- **`schemas.py` (Pydantic)** = the **API** shape (what the client sends,
  what the API returns).

Keeping them separate means you can change one without breaking the other.
Example: a `Patient` ORM model can have `password_hash`, but the `PatientOut`
schema doesn't include it — so it can never accidentally leak in an API
response.

---

## 3. `requirements.txt`

```text
fastapi==0.115.0
uvicorn[standard]==0.30.6
sqlalchemy==2.0.35
psycopg2-binary==2.9.9
pydantic==2.9.2
pydantic-settings==2.5.2
boto3==1.35.24
```

### What each pinned package does

| Package | Role |
|---|---|
| `fastapi` | The web framework. Provides `FastAPI`, `Depends`, `HTTPException`, etc. |
| `uvicorn[standard]` | The ASGI HTTP server that actually serves FastAPI. The `[standard]` extras add fast `uvloop`, `httptools`, etc. |
| `sqlalchemy` | ORM. The `2.0` line uses typed `Mapped[...]` columns. |
| `psycopg2-binary` | Postgres driver. The `-binary` variant ships compiled — no system libs needed in the container. |
| `pydantic` | Data validation library — type hints become validators. |
| `pydantic-settings` | Sub-package for loading settings from env vars / `.env` files into a `BaseSettings` class. |
| `boto3` | AWS SDK. Used in **Doc 13** to fetch the DB password from Secrets Manager; harmless to include locally. |

> 🧠 **Why pin versions?** Reproducible builds. Without pins, a rebuild months
> from now might pull a newer FastAPI with breaking changes. `boto3` is the AWS
> SDK — unused locally, but Doc 13 uses it to read the DB password from Secrets
> Manager.

---

## 4. `app/config.py` — settings from the environment

The app never hardcodes credentials. Locally they come from environment variables
(via `.env`); on AWS (Doc 13) the same variables are populated from Secrets
Manager. The code doesn't care where they come from.

```python
# app/backend/app/config.py
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Read from environment variables (or a .env file when present).
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "cloudcare"
    db_user: str = "cloudcare_admin"
    db_password: str = "localdevpassword"

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )


settings = Settings()
```

### Walk-through — line by line

| Line | Meaning |
|---|---|
| `from pydantic_settings import BaseSettings, SettingsConfigDict` | Import the helper class that loads env vars into a typed Python object. |
| `class Settings(BaseSettings):` | Define our settings class. Inheriting `BaseSettings` enables auto-loading from env. |
| `model_config = SettingsConfigDict(env_file=".env", extra="ignore")` | Optional `.env` file is read at startup; unknown env vars are ignored (so `PATH`, `HOME`, etc., don't fail validation). |
| `db_host: str = "localhost"` | A typed attribute with a default. **Pydantic looks for env var `DB_HOST`** (auto-uppercased) and uses it if set; otherwise uses the default. |
| `db_port: int = 5432` | Same pattern; **automatic int coercion** — env vars are always strings, Pydantic converts. |
| `database_url` (a `@property`) | Computed at access time; builds the SQLAlchemy URL string from the parts. |
| `settings = Settings()` | Instantiate once; `from .config import settings` everywhere else. |

### The DATABASE_URL format, decoded

```
postgresql+psycopg2://cloudcare_admin:localdevpassword@db:5432/cloudcare
↑          ↑          ↑              ↑              ↑  ↑    ↑
│          │          │              │              │  │    └─ database name
│          │          │              │              │  └─ port
│          │          │              │              └─ host
│          │          │              └─ password
│          │          └─ username
│          └─ Python driver name (psycopg2)
└─ DB family
```

This is SQLAlchemy's standard URL format. Change `db:5432` to your RDS endpoint
in Phase 4 and the same code talks to RDS.

> 🧠 **Twelve-Factor config.** Reading config from the environment (not from code
> or a checked-in file) is a core cloud-app principle: the *same* image runs in
> dev, staging, and prod — only the env vars differ. This is exactly why the same
> container will run locally and on EC2 unchanged.

---

## 5. `app/database.py` — the SQLAlchemy plumbing

```python
# app/backend/app/database.py
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

from .config import settings

# The engine manages the connection pool to Postgres.
# pool_pre_ping checks a connection is alive before using it (survives RDS
# failovers / idle drops).
engine = create_engine(settings.database_url, pool_pre_ping=True)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base class all ORM models inherit from.
Base = declarative_base()


# FastAPI dependency: yields a DB session per request and always closes it.
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
```

### Walk-through

| Line | Meaning |
|---|---|
| `engine = create_engine(settings.database_url, pool_pre_ping=True)` | Create the **engine** — SQLAlchemy's connection-pool manager. Hands out connections from a pool of N rather than opening one per request. |
| `pool_pre_ping=True` | Before reusing a pooled connection, send a tiny ping to confirm it's alive. Defends against connections silently dropped by RDS failovers / network blips / idle timeouts. |
| `SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)` | A **factory** for sessions. Calling `SessionLocal()` gives you a fresh session bound to the engine. `autocommit=False` = you must call `.commit()` explicitly. `autoflush=False` = SQLAlchemy doesn't auto-write pending changes mid-query. Both safer defaults for explicit transactional code. |
| `Base = declarative_base()` | The class **all your ORM models inherit from**. SQLAlchemy uses it to track every model + its metadata (used by `create_all()` and Alembic). |
| `def get_db(): ... yield db ... db.close()` | A FastAPI **dependency** function. The `yield` is the key: code before yield runs at request start (open session); code after yield runs at request end (close it). The `try/finally` guarantees close even if the route raises. |

### How `get_db` plugs into a route

```python
@app.get("/patients")
def list_patients(db: Session = Depends(get_db)):
                       ↑       ↑
                       │       └─ FastAPI: "call get_db(), pass the yielded value as `db`"
                       └─ type hint so editors know what `db` is

    return db.scalars(...).all()
```

Every request gets its own session; the session goes back to the pool when
done. You never write `db.close()` yourself — `get_db`'s `finally` does it.

> 🧠 **Why a session *per request*?** Each HTTP request gets its own DB session and
> returns it to the pool when done. The `try/finally` guarantees we never leak
> connections — important on a tiny instance with a small connection limit.

---

## 6. `app/models.py` — the database tables

```python
# app/backend/app/models.py
from datetime import datetime, date

from sqlalchemy import String, ForeignKey, DateTime, Date, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base


class Patient(Base):
    __tablename__ = "patients"

    id: Mapped[int] = mapped_column(primary_key=True)
    full_name: Mapped[str] = mapped_column(String(120))
    date_of_birth: Mapped[date] = mapped_column(Date)
    phone: Mapped[str] = mapped_column(String(20))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    appointments: Mapped[list["Appointment"]] = relationship(
        back_populates="patient", cascade="all, delete-orphan"
    )


class Appointment(Base):
    __tablename__ = "appointments"

    id: Mapped[int] = mapped_column(primary_key=True)
    patient_id: Mapped[int] = mapped_column(ForeignKey("patients.id"))
    scheduled_for: Mapped[datetime] = mapped_column(DateTime)
    reason: Mapped[str] = mapped_column(String(200))
    status: Mapped[str] = mapped_column(String(20), default="scheduled")

    patient: Mapped["Patient"] = relationship(back_populates="appointments")
```

### Walk-through — the Patient class

| Line | Meaning |
|---|---|
| `class Patient(Base):` | Define an ORM model. Inheriting `Base` registers it with SQLAlchemy. |
| `__tablename__ = "patients"` | The actual DB table name. Convention: lowercase plural. |
| `id: Mapped[int] = mapped_column(primary_key=True)` | An `int` column named `id`, the primary key (auto-incrementing by default in Postgres). |
| `full_name: Mapped[str] = mapped_column(String(120))` | A `VARCHAR(120)` column for the name. |
| `date_of_birth: Mapped[date] = mapped_column(Date)` | A `DATE` column. |
| `phone: Mapped[str] = mapped_column(String(20))` | A `VARCHAR(20)` for the phone number. |
| `created_at: ... server_default=func.now()` | A `TIMESTAMP` column whose default value is computed by the **DB server** (not Python) — `func.now()` becomes Postgres's `NOW()`. Guaranteed correct UTC. |
| `appointments: Mapped[list["Appointment"]] = relationship(...)` | The **one-to-many** relationship: `patient.appointments` returns a list of related appointments. `back_populates="patient"` pairs it with the reverse on `Appointment`. `cascade="all, delete-orphan"` means deleting a patient deletes their appointments too. |

### Walk-through — the Appointment class

| Line | Meaning |
|---|---|
| `patient_id: Mapped[int] = mapped_column(ForeignKey("patients.id"))` | An `INT` column that **references** the patients table's `id`. This is the **FK constraint** — Postgres will refuse an appointment whose patient_id doesn't exist. |
| `scheduled_for: Mapped[datetime] = mapped_column(DateTime)` | A `TIMESTAMP` (no default — must be provided). |
| `reason: ...(String(200))` | Free-text reason. |
| `status: ...(String(20), default="scheduled")` | A Python-side default of `"scheduled"` when not provided. |
| `patient: Mapped["Patient"] = relationship(back_populates="appointments")` | The reverse of the patient's `appointments` — `appointment.patient` returns the parent. |

> 🧠 **The relationship + foreign key** is the "relational" in relational
> database: every appointment belongs to exactly one patient
> (`patient_id → patients.id`), and a patient has many appointments. This is the
> kind of structured, related data SQL/RDS is built for (vs DynamoDB).

> 💡 **Why `Mapped[str]` (typed style)?** SQLAlchemy 2.0 adopted typed
> `Mapped[T]` columns so editors / type checkers know `patient.full_name` is a
> `str`, not "the SQLAlchemy column metaclass." Improves IDE auto-complete and
> catches bugs.

---

## 7. `app/schemas.py` — request/response shapes

ORM models are the *storage* shape; Pydantic schemas are the *API* shape. Keeping
them separate means you control exactly what the API accepts and returns.

```python
# app/backend/app/schemas.py
from datetime import datetime, date
from pydantic import BaseModel, ConfigDict


class PatientCreate(BaseModel):
    full_name: str
    date_of_birth: date
    phone: str


class PatientOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)  # read from ORM objects
    id: int
    full_name: str
    date_of_birth: date
    phone: str
    created_at: datetime


class AppointmentCreate(BaseModel):
    patient_id: int
    scheduled_for: datetime
    reason: str


class AppointmentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    patient_id: int
    scheduled_for: datetime
    reason: str
    status: str
```

### "Create" vs "Out" schemas — the pattern

For each entity you typically have **two** schemas:

| Schema | Used for | Contains |
|---|---|---|
| `XxxCreate` | Validating **incoming** POST bodies | Only fields the client may send |
| `XxxOut` | Shaping **outgoing** responses | All fields including server-generated ones (`id`, `created_at`, etc.) |

Why two? `XxxCreate` deliberately **omits** `id` and `created_at` — those are
server-controlled. If you used one schema for both, a client could try to send
an `id` and confuse things, or you'd have to mark every server-field optional,
which weakens the response validation.

### `ConfigDict(from_attributes=True)` — letting Pydantic read ORM objects

```python
model_config = ConfigDict(from_attributes=True)
```

Pydantic models normally expect a **dict**. With `from_attributes=True`, Pydantic
also accepts an **object** and reads its attributes (`obj.full_name`). FastAPI
returns ORM objects from route handlers; this lets them be serialized
automatically into the schema's shape.

### How validation actually plays out at runtime

```python
@app.post("/patients", response_model=schemas.PatientOut, status_code=201)
def create_patient(payload: schemas.PatientCreate, db: Session = Depends(get_db)):
    ...
```

1. Client sends JSON.
2. FastAPI parses it, runs it through `PatientCreate` — **validates**. If a
   required field is missing or a date is malformed, FastAPI auto-returns 422
   with a detailed error (no code from us).
3. The validated `payload` arrives as a typed Python object.
4. We do DB work, get an ORM `Patient` back.
5. FastAPI shapes the return through `response_model=PatientOut` — only the
   fields declared there are returned, in exactly that shape.

The two schemas are the gateway: **only what's in the schema enters/exits the
API.**

---

## 8. `app/main.py` — the API itself

```python
# app/backend/app/main.py
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from sqlalchemy import select

from .database import Base, engine, get_db
from . import models, schemas

# Create tables on startup if they don't exist. Fine for a learning project;
# in production you'd use Alembic migrations (mention this in interviews).
Base.metadata.create_all(bind=engine)

app = FastAPI(title="CloudCare API", version="1.0.0")

# Allow the React frontend (Doc 14) to call this API from the browser.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten to the real frontend origin in production
    allow_methods=["*"],
    allow_headers=["*"],
)


# The endpoint the ALB target group health-checks. Keep it cheap and dependency-
# free so it stays green even if the DB hiccups momentarily.
@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/patients", response_model=list[schemas.PatientOut])
def list_patients(db: Session = Depends(get_db)):
    return db.scalars(select(models.Patient)).all()


@app.post("/patients", response_model=schemas.PatientOut, status_code=201)
def create_patient(payload: schemas.PatientCreate, db: Session = Depends(get_db)):
    patient = models.Patient(**payload.model_dump())
    db.add(patient)
    db.commit()
    db.refresh(patient)
    return patient


@app.get("/appointments", response_model=list[schemas.AppointmentOut])
def list_appointments(db: Session = Depends(get_db)):
    return db.scalars(select(models.Appointment)).all()


@app.post("/appointments", response_model=schemas.AppointmentOut, status_code=201)
def create_appointment(payload: schemas.AppointmentCreate, db: Session = Depends(get_db)):
    if not db.get(models.Patient, payload.patient_id):
        raise HTTPException(status_code=404, detail="patient not found")
    appt = models.Appointment(**payload.model_dump())
    db.add(appt)
    db.commit()
    db.refresh(appt)
    return appt
```

(Also create an empty `app/backend/app/__init__.py` so Python treats `app/` as a
package.)

### Walk-through — the setup section

```python
Base.metadata.create_all(bind=engine)
```

Tells SQLAlchemy: *"Look at all the classes registered on `Base` (Patient,
Appointment) and `CREATE TABLE IF NOT EXISTS` for each one."* Runs on import →
on every container start. **Idempotent** (won't recreate tables that already
exist) but **does not handle schema changes** — if you add a column, you have
to drop the table or use Alembic. Fine for a learning project; flag the
limitation in interviews.

```python
app = FastAPI(title="CloudCare API", version="1.0.0")
```

Create the FastAPI app. `title` and `version` show up on `/docs` (the
auto-generated Swagger UI).

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
```

**CORS** = Cross-Origin Resource Sharing. Browsers refuse JavaScript from one
origin (e.g. `https://cloudcare.com`) calling an API on another origin (e.g.
`https://api.cloudcare.com`) **unless the API returns headers saying it's OK**.
This middleware adds those headers.

- `allow_origins=["*"]` → any origin (open by design for the lab). Production
  should list the actual frontend origin.
- `allow_methods=["*"]` → any HTTP verb (GET, POST, PUT, DELETE…).
- `allow_headers=["*"]` → any custom request headers.

### Walk-through — `/health` (the simplest possible route)

```python
@app.get("/health")
def health():
    return {"status": "ok"}
```

| Line | Meaning |
|---|---|
| `@app.get("/health")` | Register a function as the handler for `GET /health`. |
| `def health(): return {"status": "ok"}` | Return a dict; FastAPI serializes it to JSON automatically. |

> 🧠 **`/health` is intentionally dumb.** The load balancer hits it every 15
> seconds; it must be fast and not depend on the database, or a brief DB blip
> would mark every instance unhealthy and take the whole service down. Health
> checks test "is this process alive?", not "is the entire system perfect?".

### Walk-through — `list_patients` (a typical GET)

```python
@app.get("/patients", response_model=list[schemas.PatientOut])
def list_patients(db: Session = Depends(get_db)):
    return db.scalars(select(models.Patient)).all()
```

| Line | Meaning |
|---|---|
| `@app.get("/patients", response_model=list[schemas.PatientOut])` | Handle `GET /patients`. Shape the response as a **list of PatientOut**. |
| `def list_patients(db: Session = Depends(get_db)):` | Take a `db` parameter, **inject** the session via `get_db()`. |
| `db.scalars(select(models.Patient)).all()` | SQLAlchemy 2.0 query: `SELECT * FROM patients`, return the row objects as a list. |
| `return ...` | FastAPI serializes each via `PatientOut` (only the listed fields appear). |

### Walk-through — `create_patient` (a typical POST)

```python
@app.post("/patients", response_model=schemas.PatientOut, status_code=201)
def create_patient(payload: schemas.PatientCreate, db: Session = Depends(get_db)):
    patient = models.Patient(**payload.model_dump())
    db.add(patient)
    db.commit()
    db.refresh(patient)
    return patient
```

| Line | Meaning |
|---|---|
| `status_code=201` | Return `201 Created` on success (not the default `200 OK`). |
| `payload: schemas.PatientCreate` | FastAPI parses + **validates** the JSON body through `PatientCreate`. Bad data → automatic 422 response with field details. |
| `models.Patient(**payload.model_dump())` | Convert the Pydantic object to a dict, then unpack as kwargs to construct an ORM object. |
| `db.add(patient)` | Stage the new row. |
| `db.commit()` | **INSERT** runs now; `id` and `created_at` get populated. |
| `db.refresh(patient)` | Reload the object from the DB so server-generated fields (`id`, `created_at`) are present in the response. |

### Walk-through — `create_appointment` (validation + lookup)

```python
if not db.get(models.Patient, payload.patient_id):
    raise HTTPException(status_code=404, detail="patient not found")
```

`db.get(Model, key)` is the **primary-key lookup shortcut**. If the patient
doesn't exist, raise an `HTTPException` — FastAPI catches it and returns the
correct HTTP status + JSON error body. Saves you writing `return JSONResponse(...)`
manually.

---

## 9. `Dockerfile` — package the API into an image

```dockerfile
# app/backend/Dockerfile
FROM python:3.12-slim

# Don't write .pyc files; flush logs immediately (so they show in CloudWatch).
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /code

# Install deps first (this layer is cached unless requirements.txt changes).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Then copy the app code.
COPY app ./app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Walk-through — every line

| Line | Meaning |
|---|---|
| `FROM python:3.12-slim` | Start from the **official slim Python 3.12 base image** (~50 MB instead of ~120 MB for the full one). Contains Python + minimal Debian, nothing else. |
| `ENV PYTHONDONTWRITEBYTECODE=1` | Disable `.pyc` cache files (no benefit in a one-shot container; saves layer space). |
| `ENV PYTHONUNBUFFERED=1` | Force Python to flush stdout/stderr immediately — otherwise logs are buffered and you don't see them in CloudWatch in real time. |
| `WORKDIR /code` | Set the working directory inside the image to `/code`. Subsequent `COPY`/`RUN` commands run from here. |
| `COPY requirements.txt .` | Copy **only `requirements.txt`** into `/code`. (`.` = current WORKDIR.) |
| `RUN pip install --no-cache-dir -r requirements.txt` | Install all pinned deps. `--no-cache-dir` skips pip's local cache (saves ~50 MB of image space). |
| `COPY app ./app` | Copy the application source code into `/code/app`. |
| `EXPOSE 8000` | **Documentation-only.** Tells humans (and Compose/orchestrators) that this image listens on port 8000. Doesn't actually open the port. |
| `CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]` | The default command when the container starts. `app.main:app` = "in module `app.main`, the variable named `app`." `--host 0.0.0.0` makes uvicorn listen on **all** interfaces (not just localhost). |

### Why the order of COPY/RUN matters (layer caching)

```
Layer 1: FROM python:3.12-slim                     [cached forever]
Layer 2: ENV ...                                   [cached forever]
Layer 3: WORKDIR /code                             [cached forever]
Layer 4: COPY requirements.txt .                   [cached unless deps change]
Layer 5: RUN pip install ...                       [cached unless deps change]  ← slow step
Layer 6: COPY app ./app                            [rebuilt when YOU edit code]
Layer 7: EXPOSE 8000                               [cached]
Layer 8: CMD [...]                                 [cached]
```

Docker caches each layer. If you edit a Python file, **only layers 6+ rebuild**
— the slow `pip install` is cached. If you reordered (`COPY app` before
`requirements.txt`), every code edit would trigger a full reinstall. That's why
the order matters.

> 🧠 **Layer caching:** copying `requirements.txt` and installing *before* copying
> the code means Docker only re-runs the slow `pip install` when dependencies
> change, not on every code edit. A small ordering trick that saves real time.

> 🧠 **`--host 0.0.0.0`** makes uvicorn listen on all interfaces inside the
> container (not just localhost), so traffic from outside the container (the ALB,
> or your host) can reach it. This is the `:8000` the app-sg expects.

---

## 10. `docker-compose.yml` — API + Postgres, locally

```yaml
# app/backend/docker-compose.yml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: cloudcare
      POSTGRES_USER: cloudcare_admin
      POSTGRES_PASSWORD: localdevpassword
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cloudcare_admin -d cloudcare"]
      interval: 5s
      timeout: 3s
      retries: 5

  api:
    build: .
    environment:
      DB_HOST: db          # the service name above — Compose gives it a DNS name
      DB_PORT: 5432
      DB_NAME: cloudcare
      DB_USER: cloudcare_admin
      DB_PASSWORD: localdevpassword
    ports:
      - "8000:8000"
    depends_on:
      db:
        condition: service_healthy
```

### Walk-through — the `db` service

| Line | Meaning |
|---|---|
| `image: postgres:16` | Use the official Postgres 16 image from Docker Hub. No custom build. |
| `environment: POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD` | The Postgres image reads these on first run and auto-creates the database + user. |
| `ports: - "5432:5432"` | Publish container's port 5432 to your laptop's port 5432 — so you could `psql` from the host if you wanted. |
| `healthcheck:` | Tell Compose how to check if Postgres is ready. |
| `test: ["CMD-SHELL", "pg_isready ..."]` | Run `pg_isready` (Postgres' bundled liveness tool) — exits 0 if accepting connections. |
| `interval: 5s, timeout: 3s, retries: 5` | Check every 5s; each check waits ≤3s; 5 failed checks → marked unhealthy. |

### Walk-through — the `api` service

| Line | Meaning |
|---|---|
| `build: .` | Build an image from the `Dockerfile` in the current directory. |
| `environment:` | Set env vars inside the container — read by `pydantic-settings` in `config.py`. |
| `DB_HOST: db` | **The hostname `db` resolves to the db service.** Compose creates a virtual network where each service is reachable by its name. |
| `ports: - "8000:8000"` | Publish the API on your host's port 8000 — that's how `curl http://localhost:8000/...` reaches it. |
| `depends_on: db: condition: service_healthy` | Don't start the API until the db's healthcheck passes. Without this, the API would start, fail to connect, and crash-loop. |

> 🧠 **`DB_HOST: db`** — Compose runs both containers on one network and lets them
> reach each other by service name. The API connects to `db:5432`. On AWS, the
> *same* `DB_HOST` env var will instead point at the RDS endpoint — the code
> doesn't change.

### One env var, three different values

The whole point of env-var config:

| Environment | `DB_HOST` value |
|---|---|
| Local (compose) | `db` (the compose service name) |
| EC2 (Phase 4) | the RDS endpoint, e.g. `cloudcare-postgres.xxx.rds.amazonaws.com`, fetched from Secrets Manager |
| CI/CD test | a throwaway test DB hostname |

**Same image, same code — only the env changes.**

---

## 11. Run it locally

From inside `app/backend/`:

### Step 1 — Build and start

```bash
docker compose up --build
```

**Decoded:**

- `docker compose up` — start all services defined in `docker-compose.yml`.
- `--build` — rebuild any service with a `build:` directive first. Important after code changes.

What happens:
1. Compose creates the **network** for the two containers to talk on.
2. Pulls `postgres:16` if not cached.
3. Builds the `api` image from the Dockerfile (slow the first time, ~30s subsequent due to layer cache).
4. Starts the `db` container; runs its healthcheck.
5. Once `db` reports healthy, starts the `api` container.
6. Streams both containers' logs to your terminal.

When you see uvicorn report `Application startup complete`, the API is live.

### Step 2 — Exercise the API (in another terminal)

```bash
# 1) Health check (what the ALB will poll):
curl http://localhost:8000/health
# → {"status":"ok"}

# 2) Create a patient:
curl -X POST http://localhost:8000/patients \
  -H "Content-Type: application/json" \
  -d '{"full_name":"Asha Perera","date_of_birth":"1990-04-12","phone":"0771234567"}'

# 3) Book an appointment for patient id 1:
curl -X POST http://localhost:8000/appointments \
  -H "Content-Type: application/json" \
  -d '{"patient_id":1,"scheduled_for":"2026-06-10T09:30:00","reason":"General checkup"}'

# 4) List them back:
curl http://localhost:8000/patients
curl http://localhost:8000/appointments
```

**Curl flags explained:**

| Flag | Meaning |
|---|---|
| `-X POST` | Use HTTP POST (default is GET). |
| `-H "Content-Type: application/json"` | Add a request header — tells the server the body is JSON. |
| `-d '{"...": "..."}'` | The request body. Single quotes prevent shell-interpretation of the inner JSON. |
| (none) `curl http://...` | Plain GET. |

### Step 3 — Try the auto-generated docs

Open **http://localhost:8000/docs** in your browser — FastAPI's
auto-generated interactive API documentation (Swagger UI). Click "Try it out"
on any endpoint to issue real calls.

There's also **`/redoc`** for a different doc style and **`/openapi.json`** for
the raw OpenAPI spec (used to generate client libraries).

### Step 4 — Stop cleanly

```bash
# Stop and remove the containers when done (add -v to also wipe the DB volume):
docker compose down
```

**Decoded:**

- `docker compose down` — stop and remove all containers from this Compose project.
- `-v` (optional) — also remove the **volumes** (so the DB starts fresh next time). Without `-v`, your data persists across `up`/`down` cycles.

> ✅ **The finish line for this doc:** all four `curl`s work and `/docs` loads. You
> now have a real, containerized API talking to Postgres — proven on your laptop.

---

## 12. `.env.example` and committing safely

Create `.env.example` as a template (commit this), and note that a real `.env`
(if you make one) is already ignored by the Phase 0 `.gitignore`:

```text
# app/backend/.env.example  (copy to .env for local overrides; .env is gitignored)
DB_HOST=localhost
DB_PORT=5432
DB_NAME=cloudcare
DB_USER=cloudcare_admin
DB_PASSWORD=localdevpassword
```

### The `.env` vs `.env.example` pattern

| File | Purpose | Committed? |
|---|---|---|
| `.env.example` | A **template** showing what env vars exist. Sane / non-secret defaults. | ✅ yes — newcomers `cp .env.example .env` to get started |
| `.env` | Your **actual** local values, possibly with secrets. | ❌ no — listed in `.gitignore` |

This is the standard pattern across the industry. Run `git status` after
creating `.env` — it should NOT appear.

> 🔒 The local password here is deliberately throwaway and only ever touches your
> laptop. The **real** database password lives in Secrets Manager (Phase 3) and is
> never written to a file — Doc 13 wires that in.

---

## 13. Plain-English summary (what you just built)

If asked to explain Phase 4 part 1:

1. **A small FastAPI backend** with three concept layers cleanly separated:
   - **`models.py`** = how the data is stored (SQLAlchemy ORM).
   - **`schemas.py`** = how the API speaks (Pydantic) — only what's listed enters/exits.
   - **`main.py`** = the routes that glue requests to DB operations.
2. **Config from env vars** (`config.py` + `pydantic-settings`) — same code runs
   locally and on EC2; only env values change.
3. A **`/health`** endpoint that doesn't touch the DB — for the ALB.
4. **One Dockerfile** producing a slim, layer-cached image.
5. **One `docker-compose.yml`** spinning up the API + a throwaway Postgres,
   wired by a Compose-managed network where services find each other by name.
6. **Validated**: 4 `curl`s create + list patients + appointments, plus
   FastAPI's auto-generated Swagger at `/docs`.

The image you just built is the **exact** image Doc 13 will push to ECR and run
on EC2 — no edits needed.

---

## 14. Interview soundbites

- **Twelve-Factor config** — *"The app reads all configuration from environment
  variables. The same Docker image runs locally with Compose (`DB_HOST=db`),
  on EC2 with RDS (`DB_HOST=<rds-endpoint>`), or in CI tests, with zero code
  changes."*

- **Models vs schemas** — *"ORM models describe storage; Pydantic schemas
  describe the API contract. Keeping them separate means I can never accidentally
  leak a stored field — only what's declared in the schema is serialized."*

- **`/health` design** — *"The health endpoint is intentionally dependency-free.
  The ALB hits it every 15 seconds; if it touched the DB, a brief Postgres blip
  would mark every instance unhealthy and take the whole service down. Health
  checks ask *'is this process alive'*, not *'is the universe perfect'*."*

- **Docker layer caching** — *"The Dockerfile copies `requirements.txt` and
  installs deps **before** copying source code. That way a code edit only
  rebuilds the last two layers; pip install stays cached. Tiny ordering choice,
  big build-time win."*

- **Schema migrations** — *"For the lab we use `Base.metadata.create_all` —
  idempotent table creation on startup. In production this becomes Alembic
  migrations under a CI step, so schema changes are versioned and reviewable."*

---

## ✅ Checkpoint

You're ready for Doc 13 when:

- [ ] `docker compose up --build` starts the API and Postgres cleanly.
- [ ] `curl /health` returns `{"status":"ok"}`, and you can create + list patients
      and appointments.
- [ ] `/docs` loads in the browser.
- [ ] You can explain: why config comes from env vars, why `/health` doesn't touch
      the DB, what the Docker image gives you, and the models-vs-schemas split.
- [ ] You can read every line of every Python file and the Dockerfile and explain
      it in plain English.

Next: **[13 — Deploy the Backend to EC2](13-application-deploy-to-ec2.md)** — we
give the private app instances internet egress (a NAT instance), let them pull the
DB password from Secrets Manager via their IAM role, run this exact image, and
serve it through the Phase 2 ALB.

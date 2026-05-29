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

> 🧠 **The relationship + foreign key** is the "relational" in relational
> database: every appointment belongs to exactly one patient
> (`patient_id → patients.id`), and a patient has many appointments. This is the
> kind of structured, related data SQL/RDS is built for (vs DynamoDB).

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

> 🧠 **`/health` is intentionally dumb.** The load balancer hits it every 15
> seconds; it must be fast and not depend on the database, or a brief DB blip
> would mark every instance unhealthy and take the whole service down. Health
> checks test "is this process alive?", not "is the entire system perfect?".

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

> 🧠 **`DB_HOST: db`** — Compose runs both containers on one network and lets them
> reach each other by service name. The API connects to `db:5432`. On AWS, the
> *same* `DB_HOST` env var will instead point at the RDS endpoint — the code
> doesn't change.

---

## 11. Run it locally

From inside `app/backend/`:

```bash
# Build the image and start both containers.
docker compose up --build
```

When you see uvicorn report `Application startup complete`, open another terminal:

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

Then open **http://localhost:8000/docs** in your browser — FastAPI's
auto-generated interactive API documentation. Click "Try it out" on any endpoint.

```bash
# Stop and remove the containers when done (add -v to also wipe the DB volume):
docker compose down
```

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

> 🔒 The local password here is deliberately throwaway and only ever touches your
> laptop. The **real** database password lives in Secrets Manager (Phase 3) and is
> never written to a file — Doc 13 wires that in.

---

## ✅ Checkpoint

You're ready for Doc 13 when:

- [ ] `docker compose up --build` starts the API and Postgres cleanly.
- [ ] `curl /health` returns `{"status":"ok"}`, and you can create + list patients
      and appointments.
- [ ] `/docs` loads in the browser.
- [ ] You can explain: why config comes from env vars, why `/health` doesn't touch
      the DB, and what the Docker image gives you.

Next: **[13 — Deploy the Backend to EC2](13-application-deploy-to-ec2.md)** — we
give the private app instances internet egress (a NAT instance), let them pull the
DB password from Secrets Manager via their IAM role, run this exact image, and
serve it through the Phase 2 ALB.

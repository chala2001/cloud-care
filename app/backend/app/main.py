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
# @app.get("/health")
# def health():
#     return {"status": "ok"}


# @app.get("/patients", response_model=list[schemas.PatientOut])
# def list_patients(db: Session = Depends(get_db)):
#     return db.scalars(select(models.Patient)).all()


# @app.post("/patients", response_model=schemas.PatientOut, status_code=201)
# def create_patient(payload: schemas.PatientCreate, db: Session = Depends(get_db)):
#     patient = models.Patient(**payload.model_dump())
#     db.add(patient)
#     db.commit()
#     db.refresh(patient)
#     return patient


# @app.get("/appointments", response_model=list[schemas.AppointmentOut])
# def list_appointments(db: Session = Depends(get_db)):
#     return db.scalars(select(models.Appointment)).all()


# @app.post("/appointments", response_model=schemas.AppointmentOut, status_code=201)
# def create_appointment(payload: schemas.AppointmentCreate, db: Session = Depends(get_db)):
#     if not db.get(models.Patient, payload.patient_id):
#         raise HTTPException(status_code=404, detail="patient not found")
#     appt = models.Appointment(**payload.model_dump())
#     db.add(appt)
#     db.commit()
#     db.refresh(appt)
#     return appt

# replace the @app.get/post for patients & appointments with this router

from fastapi import APIRouter

router = APIRouter(prefix="/api")

@router.get("/patients", response_model=list[schemas.PatientOut])
def list_patients(db: Session = Depends(get_db)):
    return db.scalars(select(models.Patient)).all()

@router.post("/patients", response_model=schemas.PatientOut, status_code=201)
def create_patient(payload: schemas.PatientCreate, db: Session = Depends(get_db)):
    patient = models.Patient(**payload.model_dump())
    db.add(patient); db.commit(); db.refresh(patient)
    return patient

@router.get("/appointments", response_model=list[schemas.AppointmentOut])
def list_appointments(db: Session = Depends(get_db)):
    return db.scalars(select(models.Appointment)).all()

@router.post("/appointments", response_model=schemas.AppointmentOut, status_code=201)
def create_appointment(payload: schemas.AppointmentCreate, db: Session = Depends(get_db)):
    if not db.get(models.Patient, payload.patient_id):
        raise HTTPException(status_code=404, detail="patient not found")
    appt = models.Appointment(**payload.model_dump())
    db.add(appt); db.commit(); db.refresh(appt)
    return appt

app.include_router(router)
# /health stays a top-level @app.get("/health")

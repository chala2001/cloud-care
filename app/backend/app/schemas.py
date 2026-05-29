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
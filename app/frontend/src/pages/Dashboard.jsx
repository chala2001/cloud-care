// app/frontend/src/pages/Dashboard.jsx
import { useEffect, useState } from "react";
import { api } from "../api";

export default function Dashboard() {
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

  function badgeClass(status) {
    switch ((status || "").toLowerCase()) {
      case "scheduled": return "badge badge-scheduled";
      case "completed": return "badge badge-completed";
      case "cancelled":
      case "canceled":  return "badge badge-cancelled";
      default:          return "badge badge-default";
    }
  }

  return (
    <>
      {error && <p className="error">{error}</p>}

      <section className="card">
        <div className="card-header">
          <h2 className="card-title">Patients</h2>
          <span className="card-count">{patients.length} total</span>
        </div>
        <div className="card-body">
          <form onSubmit={addPatient} className="form-row">
            <input
              className="input"
              required
              placeholder="Full name"
              value={patient.full_name}
              onChange={(e) => setPatient({ ...patient, full_name: e.target.value })}
            />
            <input
              className="input"
              required
              type="date"
              value={patient.date_of_birth}
              onChange={(e) => setPatient({ ...patient, date_of_birth: e.target.value })}
            />
            <input
              className="input"
              required
              placeholder="Phone"
              value={patient.phone}
              onChange={(e) => setPatient({ ...patient, phone: e.target.value })}
            />
            <div className="form-action">
              <button type="submit" className="btn">Add patient</button>
            </div>
          </form>

          {patients.length === 0 ? (
            <div className="empty">No patients yet. Add one above to get started.</div>
          ) : (
            <ul className="list">
              {patients.map((p) => (
                <li key={p.id} className="list-item">
                  <span className="id-chip">#{p.id}</span>
                  <div className="item-body">
                    <span className="item-primary">{p.full_name}</span>
                    <span className="item-secondary">{p.phone}</span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      <section className="card">
        <div className="card-header">
          <h2 className="card-title">Appointments</h2>
          <span className="card-count">{appointments.length} total</span>
        </div>
        <div className="card-body">
          <form onSubmit={bookAppointment} className="form-row">
            <input
              className="input"
              required
              type="number"
              placeholder="Patient id"
              value={appt.patient_id}
              onChange={(e) => setAppt({ ...appt, patient_id: e.target.value })}
            />
            <input
              className="input"
              required
              type="datetime-local"
              value={appt.scheduled_for}
              onChange={(e) => setAppt({ ...appt, scheduled_for: e.target.value })}
            />
            <input
              className="input"
              required
              placeholder="Reason"
              value={appt.reason}
              onChange={(e) => setAppt({ ...appt, reason: e.target.value })}
            />
            <div className="form-action">
              <button type="submit" className="btn">Book</button>
            </div>
          </form>

          {appointments.length === 0 ? (
            <div className="empty">No appointments yet. Book one above.</div>
          ) : (
            <ul className="list">
              {appointments.map((a) => (
                <li key={a.id} className="list-item">
                  <span className="id-chip">#{a.id}</span>
                  <div className="item-body">
                    <div className="item-body-row">
                      <span className="item-primary">Patient {a.patient_id}</span>
                      <span className={badgeClass(a.status)}>{a.status}</span>
                    </div>
                    <span className="item-secondary">{a.reason}</span>
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

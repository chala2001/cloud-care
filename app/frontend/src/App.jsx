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
// app/frontend/src/pages/Contact.jsx
//
// Hits the serverless contact stack: API Gateway → Lambda → SES.
// SES is in sandbox mode, so the recipient must be a verified identity.

import { useState } from "react";
import { contactApi } from "../api";

const empty = { name: "", email: "", message: "" };

export default function Contact() {
  const [form, setForm] = useState(empty);
  const [status, setStatus] = useState(null); // null | "sending" | "sent" | "error"
  const [error, setError] = useState("");

  const configured = contactApi.configured();

  async function submit(e) {
    e.preventDefault();
    setStatus("sending");
    setError("");
    try {
      await contactApi.send(form);
      setForm(empty);
      setStatus("sent");
    } catch (err) {
      setError(String(err));
      setStatus("error");
    }
  }

  return (
    <>
      <section className="card hero">
        <div className="card-body">
          <span className="eyebrow">Serverless &middot; Contact form</span>
          <h2 className="hero-title">Get in touch</h2>
          <p className="hero-lead">
            Submissions are delivered by an AWS Lambda function behind API
            Gateway. The Lambda calls <code>ses:SendEmail</code> with a verified
            SES identity, so the message lands in the hospital admin inbox
            without any mail server of our own.
          </p>
        </div>
      </section>

      {!configured && (
        <section className="card scope">
          <div className="card-body">
            <h3 className="section-heading">Contact API URL not configured</h3>
            <p className="muted">
              The build did not receive <code>VITE_CONTACT_API_URL</code>.
              Submissions will fail until the CI workflow injects it from the{" "}
              <code>serverless-contact</code> Terraform output.
            </p>
          </div>
        </section>
      )}

      <section className="card">
        <div className="card-header">
          <h3 className="card-title">Send a message</h3>
        </div>
        <div className="card-body">
          {status === "sent" && (
            <p className="success-banner">
              Message sent &mdash; check the hospital admin inbox.
            </p>
          )}
          {status === "error" && <p className="error">{error}</p>}

          <form onSubmit={submit} className="form-stack">
            <label className="field">
              <span className="field-label">Your name</span>
              <input
                className="input"
                required
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                placeholder="Jane Doe"
              />
            </label>

            <label className="field">
              <span className="field-label">Email address</span>
              <input
                className="input"
                required
                type="email"
                value={form.email}
                onChange={(e) => setForm({ ...form, email: e.target.value })}
                placeholder="jane@example.com"
              />
            </label>

            <label className="field">
              <span className="field-label">Message</span>
              <textarea
                className="input textarea"
                required
                rows="5"
                value={form.message}
                onChange={(e) => setForm({ ...form, message: e.target.value })}
                placeholder="What would you like us to know?"
              />
            </label>

            <button
              type="submit"
              className="btn btn-inline"
              disabled={status === "sending" || !configured}
            >
              {status === "sending" ? "Sending..." : "Send message"}
            </button>
          </form>
        </div>
      </section>

      <section className="card">
        <div className="card-header">
          <h3 className="card-title">How this works</h3>
        </div>
        <div className="card-body">
          <ol className="numbered">
            <li>Browser POSTs JSON to <code>/contact</code> on the API Gateway HTTP API.</li>
            <li>API Gateway invokes the contact Lambda with payload format 2.0.</li>
            <li>Lambda validates the fields and calls SES <code>SendEmail</code>.</li>
            <li>SES delivers the email to the verified recipient address.</li>
            <li>The <code>Reply-To</code> is set to the sender, so replies go to them, not us.</li>
          </ol>
        </div>
      </section>
    </>
  );
}

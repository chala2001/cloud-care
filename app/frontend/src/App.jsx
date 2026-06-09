// app/frontend/src/App.jsx
import { useEffect, useState } from "react";
import Dashboard from "./pages/Dashboard.jsx";
import About from "./pages/About.jsx";
import Contact from "./pages/Contact.jsx";
import Audit from "./pages/Audit.jsx";

// Tiny hash-based router so deep links (#/about, #/contact, #/audit) work
// without adding a router library.
const ROUTES = ["dashboard", "about", "contact", "audit"];

function getRoute() {
  const h = (window.location.hash || "").replace(/^#\/?/, "");
  return ROUTES.includes(h) ? h : "dashboard";
}

export default function App() {
  const [route, setRoute] = useState(getRoute());

  useEffect(() => {
    const onHashChange = () => setRoute(getRoute());
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);

  function navClass(target) {
    return "nav-link" + (route === target ? " nav-link-active" : "");
  }

  function renderPage() {
    switch (route) {
      case "about":    return <About />;
      case "contact":  return <Contact />;
      case "audit":    return <Audit />;
      default:         return <Dashboard />;
    }
  }

  return (
    <>
      <header className="app-header">
        <div className="app-header-inner">
          <a href="#/" className="app-brand">
            <div className="app-logo" aria-hidden="true">CC</div>
            <div>
              <h1 className="app-title">CloudCare HMS</h1>
              <p className="app-subtitle">Hospital management system</p>
            </div>
          </a>

          <nav className="app-nav">
            <a href="#/"        className={navClass("dashboard")}>Dashboard</a>
            <a href="#/audit"   className={navClass("audit")}>Audit</a>
            <a href="#/contact" className={navClass("contact")}>Contact</a>
            <a href="#/about"   className={navClass("about")}>About</a>
          </nav>
        </div>
      </header>

      <main className="app-main">
        {renderPage()}
      </main>
    </>
  );
}

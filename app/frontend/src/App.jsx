// app/frontend/src/App.jsx
import { useEffect, useState } from "react";
import Dashboard from "./pages/Dashboard.jsx";
import About from "./pages/About.jsx";

// Tiny hash-based router so deep links (#/about) work without adding a router
// library. Two routes is not enough to justify react-router-dom.
function getRoute() {
  const h = (window.location.hash || "").replace(/^#\/?/, "");
  return h === "about" ? "about" : "dashboard";
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
            <a href="#/"      className={navClass("dashboard")}>Dashboard</a>
            <a href="#/about" className={navClass("about")}>About</a>
          </nav>
        </div>
      </header>

      <main className="app-main">
        {route === "about" ? <About /> : <Dashboard />}
      </main>
    </>
  );
}

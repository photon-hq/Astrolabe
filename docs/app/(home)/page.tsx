import Link from 'next/link';
import {
  Activity,
  ArrowRight,
  GitBranch,
  PackageCheck,
  RefreshCw,
  ShieldCheck,
  Terminal,
} from 'lucide-react';

const highlights = [
  {
    icon: PackageCheck,
    title: 'Declare the Mac you want',
    body: 'Homebrew, packages, launchd jobs, Jamf settings, system preferences, and custom steps live in one Swift tree.',
  },
  {
    icon: RefreshCw,
    title: 'Reconcile continuously',
    body: 'Astrolabe runs as a LaunchDaemon and keeps checking drift instead of treating setup as a one-shot script.',
  },
  {
    icon: ShieldCheck,
    title: 'Operate from root safely',
    body: 'State, persistence, daemon activation, telemetry, and updates are built around explicit system boundaries.',
  },
];

export default function HomePage() {
  return (
    <div className="photon-home">
      <section className="photon-hero" aria-labelledby="hero-title">
        <div className="photon-hero__backdrop" aria-hidden="true" />
        <div className="photon-hero__veil" aria-hidden="true" />
        <div className="photon-hero__content">
          <p className="eyebrow">Declarative macOS configuration</p>
          <h1 id="hero-title">Astrolabe</h1>
          <p className="photon-hero__copy">
            A Swift framework for keeping macOS machines in a known state over time.
          </p>
          <div className="photon-hero__actions" aria-label="Primary actions">
            <Link href="/docs" className="photon-button photon-button--primary">
              Read the docs
              <ArrowRight aria-hidden="true" />
            </Link>
            <Link
              href="https://github.com/photon-hq/Astrolabe"
              className="photon-button photon-button--secondary"
              target="_blank"
              rel="noreferrer"
            >
              <GitBranch aria-hidden="true" />
              GitHub
            </Link>
          </div>
        </div>
      </section>

      <section className="photon-home-section" aria-label="Astrolabe overview">
        <div className="photon-section-heading">
          <p className="eyebrow">System state, expressed in Swift</p>
          <h2>Built for developer-managed Macs</h2>
        </div>
        <div className="photon-card-grid">
          {highlights.map((item) => (
            <article className="photon-card" key={item.title}>
              <item.icon aria-hidden="true" />
              <h3>{item.title}</h3>
              <p>{item.body}</p>
            </article>
          ))}
        </div>
        <div className="photon-command-strip" aria-label="Example command">
          <Terminal aria-hidden="true" />
          <code>sudo .build/debug/BasicSetup update-loop</code>
          <Activity aria-hidden="true" />
        </div>
      </section>
    </div>
  );
}

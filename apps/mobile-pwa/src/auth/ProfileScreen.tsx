import { useAppStore } from '../lib/store';

export function ProfileScreen() {
  const user = useAppStore((s) => s.user);
  const pairedHost = useAppStore((s) => s.pairedHost);
  const availableHosts = useAppStore((s) => s.availableHosts);
  const navigateTo = useAppStore((s) => s.navigateTo);
  const signOut = useAppStore((s) => s.signOut);
  const onlineHosts = availableHosts.filter((host) => host.online).length;

  return (
    <div className="h-full overflow-y-auto safe-pad-x safe-pad-bottom">
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-5 py-6">
        <section>
          <div className="gt-kicker">Account</div>
          <h1 className="mt-2 text-4xl font-semibold">Profile</h1>
          <p className="gt-muted mt-2 text-sm">Manage your signed-in Glasstunnel session.</p>
        </section>

        <section className="gt-panel p-6">
          <div className="flex flex-col gap-5 md:flex-row md:items-center md:justify-between">
            <div className="flex min-w-0 items-center gap-4">
              <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full border border-accent/45 bg-accent/15 text-lg font-semibold text-accent">
                {initialsFor(user?.displayName || user?.email || 'GT')}
              </div>
              <div className="min-w-0">
                <h2 className="truncate text-xl font-semibold">
                  {user?.displayName || 'Glasstunnel account'}
                </h2>
                <p className="gt-muted mt-1 truncate text-sm">{user?.email ?? 'Signed in'}</p>
              </div>
            </div>

            <button
              type="button"
              onClick={() => void signOut()}
              className="gt-button gt-button-secondary justify-center px-5 py-3 text-sm"
            >
              Sign out
            </button>
          </div>
        </section>

        <section className="grid gap-3 md:grid-cols-3">
          <StatCard label="Linked Macs" value={String(availableHosts.length)} />
          <StatCard label="Online" value={String(onlineHosts)} />
          <StatCard label="Current Mac" value={pairedHost ? 'Open' : 'None'} />
        </section>

        <section className="gt-panel p-5">
          <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
            <div>
              <h2 className="text-lg font-semibold">Current workspace</h2>
              <p className="gt-muted mt-1 text-sm">
                {pairedHost ? pairedHost.label : 'Choose a Mac to open a remote workspace.'}
              </p>
            </div>
            <div className="flex flex-col gap-2 sm:flex-row">
              {pairedHost && (
                <button
                  type="button"
                  onClick={() => navigateTo('workspace')}
                  className="gt-button gt-button-primary justify-center px-5 py-3 text-sm"
                >
                  Open workspace
                </button>
              )}
              <button
                type="button"
                onClick={() => navigateTo('hosts')}
                className="gt-button gt-button-secondary justify-center px-5 py-3 text-sm"
              >
                Your Macs
              </button>
            </div>
          </div>
        </section>
      </div>
    </div>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="gt-panel p-5">
      <div className="text-3xl font-semibold">{value}</div>
      <div className="gt-muted mt-1 text-sm">{label}</div>
    </div>
  );
}

function initialsFor(value: string) {
  const words = value
    .replace(/@.*/, '')
    .split(/[\s._-]+/)
    .filter(Boolean);
  const initials = words.slice(0, 2).map((word) => word[0]?.toUpperCase()).join('');
  return initials || 'GT';
}

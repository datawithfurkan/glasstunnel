import { useDeferredValue, useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react';
import type { AgentStateSnapshot, AgentTargetOption, RemoteApp, RemoteAppActionRequest } from '@glasstunnel/protocol';
import { AgentStatus } from '@glasstunnel/protocol';
import { useAppStore } from '../lib/store';
import { isDirectRemoteApp, isProjectRemoteApp } from '../lib/remoteApps';
import { currentWorkspaceFixtureInitialAppId } from '../dev/workspaceFixture';
import { HorizontalScrollStrip } from '../ui/HorizontalScrollStrip';
import { AgentCard, selectedTerminalSessionLabel } from './AgentCard';
import { ScreenRemotePanel } from './ScreenRemotePanel';

export type AppFilterId =
  | 'all'
  | 'screen'
  | 'codex'
  | 'claude-desktop'
  | 'claude-code'
  | 'cursor'
  | 'cursor-agent'
  | 'gemini-cli'
  | 'opencode'
  | 'codex-cli'
  | 'terminal';

interface AppFilter {
  id: AppFilterId;
  label: string;
  shortLabel?: string;
}

interface ChatSelection {
  appId: string;
  targetId?: string;
}

export interface PendingAppAction {
  action: RemoteAppActionRequest['action'];
  atUnixMs: number;
}

type WorkspaceTone = 'neutral' | 'warning' | 'error';

interface RemoteAppStartState {
  title: string;
  copy: string;
  detail?: string;
  action: string;
  tone: WorkspaceTone;
}

export const REMOTE_APP_ACTION_TIMEOUT_MS = 20_000;

interface WorkspaceConnectionNotice {
  title: string;
  copy: string;
  detail?: string;
  action: string;
  tone: WorkspaceTone;
}

export interface ProjectGroup {
  id: string;
  kind: 'project' | 'chat';
  app: RemoteApp;
  snapshot?: AgentStateSnapshot;
  label: string;
  path: string;
  threads: AgentTargetOption[];
  directTarget?: AgentTargetOption;
  selected: boolean;
  lastActivityUnixMs?: number;
}

const APP_FILTERS: AppFilter[] = [
  { id: 'all', label: 'All' },
  { id: 'screen', label: 'Mac Screen', shortLabel: 'Screen' },
  { id: 'codex', label: 'Codex' },
  { id: 'claude-desktop', label: 'Claude' },
  { id: 'claude-code', label: 'Claude Code', shortLabel: 'Code' },
  { id: 'cursor', label: 'Cursor' },
  { id: 'cursor-agent', label: 'Cursor Agent', shortLabel: 'Agent' },
  { id: 'gemini-cli', label: 'Gemini CLI', shortLabel: 'Gemini' },
  { id: 'opencode', label: 'OpenCode' },
  { id: 'codex-cli', label: 'Codex CLI', shortLabel: 'CLI' },
  { id: 'terminal', label: 'Terminal' },
];


/**
 * Heading of an open card. The session's own name comes first (a thread
 * label, or the live session name the Mac reports); the project it belongs
 * to is the subtitle, and the absolute path only when nothing shorter exists.
 */
export function focusedChatHeading(input: {
  threadLabel?: string;
  targetLabel?: string;
  agentLabel?: string;
  groupLabel?: string;
  displayName?: string;
  projectLabel?: string;
  projectPath?: string;
  targetSubtitle?: string;
  terminalSessionLabel?: string | null;
  groupPath?: string;
  statusDetail?: string;
}): { title: string | undefined; subtitle: string | undefined } {
  const title =
    input.threadLabel || input.targetLabel || input.agentLabel || input.groupLabel || input.displayName || undefined;
  const candidates = [
    input.terminalSessionLabel,
    input.projectLabel,
    input.groupLabel,
    input.projectPath,
    input.targetSubtitle,
    input.groupPath,
    input.statusDetail,
  ];
  const subtitle = candidates.find((candidate) => candidate && candidate !== title) || undefined;
  return { title, subtitle };
}

export function AgentCarousel() {
  const remoteApps = useAppStore((s) => s.remoteApps);
  const agents = useAppStore((s) => s.agents);
  const hello = useAppStore((s) => s.hostHello);
  const error = useAppStore((s) => s.error);
  const relayHostOnline = useAppStore((s) => s.relayHostOnline);
  const recoverConnection = useAppStore((s) => s.recoverConnection);
  const selectTarget = useAppStore((s) => s.selectTarget);
  const renameTarget = useAppStore((s) => s.renameTarget);
  const requestRemoteAppAction = useAppStore((s) => s.requestRemoteAppAction);
  const fixtureInitialAppId = currentWorkspaceFixtureInitialAppId();
  const deepLinkInitialAppId = fixtureInitialAppId ?? currentWorkspaceInitialAppId();

  const [appFilter, setAppFilter] = useState<AppFilterId>(deepLinkInitialAppId ?? 'all');
  const [selectedChat, setSelectedChat] = useState<ChatSelection | null>(
    deepLinkInitialAppId ? { appId: deepLinkInitialAppId } : null,
  );
  const [collapsedProjects, setCollapsedProjects] = useState<Set<string>>(() => new Set());
  const [mobileMode, setMobileMode] = useState<'list' | 'chat'>(deepLinkInitialAppId ? 'chat' : 'list');
  const [searchQuery, setSearchQuery] = useState('');
  const [pendingAppActions, setPendingAppActions] = useState<Record<string, PendingAppAction>>({});
  const [pendingActionClockMs, setPendingActionClockMs] = useState(() => Date.now());
  const deferredSearchQuery = useDeferredValue(searchQuery);

  const projectApps = useMemo(() => remoteApps.filter(isProjectRemoteApp), [remoteApps]);
  const appsById = useMemo(() => new Map(remoteApps.map((app) => [app.remoteAppId, app])), [remoteApps]);
  const appAvailability = useMemo(
    () => new Map(remoteApps.map((app) => [app.remoteAppId, app])),
    [remoteApps],
  );
  const filteredApps = useMemo(
    () =>
      appFilter === 'all'
        ? projectApps
        : remoteApps.filter((app) => app.remoteAppId === appFilter),
    [appFilter, projectApps, remoteApps],
  );
  const groupsByApp = useMemo(
    () => new Map(projectApps.map((app) => [app.remoteAppId, buildProjectGroups(app, agents[app.agentId])])),
    [agents, projectApps],
  );
  const visibleGroups = useMemo(() => {
    const query = normalizeSearch(deferredSearchQuery);
    return filteredApps.flatMap((app) => {
      const groups = groupsByApp.get(app.remoteAppId) ?? [];
      if (!query) return groups;
      return groups
        .map((group) => filterProjectGroup(group, query))
        .filter((group): group is ProjectGroup => Boolean(group));
    });
  }, [deferredSearchQuery, filteredApps, groupsByApp]);
  const selectedApp = selectedChat ? appsById.get(selectedChat.appId) : null;
  const selectedFilterApp = appFilter === 'all' ? null : appsById.get(appFilter) ?? null;
  const selectedSnapshot = selectedApp ? agents[selectedApp.agentId] : undefined;
  const selectedTarget = selectedSnapshot?.availableTargets?.find((target) => target.targetId === selectedChat?.targetId);
  const selectedGroup = selectedApp
    ? (groupsByApp.get(selectedApp.remoteAppId) ?? []).find((group) =>
        group.directTarget?.targetId === selectedChat?.targetId ||
        group.threads.some((thread) => thread.targetId === selectedChat?.targetId),
      )
    : undefined;
  const { title: selectedTitle, subtitle: selectedSubtitle } = focusedChatHeading({
    threadLabel: selectedTarget?.threadLabel,
    targetLabel: selectedTarget?.label,
    agentLabel: selectedSnapshot?.agentLabel,
    groupLabel: selectedGroup?.label,
    displayName: selectedApp?.displayName,
    projectLabel: selectedTarget?.projectLabel,
    projectPath: selectedTarget?.projectPath,
    targetSubtitle: selectedTarget?.subtitle,
    terminalSessionLabel:
      selectedApp?.remoteAppId === 'terminal' ? selectedTerminalSessionLabel(selectedSnapshot) : null,
    groupPath: selectedGroup?.path,
    statusDetail: selectedSnapshot?.statusDetail || selectedApp?.statusDetail,
  });

  useEffect(() => {
    if (!shouldResetAppFilter(appFilter, remoteApps.length, appAvailability)) return;
    setAppFilter('all');
  }, [appAvailability, appFilter, remoteApps.length]);

  useEffect(() => {
    if (remoteApps.length === 0) {
      setSelectedChat(null);
      return;
    }

    if (selectedChat && appsById.has(selectedChat.appId)) {
      const app = appsById.get(selectedChat.appId);
      const snapshot = agents[app?.agentId ?? ''];
      if (app && isDirectRemoteApp(app.remoteAppId)) return;
      if (!selectedChat.targetId || snapshot?.availableTargets?.some((target) => target.targetId === selectedChat.targetId)) {
        return;
      }
    }

    const next = defaultSelection(filteredApps.length > 0 ? filteredApps : projectApps, agents);
    setSelectedChat(next);
  }, [agents, appsById, filteredApps, projectApps, remoteApps.length, selectedChat]);

  useEffect(() => {
    setPendingAppActions((current) => {
      let changed = false;
      const next = { ...current };
      for (const [appId, pending] of Object.entries(current)) {
        const app = appsById.get(appId);
        const snapshot = app ? agents[app.agentId] : undefined;
        const snapshotUpdatedAfterAction = snapshot
          ? latestSnapshotUnixMs(snapshot) >= pending.atUnixMs - 1000
          : false;
        const remoteAppSettled =
          app?.status === AgentStatus.Done ||
          app?.status === AgentStatus.Error ||
          app?.status === AgentStatus.Disconnected;
        if (!app || snapshotUpdatedAfterAction || remoteAppSettled) {
          delete next[appId];
          changed = true;
        }
      }
      return changed ? next : current;
    });
  }, [agents, appsById, remoteApps]);

  useEffect(() => {
    if (Object.keys(pendingAppActions).length === 0) return;
    const timer = window.setInterval(() => setPendingActionClockMs(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [pendingAppActions]);

  const openThread = (app: RemoteApp, target?: AgentTargetOption) => {
    if (target && shouldRequestTargetSelection(app, target)) {
      const delivered = selectTarget(app.agentId, target.targetId);
      if (!delivered) return;
    }
    setSelectedChat({ appId: app.remoteAppId, targetId: target?.targetId });
    setMobileMode('chat');
  };

  const openDefaultChat = () => {
    const app =
      (selectedChat ? appsById.get(selectedChat.appId) : null) ??
      (filteredApps.length > 0 ? filteredApps[0] : projectApps[0] ?? remoteApps[0]);
    if (!app) return;
    const target = defaultTarget(agents[app.agentId]);
    openThread(app, target);
  };

  const startRemoteApp = (app: RemoteApp) => {
    const action: RemoteAppActionRequest['action'] = app.available ? 'start' : 'launch';
    const delivered = requestRemoteAppAction(app.remoteAppId, action);
    if (!delivered) {
      void recoverConnection({ forceRestart: true, reason: 'remote-app-start', refreshHosts: true });
      return;
    }
    setPendingAppActions((current) => ({
      ...current,
      [app.remoteAppId]: { action, atUnixMs: Date.now() },
    }));
    setSelectedChat({ appId: app.remoteAppId });
    setMobileMode('chat');
  };

  const startNewTerminalSession = (app: RemoteApp) => {
    const action: RemoteAppActionRequest['action'] = 'newSession';
    const delivered = requestRemoteAppAction(app.remoteAppId, action);
    if (!delivered) {
      void recoverConnection({ forceRestart: true, reason: 'terminal-new-session', refreshHosts: true });
      return;
    }
    setPendingAppActions((current) => ({
      ...current,
      [app.remoteAppId]: { action, atUnixMs: Date.now() },
    }));
    setSelectedChat({ appId: app.remoteAppId });
    setMobileMode('chat');
  };

  const closeTerminalSession = (app: RemoteApp) => {
    const action: RemoteAppActionRequest['action'] = 'closeSession';
    const delivered = requestRemoteAppAction(app.remoteAppId, action);
    if (!delivered) {
      void recoverConnection({ forceRestart: true, reason: 'terminal-close-session', refreshHosts: true });
      return;
    }
    setPendingAppActions((current) => ({
      ...current,
      [app.remoteAppId]: { action, atUnixMs: Date.now() },
    }));
    setSelectedChat({ appId: app.remoteAppId });
    setMobileMode('chat');
  };

  const renameTerminalSession = (app: RemoteApp, target: AgentTargetOption, label: string) => {
    const delivered = renameTarget(app.agentId, target.targetId, label);
    if (!delivered) {
      void recoverConnection({ forceRestart: true, reason: 'terminal-rename-session', refreshHosts: true });
    }
  };

  const selectFocusedTarget = (app: RemoteApp, target: AgentTargetOption) => {
    if (shouldRequestTargetSelection(app, target)) {
      const delivered = selectTarget(app.agentId, target.targetId);
      if (!delivered) return;
    }
    setSelectedChat({ appId: app.remoteAppId, targetId: target.targetId });
    setMobileMode('chat');
  };

  const toggleProject = (groupId: string) => {
    setCollapsedProjects((current) => {
      const next = new Set(current);
      if (next.has(groupId)) {
        next.delete(groupId);
      } else {
        next.add(groupId);
      }
      return next;
    });
  };

  const chooseAppFilter = (filterId: AppFilterId) => {
    setAppFilter(filterId);
    if (filterId === 'all') return;
    const app = appsById.get(filterId);
    if (!app) return;
    if (isDirectRemoteApp(filterId)) {
      setSelectedChat({ appId: app.remoteAppId });
      setMobileMode('chat');
      return;
    }
    const target = defaultTarget(agents[app.agentId]);
    setSelectedChat({ appId: app.remoteAppId, targetId: target?.targetId });
  };

  if (!hello && error) {
    return (
      <WorkspaceState
        title="Reconnecting to your Mac"
        copy={workspaceStateCopy('reconnecting')}
        detail={error}
        action="Retry now"
        onAction={() => void recoverConnection({ forceRestart: true, reason: 'workspace-retry' })}
        tone="error"
      />
    );
  }

  if (!hello) {
    return (
      <WorkspaceState
        title="Connecting"
        copy={workspaceStateCopy('connecting')}
        detail={error ?? undefined}
        action="Retry now"
        onAction={() => void recoverConnection({ forceRestart: true, reason: 'workspace-retry' })}
      />
    );
  }

  if (remoteApps.length === 0) {
    return (
      <WorkspaceState
        title="Syncing apps"
        copy={workspaceStateCopy('syncing-apps')}
        detail="This should only take a moment."
      />
    );
  }

  return (
    <div className="h-full min-h-0 bg-surface-0">
      <div className="md:hidden h-full min-h-0">
        {mobileMode === 'chat' && selectedApp ? (
          <FocusedChat
            app={selectedApp}
            snapshot={selectedSnapshot}
            title={selectedTitle}
            subtitle={selectedSubtitle}
            onBack={() => setMobileMode('list')}
            onStartApp={startRemoteApp}
            onNewTerminalSession={startNewTerminalSession}
            onCloseTerminalSession={closeTerminalSession}
            onRenameTerminalSession={renameTerminalSession}
            onSelectTarget={selectFocusedTarget}
            pendingAction={pendingAppActions[selectedApp.remoteAppId]}
            pendingActionNowMs={pendingActionClockMs}
            hostOnline={relayHostOnline}
            connectionError={error}
            onRetryConnection={() =>
              void recoverConnection({ forceRestart: true, reason: 'remote-app-retry', refreshHosts: true })
            }
          />
        ) : (
          <ProjectHome
            appFilter={appFilter}
            appAvailability={appAvailability}
            groups={visibleGroups}
            collapsedProjects={collapsedProjects}
            searchQuery={searchQuery}
            selectedChat={selectedChat}
            selectedFilterApp={selectedFilterApp}
            onAppFilter={chooseAppFilter}
            onSearch={setSearchQuery}
            onToggleProject={toggleProject}
            onOpenThread={openThread}
            onOpenDefaultChat={openDefaultChat}
            onStartApp={startRemoteApp}
            pendingAppActions={pendingAppActions}
            pendingActionNowMs={pendingActionClockMs}
            hostOnline={relayHostOnline}
            connectionError={error}
            onRetryConnection={() =>
              void recoverConnection({ forceRestart: true, reason: 'remote-app-retry', refreshHosts: true })
            }
            mobile
          />
        )}
      </div>
      <div className="hidden h-full min-h-0 md:grid md:grid-cols-[minmax(320px,420px)_minmax(0,1fr)]">
        <ProjectHome
          appFilter={appFilter}
          appAvailability={appAvailability}
          groups={visibleGroups}
          collapsedProjects={collapsedProjects}
          searchQuery={searchQuery}
          selectedChat={selectedChat}
          selectedFilterApp={selectedFilterApp}
          onAppFilter={chooseAppFilter}
          onSearch={setSearchQuery}
          onToggleProject={toggleProject}
          onOpenThread={openThread}
          onOpenDefaultChat={openDefaultChat}
          onStartApp={startRemoteApp}
          pendingAppActions={pendingAppActions}
          pendingActionNowMs={pendingActionClockMs}
          hostOnline={relayHostOnline}
          connectionError={error}
          onRetryConnection={() =>
            void recoverConnection({ forceRestart: true, reason: 'remote-app-retry', refreshHosts: true })
          }
        />
        <div className="min-h-0 border-l border-[color:var(--gt-border)] p-4">
          {selectedApp ? (
            <FocusedChat
              app={selectedApp}
              snapshot={selectedSnapshot}
              title={selectedTitle}
              subtitle={selectedSubtitle}
              onStartApp={startRemoteApp}
              onNewTerminalSession={startNewTerminalSession}
              onCloseTerminalSession={closeTerminalSession}
              onRenameTerminalSession={renameTerminalSession}
              onSelectTarget={selectFocusedTarget}
              pendingAction={pendingAppActions[selectedApp.remoteAppId]}
              pendingActionNowMs={pendingActionClockMs}
              hostOnline={relayHostOnline}
              connectionError={error}
              onRetryConnection={() =>
                void recoverConnection({ forceRestart: true, reason: 'remote-app-retry', refreshHosts: true })
              }
            />
          ) : (
            <WorkspaceState
              title="Choose a project"
              copy="Select a coding app and thread to continue from your Mac."
            />
          )}
        </div>
      </div>
    </div>
  );
}

function ProjectHome({
  appFilter,
  appAvailability,
  groups,
  collapsedProjects,
  searchQuery,
  selectedChat,
  selectedFilterApp,
  onAppFilter,
  onSearch,
  onToggleProject,
  onOpenThread,
  onOpenDefaultChat,
  onStartApp,
  pendingAppActions,
  pendingActionNowMs,
  hostOnline,
  connectionError,
  onRetryConnection,
  mobile = false,
}: {
  appFilter: AppFilterId;
  appAvailability: Map<string, RemoteApp>;
  groups: ProjectGroup[];
  collapsedProjects: Set<string>;
  searchQuery: string;
  selectedChat: ChatSelection | null;
  selectedFilterApp: RemoteApp | null;
  onAppFilter: (filterId: AppFilterId) => void;
  onSearch: (query: string) => void;
  onToggleProject: (groupId: string) => void;
  onOpenThread: (app: RemoteApp, target?: AgentTargetOption) => void;
  onOpenDefaultChat: () => void;
  onStartApp: (app: RemoteApp) => void;
  pendingAppActions: Record<string, PendingAppAction>;
  pendingActionNowMs: number;
  hostOnline: boolean | null;
  connectionError: string | null;
  onRetryConnection: () => void;
  mobile?: boolean;
}) {
  const projectGroups = groups.filter((group) => group.kind === 'project');
  const chatGroups = groups.filter((group) => group.kind === 'chat');
  const connectionNotice = workspaceConnectionNotice({
    hostOnline,
    connectionError,
    hasContent: groups.length > 0,
  });

  return (
    <section className="relative flex h-full min-h-0 w-full min-w-0 flex-col overflow-hidden bg-surface-0">
      <div className={`${mobile ? 'px-5 pb-2 pt-3' : 'px-6 pb-3 pt-5'} shrink-0 border-b border-[color:var(--gt-border)]/70`}>
        <AppSwitcher
          activeFilter={appFilter}
          appAvailability={appAvailability}
          hostOnline={hostOnline}
          onChoose={onAppFilter}
          compact={mobile}
        />
        <div className={`${mobile ? 'mt-4' : 'mt-5'} flex items-center justify-between gap-4`}>
          <h2 className={`${mobile ? 'text-[28px]' : 'text-xl'} font-semibold`}>
            Workspace
          </h2>
          {!mobile && (
            <button
              type="button"
              onClick={onOpenDefaultChat}
              className="gt-button gt-button-primary px-3 py-2 text-sm"
            >
              <ChatIcon />
              Chat
            </button>
          )}
        </div>
        {!mobile && (
          <label className="mt-4 flex items-center gap-2 rounded-full border border-[color:var(--gt-border)] bg-black/20 px-4 py-2.5 text-sm">
            <SearchIcon />
            <input
              value={searchQuery}
              onChange={(event) => onSearch(event.target.value)}
              placeholder="Search chats"
              className="min-w-0 flex-1 bg-transparent outline-none placeholder:text-white/38"
            />
          </label>
        )}
      </div>

      <div className={`page-scroll min-h-0 flex-1 ${mobile ? 'px-6 pb-32 pt-4' : 'px-6 pb-6 pt-4'}`}>
        {groups.length === 0 ? (
          selectedFilterApp && !isDirectRemoteApp(selectedFilterApp.remoteAppId) ? (
            <StartRemoteAppPanel
              app={selectedFilterApp}
              hostOnline={hostOnline}
              connectionError={connectionError}
              onStart={onStartApp}
              pendingAction={pendingAppActions[selectedFilterApp.remoteAppId]}
              pendingActionNowMs={pendingActionNowMs}
              onRetryConnection={onRetryConnection}
            />
          ) : (
            <ProjectEmptyState searchQuery={searchQuery} selectedFilterApp={selectedFilterApp} />
          )
        ) : (
          <div className="space-y-7">
            {connectionNotice && (
              <WorkspaceConnectionBanner notice={connectionNotice} onRetry={onRetryConnection} />
            )}
            {projectGroups.length > 0 && (
              <TargetSection title="Projects" mobile={mobile}>
                <div className="space-y-1">
                  {projectGroups.map((group) => (
                    <ProjectGroupRow
                      key={group.id}
                      group={group}
                      collapsed={collapsedProjects.has(group.id)}
                      selectedChat={selectedChat}
                      showAppLabel={appFilter === 'all'}
                      onToggle={() => onToggleProject(group.id)}
                      onOpenThread={onOpenThread}
                    />
                  ))}
                </div>
              </TargetSection>
            )}
            {chatGroups.length > 0 && (
              <TargetSection title="Chats" mobile={mobile}>
                <div className="space-y-1">
                  {chatGroups.map((group) => (
                    <StandaloneChatRow
                      key={group.id}
                      group={group}
                      selectedChat={selectedChat}
                      showAppLabel={appFilter === 'all'}
                      onOpenThread={onOpenThread}
                    />
                  ))}
                </div>
              </TargetSection>
            )}
          </div>
        )}
      </div>

      {mobile && (
        <div className="pointer-events-none fixed bottom-0 left-4 z-20 box-border grid w-[calc(min(100vw,390px)-2rem)] grid-cols-[minmax(0,1fr)_5.75rem] items-end gap-2 overflow-hidden pb-[max(env(safe-area-inset-bottom),18px)] pt-10">
          <label className="pointer-events-auto flex min-w-0 items-center gap-3 rounded-full border border-white/10 bg-black/82 px-4 py-4 shadow-2xl backdrop-blur">
            <SearchIcon />
            <input
              value={searchQuery}
              onChange={(event) => onSearch(event.target.value)}
              placeholder="Search workspace"
              className="min-w-0 flex-1 bg-transparent text-lg outline-none placeholder:text-white/44"
            />
          </label>
          <button
            type="button"
            onClick={onOpenDefaultChat}
            className="pointer-events-auto flex min-w-0 items-center justify-center gap-2 rounded-full bg-white px-3 py-4 text-base font-semibold text-black shadow-2xl"
          >
            <ChatIcon />
            <span className="truncate">Chat</span>
          </button>
        </div>
      )}
    </section>
  );
}

function WorkspaceConnectionBanner({
  notice,
  onRetry,
}: {
  notice: WorkspaceConnectionNotice;
  onRetry: () => void;
}) {
  const toneClass =
    notice.tone === 'error'
      ? 'border-err/30 bg-err/10 text-err'
      : 'border-warn/30 bg-warn/10 text-warn';

  return (
    <div className={`rounded-[16px] border px-4 py-3 ${toneClass}`}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-sm font-semibold">{notice.title}</div>
          <div className="mt-1 text-xs leading-relaxed text-white/72">{notice.copy}</div>
          {notice.detail && (
            <div className="mt-1 truncate text-xs leading-relaxed text-white/50" title={notice.detail}>
              {notice.detail}
            </div>
          )}
        </div>
        <button
          type="button"
          onClick={onRetry}
          className="shrink-0 rounded-full bg-white px-3 py-1.5 text-xs font-semibold text-black transition hover:bg-white/88"
        >
          {notice.action}
        </button>
      </div>
    </div>
  );
}

function TargetSection({
  title,
  mobile,
  children,
}: {
  title: string;
  mobile: boolean;
  children: ReactNode;
}) {
  return (
    <section>
      <h3 className={`${mobile ? 'px-0 text-sm' : 'text-xs'} mb-2 font-semibold uppercase tracking-[0.12em] text-white/45`}>
        {title}
      </h3>
      {children}
    </section>
  );
}

function AppSwitcher({
  activeFilter,
  appAvailability,
  hostOnline,
  onChoose,
  compact = false,
}: {
  activeFilter: AppFilterId;
  appAvailability: Map<string, RemoteApp>;
  hostOnline: boolean | null;
  onChoose: (filterId: AppFilterId) => void;
  compact?: boolean;
}) {
  const visibleFilters = appFiltersForAvailableApps(appAvailability);
  return (
    <HorizontalScrollStrip
      ariaLabel="Coding apps"
      contentClassName="flex gap-2 overflow-x-auto pb-1 scrollbar-none"
    >
      {visibleFilters.map((filter) => {
        const app = appAvailability.get(filter.id);
        const active = activeFilter === filter.id;
        const ready = filter.id === 'all' || (hostOnline !== false && appReady(app));
        const label = compact ? filter.shortLabel ?? filter.label : filter.label;
        return (
          <button
            key={filter.id}
            type="button"
            onClick={() => onChoose(filter.id)}
            title={filter.label}
            className={`gt-touch-target flex h-11 shrink-0 items-center gap-2 rounded-full px-3 text-sm font-semibold transition ${
              active
                ? 'bg-white text-black'
                : 'bg-white/12 text-white hover:bg-white/18'
            }`}
          >
            <span
              className={`relative flex h-6 w-6 shrink-0 items-center justify-center rounded-full ${
                active ? 'bg-black/8' : 'bg-black/20'
              }`}
            >
              <AppGlyph appId={filter.id} />
              {filter.id !== 'all' && (
                <span
                  className={`absolute -right-0.5 -top-0.5 h-2.5 w-2.5 rounded-full border ${
                    active ? 'border-white' : 'border-black/45'
                  } ${appStatusDotClass(app, ready, hostOnline)}`}
                />
              )}
            </span>
            <span>{label}</span>
          </button>
        );
      })}
    </HorizontalScrollStrip>
  );
}

export function appFiltersForAvailableApps(appAvailability: Map<string, RemoteApp>): AppFilter[] {
  const projectAppCount = Array.from(appAvailability.values()).filter(isProjectRemoteApp).length;
  return APP_FILTERS.filter((filter) => {
    if (filter.id === 'all') return projectAppCount > 1;
    return appAvailability.has(filter.id);
  });
}

function ProjectGroupRow({
  group,
  collapsed,
  selectedChat,
  showAppLabel,
  onToggle,
  onOpenThread,
}: {
  group: ProjectGroup;
  collapsed: boolean;
  selectedChat: ChatSelection | null;
  showAppLabel: boolean;
  onToggle: () => void;
  onOpenThread: (app: RemoteApp, target?: AgentTargetOption) => void;
}) {
  const canOpenDirectly = group.threads.length === 0;
  const defaultTarget = defaultTargetFromGroup(group);

  return (
    <section className="rounded-[18px] transition hover:bg-white/[0.035]">
      <div className="flex items-center gap-3 py-2.5">
        <button
          type="button"
          onClick={canOpenDirectly ? () => onOpenThread(group.app, defaultTarget) : onToggle}
          className="gt-touch-target flex min-w-0 flex-1 items-center gap-3 rounded-[14px] px-1 py-1.5 text-left transition focus:outline-none focus:ring-2 focus:ring-accent/35"
        >
          <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[12px] bg-white/[0.06] text-white">
            <FolderIcon />
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-[22px] font-semibold leading-tight">{group.label}</span>
            <span className="gt-dim mt-0.5 block truncate text-xs">
              {projectMeta(group, showAppLabel)}
            </span>
          </span>
          {!canOpenDirectly && (
            <span className={`gt-muted transition ${collapsed ? '-rotate-90' : 'rotate-0'}`}>
              <ChevronDownIcon />
            </span>
          )}
        </button>
        <button
          type="button"
          onClick={() => onOpenThread(group.app, defaultTarget)}
          className="gt-touch-target flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-white/70 transition hover:bg-white/8 hover:text-white"
          aria-label={`Open ${group.label}`}
          title={`Open ${group.label}`}
        >
          <ComposeIcon />
        </button>
      </div>
      {!collapsed && group.threads.length > 0 && (
        <div className="ml-[52px] space-y-1 border-l border-white/10 pb-3 pl-3">
          {group.threads.map((thread) => {
            const selected =
              selectedChat?.appId === group.app.remoteAppId && selectedChat.targetId === thread.targetId;
            return (
              <button
                key={thread.targetId}
                type="button"
                onClick={() => onOpenThread(group.app, thread)}
                className={`gt-touch-target block w-full rounded-[14px] px-3 py-2.5 text-left transition ${
                  selected ? 'bg-white/12 text-white' : 'text-white/88 hover:bg-white/[0.06]'
                }`}
              >
                <span className="block truncate text-[17px] font-medium leading-snug">{threadTitle(thread)}</span>
                <span className="gt-dim mt-0.5 block truncate text-xs">
                  {threadMeta(thread)}
                </span>
              </button>
            );
          })}
        </div>
      )}
    </section>
  );
}

function StandaloneChatRow({
  group,
  selectedChat,
  showAppLabel,
  onOpenThread,
}: {
  group: ProjectGroup;
  selectedChat: ChatSelection | null;
  showAppLabel: boolean;
  onOpenThread: (app: RemoteApp, target?: AgentTargetOption) => void;
}) {
  const target = defaultTargetFromGroup(group);
  const selected = Boolean(
    target &&
      selectedChat?.appId === group.app.remoteAppId &&
      selectedChat.targetId === target.targetId,
  );

  return (
    <button
      type="button"
      onClick={() => onOpenThread(group.app, target)}
      className={`gt-touch-target flex w-full items-center gap-3 rounded-[16px] px-2 py-2.5 text-left transition ${
        selected ? 'bg-white/12 text-white' : 'text-white/90 hover:bg-white/[0.06]'
      }`}
    >
      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[12px] bg-white/[0.06] text-white">
        <ChatIcon />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[19px] font-semibold leading-tight">{group.label}</span>
        <span className="gt-dim mt-0.5 block truncate text-xs">
          {projectMeta(group, showAppLabel)}
        </span>
      </span>
    </button>
  );
}

function FocusedChat({
  app,
  snapshot,
  title,
  subtitle,
  onBack,
  onStartApp,
  onNewTerminalSession,
  onCloseTerminalSession,
  onRenameTerminalSession,
  onSelectTarget,
  pendingAction,
  pendingActionNowMs,
  hostOnline,
  connectionError,
  onRetryConnection,
}: {
  app: RemoteApp;
  snapshot?: AgentStateSnapshot;
  title?: string;
  subtitle?: string;
  onBack?: () => void;
  onStartApp: (app: RemoteApp) => void;
  onNewTerminalSession: (app: RemoteApp) => void;
  onCloseTerminalSession: (app: RemoteApp) => void;
  onRenameTerminalSession: (app: RemoteApp, target: AgentTargetOption, label: string) => void;
  onSelectTarget: (app: RemoteApp, target: AgentTargetOption) => void;
  pendingAction?: PendingAppAction;
  pendingActionNowMs: number;
  hostOnline: boolean | null;
  connectionError: string | null;
  onRetryConnection: () => void;
}) {
  const terminalSessionTarget = app.remoteAppId === 'terminal' ? defaultTarget(snapshot) : undefined;
  const terminalSessionLabel =
    terminalSessionTarget?.threadLabel ||
    terminalSessionTarget?.label ||
    selectedTerminalSessionLabel(snapshot) ||
    'Default Terminal';
  const [renamingTerminal, setRenamingTerminal] = useState(false);
  const [renameDraft, setRenameDraft] = useState(terminalSessionLabel);

  useEffect(() => {
    if (!renamingTerminal) {
      setRenameDraft(terminalSessionLabel);
    }
  }, [renamingTerminal, terminalSessionLabel]);

  const submitTerminalRename = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!terminalSessionTarget) return;
    const nextLabel = renameDraft.trim();
    if (!nextLabel) return;
    onRenameTerminalSession(app, terminalSessionTarget, nextLabel);
    setRenamingTerminal(false);
  };

  if (app.remoteAppId === 'screen') {
    return (
      <ScreenRemotePanel
        app={app}
        snapshot={snapshot}
        onBack={onBack}
        hostOnline={hostOnline}
        connectionError={connectionError}
        onRetryConnection={onRetryConnection}
      />
    );
  }

  if (hostOnline === false && !snapshot) {
    return (
      <WorkspaceState
        title="Mac offline"
        copy={`Reconnect before starting ${app.displayName}. Your workspace is still available.`}
        detail={connectionError ?? undefined}
        action="Retry connection"
        onAction={onRetryConnection}
        tone="error"
      />
    );
  }

  if (shouldShowStartRemoteAppPanel(app, snapshot)) {
    if (pendingAction) {
      const timedOut = remoteAppActionTimedOut(pendingAction, pendingActionNowMs);
      const state = remoteAppStartState({
        appName: app.displayName,
        available: app.available,
        status: app.status,
        offline: false,
        pending: !timedOut,
        timedOut,
        fallbackStatusDetail: app.statusDetail || connectionError || '',
      });
      return (
        <WorkspaceState
          title={state.title}
          copy={state.copy}
          detail={state.detail}
          action={state.action}
          onAction={() => onStartApp(app)}
          tone={state.tone}
        />
      );
    }
    const state = remoteAppStartState({
      appName: app.displayName,
      available: app.available,
      status: app.status,
      offline: false,
      pending: false,
      timedOut: false,
      fallbackStatusDetail: app.statusDetail,
    });

    return (
      <WorkspaceState
        title={state.title}
        copy={state.copy}
        detail={state.detail}
        action={state.action}
        onAction={() => onStartApp(app)}
        tone={state.tone}
      />
    );
  }

  if (directCliStartTimedOut(app, snapshot, pendingActionNowMs)) {
    const state = remoteAppStartState({
      appName: app.displayName,
      available: app.available,
      status: app.status,
      offline: false,
      pending: false,
      timedOut: true,
      fallbackStatusDetail: app.statusDetail || snapshot?.statusDetail || connectionError || '',
    });
    return (
      <WorkspaceState
        title={state.title}
        copy={state.copy}
        detail={state.detail}
        action={state.action}
        onAction={() => onStartApp(app)}
        tone={state.tone}
      />
    );
  }

  const showTerminalSessionAction = app.remoteAppId === 'terminal' && Boolean(snapshot) && appReady(app);
  const pendingSessionAction = pendingAction &&
    (pendingAction.action === 'newSession' || pendingAction.action === 'closeSession') &&
    !remoteAppActionTimedOut(pendingAction, pendingActionNowMs)
    ? pendingAction
    : undefined;
  const newTerminalSessionPending = pendingSessionAction?.action === 'newSession';
  const terminalHeaderAction = showTerminalSessionAction ? (
    <div className="flex flex-wrap items-center gap-2">
      {renamingTerminal && terminalSessionTarget ? (
        <form onSubmit={submitTerminalRename} className="flex max-w-full items-center gap-2">
          <input
            value={renameDraft}
            onChange={(event) => setRenameDraft(event.target.value)}
            maxLength={48}
            autoFocus
            aria-label="Terminal session name"
            className="gt-composer-input gt-touch-target h-11 min-w-0 max-w-[12rem] rounded-full border border-white/12 bg-black/30 px-3 text-sm font-semibold text-white outline-none ring-0 placeholder:text-white/35 focus:border-blue-400/70"
          />
          <button
            type="submit"
            disabled={!renameDraft.trim()}
            className="gt-touch-target rounded-full bg-white/10 px-3 py-2 text-xs font-semibold text-white transition hover:bg-white/16 disabled:cursor-not-allowed disabled:opacity-45"
          >
            Save
          </button>
          <button
            type="button"
            onClick={() => {
              setRenameDraft(terminalSessionLabel);
              setRenamingTerminal(false);
            }}
            className="gt-touch-target rounded-full border border-white/10 px-3 py-2 text-xs font-semibold text-white/70 transition hover:bg-white/10"
          >
            Cancel
          </button>
        </form>
      ) : (
        <>
          <button
            type="button"
            onClick={() => onNewTerminalSession(app)}
            disabled={Boolean(pendingSessionAction)}
            aria-label="Start a new Terminal session"
            title="Start a new Terminal session"
            className={`gt-touch-target rounded-full border px-3 py-2 text-xs font-semibold transition disabled:cursor-wait disabled:opacity-60 ${
              newTerminalSessionPending
                ? 'border-blue-400/35 bg-blue-500/15 text-blue-100'
                : 'border-white/10 text-white/80 hover:bg-white/10'
            }`}
          >
            {terminalSessionActionCopy('newSession', pendingSessionAction)}
          </button>
          {terminalSessionTarget && (
            <button
              type="button"
              onClick={() => setRenamingTerminal(true)}
              disabled={Boolean(pendingSessionAction)}
              aria-label="Rename Terminal session"
              title="Rename Terminal session"
              className="gt-touch-target rounded-full border border-white/10 px-3 py-2 text-xs font-semibold text-white/80 transition hover:bg-white/10 disabled:cursor-wait disabled:opacity-60"
            >
              Rename
            </button>
          )}
          <button
            type="button"
            onClick={() => onCloseTerminalSession(app)}
            disabled={Boolean(pendingSessionAction)}
            aria-label="Close Terminal session"
            title="Close Terminal session"
            className="gt-touch-target rounded-full border border-white/10 px-3 py-2 text-xs font-semibold text-white/80 transition hover:bg-white/10 disabled:cursor-wait disabled:opacity-60"
          >
            {terminalSessionActionCopy('closeSession', pendingSessionAction)}
          </button>
        </>
      )}
    </div>
  ) : undefined;

  return (
    <AgentCard
      app={app}
      snapshot={snapshot}
      showTargetSwitcher={shouldShowCommandTargetSwitcher(app)}
      onBack={onBack}
      titleOverride={title}
      subtitleOverride={subtitle}
      hostOnline={hostOnline}
      connectionError={connectionError}
      headerAction={terminalHeaderAction}
      onSelectTarget={(target) => onSelectTarget(app, target)}
      compactChrome={Boolean(onBack)}
    />
  );
}

function WorkspaceState({
  title,
  copy,
  detail,
  action,
  onAction,
  tone = 'neutral',
}: {
  title: string;
  copy: string;
  detail?: string;
  action?: string;
  onAction?: () => void;
  tone?: 'neutral' | 'warning' | 'error';
}) {
  const toneClass =
    tone === 'error'
      ? 'border-err/35 bg-err/10 text-err'
      : tone === 'warning'
        ? 'border-warn/35 bg-warn/10 text-warn'
        : 'border-accent/25 bg-accent/8 text-accent';

  return (
    <div className="flex h-full safe-pad-x safe-pad-bottom items-center justify-center bg-surface-0 p-6">
      <div className="gt-panel max-w-md px-6 py-7 text-center">
        <div className={`mx-auto flex h-12 w-12 items-center justify-center rounded-[14px] border ${toneClass}`}>
          <StateIcon tone={tone} />
        </div>
        <h2 className="mt-5 text-2xl font-semibold">{title}</h2>
        <p className="gt-muted mt-3 text-sm leading-relaxed">{copy}</p>
        {detail && <p className="mt-4 text-sm leading-relaxed text-err">{detail}</p>}
        {action && onAction && (
          <button
            type="button"
            onClick={onAction}
            className="gt-button gt-button-primary mt-5 px-5 py-2.5"
          >
            {action}
          </button>
        )}
      </div>
    </div>
  );
}

function ProjectEmptyState({
  searchQuery,
  selectedFilterApp,
}: {
  searchQuery: string;
  selectedFilterApp: RemoteApp | null;
}) {
  const directFeature = selectedFilterApp && isDirectRemoteApp(selectedFilterApp.remoteAppId);
  const title = projectEmptyStateTitle({
    searchQuery,
    directFeatureName: directFeature ? selectedFilterApp.displayName : undefined,
  });
  const copy = projectEmptyStateCopy({ searchQuery, directFeature: Boolean(directFeature) });
  return (
    <div className="flex min-h-[220px] items-center justify-center py-10 text-center">
      <div className="max-w-xs">
        <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-[14px] border border-[color:var(--gt-border)] bg-surface-2 gt-muted">
          {directFeature ? <AppGlyph appId={selectedFilterApp.remoteAppId} /> : <FolderIcon />}
        </div>
        <div className="mt-4 text-base font-semibold">{title}</div>
        <div className="gt-muted mt-2 text-sm leading-relaxed">{copy}</div>
      </div>
    </div>
  );
}

function StartRemoteAppPanel({
  app,
  hostOnline,
  connectionError,
  onStart,
  pendingAction,
  pendingActionNowMs,
  onRetryConnection,
}: {
  app: RemoteApp;
  hostOnline: boolean | null;
  connectionError: string | null;
  onStart: (app: RemoteApp) => void;
  pendingAction?: PendingAppAction;
  pendingActionNowMs: number;
  onRetryConnection: () => void;
}) {
  const offline = hostOnline === false;
  const pendingTimedOut = pendingAction ? remoteAppActionTimedOut(pendingAction, pendingActionNowMs) : false;
  const state = remoteAppStartState({
    appName: app.displayName,
    available: app.available,
    status: app.status,
    offline,
    pending: Boolean(pendingAction) && !pendingTimedOut,
    timedOut: pendingTimedOut,
    fallbackStatusDetail: app.statusDetail || connectionError || '',
  });

  return (
    <div className="flex min-h-[240px] items-center justify-center py-10 text-center">
      <div className="max-w-sm">
        <div className={`mx-auto flex h-12 w-12 items-center justify-center rounded-[14px] border ${
          state.tone === 'error'
            ? 'border-err/35 bg-err/10 text-err'
            : state.tone === 'warning'
              ? 'border-warn/35 bg-warn/10 text-warn'
              : 'border-accent/25 bg-accent/8 text-accent'
        }`}>
          {state.tone === 'error' ? <StateIcon tone="error" /> : <AppGlyph appId={app.remoteAppId} />}
        </div>
        <div className="mt-4 text-base font-semibold">{state.title}</div>
        <div className="gt-muted mt-2 text-sm leading-relaxed">{state.copy}</div>
        {state.detail && <div className="mt-3 text-sm leading-relaxed text-err">{state.detail}</div>}
        <button
          type="button"
          onClick={offline ? onRetryConnection : () => onStart(app)}
          className="gt-button gt-button-primary mt-5 px-5 py-2.5"
        >
          {state.action}
        </button>
      </div>
    </div>
  );
}

export function workspaceStateCopy(state: 'connecting' | 'reconnecting' | 'syncing-apps'): string {
  switch (state) {
    case 'connecting':
      return 'Loading your Mac workspace.';
    case 'reconnecting':
      return 'Opening a fresh connection.';
    case 'syncing-apps':
      return 'Loading apps from your Mac.';
  }
}

export function workspaceConnectionNotice({
  hostOnline,
  connectionError,
  hasContent,
}: {
  hostOnline: boolean | null;
  connectionError: string | null;
  hasContent: boolean;
}): WorkspaceConnectionNotice | null {
  if (!hasContent) return null;

  const detail = connectionError?.trim() || undefined;
  if (hostOnline === false) {
    return {
      title: 'Mac offline',
      copy: 'Projects and chats stay visible.',
      detail,
      action: 'Retry',
      tone: 'error',
    };
  }

  if (connectionError) {
    return {
      title: 'Reconnecting',
      copy: 'Projects and chats stay visible.',
      detail,
      action: 'Retry',
      tone: 'warning',
    };
  }

  return null;
}

export function projectEmptyStateCopy({
  searchQuery,
  directFeature,
}: {
  searchQuery: string;
  directFeature: boolean;
}): string {
  if (directFeature) return 'Choose it from the app switcher.';
  if (searchQuery.trim()) return 'Try another project, chat, or app.';
  return 'Open a coding app on your Mac.';
}

export function projectEmptyStateTitle({
  searchQuery,
  directFeatureName,
}: {
  searchQuery: string;
  directFeatureName?: string;
}): string {
  if (directFeatureName) return `${directFeatureName} opens directly`;
  if (searchQuery.trim()) return 'No results';
  return 'No projects yet';
}

export function startRemoteAppCopy({
  appName,
  available,
  offline,
  pending,
  fallbackStatusDetail,
}: {
  appName: string;
  available: boolean;
  offline: boolean;
  pending: boolean;
  fallbackStatusDetail: string | undefined;
}): string {
  if (pending) return 'Waiting for your Mac.';
  if (offline) return `Reconnect to start ${appName}.`;
  if (appName === 'Terminal' && available) return 'Open Terminal on this Mac.';
  if (available) return `Start ${appName} on this Mac.`;
  return fallbackStatusDetail?.trim() || `Open ${appName} on this Mac.`;
}

export function remoteAppStartState({
  appName,
  available,
  status,
  offline,
  pending,
  timedOut = false,
  fallbackStatusDetail,
}: {
  appName: string;
  available: boolean;
  status: AgentStatus;
  offline: boolean;
  pending: boolean;
  timedOut?: boolean;
  fallbackStatusDetail: string | undefined;
}): RemoteAppStartState {
  const detail = fallbackStatusDetail?.trim() || undefined;

  if (timedOut) {
    return {
      title: `${appName} did not respond`,
      copy: 'Try again or open it on the Mac.',
      detail,
      action: 'Retry',
      tone: 'error',
    };
  }

  if (pending) {
    return {
      title: `Opening ${appName}`,
      copy: startRemoteAppCopy({ appName, available, offline, pending: true, fallbackStatusDetail }),
      detail,
      action: 'Retry',
      tone: 'neutral',
    };
  }

  if (offline) {
    return {
      title: 'Mac offline',
      copy: startRemoteAppCopy({ appName, available, offline: true, pending: false, fallbackStatusDetail }),
      detail,
      action: 'Retry connection',
      tone: 'error',
    };
  }

  if (available && processExitedDetail(detail)) {
    return {
      title: `${appName} stopped`,
      copy: startRemoteAppCopy({ appName, available, offline: false, pending: false, fallbackStatusDetail }),
      action: appName === 'Terminal' ? 'Open Terminal' : 'Start',
      tone: 'neutral',
    };
  }

  if (status === AgentStatus.Error) {
    return {
      title: `${appName} could not open`,
      copy: 'Try again or open it on the Mac.',
      detail,
      action: 'Retry',
      tone: 'error',
    };
  }

  if (available) {
    return {
      title: `${appName} is ready`,
      copy: startRemoteAppCopy({ appName, available, offline: false, pending: false, fallbackStatusDetail }),
      action: appName === 'Terminal' ? 'Open Terminal' : 'Start',
      tone: 'neutral',
    };
  }

  return {
    title: `${appName} is not ready`,
    copy: startRemoteAppCopy({ appName, available, offline: false, pending: false, fallbackStatusDetail }),
    detail,
    action: 'Open on Mac',
    tone: 'warning',
  };
}

export function remoteAppActionTimedOut(pending: PendingAppAction, nowUnixMs: number): boolean {
  return nowUnixMs - pending.atUnixMs >= REMOTE_APP_ACTION_TIMEOUT_MS;
}

export function terminalSessionActionCopy(
  action: Extract<RemoteAppActionRequest['action'], 'newSession' | 'closeSession'>,
  pending?: PendingAppAction,
): string {
  if (pending?.action === action) {
    return action === 'newSession' ? 'Starting' : 'Closing';
  }
  return action === 'newSession' ? 'New' : 'Close';
}

export function shouldShowCommandTargetSwitcher(app: RemoteApp): boolean {
  return (
    app.remoteAppId === 'terminal' ||
    app.remoteAppId === 'opencode' ||
    app.remoteAppId === 'cursor' ||
    app.remoteAppId === 'cursor-agent' ||
    app.remoteAppId === 'codex' ||
    app.remoteAppId === 'claude-desktop' ||
    app.remoteAppId === 'claude-code'
  );
}

export function shouldRequestTargetSelection(
  app: Pick<RemoteApp, 'remoteAppId'>,
  target: Pick<AgentTargetOption, 'selected' | 'isActive'>,
): boolean {
  return (
    !target.selected ||
    ((app.remoteAppId === 'codex' || app.remoteAppId === 'claude-desktop' || app.remoteAppId === 'cursor') &&
      target.isActive === false)
  );
}

export function workspaceInitialAppIdFromSearch(search: string): AppFilterId | null {
  const params = new URLSearchParams(search);
  const value = params.get('app')?.trim().toLowerCase() as AppFilterId | undefined;
  if (!value || !APP_FILTERS.some((filter) => filter.id === value) || value === 'all') return null;
  return value;
}

export function shouldResetAppFilter(
  appFilter: AppFilterId,
  remoteAppCount: number,
  appAvailability: Map<string, RemoteApp>,
): boolean {
  if (appFilter === 'all') return false;
  if (remoteAppCount === 0) return false;
  return !appAvailability.has(appFilter);
}

function currentWorkspaceInitialAppId(): AppFilterId | null {
  if (typeof window === 'undefined') return null;
  return workspaceInitialAppIdFromSearch(window.location.search);
}

function latestSnapshotUnixMs(snapshot: AgentStateSnapshot): number {
  const messageTimes = (snapshot.recentMessages ?? [])
    .map((message) => message.atUnixMs ?? 0)
    .filter((at) => at > 0);
  return Math.max(snapshot.lastActivityUnixMs ?? 0, 0, ...messageTimes);
}

export function buildProjectGroups(app: RemoteApp, snapshot?: AgentStateSnapshot): ProjectGroup[] {
  if (isDirectRemoteApp(app.remoteAppId)) {
    return [];
  }

  const targets = snapshot?.availableTargets ?? [];
  if (targets.length === 0) {
    if (!snapshot || app.available === false || app.status === AgentStatus.Disconnected) {
      return [];
    }

    return [
      {
        id: `${app.remoteAppId}:current`,
        app,
        snapshot,
        kind: 'chat',
        label: snapshot?.agentLabel || app.displayName,
        path: app.statusDetail || snapshot?.statusDetail || 'Current session',
        threads: [],
        selected: true,
        lastActivityUnixMs: snapshot?.lastActivityUnixMs,
      },
    ];
  }

  const grouped = new Map<string, ProjectGroup>();
  for (const target of targets) {
    const hasProject = Boolean(target.projectId || target.projectLabel || target.projectPath);
    const isProjectTarget = target.targetKind === 'project';
    const projectId = hasProject
      ? target.projectId || target.projectPath || target.projectLabel || target.subtitle || target.targetId
      : target.threadId || target.targetId;
    const key = `${app.remoteAppId}:${projectId}`;
    const existing = grouped.get(key);
    const activity = target.lastActivityUnixMs;

    if (existing) {
      if (isProjectTarget) {
        existing.directTarget = target;
      } else {
        existing.threads.push(target);
      }
      existing.selected = existing.selected || Boolean(target.selected || target.isActive);
      existing.lastActivityUnixMs = maxActivity(existing.lastActivityUnixMs, activity);
      continue;
    }

    grouped.set(key, {
      id: key,
      kind: hasProject ? 'project' : 'chat',
      app,
      snapshot,
      label: hasProject
        ? target.projectLabel || folderName(target.projectPath) || target.label || app.displayName
        : threadTitle(target),
      path: hasProject ? target.projectPath || target.subtitle || '' : target.subtitle || app.displayName,
      threads: isProjectTarget ? [] : [target],
      directTarget: isProjectTarget ? target : undefined,
      selected: Boolean(target.selected || target.isActive),
      lastActivityUnixMs: activity ?? snapshot?.lastActivityUnixMs,
    });
  }

  return Array.from(grouped.values())
    .map((group) => ({
      ...group,
      threads: group.threads.slice().sort(compareTargets),
    }))
    .sort(compareGroups);
}

function filterProjectGroup(group: ProjectGroup, query: string): ProjectGroup | null {
  const projectMatches =
    normalizeSearch(group.label).includes(query) ||
    normalizeSearch(group.path).includes(query) ||
    normalizeSearch(group.app.displayName).includes(query);
  const matchingThreads = group.threads.filter(
    (thread) =>
      normalizeSearch(threadTitle(thread)).includes(query) ||
      normalizeSearch(thread.subtitle).includes(query) ||
      normalizeSearch(thread.projectPath ?? '').includes(query),
  );

  if (projectMatches) return group;
  if (matchingThreads.length === 0) return null;
  return {
    ...group,
    threads: matchingThreads,
  };
}

function defaultSelection(apps: RemoteApp[], agents: Record<string, AgentStateSnapshot>): ChatSelection | null {
  for (const app of apps) {
    const target = defaultTarget(agents[app.agentId]);
    if (target) return { appId: app.remoteAppId, targetId: target.targetId };
  }
  const first = apps[0];
  return first ? { appId: first.remoteAppId } : null;
}

function defaultTarget(snapshot?: AgentStateSnapshot): AgentTargetOption | undefined {
  const targets = snapshot?.availableTargets ?? [];
  return targets.find((target) => target.selected || target.isActive) ?? targets[0];
}

function defaultTargetFromGroup(group: ProjectGroup): AgentTargetOption | undefined {
  const selectedThread = group.threads.find((target) => target.selected || target.isActive);
  const selectedProject = group.directTarget?.selected || group.directTarget?.isActive ? group.directTarget : undefined;
  return selectedThread ?? selectedProject ?? group.directTarget ?? group.threads[0];
}

function compareGroups(a: ProjectGroup, b: ProjectGroup): number {
  if (a.selected !== b.selected) return a.selected ? -1 : 1;
  return (b.lastActivityUnixMs ?? 0) - (a.lastActivityUnixMs ?? 0) || a.label.localeCompare(b.label);
}

function compareTargets(a: AgentTargetOption, b: AgentTargetOption): number {
  const aSelected = Boolean(a.selected || a.isActive);
  const bSelected = Boolean(b.selected || b.isActive);
  if (aSelected !== bSelected) return aSelected ? -1 : 1;
  return (b.lastActivityUnixMs ?? 0) - (a.lastActivityUnixMs ?? 0) || threadTitle(a).localeCompare(threadTitle(b));
}

function maxActivity(current?: number, next?: number): number | undefined {
  if (!current) return next;
  if (!next) return current;
  return Math.max(current, next);
}

export function appReady(app: RemoteApp | undefined): boolean {
  return Boolean(
    app?.enabled &&
      app.available &&
      app.status !== AgentStatus.Disconnected &&
      app.status !== AgentStatus.Error &&
      !processExitedDetail(app.statusDetail),
  );
}

export function shouldShowStartRemoteAppPanel(
  app: RemoteApp,
  snapshot?: AgentStateSnapshot,
): boolean {
  if (isDirectRemoteApp(app.remoteAppId) && app.remoteAppId !== 'screen') {
    return !snapshot || !appReady(app);
  }
  return !appReady(app) && (!snapshot || !app.enabled);
}

export function directCliStartTimedOut(
  app: RemoteApp,
  snapshot: AgentStateSnapshot | undefined,
  nowUnixMs: number,
): boolean {
  if (!isDirectCliApp(app.remoteAppId)) return false;
  if (app.status !== AgentStatus.Working) return false;
  if (!/^starting\b/i.test((app.statusDetail || snapshot?.statusDetail || '').trim())) return false;
  const latest = snapshot ? latestSnapshotUnixMs(snapshot) : 0;
  if (latest <= 0) return false;
  return nowUnixMs - latest >= REMOTE_APP_ACTION_TIMEOUT_MS;
}

function isDirectCliApp(remoteAppId: string): boolean {
  return (
    remoteAppId === 'codex-cli' ||
    remoteAppId === 'cursor-agent' ||
    remoteAppId === 'claude-code' ||
    remoteAppId === 'gemini-cli' ||
    remoteAppId === 'opencode'
  );
}

function processExitedDetail(detail: string | null | undefined): boolean {
  return /^process exited\b/i.test(detail?.trim() ?? '');
}

export function appStatusDotClass(
  app: RemoteApp | undefined,
  ready: boolean,
  hostOnline: boolean | null = true,
): string {
  if (hostOnline === false) return 'bg-err';
  if (app?.status === AgentStatus.Error) return 'bg-err';
  return ready ? 'bg-ok' : 'bg-white/28';
}

function projectMeta(group: ProjectGroup, showAppLabel: boolean): string {
  const parts = [
    showAppLabel ? group.app.displayName : '',
    group.path,
    group.lastActivityUnixMs ? formatActivity(group.lastActivityUnixMs) : '',
  ].filter(Boolean);
  return parts.join(' · ');
}

function threadTitle(thread: AgentTargetOption): string {
  return thread.threadLabel || thread.label || 'Current session';
}

function threadMeta(thread: AgentTargetOption): string {
  const parts = [
    thread.subtitle,
    thread.lastActivityUnixMs ? formatActivity(thread.lastActivityUnixMs) : '',
  ].filter(Boolean);
  return parts.join(' · ');
}

function formatActivity(unixMs: number): string {
  const date = new Date(unixMs);
  const now = new Date();
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();

  if (sameDay) {
    return new Intl.DateTimeFormat(undefined, {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    }).format(date);
  }

  return new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
  }).format(date);
}

function folderName(path: string | undefined): string {
  if (!path) return '';
  return path.split('/').filter(Boolean).at(-1) ?? path;
}

function normalizeSearch(value: string): string {
  return value.trim().toLowerCase();
}

function AppGlyph({ appId }: { appId: string }) {
  if (appId === 'all') return <AllAppsGlyph />;
  if (appId === 'screen') return <ScreenGlyph />;
  if (appId === 'cursor') return <CursorGlyph />;
  if (appId === 'claude-desktop' || appId === 'claude-code') return <ClaudeGlyph />;
  if (appId === 'gemini-cli') return <GeminiGlyph />;
  if (appId === 'opencode') return <OpenCodeGlyph />;
  if (appId === 'codex-cli' || appId === 'cursor-agent' || appId === 'terminal') return <TerminalGlyph />;
  return <CodexGlyph />;
}

function ScreenGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <rect x="3.5" y="4.8" width="13" height="8.8" rx="1.7" />
      <path d="M8.2 16h3.6M10 13.6V16" strokeLinecap="round" />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z" />
    </svg>
  );
}

function ComposeIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M12 20h8" />
      <path d="m16.5 3.5 4 4L8 20l-5 1 1-5Z" />
    </svg>
  );
}

function ChatIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="m16.5 3.5 4 4L8 20l-5 1 1-5Z" />
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className="h-5 w-5 shrink-0 text-white/52" fill="none" stroke="currentColor" strokeWidth="2">
      <circle cx="11" cy="11" r="7" />
      <path d="m16.5 16.5 4 4" />
    </svg>
  );
}

function ChevronDownIcon() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="m5 7.5 5 5 5-5" />
    </svg>
  );
}

function StateIcon({ tone }: { tone: 'neutral' | 'warning' | 'error' }) {
  if (tone === 'error') {
    return <span className="font-mono text-lg">[]</span>;
  }
  if (tone === 'warning') {
    return <span className="font-mono text-lg">!</span>;
  }
  return <span className="h-5 w-5 rounded-full border-2 border-current/30 border-t-current animate-spin" />;
}

function AllAppsGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="M4.5 5.2h4.1v4.1H4.5zM11.4 5.2h4.1v4.1h-4.1zM4.5 12h4.1v2.8H4.5zM11.4 12h4.1v2.8h-4.1z" />
    </svg>
  );
}

function CodexGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="M5 5.5h10a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 15 14.5H5A1.5 1.5 0 0 1 3.5 13V7A1.5 1.5 0 0 1 5 5.5Z" />
      <path d="M7.2 8.2 5.5 10l1.7 1.8M12.8 8.2l1.7 1.8-1.7 1.8M9.4 12.3l1.2-4.6" />
    </svg>
  );
}

function CursorGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="m4.5 3.5 11 6.2-4.7 1.1-2.3 4.4Z" />
    </svg>
  );
}

function ClaudeGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="M10 3.2v13.6M3.2 10h13.6M5.2 5.2l9.6 9.6M14.8 5.2l-9.6 9.6" />
    </svg>
  );
}

function OpenCodeGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="M7.5 5.2 4.2 10l3.3 4.8M12.5 5.2l3.3 4.8-3.3 4.8" />
    </svg>
  );
}

function GeminiGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="M10 3.2 11.8 8l5 2-5 2L10 16.8 8.2 12l-5-2 5-2Z" />
      <path d="M15.2 3.8v3.1M13.7 5.4h3.1" strokeLinecap="round" />
    </svg>
  );
}

function TerminalGlyph() {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.9">
      <path d="M3.5 5.5h13v9h-13z" />
      <path d="m6 8 2 2-2 2M9.5 12h3.5" />
    </svg>
  );
}

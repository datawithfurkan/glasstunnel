/**
 * Glasstunnel protocol - hand-written TypeScript shim.
 *
 * The source of truth for the protocol is `packages/protocol/schema/glasstunnel.proto`.
 * Run `pnpm --filter=@glasstunnel/protocol gen` to regenerate real protobuf bindings
 * once ts-proto is installed. In the meantime these hand-written types keep the rest
 * of the repo buildable and match the proto schema one-to-one.
 */

export const PROTOCOL_VERSION = '0.2.3';

export type DeviceId = string;
export type AgentId = string;

export enum AgentStatus {
  Unspecified = 0,
  Idle = 1,
  Working = 2,
  WaitingInput = 3,
  AwaitingApproval = 4,
  Done = 5,
  Error = 6,
  Disconnected = 7,
}

export enum AdapterKind {
  Unspecified = 0,
  Mirror = 1,
  Cursor = 2,
  ClaudeCode = 3,
  CodexCli = 4,
  OpenCode = 5,
  Terminal = 6,
  GeminiCli = 7,
  CursorAgent = 8,
  ClaudeDesktop = 9,
}

export enum ChatRole {
  Unspecified = 0,
  User = 1,
  Assistant = 2,
  System = 3,
  Tool = 4,
}

export enum QuickReplyKind {
  Unspecified = 0,
  Continue = 1,
  TryAgain = 2,
  Explain = 3,
  Commit = 4,
  Stop = 5,
  Approve = 6,
  Reject = 7,
}

export enum GridShape {
  Unspecified = 0,
  OneByOne = 1,
  TwoByOne = 2,
  OneByTwo = 3,
  TwoByTwo = 4,
}

export interface GridCellPosition {
  row: number;
  col: number;
  rowSpan: number;
  colSpan: number;
}

export interface GridCell {
  position: GridCellPosition;
  agentId: AgentId;
  windowTitle: string;
  applicationBundleId: string;
  adapterKind: AdapterKind;
  videoEnabled: boolean;
}

export interface GridLayout {
  shape: GridShape;
  cells: GridCell[];
}

export interface RemoteApp {
  remoteAppId: string;
  displayName: string;
  adapterKind: AdapterKind;
  agentId: AgentId;
  enabled: boolean;
  available: boolean;
  status: AgentStatus;
  statusDetail: string;
  windowTitle: string;
  applicationBundleId: string;
  hasVideo: boolean;
}

export interface PendingToolCall {
  toolName: string;
  toolCallId: string;
  summary: string;
}

/** What a transcript record is, for rendering transcripts for reading. */
export enum ChatMessageKind {
  Unspecified = 0,
  Text = 1,
  ToolCall = 2,
  ToolResult = 3,
  Event = 4,
}

export interface AgentChatMessage {
  messageId: string;
  role: ChatRole;
  text: string;
  atUnixMs: number;
  redacted: boolean;
  pendingToolCalls: PendingToolCall[];
  /** Pattern names (not matched text) for any redactions applied to `text`. */
  redactionReasons?: string[];
  /** Structure for reading transcripts; absent from Macs that predate it. */
  kind?: ChatMessageKind;
  toolName?: string;
  /** Pairs a tool result with its call. */
  toolCallId?: string;
  /** One-line label derived on the Mac (a command, a file name, a pattern). */
  title?: string;
  outputLineCount?: number;
  durationMs?: number;
  isError?: boolean;
  /** `text` is a preview; the full text is available through a MessageDetailRequest. */
  truncated?: boolean;
}

/** Phone → Mac: the full text of a message whose snapshot copy was a preview. */
export interface MessageDetailRequest {
  agentId: AgentId;
  messageId: string;
}

/** Mac → phone: the full text of one message, redacted like a snapshot. */
export interface MessageDetail {
  agentId: AgentId;
  messageId: string;
  text: string;
  redacted: boolean;
  redactionReasons?: string[];
  /** Still cut at the Mac's own cap. */
  truncated: boolean;
}

export interface AgentTargetOption {
  targetId: string;
  label: string;
  subtitle: string;
  selected: boolean;
  projectId?: string;
  projectLabel?: string;
  projectPath?: string;
  threadId?: string;
  threadLabel?: string;
  targetKind?: 'project' | 'thread' | 'session';
  lastActivityUnixMs?: number;
  isActive?: boolean;
  supportsNewThread?: boolean;
}

export interface AgentRuntimeOption {
  id: string;
  label: string;
  description?: string;
}

export interface AgentRuntimeControls {
  modelId?: string;
  modelLabel?: string;
  modelOptions: AgentRuntimeOption[];
  reasoningEffort?: string;
  reasoningEffortLabel?: string;
  reasoningEffortOptions: AgentRuntimeOption[];
  fastMode?: boolean;
  supportsModelSelection: boolean;
  supportsReasoningEffort: boolean;
  supportsFastMode: boolean;
  editable: boolean;
  appliesOn: 'immediate' | 'next_start' | 'managed_locally';
  note?: string;
}

export interface AgentInputRequestChoice {
  choiceId: string;
  label: string;
  description: string;
  recommended: boolean;
}

export interface AgentInputRequestQuestion {
  questionId: string;
  header: string;
  question: string;
  choices: AgentInputRequestChoice[];
}

export interface AgentInputRequest {
  requestId: string;
  questions: AgentInputRequestQuestion[];
}

export interface AgentInputRequestAnswer {
  questionId: string;
  choiceIds: string[];
}

export interface AgentInputRequestResponse {
  agentId: AgentId;
  requestId: string;
  answers: AgentInputRequestAnswer[];
}

export interface AgentStateSnapshot {
  agentId: AgentId;
  agentLabel: string;
  adapterKind: AdapterKind;
  status: AgentStatus;
  statusDetail: string;
  recentMessages: AgentChatMessage[];
  lastActivityUnixMs: number;
  position: GridCellPosition;
  hasVideoTrack: boolean;
  availableTargets?: AgentTargetOption[];
  remoteAppId?: string;
  pendingInputRequest?: AgentInputRequest;
  runtimeControls?: AgentRuntimeControls;
}

export interface Hello {
  hostVersion: string;
  hostOsVersion: string;
  hostDeviceLabel: string;
  supportedAdapters: string[];
  currentLayout: GridLayout;
  remoteApps?: RemoteApp[];
  protocolVersion: number;
}

/** Wire protocol version. Even = stable, odd = development. */
export const CURRENT_PROTOCOL_VERSION = 4;

export interface UserInput {
  agentId: AgentId;
  text: string;
  submitOnSend: boolean;
}

export type ScreenPointerAction = 'click' | 'doubleClick';

export interface ScreenPointerInput {
  agentId: AgentId;
  x: number;
  y: number;
  action: ScreenPointerAction;
}

export interface ImageAttachmentInput {
  agentId: AgentId;
  text: string;
  filename: string;
  mimeType: string;
  bytes: Uint8Array;
  submitOnSend: boolean;
}

export interface ImageAttachmentChunk {
  transferId: string;
  agentId: AgentId;
  text: string;
  filename: string;
  mimeType: string;
  totalBytes: number;
  chunkIndex: number;
  chunkCount: number;
  bytes: Uint8Array;
  submitOnSend: boolean;
}

export interface FileAttachmentChunk {
  batchId: string;
  transferId: string;
  agentId: AgentId;
  text: string;
  filename: string;
  mimeType: string;
  totalBytes: number;
  fileIndex: number;
  fileCount: number;
  chunkIndex: number;
  chunkCount: number;
  bytes: Uint8Array;
  submitOnSend: boolean;
}

export interface QuickReply {
  agentId: AgentId;
  kind: QuickReplyKind;
}

export interface InterruptRequest {
  agentId: AgentId;
}

export interface TargetSelectionRequest {
  agentId: AgentId;
  targetId: string;
}

export interface TargetRenameRequest {
  agentId: AgentId;
  targetId: string;
  label: string;
}

export interface AgentRuntimeSettingsUpdate {
  agentId: AgentId;
  modelId?: string;
  reasoningEffort?: string;
  fastMode?: boolean;
}

export type RemoteAppAction = 'enable' | 'disable' | 'launch' | 'start' | 'stop' | 'newSession' | 'closeSession';
export type ScreenShareQuality = 'fast' | 'readable';

export interface RemoteAppActionRequest {
  remoteAppId: string;
  action: RemoteAppAction;
  screenQuality?: ScreenShareQuality;
}

export interface GridLayoutUpdate {
  layout: GridLayout;
}

export interface RemoteAppsUpdate {
  remoteApps: RemoteApp[];
}

export interface ReadOnlyModeUpdate {
  readOnly: boolean;
}

export interface HeartbeatPing {
  atUnixMs: number;
}

export interface HeartbeatPong {
  atUnixMs: number;
}

export interface VideoTrackHint {
  agentId: AgentId;
  trackId: string;
  active: boolean;
}

export interface RedactionPolicyUpdate {
  patterns: string[];
}

export type DataChannelBody =
  | { kind: 'hello'; hello: Hello }
  | { kind: 'agentState'; agentState: AgentStateSnapshot }
  | { kind: 'agentChatMessage'; agentChatMessage: AgentChatMessage }
  | { kind: 'userInput'; userInput: UserInput }
  | { kind: 'screenPointerInput'; screenPointerInput: ScreenPointerInput }
  | { kind: 'imageAttachmentInput'; imageAttachmentInput: ImageAttachmentInput }
  | { kind: 'imageAttachmentChunk'; imageAttachmentChunk: ImageAttachmentChunk }
  | { kind: 'fileAttachmentChunk'; fileAttachmentChunk: FileAttachmentChunk }
  | { kind: 'quickReply'; quickReply: QuickReply }
  | { kind: 'interruptRequest'; interruptRequest: InterruptRequest }
  | { kind: 'targetSelectionRequest'; targetSelectionRequest: TargetSelectionRequest }
  | { kind: 'targetRenameRequest'; targetRenameRequest: TargetRenameRequest }
  | { kind: 'agentRuntimeSettingsUpdate'; agentRuntimeSettingsUpdate: AgentRuntimeSettingsUpdate }
  | { kind: 'remoteAppActionRequest'; remoteAppActionRequest: RemoteAppActionRequest }
  | { kind: 'inputRequestResponse'; inputRequestResponse: AgentInputRequestResponse }
  | { kind: 'gridLayoutUpdate'; gridLayoutUpdate: GridLayoutUpdate }
  | { kind: 'remoteAppsUpdate'; remoteAppsUpdate: RemoteAppsUpdate }
  | { kind: 'readOnlyModeUpdate'; readOnlyModeUpdate: ReadOnlyModeUpdate }
  | { kind: 'heartbeatPing'; heartbeatPing: HeartbeatPing }
  | { kind: 'heartbeatPong'; heartbeatPong: HeartbeatPong }
  | { kind: 'videoTrackHint'; videoTrackHint: VideoTrackHint }
  | { kind: 'redactionPolicyUpdate'; redactionPolicyUpdate: RedactionPolicyUpdate }
  | { kind: 'messageDetailRequest'; messageDetailRequest: MessageDetailRequest }
  | { kind: 'messageDetail'; messageDetail: MessageDetail };

export interface DataChannelMessage {
  messageId: string;
  atUnixMs: number;
  body: DataChannelBody;
}

// =============================================================================
// RELAY TRANSPORT TYPES
// =============================================================================

export const RELAY_PATH = '/relay';
export const RELAY_PROTOCOL_VERSION = 1;

export type RelayRole = 'host' | 'client';

export type RelayMessageKind =
  | 'relayHello'
  | 'relayPresence'
  | 'relayRemoteAppsSnapshot'
  | 'relayAgentSnapshot'
  | 'relayAgentDelta'
  | 'relayCommand'
  | 'relayAck'
  | 'relayError'
  | 'relayPing'
  | 'relayPong';

export interface RelayMessageBase {
  protocolVersion: number;
  hostDeviceId: DeviceId;
  clientDeviceId: DeviceId;
  seq: number;
  timestamp: number;
  kind: RelayMessageKind;
}

export interface RelayPresencePayload {
  online: boolean;
  lastSeenAtUnixMs: number;
}

export interface RelayRemoteAppsSnapshotPayload {
  remoteApps: RemoteApp[];
}

export interface RelayAgentSnapshotPayload {
  snapshot: AgentStateSnapshot;
}

export interface RelayCommandPayload {
  command: DataChannelMessage;
}

export interface RelayAckPayload {
  messageId: string;
}

export interface RelayErrorPayload {
  code: string;
  message: string;
}

export type RelayPlainPayload =
  | { kind: 'relayPresence'; relayPresence: RelayPresencePayload }
  | { kind: 'relayRemoteAppsSnapshot'; relayRemoteAppsSnapshot: RelayRemoteAppsSnapshotPayload }
  | { kind: 'relayAgentSnapshot'; relayAgentSnapshot: RelayAgentSnapshotPayload }
  | { kind: 'relayCommand'; relayCommand: RelayCommandPayload }
  | { kind: 'relayAck'; relayAck: RelayAckPayload }
  | { kind: 'relayError'; relayError: RelayErrorPayload };

export interface RelayEnvelope extends RelayMessageBase {
  /**
   * Phase-1 relay transports plaintext protocol payloads inside an authenticated
   * WebSocket. Phase-2 will move these to encryptedPayload while keeping the
   * metadata shape stable.
   */
  payload?: RelayPlainPayload;
  encryptedPayload?: string;
}

// =============================================================================
// SIGNALING ENVELOPE TYPES
// =============================================================================

export interface SdpOffer {
  sdp: string;
  sessionId: string;
}

export interface SdpAnswer {
  sdp: string;
  sessionId: string;
}

export interface IceCandidate {
  candidate: string;
  sdpMid: string;
  sdpMlineIndex: number;
  sessionId: string;
}

export interface PushRegister {
  endpoint: string;
  p256dh: string;
  auth: string;
  phonePublicKey: Uint8Array;
}

export interface AgentStateEvent {
  agentId: AgentId;
  status: AgentStatus;
  summary: string;
  atUnixMs: number;
}

export interface Ping {
  atUnixMs: number;
}

export interface Pong {
  atUnixMs: number;
}

export interface ProtoError {
  code: string;
  message: string;
}

export type EnvelopePayload =
  | { kind: 'sdpOffer'; sdpOffer: SdpOffer }
  | { kind: 'sdpAnswer'; sdpAnswer: SdpAnswer }
  | { kind: 'iceCandidate'; iceCandidate: IceCandidate }
  | { kind: 'pushRegister'; pushRegister: PushRegister }
  | { kind: 'agentStateEvent'; agentStateEvent: AgentStateEvent }
  | { kind: 'ping'; ping: Ping }
  | { kind: 'pong'; pong: Pong }
  | { kind: 'error'; error: ProtoError };

export interface Envelope {
  envelopeId: string;
  fromDeviceId: DeviceId;
  toDeviceId: DeviceId;
  sentAtUnixMs: number;
  signature: Uint8Array;
  payload: EnvelopePayload;
}

// =============================================================================
// JSON ENCODING/DECODING
// =============================================================================

export const encodeEnvelopeJson = (env: Envelope): string => JSON.stringify(env, bufferReplacer);
export const encodeDataChannelMessageJson = (msg: DataChannelMessage): string =>
  JSON.stringify(msg, bufferReplacer);

export const decodeEnvelopeJson = (raw: string): Envelope => JSON.parse(raw) as Envelope;
export const decodeDataChannelMessageJson = (raw: string): DataChannelMessage =>
  JSON.parse(raw) as DataChannelMessage;

/**
 * Canonical wire representation of binary fields: bare base64 strings.
 * Swift's JSONEncoder with `.base64` strategy and Go's `encoding/json`
 * unmarshalling into a `string` field both expect the same thing.
 *
 * Incoming envelopes (from Swift or Go) arrive with the Uint8Array-typed
 * fields as base64 strings; callers that need the raw bytes on the phone
 * can decode via `bytesFromBase64(field as unknown as string)`. In the
 * current PWA codebase nobody does, so we save a pass.
 */
function bufferReplacer(_key: string, value: unknown): unknown {
  if (value instanceof Uint8Array) {
    return base64FromBytes(value);
  }
  return value;
}

export function base64FromBytes(bytes: Uint8Array): string {
  const anyGlobal = globalThis as unknown as {
    Buffer?: { from: (v: Uint8Array) => { toString: (enc: string) => string } };
    btoa?: (s: string) => string;
  };
  if (anyGlobal.Buffer) {
    return anyGlobal.Buffer.from(bytes).toString('base64');
  }
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return anyGlobal.btoa ? anyGlobal.btoa(binary) : '';
}

export function bytesFromBase64(b64: string): Uint8Array {
  const anyGlobal = globalThis as unknown as {
    Buffer?: { from: (v: string, enc: string) => Uint8Array };
    atob?: (s: string) => string;
  };
  if (anyGlobal.Buffer) {
    return new Uint8Array(anyGlobal.Buffer.from(b64, 'base64'));
  }
  const binary = anyGlobal.atob ? anyGlobal.atob(b64) : '';
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// =============================================================================
// CONSTANTS
// =============================================================================

export const SIGNALING_PATH = '/signal';
export const SIGNALING_DEFAULT_PORT = 8080;

export const DEFAULT_SIGNALING_URL = 'wss://signaling.glasstunnel.io/signal';
export const DEFAULT_TURN_URL = 'turn:turn.glasstunnel.io:3478';
export const DEFAULT_STUN_URLS = [
  'stun:stun.l.google.com:19302',
  'stun:stun.cloudflare.com:3478',
];

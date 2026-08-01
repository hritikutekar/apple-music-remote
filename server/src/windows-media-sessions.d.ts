// windows-media-sessions ships full TypeScript typings, but it is an
// optionalDependency (os: win32 only) so it is not installed on this dev
// machine. These shims mirror the published API surface we use.
declare module "windows-media-sessions" {
  export type PlaybackStatus =
    | "closed"
    | "opened"
    | "changing"
    | "stopped"
    | "playing"
    | "paused";

  export interface MediaSession {
    id: string;
    sourceAppUserModelId: string;
    sourceAppDisplayName?: string;
    title?: string;
    artist?: string;
    albumTitle?: string;
    genres?: string[];
    playbackStatus: PlaybackStatus;
    timeline?: { positionMs?: number; durationMs?: number };
    controls?: {
      canPlay: boolean;
      canPause: boolean;
      canSkipNext: boolean;
      canSkipPrevious: boolean;
    };
    /** ready-to-use data URL, e.g. data:image/jpeg;base64,... */
    thumbnail?: string;
  }

  export function getAllSessions(): Promise<MediaSession[]>;
  export function getActiveSessions(): Promise<MediaSession[]>;
}

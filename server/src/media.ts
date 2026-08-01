import {
  GlobalSystemMediaTransportControlsSessionManager,
  GlobalSystemMediaTransportControlsSession,
  GlobalSystemMediaTransportControlsSessionPlaybackStatus,
} from "@nodert-win11/windows.media.control";
import { DataReader } from "@nodert-win11/windows.storage.streams";

export type PlaybackState = "playing" | "paused" | "stopped";

export interface NowPlaying {
  title: string | null;
  artist: string | null;
  album: string | null;
  status: PlaybackState;
  positionSec: number;
  durationSec: number;
  /** data URL (base64) or null when no artwork is available */
  artwork: string | null;
  /** App User Model ID of the session we are controlling */
  sourceApp: string | null;
}

const APPLE_MUSIC_HINTS = ["applemusic", "apple.music", "appleinc"];

let managerPromise: Promise<GlobalSystemMediaTransportControlsSessionManager> | null =
  null;

function getManager() {
  if (!managerPromise) {
    managerPromise = GlobalSystemMediaTransportControlsSessionManager.requestAsync();
  }
  return managerPromise;
}

/**
 * Pick the session to control: prefer Apple Music, then the system's
 * "current" session, then the most recently listed session.
 */
async function pickSession(): Promise<GlobalSystemMediaTransportControlsSession | null> {
  const manager = await getManager();
  const sessions = Array.from(manager.getSessions() ?? []);
  if (sessions.length === 0) return null;

  const appleMusic = sessions.find((s) => {
    const id = (s.sourceAppUserModelId || "").toLowerCase();
    return APPLE_MUSIC_HINTS.some((hint) => id.includes(hint));
  });
  if (appleMusic) return appleMusic;

  return manager.getCurrentSession() ?? sessions[0] ?? null;
}

function mapStatus(
  status: GlobalSystemMediaTransportControlsSessionPlaybackStatus,
): PlaybackState {
  switch (status) {
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus.playing:
      return "playing";
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus.paused:
      return "paused";
    default:
      return "stopped";
  }
}

/** Windows TimeSpan { duration } is in 100-nanosecond ticks. */
function ticksToSeconds(ticks: unknown): number {
  const n = Number(ticks);
  return Number.isFinite(n) ? n / 10_000_000 : 0;
}

async function readArtwork(thumbnail: any): Promise<string | null> {
  if (!thumbnail) return null;
  let stream: any;
  let reader: DataReader | null = null;
  try {
    stream = await thumbnail.openReadAsync();
    const size = Number(stream.size);
    if (!size || size <= 0 || size > 10 * 1024 * 1024) return null;

    reader = new DataReader(stream);
    await reader.loadAsync(size);

    // NodeRT versions differ: readBytes may fill a plain array or a Buffer.
    const arr = new Array<number>(size).fill(0);
    reader.readBytes(arr);
    const buf = Buffer.isBuffer(arr) ? arr : Buffer.from(arr);

    const mime = stream.contentType || "image/jpeg";
    return `data:${mime};base64,${buf.toString("base64")}`;
  } catch {
    return null;
  } finally {
    try {
      reader?.close();
      stream?.close?.();
    } catch {
      /* ignore */
    }
  }
}

export async function getNowPlaying(): Promise<NowPlaying | null> {
  const session = await pickSession();
  if (!session) return null;

  const [props, timeline] = await Promise.all([
    session.getMediaPropertiesAsync(),
    Promise.resolve(session.getTimelineProperties()),
  ]);
  const info = session.getPlaybackInfo();

  return {
    title: props?.title || null,
    artist: props?.artist || props?.albumArtist || null,
    album: props?.albumTitle || null,
    status: mapStatus(info.playbackStatus),
    positionSec: ticksToSeconds(timeline?.position?.duration ?? timeline?.position),
    durationSec: ticksToSeconds(timeline?.endTime?.duration ?? timeline?.endTime),
    artwork: await readArtwork(props?.thumbnail),
    sourceApp: session.sourceAppUserModelId || null,
  };
}

async function withSession(
  fn: (s: GlobalSystemMediaTransportControlsSession) => Promise<boolean>,
): Promise<boolean> {
  const session = await pickSession();
  if (!session) throw new Error("no active media session");
  return fn(session);
}

export const playPause = () => withSession((s) => s.tryTogglePlayPauseAsync());
export const next = () => withSession((s) => s.trySkipNextAsync());
export const previous = () => withSession((s) => s.trySkipPreviousAsync());
export const play = () => withSession((s) => s.tryPlayAsync());
export const pause = () => withSession((s) => s.tryPauseAsync());

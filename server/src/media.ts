import { spawn, ChildProcess } from "child_process";
import { getAllSessions, MediaSession } from "windows-media-sessions";

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
  /** App User Model ID of the session we are reporting on */
  sourceApp: string | null;
}

const APPLE_MUSIC_HINTS = ["applemusic", "apple.music", "apple music"];

/**
 * Pick the session to report on: prefer Apple Music, then any playing
 * session, then the first session Windows knows about.
 */
function pickSession(sessions: MediaSession[]): MediaSession | null {
  if (sessions.length === 0) return null;

  const appleMusic = sessions.find((s) => {
    const haystack =
      `${s.sourceAppUserModelId} ${s.sourceAppDisplayName ?? ""}`.toLowerCase();
    return APPLE_MUSIC_HINTS.some((hint) => haystack.includes(hint));
  });
  if (appleMusic) return appleMusic;

  return (
    sessions.find((s) => s.playbackStatus === "playing") ?? sessions[0] ?? null
  );
}

export async function getNowPlaying(): Promise<NowPlaying | null> {
  const sessions = await getAllSessions();
  const s = pickSession(sessions);
  if (!s) return null;

  return {
    title: s.title ?? null,
    artist: s.artist ?? null,
    album: s.albumTitle ?? null,
    status:
      s.playbackStatus === "playing"
        ? "playing"
        : s.playbackStatus === "paused"
          ? "paused"
          : "stopped",
    positionSec: (s.timeline?.positionMs ?? 0) / 1000,
    durationSec: (s.timeline?.durationMs ?? 0) / 1000,
    artwork: s.thumbnail ?? null,
    sourceApp: s.sourceAppUserModelId || null,
  };
}

// MARK: Transport — media keys via a persistent PowerShell helper
//
// windows-media-sessions is read-only, so transport control is done by
// injecting hardware-style media key presses (VK_MEDIA_*) into Windows,
// exactly what the media keys on a keyboard do. A single PowerShell child
// process is kept alive; the C# helper class is compiled once at startup,
// then each command is one line on stdin — no per-press startup cost.

const VK = {
  playPause: "0xB3",
  next: "0xB0",
  previous: "0xB1",
} as const;

const BOOTSTRAP = `
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MediaKeys {
  [DllImport("user32.dll")]
  public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  public static void Press(byte vk) {
    keybd_event(vk, 0, 0, UIntPtr.Zero);
    keybd_event(vk, 0, 2, UIntPtr.Zero);
  }
}
'@
function Send-MediaKey([string]$vk) { [MediaKeys]::Press([byte]$vk) }
Write-Output "READY"
`;

let helper: ChildProcess | null = null;
let helperReady: Promise<void> | null = null;

function getHelper(): Promise<void> {
  if (helperReady) return helperReady;

  helperReady = new Promise<void>((resolve, reject) => {
    helper = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "-"], {
      stdio: ["pipe", "pipe", "inherit"],
    });

    const onData = (chunk: Buffer) => {
      if (chunk.toString().includes("READY")) {
        helper!.stdout!.off("data", onData);
        resolve();
      }
    };
    helper.stdout!.on("data", onData);

    helper.on("error", reject);
    helper.on("exit", (code) => {
      helper = null;
      helperReady = null;
      if (code !== 0 && code !== null) {
        reject(new Error(`media-key helper exited with code ${code}`));
      }
    });

    helper.stdin!.write(BOOTSTRAP + "\n");
  });

  return helperReady;
}

async function sendMediaKey(vk: string): Promise<boolean> {
  try {
    await getHelper();
    helper!.stdin!.write(`Send-MediaKey ${vk}\n`);
    return true;
  } catch (err) {
    console.error("failed to send media key:", err);
    return false;
  }
}

export const playPause = () => sendMediaKey(VK.playPause);
export const next = () => sendMediaKey(VK.next);
export const previous = () => sendMediaKey(VK.previous);

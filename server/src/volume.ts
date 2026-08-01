import * as loudness from "loudness";

export async function getVolume(): Promise<number> {
  return loudness.getVolume();
}

export async function setVolume(level: number): Promise<void> {
  const clamped = Math.max(0, Math.min(100, Math.round(level)));
  await loudness.setVolume(clamped);
}

export async function getMuted(): Promise<boolean> {
  return loudness.getMuted();
}

export async function setMuted(muted: boolean): Promise<void> {
  await loudness.setMuted(muted);
}

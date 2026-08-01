// loudness ships no TypeScript typings; declare the promise-based API we use.
declare module "loudness" {
  export function getVolume(): Promise<number>;
  export function setVolume(level: number): Promise<void>;
  export function getMuted(): Promise<boolean>;
  export function setMuted(muted: boolean): Promise<void>;
}

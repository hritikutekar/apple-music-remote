// Minimal module shims for the NodeRT packages. The real packages ship
// their own WinRT-generated surface; we only declare what we use so tsc
// stays happy even if the bundled typings differ across NodeRT versions.

declare module "@nodert-win11/windows.media.control" {
  export enum GlobalSystemMediaTransportControlsSessionPlaybackStatus {
    closed = 0,
    opened = 1,
    changing = 2,
    stopped = 3,
    playing = 4,
    paused = 5,
  }

  export class GlobalSystemMediaTransportControlsSessionMediaProperties {
    title: string;
    subtitle: string;
    artist: string;
    albumArtist: string;
    albumTitle: string;
    albumTrackCount: number;
    trackNumber: number;
    thumbnail: any; // IRandomAccessStreamReference
  }

  export class GlobalSystemMediaTransportControlsSessionTimelineProperties {
    position: any; // Windows.Foundation.TimeSpan ({ duration } in 100ns units)
    endTime: any;
    startTime: any;
    lastUpdatedTime: any;
  }

  export class GlobalSystemMediaTransportControlsSessionPlaybackInfo {
    playbackStatus: GlobalSystemMediaTransportControlsSessionPlaybackStatus;
    playbackType: any;
  }

  export class GlobalSystemMediaTransportControlsSession {
    sourceAppUserModelId: string;
    getMediaPropertiesAsync(): Promise<GlobalSystemMediaTransportControlsSessionMediaProperties>;
    getPlaybackInfo(): GlobalSystemMediaTransportControlsSessionPlaybackInfo;
    getTimelineProperties(): GlobalSystemMediaTransportControlsSessionTimelineProperties;
    tryPlayAsync(): Promise<boolean>;
    tryPauseAsync(): Promise<boolean>;
    tryTogglePlayPauseAsync(): Promise<boolean>;
    trySkipNextAsync(): Promise<boolean>;
    trySkipPreviousAsync(): Promise<boolean>;
  }

  export class GlobalSystemMediaTransportControlsSessionManager {
    static requestAsync(): Promise<GlobalSystemMediaTransportControlsSessionManager>;
    getSessions(): GlobalSystemMediaTransportControlsSession[];
    getCurrentSession(): GlobalSystemMediaTransportControlsSession | null;
  }
}

declare module "@nodert-win11/windows.storage.streams" {
  export class DataReader {
    constructor(stream: any);
    loadAsync(count: number): Promise<number>;
    readBytes(value: number[] | Buffer): void;
    close(): void;
  }
}

import express from "express";
import { hostname } from "os";
import { Bonjour } from "bonjour-service";
import { getNowPlaying, playPause, next, previous } from "./media";
import { getVolume, setVolume, getMuted, setMuted } from "./volume";

const PORT = Number(process.env.PORT ?? 4789);

const app = express();
app.use(express.json());

// Tiny request log so the Windows console shows what the remote is doing.
app.use((req, _res, nextFn) => {
  console.log(`${new Date().toISOString()} ${req.method} ${req.path}`);
  nextFn();
});

function asyncRoute(
  handler: (req: express.Request, res: express.Response) => Promise<void>,
): express.RequestHandler {
  return (req, res) => {
    handler(req, res).catch((err) => {
      console.error(err);
      res.status(500).json({ error: String(err?.message ?? err) });
    });
  };
}

app.get(
  "/now-playing",
  asyncRoute(async (_req, res) => {
    const [np, volume, muted] = await Promise.all([
      getNowPlaying(),
      getVolume().catch(() => null),
      getMuted().catch(() => null),
    ]);
    res.json({
      ...(np ?? {
        title: null,
        artist: null,
        album: null,
        status: "stopped",
        positionSec: 0,
        durationSec: 0,
        artwork: null,
        sourceApp: null,
      }),
      volume,
      muted,
    });
  }),
);

app.post(
  "/play-pause",
  asyncRoute(async (_req, res) => {
    res.json({ ok: await playPause() });
  }),
);

app.post(
  "/next",
  asyncRoute(async (_req, res) => {
    res.json({ ok: await next() });
  }),
);

app.post(
  "/previous",
  asyncRoute(async (_req, res) => {
    res.json({ ok: await previous() });
  }),
);

app.post(
  "/volume",
  asyncRoute(async (req, res) => {
    const level = Number(req.body?.level);
    if (!Number.isFinite(level)) {
      res.status(400).json({ error: "body must include numeric 'level' (0-100)" });
      return;
    }
    await setVolume(level);
    res.json({ ok: true, volume: await getVolume() });
  }),
);

app.post(
  "/mute",
  asyncRoute(async (req, res) => {
    await setMuted(Boolean(req.body?.muted));
    res.json({ ok: true, muted: await getMuted() });
  }),
);

app.get("/health", (_req, res) => res.json({ ok: true }));

app.listen(PORT, "0.0.0.0", () => {
  console.log(`apple-music-remote server listening on http://0.0.0.0:${PORT}`);

  // Advertise via mDNS so the Mac app can find this PC without a manual IP.
  // Service type must be <= 15 chars: "_amremote._tcp".
  // host must be a proper .local name — a bare hostname (e.g. "DESKTOP-ABC")
  // cannot be resolved by clients.
  const bonjour = new Bonjour();
  bonjour.publish({
    name: `Apple Music Remote (${hostname()})`,
    type: "amremote",
    protocol: "tcp",
    port: PORT,
    host: `${hostname()}.local`,
  });
  console.log("mDNS: advertising as _amremote._tcp");
});

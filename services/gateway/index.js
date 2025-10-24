
import express from 'express';
import fetch from 'node-fetch';
import client from 'prom-client';

const app = express();
const AUTH_INTROSPECT = process.env.AUTH_INTROSPECT || 'http://auth:7000/introspect';
const TARGET_ACCOUNTS = process.env.TARGET_ACCOUNTS || 'http://accounts:7300';

const register = new client.Registry();
client.collectDefaultMetrics({ register });
const reqLatency = new client.Histogram({
  name: 'gateway_request_latency_ms',
  help: 'Gateway request latency',
  // Wider and more granular buckets (ms)
  buckets: [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
});
register.registerMetric(reqLatency);

async function introspect(token) {
  const r = await fetch(AUTH_INTROSPECT, { method: 'POST', headers: { Authorization: `Bearer ${token}` }});
  return r.json();
}

app.get('/accounts', async (req, res) => {
  const end = reqLatency.startTimer();
  try {
    const authz = req.headers['authorization'] || '';
    if (!authz.startsWith('Bearer ')) { end(); return res.status(401).json({ error: 'missing_bearer' }); }
    const token = authz.slice(7);
    const info = await introspect(token);
    if (!info.active) { end(); return res.status(401).json({ error: 'inactive_token' }); }
    const up = await fetch(`${TARGET_ACCOUNTS}/protected`, { headers: { 'x-sub': info.sub }});
    const body = await up.json();
    end();
    return res.json({ ok: true, sub: info.sub, body });
  } catch (e) {
    end();
    return res.status(502).json({ error: 'upstream_error' });
  }
});

app.get('/metrics', async (_, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

const PORT = process.env.PORT || 8080;
const PROM_PORT = process.env.PROM_PORT || 9101;
app.listen(PORT, () => console.log(`gateway ${PORT}`));
app.listen(PROM_PORT, () => console.log(`gateway metrics ${PROM_PORT}`));

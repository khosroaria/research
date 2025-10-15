
import fetch from 'node-fetch';
import client from 'prom-client';

const AUTH_ISSUE = process.env.AUTH_ISSUE || 'http://localhost:7000/issue';
const SERVICE_ID = process.env.SERVICE_ID || 'accounts';
const ROTATE_INTERVAL_SEC = parseInt(process.env.ROTATE_INTERVAL_SEC || '300', 10);

const register = new client.Registry();
client.collectDefaultMetrics({ register });
const rotationEvents = new client.Counter({ name: 'rotation_events_total', help: 'Rotation events' });
const rotationErrors = new client.Counter({ name: 'rotation_errors_total', help: 'Rotation errors' });
register.registerMetric(rotationEvents);
register.registerMetric(rotationErrors);

async function rotate() {
  try {
    const r = await fetch(AUTH_ISSUE, {
      method: 'POST',
      headers: { 'Content-Type':'application/json' },
      body: JSON.stringify({ service_id: SERVICE_ID, scope: 'accounts:read' })
    });
    const j = await r.json();
    if (!j.access_token) throw new Error('issue_failed');
    console.log(`[rotation] ${SERVICE_ID} token rotated: ${j.access_token.substring(0,16)}... expIn=${j.expires_in}s`);
    rotationEvents.inc();
  } catch (e) {
    rotationErrors.inc();
    console.error('[rotation] error', e.message);
  }
}

setInterval(rotate, ROTATE_INTERVAL_SEC * 1000);
rotate();

import express from 'express';
const app = express();
app.get('/metrics', async (_, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});
const PROM_PORT = process.env.PROM_PORT || 9103;
app.listen(PROM_PORT, () => console.log(`rotation metrics on ${PROM_PORT}`));


import express from 'express';
import Database from 'better-sqlite3';
import { nanoid } from 'nanoid';
import client from 'prom-client';

const app = express();
app.use(express.json());

const DB_PATH = process.env.DB_PATH || './auth.sqlite';
const db = new Database(DB_PATH);
db.exec(`
CREATE TABLE IF NOT EXISTS tokens (
  token TEXT PRIMARY KEY,
  sub TEXT NOT NULL,
  scope TEXT NOT NULL,
  exp INTEGER NOT NULL,
  issued INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tokens_exp ON tokens(exp);
`);

const ACCESS_TTL = parseInt(process.env.ACCESS_TTL_SEC || '600', 10);

const register = new client.Registry();
client.collectDefaultMetrics({ register });
const introspectLatency = new client.Histogram({
  name: 'introspection_latency_ms',
  help: 'Introspection latency',
  buckets: [5,10,20,50,100,200,500,1000]
});
register.registerMetric(introspectLatency);
const issueCounter = new client.Counter({ name: 'issue_tokens_total', help: 'Tokens issued' });
register.registerMetric(issueCounter);

const now = () => Math.floor(Date.now() / 1000);

// POST /issue
app.post('/issue', (req, res) => {
  const { service_id = 'accounts', scope = 'accounts:read' } = req.body || {};
  const t = `tok_${nanoid(24)}`;
  const issued = now();
  const exp = issued + ACCESS_TTL;
  db.prepare('INSERT INTO tokens (token, sub, scope, exp, issued) VALUES (?, ?, ?, ?, ?)')
    .run(t, service_id, scope, exp, issued);
  issueCounter.inc();
  res.json({ access_token: t, token_type: 'Bearer', expires_in: ACCESS_TTL, sub: service_id, scope });
});

// POST /introspect
app.post('/introspect', (req, res) => {
  const end = introspectLatency.startTimer();
  try {
    const authz = req.headers['authorization'] || '';
    const token = (authz.startsWith('Bearer ') ? authz.slice(7) : '').trim();
    if (!token) { end(); return res.json({ active: false }); }
    const row = db.prepare('SELECT sub, scope, exp FROM tokens WHERE token = ?').get(token);
    if (!row) { end(); return res.json({ active: false }); }
    const active = Math.floor(Date.now()/1000) <= row.exp;
    end();
    return res.json({ active, sub: row.sub, scope: row.scope, exp: row.exp });
  } catch (e) {
    end();
    return res.status(500).json({ active: false, error: 'introspection_error' });
  }
});

// metrics
app.get('/metrics', async (_, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

const PORT = process.env.PORT || 7000;
const PROM_PORT = process.env.PROM_PORT || 9100;
app.listen(PORT, () => console.log(`auth listening ${PORT}`));
app.listen(PROM_PORT, () => console.log(`auth metrics ${PROM_PORT}`));

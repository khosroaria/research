
import express from 'express';
import client from 'prom-client';
const app = express();

const register = new client.Registry();
client.collectDefaultMetrics({ register });

app.get('/protected', (req, res) => {
  const sub = req.headers['x-sub'] || 'unknown';
  res.json({ service: 'accounts', sub, balance: 123.45, ts: Date.now() });
});

app.get('/metrics', async (_, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

const PORT = process.env.PORT || 7300;
const PROM_PORT = process.env.PROM_PORT || 9102;
app.listen(PORT, () => console.log(`accounts on ${PORT}`));
app.listen(PROM_PORT, () => console.log(`accounts metrics on ${PROM_PORT}`));

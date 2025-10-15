
import http from 'k6/http';
import { sleep } from 'k6';

export const options = { vus: 1, duration: '5m' };

export default function () {
  const token = __ENV.STOLEN_TOKEN || '';
  const r = http.get('http://localhost:8080/accounts', { headers: { Authorization: `Bearer ${token}` }});
  console.log(`replay status=${r.status}`);
  sleep(1);
}

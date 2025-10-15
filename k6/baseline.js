
import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  scenarios: {
    steady: { executor: 'constant-arrival-rate', rate: 10, timeUnit: '1s', duration: '2m', preAllocatedVUs: 10 }
  }
};

export default function () {
  const token = __ENV.TOKEN || '';
  const res = http.get('http://localhost:8080/accounts', { headers: { Authorization: `Bearer ${token}` }});
  check(res, { 'ok or unauthorized': r => [200,401].includes(r.status) });
  sleep(0.2);
}


import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  scenarios: {
    steady: { executor: 'constant-arrival-rate', rate: 10, timeUnit: '1s', duration: '2m', preAllocatedVUs: 10 }
  }
};


let token = __ENV.TOKEN || '';
let refreshing = false;
let refreshStart = 0;

export default function () {
  let start = Date.now();
  let res = http.get('http://localhost:8080/accounts', { headers: { Authorization: `Bearer ${token}` }});
  if (res.status === 401) {
    // Start measuring refresh latency
    refreshing = true;
    refreshStart = Date.now();
    // Simulate fetching a new token (replace with real call if needed)
    let newTokenRes = http.post('http://localhost:7000/issue', JSON.stringify({ service_id: 'accounts' }), { headers: { 'Content-Type': 'application/json' }});
    token = newTokenRes.json('access_token') || token;
    // Retry until 200
    let retryRes;
    let retryCount = 0;
    do {
      retryRes = http.get('http://localhost:8080/accounts', { headers: { Authorization: `Bearer ${token}` }});
      retryCount++;
    } while (retryRes.status !== 200 && retryCount < 5);
    let refreshLatency = Date.now() - refreshStart;
    console.log(`CLIENT_REFRESH_LATENCY_MS,${refreshLatency}`);
    refreshing = false;
    // Optionally, check(retryRes, { 'refresh ok': r => r.status === 200 });
  }
  sleep(0.2);
}

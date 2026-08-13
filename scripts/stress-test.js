import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    create_flags: {
      executor: 'constant-arrival-rate',
      rate: 60,
      timeUnit: '1s',
      duration: '60s',

      preAllocatedVUs: 25,
      maxVUs: 50,
    },
  },

  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const url = 'http://<ip_da_instancia>:5000/flags';

  const uniqueName = `new-feature-${Date.now()}-${__VU}-${__ITER}`;

  const payload = JSON.stringify({
    name: uniqueName,
    is_enabled: true,
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
    },
  };

  const response = http.post(url, payload, params);

  check(response, {
    'status é 200 ou 201': (r) => r.status === 200 || r.status === 201,
  });
}
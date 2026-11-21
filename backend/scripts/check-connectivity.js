import { checkConnectivity } from '../src/connectivity.js';

// First step of both CodeBuild jobs: fail early, with a clear message, if a private-subnet path is missing.
try {
  const { ok, results } = await checkConnectivity();
  for (const r of results) console.log(`${r.reachable ? 'ok  ' : 'FAIL'} ${r.name} (${r.host}:${r.port})`);
  if (!ok) {
    console.error('connectivity check failed: a required network path is missing (route, NAT, security group or DNS)');
    process.exit(1);
  }
  console.log('connectivity check passed');
} catch (err) {
  console.error(`connectivity check could not run: ${err.message}`);
  process.exit(1);
}

import net from 'node:net';

// Pre-flight check for the CodeBuild jobs (migrator and bootstrap), which run in private subnets and reach everything
// through the NAT Gateway or the VPC. It proves, at run time and before any database work, that this job can reach
// what it needs: RDS, the ECR API, Secrets Manager and CloudWatch Logs. It opens plain TCP connections only: no
// credentials are sent and nothing is read, so it cannot leak a secret. A failure names the missing path.

export function connectivityTargets(env) {
  const region = env.AWS_REGION;
  const targets = [
    { name: 'RDS PostgreSQL', host: env.DB_HOST, port: Number(env.DB_PORT || 5432) },
    { name: 'ECR API', host: `api.ecr.${region}.amazonaws.com`, port: 443 },
    { name: 'Secrets Manager', host: `secretsmanager.${region}.amazonaws.com`, port: 443 },
    { name: 'CloudWatch Logs', host: `logs.${region}.amazonaws.com`, port: 443 },
  ];
  return targets;
}

export function tcpConnect(host, port, timeoutMs) {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    const done = (ok) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

/**
 * @returns {Promise<{ok: boolean, results: {name: string, host: string, port: number, reachable: boolean}[]}>}
 */
export async function checkConnectivity({ env = process.env, connect = tcpConnect, timeoutMs = 5000 } = {}) {
  const missing = ['DB_HOST', 'AWS_REGION'].filter((name) => !env[name]);
  if (missing.length > 0) throw new Error(`missing settings for the connectivity check: ${missing.join(', ')}`);

  const results = await Promise.all(
    connectivityTargets(env).map(async (target) => ({ ...target, reachable: await connect(target.host, target.port, timeoutMs) })),
  );
  return { ok: results.every((r) => r.reachable), results };
}

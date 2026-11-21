import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, vi } from 'vitest';
import { checkConnectivity, connectivityTargets, tcpConnect } from '../src/connectivity.js';

const env = { DB_HOST: 'db.example.internal', DB_PORT: '5432', AWS_REGION: 'ap-south-1' };

describe('connectivityTargets', () => {
  it('names every path a private-subnet CodeBuild job needs', () => {
    const targets = connectivityTargets(env);
    expect(targets.map((t) => t.name)).toEqual(['RDS PostgreSQL', 'ECR API', 'Secrets Manager', 'CloudWatch Logs']);
    expect(targets[0]).toMatchObject({ host: 'db.example.internal', port: 5432 });
    expect(targets[1]).toMatchObject({ host: 'api.ecr.ap-south-1.amazonaws.com', port: 443 });
    expect(targets[2]).toMatchObject({ host: 'secretsmanager.ap-south-1.amazonaws.com', port: 443 });
    expect(targets[3]).toMatchObject({ host: 'logs.ap-south-1.amazonaws.com', port: 443 });
  });

  it('uses 5432 when no port is given', () => {
    expect(connectivityTargets({ DB_HOST: 'h', AWS_REGION: 'ap-south-1' })[0].port).toBe(5432);
  });
});

describe('checkConnectivity', () => {
  it('passes when every path is reachable', async () => {
    const connect = vi.fn(async () => true);
    const result = await checkConnectivity({ env, connect });
    expect(result.ok).toBe(true);
    expect(connect).toHaveBeenCalledTimes(4);
  });

  it('fails, and names the missing path, when one is not reachable', async () => {
    const connect = async (host) => !host.startsWith('secretsmanager');
    const result = await checkConnectivity({ env, connect });
    expect(result.ok).toBe(false);
    expect(result.results.filter((r) => !r.reachable).map((r) => r.name)).toEqual(['Secrets Manager']);
  });

  it('fails when the database is unreachable (for example a missing security group rule)', async () => {
    const connect = async (host) => host !== 'db.example.internal';
    const result = await checkConnectivity({ env, connect });
    expect(result.ok).toBe(false);
    expect(result.results[0]).toMatchObject({ name: 'RDS PostgreSQL', reachable: false });
  });

  it('refuses to run without the settings it needs', async () => {
    await expect(checkConnectivity({ env: { AWS_REGION: 'ap-south-1' }, connect: async () => true })).rejects.toThrow(/DB_HOST/);
  });

  it('passes the timeout to the connector', async () => {
    const connect = vi.fn(async () => true);
    await checkConnectivity({ env, connect, timeoutMs: 1234 });
    expect(connect.mock.calls[0][2]).toBe(1234);
  });
});

describe('tcpConnect', () => {
  it('reports false for a closed local port without throwing', async () => {
    expect(await tcpConnect('127.0.0.1', 9, 1000)).toBe(false);
  });
});

describe('scripts/check-connectivity.js (child process)', () => {
  const backendDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  it('exits 1 with a clear message when its settings are missing', () => {
    const env2 = { PATH: process.env.PATH };
    if (process.env.SystemRoot) env2.SystemRoot = process.env.SystemRoot;
    const result = spawnSync(process.execPath, ['scripts/check-connectivity.js'], { cwd: backendDir, env: env2, encoding: 'utf8', timeout: 15000 });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('could not run');
    expect(result.stderr).toContain('DB_HOST');
  });
});

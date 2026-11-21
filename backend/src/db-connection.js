import { readFile } from 'node:fs/promises';

// Decides HOW the backend reaches PostgreSQL, from the environment alone.
//
//   Local development, tests, CI   DATABASE_URL (a connection string; no TLS unless it asks for it)
//   AWS (private RDS)              DB_HOST + DB_NAME + a Secrets Manager secret id + a CA file:
//                                  the user name and password are read from Secrets Manager with the
//                                  instance role at start-up, and the connection is TLS with the server
//                                  certificate and host name VERIFIED against the RDS CA bundle.
//
// The two modes are mutually exclusive, so a stray DATABASE_URL can never silently win over the
// intended RDS settings (or the other way round). Nothing in this file logs or returns a secret in an
// error message.

export class DbConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DbConfigError';
  }
}

const RDS_VARIABLES = ['DB_HOST', 'DB_SECRET_ID', 'DB_OWNER_SECRET_ID', 'DB_MASTER_SECRET_ID', 'DB_SSL_CA_FILE'];

// Which secret each database role uses. 'master' (the RDS-managed master user) exists ONLY for the bootstrap job that
// runs in CodeBuild; the application and the instance role never see it.
const SECRET_VARIABLE = { app: 'DB_SECRET_ID', owner: 'DB_OWNER_SECRET_ID', master: 'DB_MASTER_SECRET_ID' };

// The default secret reader. The AWS SDK is imported on first use, so local development, the test
// suite and the DATABASE_URL path never load it.
async function readSecretString(secretId, region) {
  const { SecretsManagerClient, GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
  const client = new SecretsManagerClient({ region });
  try {
    const result = await client.send(new GetSecretValueCommand({ SecretId: secretId }));
    return result.SecretString;
  } finally {
    client.destroy();
  }
}

export function parseCredentials(secretString, secretId) {
  let parsed;
  try {
    parsed = JSON.parse(secretString);
  } catch {
    // Never include the text: it may be the password itself.
    throw new DbConfigError(`secret ${secretId} is not valid JSON (expected {"username": ..., "password": ...})`);
  }
  const { username, password } = parsed ?? {};
  if (typeof username !== 'string' || username === '' || typeof password !== 'string' || password === '') {
    throw new DbConfigError(`secret ${secretId} must contain non-empty "username" and "password" strings`);
  }
  return { username, password };
}

function parsePort(value) {
  if (value === undefined || value === '') return 5432;
  if (!/^\d{1,5}$/.test(value) || Number(value) < 1 || Number(value) > 65535) {
    throw new DbConfigError('DB_PORT must be a number between 1 and 65535');
  }
  return Number(value);
}

/**
 * @param {object} options
 * @param {NodeJS.ProcessEnv} [options.env]
 * @param {'app'|'owner'|'master'} [options.role]  the API ('app'), migrations ('owner'), or the one-off bootstrap ('master')
 * @param {(secretId: string, region: string) => Promise<string>} [options.getSecret]  replaceable in tests
 * @param {(path: string) => Promise<string|Buffer>} [options.readCaFile]  replaceable in tests
 * @returns {Promise<string | object>} a connection string, or a node-postgres connection object
 */
export async function resolveDbConnection({
  env = process.env,
  role = 'app',
  getSecret = readSecretString,
  readCaFile = readFile,
} = {}) {
  if (!Object.hasOwn(SECRET_VARIABLE, role)) throw new DbConfigError('role must be "app", "owner" or "master"');

  const hasUrl = Boolean(env.DATABASE_URL);
  const rdsVariablesSet = RDS_VARIABLES.filter((name) => env[name]);

  if (hasUrl && rdsVariablesSet.length > 0) {
    throw new DbConfigError(
      `set either DATABASE_URL or the RDS settings, not both (also set: ${rdsVariablesSet.join(', ')})`,
    );
  }
  if (hasUrl) return env.DATABASE_URL;
  if (rdsVariablesSet.length === 0) throw new DbConfigError('DATABASE_URL is not set');

  const secretVariable = SECRET_VARIABLE[role];
  const missing = ['DB_HOST', 'DB_NAME', secretVariable, 'AWS_REGION', 'DB_SSL_CA_FILE'].filter((name) => !env[name]);
  if (missing.length > 0) {
    throw new DbConfigError(`missing database settings: ${missing.join(', ')}`);
  }

  const port = parsePort(env.DB_PORT);

  // Fail closed: a connection to RDS is never made without verifying the server certificate.
  let ca;
  try {
    ca = await readCaFile(env.DB_SSL_CA_FILE);
  } catch {
    throw new DbConfigError(`cannot read the CA bundle at DB_SSL_CA_FILE (${env.DB_SSL_CA_FILE})`);
  }
  if (ca.length === 0) throw new DbConfigError('the CA bundle at DB_SSL_CA_FILE is empty');

  const secretId = env[secretVariable];
  let secretString;
  try {
    secretString = await getSecret(secretId, env.AWS_REGION);
  } catch (err) {
    // The error name (for example AccessDeniedException) is useful and safe; the message may not be.
    throw new DbConfigError(`could not read secret ${secretId} from Secrets Manager (${err?.name ?? 'error'})`);
  }
  if (typeof secretString !== 'string' || secretString === '') {
    throw new DbConfigError(`secret ${secretId} has no string value`);
  }
  const { username, password } = parseCredentials(secretString, secretId);

  return {
    host: env.DB_HOST,
    port,
    database: env.DB_NAME,
    user: username,
    password,
    ssl: { ca, rejectUnauthorized: true, minVersion: 'TLSv1.2' },
  };
}

/**
 * Reads a {"username", "password"} secret. Used by the bootstrap job for the two application roles' secrets.
 * Never put the result in a log or an error message.
 */
export async function readCredentials(secretId, region, getSecret = readSecretString) {
  let secretString;
  try {
    secretString = await getSecret(secretId, region);
  } catch (err) {
    throw new DbConfigError(`could not read secret ${secretId} from Secrets Manager (${err?.name ?? 'error'})`);
  }
  if (typeof secretString !== 'string' || secretString === '') {
    throw new DbConfigError(`secret ${secretId} has no string value`);
  }
  return parseCredentials(secretString, secretId);
}

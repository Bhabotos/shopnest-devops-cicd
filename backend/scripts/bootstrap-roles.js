import pg from 'pg';
import { bootstrapRoles, BootstrapError, validateRoleCredentials } from '../src/bootstrap-roles.js';
import { readCredentials, resolveDbConnection } from '../src/db-connection.js';

// CodeBuild-ONLY command. It is never part of the application's start-up path, and it refuses to run anywhere else:
// the RDS master credentials exist only in the bootstrap CodeBuild project's role. Starting it takes a deliberate
// act: the operator must start the build with BOOTSTRAP_CONFIRM set to "bootstrap-<environment>".
function refuse(message) {
  console.error(`bootstrap refused: ${message}`);
  process.exit(1);
}

if (!process.env.CODEBUILD_BUILD_ID) refuse('this command runs only inside the CodeBuild bootstrap project');
const environment = process.env.BOOTSTRAP_ENVIRONMENT;
if (!environment) refuse('BOOTSTRAP_ENVIRONMENT is not set');
if (process.env.BOOTSTRAP_CONFIRM !== `bootstrap-${environment}`) {
  refuse(`start the build with BOOTSTRAP_CONFIRM=bootstrap-${environment} to confirm the target`);
}
for (const name of ['DB_SECRET_ID', 'DB_OWNER_SECRET_ID', 'AWS_REGION']) {
  if (!process.env[name]) refuse(`${name} is not set`);
}

let client;
try {
  // Read and check both application secrets first: nothing is changed if either is wrong.
  const app = await readCredentials(process.env.DB_SECRET_ID, process.env.AWS_REGION);
  const owner = await readCredentials(process.env.DB_OWNER_SECRET_ID, process.env.AWS_REGION);
  validateRoleCredentials(owner, app);

  const connection = await resolveDbConnection({ role: 'master' });
  client = new pg.Client({ ...connection, connectionTimeoutMillis: 10000, statement_timeout: 60000 });
  await client.connect();

  const report = await bootstrapRoles(client, { ownerPassword: owner.password, appPassword: app.password });
  console.log('bootstrap complete (no secret values are printed)');
  console.log(JSON.stringify(report, null, 2));
} catch (err) {
  // Only messages that this program wrote itself are printed: they never contain a secret value.
  const safe = err instanceof BootstrapError || err?.name === 'DbConfigError';
  console.error(`bootstrap failed: ${safe ? err.message : `${err?.name ?? 'Error'} (${err?.code ?? 'no code'})`}`);
  process.exitCode = 1;
} finally {
  await client?.end().catch(() => {});
}

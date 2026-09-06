import { randomBytes } from 'node:crypto';
import { open } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const defaultRepositoryRoot = path.resolve(scriptDirectory, '..', '..');

export function assertP3OutputPath(outputPath, repositoryRoot = defaultRepositoryRoot) {
  if (!path.isAbsolute(outputPath)) throw new Error('P3 environment output path must be absolute.');
  const output = path.resolve(outputPath);
  const root = path.resolve(repositoryRoot);
  const relative = path.relative(root, output);
  if (relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
    throw new Error('P3 environment output must remain outside the repository.');
  }
  return output;
}

export function buildP3Environment() {
  const dbPassword = randomBytes(48).toString('base64url');
  const encryptionKey = randomBytes(64).toString('base64url');
  const jwtSecret = randomBytes(64).toString('base64url');
  return [
    'CASCADE_N8N_DB_NAME=cascade_n8n',
    'CASCADE_N8N_DB_USER=cascade_n8n',
    `CASCADE_N8N_DB_PASSWORD=${dbPassword}`,
    `CASCADE_N8N_ENCRYPTION_KEY=${encryptionKey}`,
    `CASCADE_N8N_USER_MANAGEMENT_JWT_SECRET=${jwtSecret}`,
    'CASCADE_N8N_HOST=localhost',
    'CASCADE_N8N_PROTOCOL=http',
    'CASCADE_N8N_EDITOR_BASE_URL=http://localhost:5679',
    'CASCADE_N8N_WEBHOOK_URL=http://localhost:5679/',
    'CASCADE_N8N_PROXY_HOPS=0',
    'CASCADE_N8N_BIND_PORT=5679',
    '',
  ].join('\n');
}

export async function writeP3Environment(outputPath, repositoryRoot = defaultRepositoryRoot) {
  const output = assertP3OutputPath(outputPath, repositoryRoot);
  let handle;
  try {
    handle = await open(output, 'wx', 0o600);
    await handle.writeFile(buildP3Environment(), { encoding: 'utf8' });
  } catch (error) {
    if (error?.code === 'EEXIST') throw new Error(`P3 environment output already exists: ${output}`);
    throw error;
  } finally {
    await handle?.close();
  }
  return output;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2 || args[0] !== '--output') {
    throw new Error('Usage: node scripts/deployment/p3-environment.mjs --output <absolute-path-outside-repository>');
  }
  const output = await writeP3Environment(args[1]);
  process.stdout.write(`Created owner-controlled P3 environment file: ${output}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

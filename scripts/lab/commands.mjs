import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export async function defaultRunCommand(command, args, { cwd, env } = {}) {
  const { stdout, stderr } = await execFileAsync(command, args, {
    cwd,
    env,
    encoding: 'utf8',
    maxBuffer: 10 * 1024 * 1024,
  });
  return { stdout, stderr, exitCode: 0 };
}

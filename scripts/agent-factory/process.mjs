import { spawn } from 'node:child_process';

export function runProcess(command, args = [], options = {}) {
  const timeoutMs = options.timeoutMs ?? 30_000;

  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let settled = false;

    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ stdout, stderr, timedOut: false, ...result });
    };

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', (error) => {
      finish({ code: error.code === 'ENOENT' ? 127 : 1, stderr: `${stderr}${error.message}` });
    });
    child.on('close', (code, signal) => {
      finish({ code: code ?? 1, signal });
    });

    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 1_000).unref();
      if (!settled) {
        settled = true;
        resolve({ code: 124, stdout, stderr, timedOut: true });
      }
    }, timeoutMs);
    timer.unref();
  });
}

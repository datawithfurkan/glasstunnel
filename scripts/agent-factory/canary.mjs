import { join } from 'node:path';
import { factoryEnvironment } from './config.mjs';
import { acquireLease, listLeases, releaseLease } from './lease.mjs';
import { runProcess } from './process.mjs';

const CANARY_NODE_ID = 'foundation-canary';

async function checked(runner, command, args, options, label) {
  const result = await runner(command, args, options);
  if (result.code !== 0) {
    const detail = result.stderr.trim() || result.stdout.trim() || `exit ${result.code}`;
    throw new Error(`${label}: ${detail}`);
  }
  return result;
}

function parseObject(stdout, label) {
  try {
    const value = JSON.parse(stdout);
    if (value && typeof value === 'object') return value;
  } catch {
    // The error below avoids echoing potentially verbose runtime output.
  }
  throw new Error(`${label} did not return JSON`);
}

function parseIssueArray(stdout) {
  const value = parseObject(stdout, 'canary bead details');
  if (Array.isArray(value)) return value;
  if (Array.isArray(value.issues)) return value.issues;
  if (Array.isArray(value.data)) return value.data;
  throw new Error('Canary bead details did not return a JSON array');
}

function cleanStatus(result, label) {
  if (result.code !== 0) throw new Error(`${label}: could not inspect Git state`);
  if (result.stdout.trim()) throw new Error(`${label} must be clean before and after the canary`);
}

function verifyCanaryNodes(issues) {
  const attempts = issues
    .filter(
      (issue) =>
        issue.metadata?.['gc.step_id'] === 'controlled-retry' &&
        issue.metadata?.['gc.attempt'] !== undefined,
    )
    .map((issue) => ({
      id: issue.id,
      attempt: Number(issue.metadata['gc.attempt']),
      outcome: issue.metadata['gc.outcome'],
      failureClass: issue.metadata['gc.failure_class'] ?? null,
    }))
    .sort((left, right) => left.attempt - right.attempt);

  if (attempts.length !== 2 || attempts[0].attempt !== 1 || attempts[1].attempt !== 2) {
    throw new Error('Foundation canary did not record exactly two retry attempts');
  }
  if (attempts[0].outcome !== 'fail' || attempts[0].failureClass !== 'transient') {
    throw new Error('Foundation canary attempt one was not a controlled transient failure');
  }
  if (attempts[1].outcome !== 'pass') {
    throw new Error('Foundation canary attempt two did not pass');
  }

  const review = issues.find(
    (issue) =>
      issue.metadata?.canary_reviewed === 'true' && issue.metadata?.['gc.outcome'] === 'pass',
  );
  if (!review) throw new Error('Foundation canary independent review was not recorded');
  const integration = issues.find(
    (issue) =>
      issue.metadata?.integration_ready === 'true' && issue.metadata?.['gc.outcome'] === 'pass',
  );
  if (!integration) throw new Error('Foundation canary integration readiness was not recorded');

  return { attempts, reviewId: review.id, integrationId: integration.id };
}

function findCanaryTarget(agentList) {
  const agent = (agentList.agents ?? []).find(
    (entry) =>
      entry.name?.endsWith('canary-worker') || entry.qualified_name?.endsWith('canary-worker'),
  );
  if (!agent?.qualified_name) throw new Error('Configured canary worker was not found');
  return agent.qualified_name;
}

export async function runCanary({
  paths,
  env = process.env,
  runner = runProcess,
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  clock = () => Date.now(),
  pollIntervalMs = 2_000,
  timeoutMs = 10 * 60_000,
} = {}) {
  const processEnv = factoryEnvironment(paths, env);
  const cityOptions = { cwd: paths.city, env: processEnv, timeoutMs: 120_000 };
  const sourceOptions = { cwd: paths.source, env: processEnv, timeoutMs: 30_000 };
  const mirrorOptions = {
    cwd: join(paths.rigs, 'glasstunnel'),
    env: processEnv,
    timeoutMs: 30_000,
  };
  const initialStatus = parseObject(
    (
      await checked(
        runner,
        'gc',
        ['status', paths.city, '--json'],
        cityOptions,
        'reading initial city state',
      )
    ).stdout,
    'initial city state',
  );
  const rig = (initialStatus.rigs ?? []).find((entry) => entry.name === 'glasstunnel');
  if (!rig) throw new Error('Glasstunnel rig is not registered');
  if (initialStatus.running) {
    throw new Error('Foundation canary requires the city to be stopped');
  }
  if (!rig.suspended) {
    throw new Error('Foundation canary requires the rig to be suspended');
  }

  cleanStatus(await runner('git', ['status', '--porcelain'], sourceOptions), 'Primary checkout');
  cleanStatus(await runner('git', ['status', '--porcelain'], mirrorOptions), 'Factory mirror');

  let leaseAcquired = false;
  let startedByCanary = false;
  let resumedByCanary = false;
  let evidence;
  let operationError;
  const startedAt = clock();

  try {
    await acquireLease({
      resource: 'canary-exclusive',
      nodeId: CANARY_NODE_ID,
      holder: 'deterministic-foundation-canary',
      paths,
      runner,
      env: processEnv,
    });
    leaseAcquired = true;

    if (!initialStatus.running) {
      await checked(runner, 'gc', ['start', paths.city], cityOptions, 'starting factory city');
      startedByCanary = true;
    }
    if (rig.suspended) {
      await checked(
        runner,
        'gc',
        ['rig', 'resume', 'glasstunnel', '--json'],
        cityOptions,
        'resuming canary rig',
      );
      resumedByCanary = true;
    }

    const agents = parseObject(
      (
        await checked(
          runner,
          'gc',
          ['agent', 'list', '--json'],
          cityOptions,
          'listing configured agents',
        )
      ).stdout,
      'configured agents',
    );
    const target = findCanaryTarget(agents);
    const launch = parseObject(
      (
        await checked(
          runner,
          'gc',
          ['sling', target, 'foundation-canary', '--formula', '--no-convoy', '--json'],
          cityOptions,
          'launching foundation canary',
        )
      ).stdout,
      'foundation canary launch',
    );
    const workflowId = launch.workflow_id;
    if (!workflowId) throw new Error('Foundation canary launch did not return a workflow ID');

    let graph;
    while (clock() - startedAt <= timeoutMs) {
      graph = parseObject(
        (
          await checked(
            runner,
            'gc',
            ['graph', workflowId, '--json'],
            cityOptions,
            'reading foundation canary graph',
          )
        ).stdout,
        'foundation canary graph',
      );
      if (graph.summary?.total > 0 && graph.summary.closed === graph.summary.total) break;
      await sleep(pollIntervalMs);
    }
    if (!graph || graph.summary?.closed !== graph.summary?.total) {
      throw new Error(`Foundation canary exceeded its ${timeoutMs}ms time limit`);
    }

    const nodeIds = (graph.nodes ?? []).map((node) => node.id).filter(Boolean);
    if (nodeIds.length === 0) throw new Error('Foundation canary graph returned no nodes');
    const issues = parseIssueArray(
      (
        await checked(
          runner,
          'bd',
          ['show', ...nodeIds, '--json'],
          mirrorOptions,
          'reading foundation canary evidence',
        )
      ).stdout,
    );
    const verified = verifyCanaryNodes(issues);

    cleanStatus(await runner('git', ['status', '--porcelain'], sourceOptions), 'Primary checkout');
    cleanStatus(await runner('git', ['status', '--porcelain'], mirrorOptions), 'Factory mirror');
    evidence = {
      workflowId,
      target,
      attempts: verified.attempts,
      reviewId: verified.reviewId,
      integrationId: verified.integrationId,
      reviewed: true,
      reviewerReadOnly: true,
      integrationReady: true,
      durationMs: clock() - startedAt,
    };
  } catch (error) {
    operationError = error;
  }

  const cleanupErrors = [];
  if (resumedByCanary) {
    try {
      await checked(
        runner,
        'gc',
        ['rig', 'suspend', 'glasstunnel', '--json'],
        cityOptions,
        'restoring rig suspension',
      );
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  if (startedByCanary) {
    try {
      await checked(
        runner,
        'gc',
        ['stop', paths.city, '--timeout', '2m'],
        { ...cityOptions, timeoutMs: 150_000 },
        'stopping canary-started city',
      );
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  if (leaseAcquired) {
    try {
      await releaseLease({
        resource: 'canary-exclusive',
        nodeId: CANARY_NODE_ID,
        paths,
        runner,
        env: processEnv,
      });
    } catch (error) {
      cleanupErrors.push(error);
    }
  }

  const remaining = (await listLeases(paths)).filter(
    (lease) => lease.resource === 'canary-exclusive',
  );
  if (remaining.length > 0) cleanupErrors.push(new Error('Canary lease remained open'));
  if (operationError && cleanupErrors.length > 0) {
    throw new AggregateError([operationError, ...cleanupErrors], 'Canary failed and cleanup was incomplete');
  }
  if (operationError) throw operationError;
  if (cleanupErrors.length > 0) throw new AggregateError(cleanupErrors, 'Canary cleanup failed');
  return evidence;
}

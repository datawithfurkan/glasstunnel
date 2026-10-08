// Worker unit tests must never reach the network. The test Wrangler config points
// the account-plane gateway at a fake origin, and tests that exercise account-backed
// paths stub `fetch` themselves (see relayHub.test.ts). Any other outbound fetch fails
// fast here with a descriptive error instead of attempting a real connection.
globalThis.fetch = async (input: RequestInfo | URL): Promise<Response> => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  throw new Error(`unexpected outbound fetch in Worker tests: ${url}`);
};

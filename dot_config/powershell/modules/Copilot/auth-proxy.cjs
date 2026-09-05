// Auth lacks start's --proxy-env switch. Resolve the verified package's undici
// from its entry point; do not add a dependency or change TLS verification.
const { createRequire } = require('node:module');
const proxy = process.env.HTTPS_PROXY;
if (proxy) {
  const { ProxyAgent, setGlobalDispatcher } = createRequire(process.argv[1])('undici');
  setGlobalDispatcher(new ProxyAgent(proxy));
}

// Node 16 doesn't expose crypto as a global (that landed in Node 18+, or
// behind --experimental-global-webcrypto from Node 17.6+ — a flag Node 16
// silently ignores since it doesn't exist there). The mongodb driver's
// session/cursor cleanup code assumes globalThis.crypto is available and
// throws 'ReferenceError: crypto is not defined' otherwise, which sync.js's
// db.check_stats swallows and misreports as 'database structures missing'.
// Node 16's built-in crypto module already exposes .webcrypto — just needs
// to be promoted to a global. Loaded via NODE_OPTIONS=--require.
if (typeof globalThis.crypto === 'undefined') {
    globalThis.crypto = require('crypto').webcrypto;
}

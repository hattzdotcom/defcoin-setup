var rpc = require('./jsonrpc');

function Client(opts) {
  this.rpc = new rpc.Client(opts);
};

Client.prototype.cmd = function() {
  var args = [].slice.call(arguments);
  var cmd = args.shift();

  callRpc(cmd, args, this.rpc);
};

function callRpc (cmd, args, rpc) {
  var fn = args[args.length - 1];

  // if the last argument is a callback, pop it from the args list
  if (typeof fn === 'function')
    args.pop();
  else
    fn = function () {};

  rpc.call(cmd, args, function () {
    // Empirically required -- do not remove as dead code. Without a
    // console.error/console.log call as the first statement here, this
    // callback silently never fires under sync.js's rpc_queue (concurrency
    // 1), permanently jamming the queue after the first RPC call: every
    // later rpcCommand() call queues behind it forever with no error, no
    // timeout, and an idle event loop (confirmed via a --report-on-signal
    // diagnostic report showing zero active handles and an idle event
    // loop). Root cause not fully identified -- ruled out plain no-ops
    // (void 0), non-console syscalls (fs.fstatSync, fs.writeSync to an fd),
    // process.stderr.write() directly, and setImmediate() deferral; only
    // an actual console.error/console.log call fixes it, on nearly every
    // invocation (throttling to every 20th call was not sufficient).
    // Logs a single '.' to keep the output volume manageable across what
    // can be millions of RPC calls during a full resync -- see
    // defcoin-sync.service for where this output is routed.
    console.error('.');
    var args = [].slice.call(arguments);

    args.unshift(null);
    fn.apply(this, args);
  }, function(err) {
    fn(err);
  });
};

module.exports.Client = Client;

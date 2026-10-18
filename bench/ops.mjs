// The js-framework-benchmark keyed CPU operations: setup/warm-up clicks, then the measured click.
// Shared by tests/browser/bench.mjs (Playwright) and bench/runner.html (any browser, no automation).
const row = (i, cell) => `#tbody tr:nth-child(${i}) td:nth-child(${cell}) a`;
export const OPS = [
  { name: "create1k", desc: "create 1,000 rows", warm: ["#run", "#clear", "#run", "#clear", "#run", "#clear", "#run", "#clear", "#run", "#clear"], click: "#run" },
  { name: "replace1k", desc: "replace all 1,000 rows", warm: ["#run", "#run", "#run", "#run", "#run"], click: "#run" },
  { name: "update10th", desc: "update every 10th of 1,000 rows", warm: ["#run", "#update", "#update", "#update"], click: "#update" },
  { name: "select", desc: "highlight a row (of 1,000)", warm: ["#run", row(5, 2), row(6, 2), row(7, 2), row(8, 2), row(9, 2)], click: row(2, 2) },
  { name: "swap", desc: "swap 2 of 1,000 rows", warm: ["#run", "#swaprows", "#swaprows", "#swaprows", "#swaprows", "#swaprows"], click: "#swaprows" },
  { name: "remove", desc: "remove one of 1,000 rows", warm: ["#run", row(10, 3), row(9, 3), row(8, 3), row(7, 3), row(6, 3)], click: row(4, 3) },
  { name: "create10k", desc: "create 10,000 rows", warm: ["#runlots", "#clear"], click: "#runlots" },
  { name: "append1k", desc: "append 1,000 rows to 1,000", warm: ["#run", "#clear", "#run", "#clear", "#run"], click: "#add" },
  { name: "clear1k", desc: "clear 1,000 rows", warm: ["#run", "#clear", "#run", "#clear", "#run"], click: "#clear" },
];

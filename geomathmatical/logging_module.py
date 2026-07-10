"""logging_module.py -- forensic capture log (plan 2.4, D20).

Command-by-command record: every endpoint hit, its count, and every skipped /
out-of-scope item (no-silent-truncation). The callable matches the `log(status,
label, message)` signature tree_walker.walk expects, and also takes free-form
banner lines. In real-values mode (plan 7.1) the run is bannered loudly.
"""

import sys
import time


class Logger(object):
    def __init__(self, stream=sys.stderr, echo=True, file_path=None):
        self.stream = stream
        self.echo = echo
        self.records = []
        # Optional per-run log FILE (new file per run; a durable breadcrumb that
        # survives a session death / lab timeout and syncs cleanly to Dropbox).
        self._fh = open(file_path, "a", encoding="utf-8", newline="\n") if file_path else None

    def __call__(self, status, label="", message=""):
        self.records.append((status, label, message))
        ts = time.strftime("%H:%M:%S")
        if label:
            line = "{0}  {1:<6} {2:<28} {3}\n".format(ts, status, label, message)
        else:
            line = "{0}  {1} {2}\n".format(ts, status, message)
        if self.echo:
            # Flush every line: stderr is BLOCK-buffered when captured (not a TTY),
            # so without this a long live walk shows no output until it exits -- which
            # reads as a hang. (Run with `python -u` too when in doubt.)
            self.stream.write(line)
            self.stream.flush()
        if self._fh:
            self._fh.write(line)
            self._fh.flush()

    def banner(self, message):
        self("----", "", message)

    def counts(self):
        ok = sum(1 for s, _, _ in self.records if s == "OK")
        skip = sum(1 for s, _, _ in self.records if s.startswith("SKIP"))
        return ok, skip

"""main.py -- CLI + orchestration (plan 2.4 / section 3).

Runs the top-level phases (plan section 3):
  A connect+identify -> B/C capture -> D normalize -> E sanitize -> F audit+emit -> G teardown

Flags (plan 2.4 / 2.3):
  -u/--user           REST username (password is NEVER a CLI arg; prompted no-echo)
  --replay <dir>      offline: read fixtures from a capture folder instead of HTTP (D32)
  --no-sanitize       emit REAL values (D30, plan 7.1); gated + loud; conflicts with
                      --raw-never-written
  --raw-never-written keep even the intermediate in memory (D27)
  --phases a|ab|abc   which phases to walk (default from cfg)
  --dry-run           walk + report counts; do not write capture.json
  --config <path>     cfg location (default ./geomathmatical.cfg)
  --out <path>        capture.json output path (default ./capture.json)

Milestone status: the A/B/C walk runs end-to-end today (live or --replay). D/E/F
are stubs (normalize/sanitize/audit pass through) so the whole spine is runnable
now; each fills in on its milestone. Teardown (G) always runs.
"""

import argparse
import datetime
import os
import sys

from . import config as config_mod
from . import emit as emit_mod
from . import json_writer, normalize, sanitize, audit, tree_walker
from .capture import identity as identity_mod
from .logging_module import Logger
from .rest_client import CachingRestClient, LiveRestClient, ReplayRestClient, RestError

# --ldev-option choices (D40). The 7 REST ldevOption enum values (BS p509/p511) plus
# "all" -- our own sentinel meaning "send no ldevOption", the faithful full dump (D31).
LDEV_OPTIONS = ("defined", "undefined", "dpVolume", "luMapped", "luUnmapped",
                "externalVolume", "mappedNamespace", "all")

# Curated common-flags table. Printed on first run (the orientation moment) and reused
# as the --help epilog, so there is one source of truth. Full flag list is in --help.
COMMON_FLAGS = """\
GeoMathmatical v0 -- common flags (run with --help for the full list)
  flag                what it does                                    default
  ------------------  ----------------------------------------------  -------------
  --ldev-option OPT   which LDEVs to pull. OPT is one of:             defined
                        defined | undefined | dpVolume | luMapped |
                        luUnmapped | externalVolume | mappedNamespace
                        | all  (all = no filter, faithful dump, D31)
  --raw-dir DIR       lab-safe: write each endpoint as fetched,       (off)
                        resumable; transform later with --replay
  --replay DIR        offline: serve fixtures from a capture dir      (off)
  --no-sanitize       emit REAL identifiers (gated, loud)             (off)
  --dry-run           walk + report counts; write nothing             (off)
  --out PATH          where the sanitized capture.json is written     ./capture.json
"""


def build_parser():
    p = argparse.ArgumentParser(prog="geomathmatical",
                                description="REST array-geometry capture (v0, GRAB ONLY)",
                                epilog=COMMON_FLAGS,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-u", "--user", "--username", dest="user", default=None)
    p.add_argument("--replay", metavar="DIR", default=None,
                   help="offline: serve fixtures from a capture folder (D32)")
    p.add_argument("--raw-dir", metavar="DIR", default=None,
                   help="incremental raw collection: write each endpoint to DIR as it is "
                        "fetched (atomic; RESUMABLE -- re-run continues; survives a timeout). "
                        "Skips sanitize/emit; transform later offline with --replay DIR.")
    p.add_argument("--no-sanitize", "--real-values", dest="no_sanitize",
                   action="store_true", help="emit REAL values (D30); gated + loud")
    p.add_argument("--raw-never-written", dest="raw_never_written", action="store_true")
    p.add_argument("--phases", default=None, help="a | ab | abc (default from cfg)")
    p.add_argument("--ldev-option", dest="ldev_option", choices=LDEV_OPTIONS, default=None,
                   help="which LDEVs GET ldevs returns (D40); default 'defined' (from cfg) "
                        "skips the ~99%% NOT-DEFINED slots; 'all' sends no filter (faithful "
                        "full dump, D31)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--config", default=None)
    p.add_argument("--out", default="capture.json")
    p.add_argument("--captured-at", default=None,
                   help="override capturedAtUtc (for reproducible baselines)")
    p.add_argument("--seed", type=int, default=None,
                   help="deterministic sanitizer PRNG seed for reproducible baselines "
                        "(plan 13); omit for an OS-entropy mapping in the field")
    p.add_argument("--log-dir", metavar="DIR", default=None,
                   help="also write a per-run timestamped log file to DIR (new file each run, "
                        "flushed per line -- a durable breadcrumb that survives a session death)")
    return p


def run(argv=None):
    args = build_parser().parse_args(argv)
    log_path = None
    if args.log_dir:
        if not os.path.isdir(args.log_dir):
            os.makedirs(args.log_dir)
        log_path = os.path.join(args.log_dir, "capture_{0}.log".format(
            datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")))
    log = Logger(file_path=log_path)
    if log_path:
        log.banner("run log -> {0}".format(log_path))

    # --no-sanitize conflicts with --raw-never-written (plan 7.1).
    if args.no_sanitize and args.raw_never_written:
        log("FATAL", "", "--no-sanitize conflicts with --raw-never-written (plan 7.1)")
        return 2

    # -- config: load or first-run bootstrap (milestone 0, plan 2.3) --------
    cfg = config_mod.load_or_bootstrap(args.config)
    if cfg is None:
        if not args.replay:
            # First run: the cfg template was just written. Show the common-flags
            # table (the orientation moment) so the operator sees --ldev-option etc.
            sys.stderr.write("\n" + COMMON_FLAGS)
            return 0  # live: operator fills in the cfg and re-runs
        # --replay needs no host/username, so a first-run bootstrap should NOT stop it
        # (the F7 papercut). The template now exists -> reload it and use its defaults.
        cfg = config_mod.load_or_bootstrap(args.config)

    phases = (args.phases or cfg.phases or "all")
    # LDEV filter (D40): CLI wins, else cfg, else 'defined'. 'all' -> no ldevOption.
    ldev_option = (args.ldev_option or cfg.ldev_option or "defined")

    # -- build the client: replay (offline) or live (HTTP) ------------------
    if args.replay:
        log.banner("REPLAY mode -- fixtures from {0} (no array)".format(args.replay))
        client = ReplayRestClient(args.replay, log=log)
    else:
        # Banner BEFORE resolving the password: getpass blocks with no output, so a
        # missing GEOM_PASSWORD would otherwise look like a silent hang here.
        log.banner("LIVE mode -- https://{0}/ConfigurationManager".format(cfg.host))
        if not config_mod.password_from_env():
            log.banner("resolving credentials (prompting; set {0} to run hands-free)".format(
                config_mod.ENV_PASSWORD))
        try:
            username, password = config_mod.resolve_password(cfg, cli_username=args.user)
        except ValueError as e:
            log("FATAL", "", str(e))
            return 2
        if config_mod.password_from_env():
            log.banner("password taken from {0} env (hidden testing/automation path)".format(
                config_mod.ENV_PASSWORD))
        client = LiveRestClient(cfg.host, username, password,
                                timeout_s=cfg.http_timeout_s, retries=cfg.retries, log=log)

    if args.raw_dir:
        client = CachingRestClient(client, args.raw_dir, log=log)
        log.banner("RAW COLLECTION -> {0} (incremental + resumable; transform later with "
                   "--replay {0})".format(args.raw_dir))

    if args.no_sanitize:
        log.banner("*** REAL-VALUES MODE (--no-sanitize): output carries REAL identifiers ***")

    # -- G teardown always runs (plan section 3 / 9) -----------------------
    try:
        log.banner("opening session (login + token) ...")
        if not client.open_session():
            log("FATAL", "", "could not open a session")
            return 2

        # A/B/C: walk the capture map into the raw tree (plan 2.2). An
        # unrecoverable read (401 past re-login budget, or a transient error past
        # the retry budget) raises RestError -- we abort rather than write a
        # capture that silently dropped an endpoint (D20 / plan 9).
        log.banner("Walk -- Phase A/B/C ({0}); ldevOption={1}".format(phases, ldev_option))
        tree = tree_walker.walk(client, phases=phases, page_count=cfg.page_count,
                                ldev_option=ldev_option, log=log)

        # A identity for the source header (D25).
        ident = identity_mod.resolve(
            tree,
            prefix_override=cfg.get("target", "prefix_override"),
            model_override=cfg.get("target", "model_override"),
        )
        api_ver = identity_mod.api_version(tree)
        # Log the model + confidence, NOT the raw serial: the forensic log may
        # accompany a report off-site, and the real serial lives only in the
        # on-site mapping (D20). The capture header carries the pseudonym.
        log("OK", "identity", "{0} ({1}); serial in on-site mapping".format(
            ident.model, ident.confidence))
    except RestError as e:
        log("FATAL", e.label, "capture aborted -- {0}".format(e))
        return 4
    finally:
        client.close_session()
        log.banner("Session closed (teardown)")

    # Raw collection mode stops here: the raw files are already on disk (incrementally).
    # Transform is a separate, offline, no-time-pressure step (survives lab timeouts).
    if args.raw_dir:
        log.banner("raw collection done: {0} fetched, {1} served from cache -> {2}".format(
            getattr(client, "fetched", 0), getattr(client, "hits", 0), args.raw_dir))
        log.banner("transform offline: python -m geomathmatical --replay {0} --out capture.json".format(
            args.raw_dir))
        return 0

    real_serial = ident.serial   # real, for the on-site mapping filename only

    # D: normalize -> E: sanitize -> assemble -> F: audit (plan section 3).
    # These post-walk transforms are silent AND slow at scale (sanitize/serialize
    # tens of thousands of LDEVs), so banner each -- otherwise the run looks hung
    # here after the last endpoint line.
    log.banner("normalize + {0} ...".format(
        "sanitize" if not args.no_sanitize else "REAL-VALUES (no sanitize)"))
    ntree = normalize.normalize(tree, ident)
    applied = not args.no_sanitize
    if applied:
        stree, mapping = sanitize.sanitize(ntree, seed=args.seed)
        # Pseudonymize the header serial through the SAME map as the tree, so
        # source.serial matches the storageDeviceId tails inside the capture.
        ident.serial = mapping.serial_bare(ident.serial)
    else:
        stree, mapping = ntree, None

    captured_at = args.captured_at or (
        datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))
    log.banner("assembling capture object ...")
    capture = emit_mod.assemble(stree, ident, api_ver, captured_at,
                                sanitize_applied=applied, audit_result=None)

    # F: pre-export survivor scan on the ASSEMBLED capture (plan 9). If any real
    # identifier survived, FAIL and do not write the capture; still write the
    # (redacted) report so the operator can locate the leak on-site.
    log.banner("audit (pre-export survivor scan) ...")
    audit_res = audit.audit(capture, mapping, skip=not applied)
    if not audit_res.passed:
        log("FATAL", "audit", "{0} survivor(s) -- refusing to write the capture "
            "(plan 9); see audit_report".format(audit_res.survivors))
        if not args.dry_run:
            _write_report(audit_res, args, log)
        return 3
    if applied:
        capture["sanitization"]["audit"] = {
            "patternsScanned": audit_res.patterns_scanned,
            "survivors": audit_res.survivors,
        }

    ok, skip = log.counts()
    audit_line = "audit skipped (real-values)" if audit_res.skipped else \
        "audit {0} patterns, {1} survivors".format(audit_res.patterns_scanned, audit_res.survivors)
    log.banner("Captured {0} endpoint(s), {1} skipped; outOfModel {2}; {3}".format(
        ok, skip, len(capture["outOfModel"]), audit_line))

    if args.dry_run:
        log.banner("--dry-run: capture + mapping NOT written")
        return 0

    log.banner("serializing + writing capture to {0} ...".format(args.out))
    json_writer.dump(capture, args.out)
    log.banner("Wrote {0}".format(args.out))
    if applied:
        _write_mapping(mapping, real_serial, cfg, args, log)
        _write_report(audit_res, args, log)
    return 0


def _write_report(audit_res, args, log):
    """Write audit_report.json (REDACTED -- safe to leave site; plan 9/12)."""
    out_dir = os.path.dirname(os.path.abspath(args.out)) or "."
    path = os.path.join(out_dir, "audit_report.json")
    json_writer.dump(audit_res.report(), path)
    log.banner("Wrote audit report {0} ({1} survivors)".format(path, audit_res.survivors))


def _write_mapping(mapping, real_serial, cfg, args, log):
    """Write the on-site real->pseudonym key (plan 7 / D20). Never exported."""
    mapping_dir = (cfg.get("output", "mapping_dir") or "").strip()
    if not mapping_dir:
        mapping_dir = os.path.dirname(os.path.abspath(args.out)) or "."
    path = os.path.join(mapping_dir, "mapping.{0}.json".format(real_serial or "unknown"))
    json_writer.dump(mapping.to_dict(), path)
    try:
        os.chmod(path, 0o600)   # restrictive perms where the OS honors them
    except OSError:
        pass
    log.banner("Wrote on-site mapping {0} -- KEEP ON-SITE, never export".format(path))


if __name__ == "__main__":
    sys.exit(run())

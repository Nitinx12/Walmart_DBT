"""
Entry point for building and running the Great Expectations suites across
all three layers (bronze / silver / gold) of the pipeline.

Layout this assumes (see context.py's and each suites/*.py's own
docstrings for the same caveat): `pipeline/data_quality/` holds this file
and `context.py`; `pipeline/data_quality/suites/` holds `bronze_suites.py`
/ `silver_suites.py` / `gold_suites.py` as a proper subpackage (i.e. with
an `__init__.py`). Adjust the three `from pipeline.data_quality.suites...`
imports below if your actual layout differs. Run this as
    python -m pipeline.data_quality.run [--layer {bronze,silver,gold,all}]
from the repo root -- not by `cd`-ing into `pipeline/data_quality/` and
running `run.py` directly, for the same reason the suite modules' own
docstrings call out (relative imports need `pipeline` importable as a
top-level package).

What this does, per requested layer:
  1. Calls every `*_validation()` function in that layer's
     `ALL_*_VALIDATIONS` list. Each call is the suite module's own
     `_build()` helper running `add_or_update` -- so this both creates the
     suites/validation definitions on first run and reconciles them
     against the in-code expectations on every later run, never
     duplicating anything. A single bad suite (e.g. a typo'd column name)
     is caught and logged per-table rather than crashing the whole layer.
  2. Bundles the resulting ValidationDefinitions into one Checkpoint per
     layer (`bronze_checkpoint` / `silver_checkpoint` / `gold_checkpoint`),
     via the same add_or_update-on-a-named-object pattern the suites use,
     so re-running this script doesn't pile up duplicate Checkpoints.
  3. Runs the checkpoint and logs a PASS/FAIL line per table, plus (for
     failures) which expectation(s) failed and how many rows violated
     them.

Exit codes (meant to be checked by whatever calls this, not just read off
stdout -- e.g. `python -m pipeline.data_quality.run || alert-something`):
  0 = every table in every requested layer passed.
  1 = the run completed but at least one expectation failed -- the data
      itself looks bad.
  2 = at least one layer's checkpoint couldn't be built/run at all (bad
      connection, missing table, etc.) -- distinct from 1 because it means
      "we don't know if the data is good," not "the data is bad." Treat 2
      as more urgent than 1 in an orchestrator: it means the check itself
      is broken, not just the thing being checked.

By default all requested layers run even if an earlier one fails or
errors, since seeing every layer's status in one invocation is more
useful for debugging than stopping early. Pass --fail-fast for the old
stop-on-first-red behavior (e.g. a pre-load gate where there's no point
checking silver if bronze already failed).

ASSUMPTIONS on the Great Expectations API surface (this targets the 1.x
Fluent-context API the suite files already use -- `context.suites.
add_or_update`, `gx.ValidationDefinition`, `context.validation_
definitions.add` -- so this file follows the same generation). Verify
these against your installed `great_expectations` version on first run,
since result-object attribute names have moved around across GX releases:
  - `checkpoint.run()` returns an object with `.success` (bool) and
    `.run_results` (a dict of per-table `ExpectationSuiteValidationResult`
    objects, iterated here via `.values()` since dict key order isn't
    assumed to match input order).
  - Each of those has `.success`, `.suite_name`, and `.results` (a list of
    per-expectation results, each with `.success`, `.expectation_config.
    type`, `.expectation_config.kwargs`, and a `.result` dict containing
    `unexpected_count` at the default result_format).
  - No `actions=[...]` (e.g. an UpdateDataDocsAction) are attached to the
    Checkpoints built here, to avoid assuming your installed GX version's
    exact action import path. Add one if you want Data Docs rebuilt on
    every run -- see the GX docs for the current class location.
"""

import argparse
import logging
import sys
from dataclasses import dataclass, field

import great_expectations as gx

from pipeline.data_quality.context import get_context
from pipeline.data_quality.suites.bronze_suites import ALL_BRONZE_VALIDATIONS
from pipeline.data_quality.suites.gold_suites import ALL_GOLD_VALIDATIONS
from pipeline.data_quality.suites.silver_suites import ALL_SILVER_VALIDATIONS
from utils.logger import get_logger

# Unlike the suite modules (which set console_level=logging.WARNING because
# they're meant to be imported as libraries called from here), this is the
# actual CLI entry point -- its own progress and results should show up on
# the console by default, not just in whatever log file utils.logger also
# writes to.
log = get_logger("data_quality.run", console_level=logging.INFO)

# Bronze -> silver -> gold order, preserved via dict insertion order below --
# also the sensible --fail-fast order, since there's little point checking
# silver/gold if the bronze data they're built from already failed.
LAYERS = {
    "bronze": ALL_BRONZE_VALIDATIONS,
    "silver": ALL_SILVER_VALIDATIONS,
    "gold": ALL_GOLD_VALIDATIONS,
}

EXIT_OK = 0
EXIT_VALIDATION_FAILED = 1
EXIT_RUN_ERROR = 2


@dataclass
class LayerResult:
    layer: str
    ran: bool  # False if the checkpoint never executed (build/connection error)
    success: bool = False
    passed_tables: list = field(default_factory=list)
    failed_tables: list = field(default_factory=list)  # [(table, [failure summaries]), ...]


def _build_validation_definitions(layer: str, validation_fns: list) -> list:
    """Call each `*_validation()` function for a layer, returning the
    resulting ValidationDefinitions. A single suite raising (e.g. a typo'd
    column name that doesn't exist in the live table) is logged and
    skipped rather than taking down the whole layer's run."""
    validation_definitions = []
    for validation_fn in validation_fns:
        table_label = validation_fn.__name__.removesuffix("_validation")
        try:
            validation_definitions.append(validation_fn())
        except Exception:
            log.exception(f"[{layer}] failed to build suite for '{table_label}' -- skipping it")
    return validation_definitions


def _run_layer(layer: str, validation_fns: list) -> LayerResult:
    context = get_context()
    validation_definitions = _build_validation_definitions(layer, validation_fns)

    if not validation_definitions:
        log.error(f"[{layer}] no validation definitions could be built -- skipping this layer")
        return LayerResult(layer=layer, ran=False)

    checkpoint_name = f"{layer}_checkpoint"
    log.info(f"[{layer}] running '{checkpoint_name}' ({len(validation_definitions)} tables)")
    try:
        checkpoint = context.checkpoints.add_or_update(
            gx.Checkpoint(name=checkpoint_name, validation_definitions=validation_definitions)
        )
        checkpoint_result = checkpoint.run()
    except Exception:
        log.exception(f"[{layer}] checkpoint '{checkpoint_name}' did not complete")
        return LayerResult(layer=layer, ran=False)

    result = LayerResult(layer=layer, ran=True, success=checkpoint_result.success)
    for validation_result in checkpoint_result.run_results.values():
        table_label = validation_result.suite_name.removeprefix(f"{layer}_").removesuffix("_suite")
        if validation_result.success:
            result.passed_tables.append(table_label)
            log.info(f"[{layer}] PASS  {table_label}")
        else:
            failures = [
                f"{r.expectation_config.type} on "
                f"'{r.expectation_config.kwargs.get('column', '?')}' "
                f"({r.result.get('unexpected_count', '?')} unexpected)"
                for r in validation_result.results
                if not r.success
            ]
            result.failed_tables.append((table_label, failures))
            log.error(f"[{layer}] FAIL  {table_label} -- " + "; ".join(failures))

    return result


def _log_summary(results: list) -> None:
    log.info("=" * 60)
    for result in results:
        if not result.ran:
            log.info(f"{result.layer:<8} DID NOT RUN")
            continue
        total = len(result.passed_tables) + len(result.failed_tables)
        status = "" if result.success else "  <-- FAILED"
        log.info(f"{result.layer:<8} {len(result.passed_tables)}/{total} tables passed{status}")
        for table, failures in result.failed_tables:
            for failure in failures:
                log.info(f"    - {table}: {failure}")
    log.info("=" * 60)


def run(layers: list, fail_fast: bool = False) -> int:
    results = []
    for layer in layers:
        result = _run_layer(layer, LAYERS[layer])
        results.append(result)
        if fail_fast and (not result.ran or not result.success):
            log.warning(f"--fail-fast: stopping after '{layer}'")
            break

    _log_summary(results)

    if any(not r.ran for r in results):
        return EXIT_RUN_ERROR
    if not all(r.success for r in results):
        return EXIT_VALIDATION_FAILED
    return EXIT_OK


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run Great Expectations suites for the pipeline.")
    parser.add_argument(
        "--layer",
        choices=["bronze", "silver", "gold", "all"],
        default="all",
        help="Which layer to validate (default: all).",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="Stop after the first layer that errors or fails, instead of checking every requested layer.",
    )
    args = parser.parse_args(argv)

    layers = list(LAYERS) if args.layer == "all" else [args.layer]

    try:
        return run(layers, fail_fast=args.fail_fast)
    except Exception:
        log.exception("data quality run did not complete")
        return EXIT_RUN_ERROR


if __name__ == "__main__":
    sys.exit(main())
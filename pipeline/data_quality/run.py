"""
Builds and runs the Great Expectations suites for all three pipeline
layers (bronze / silver / gold).

Layout: `pipeline/data_quality/` holds this file + `context.py`;
`pipeline/data_quality/suites/` holds `bronze_suites.py` / `silver_suites.py`
/ `gold_suites.py` as a subpackage. Run from the repo root:
    python -m pipeline.data_quality.run [--layer {bronze,silver,gold,all}]

Per requested layer, this:
  1. Calls every `*_validation()` fn in that layer's `ALL_*_VALIDATIONS`
     list (each does an `add_or_update`, so re-runs reconcile rather than
     duplicate). A single bad suite is caught/logged, not fatal.
  2. Bundles the results into one Checkpoint per layer via the same
     add_or_update pattern, so re-runs don't pile up duplicates.
  3. Runs the checkpoint and logs PASS/FAIL per table, with per-expectation
     failure detail.

Exit codes:
  0 = everything passed.
  1 = ran fine, but at least one expectation failed (bad data).
  2 = at least one layer's checkpoint couldn't be built/run at all (broken
      check, not just bad data) -- treat as more urgent than 1.

All requested layers run by default even if an earlier one fails, for a
full status picture. Pass --fail-fast to stop at the first red layer.

Targets the GX 1.x Fluent-context API (`context.suites.add_or_update`,
`gx.ValidationDefinition`, etc.) -- verify against your installed GX
version, since result-object attribute names shift across releases.
No `actions=[...]` are attached to these Checkpoints; add one (e.g.
UpdateDataDocsAction) if you want Data Docs rebuilt on every run.
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

# CLI entry point (unlike the suite modules, which log at WARNING as
# importable libraries) -- show progress on the console by default.
log = get_logger("data_quality.run", console_level=logging.INFO)

# Bronze -> silver -> gold order, also the --fail-fast order.
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
    failed_tables: list = field(
        default_factory=list
    )  # [(table, [failure summaries]), ...]


def _build_validation_definitions(layer: str, validation_fns: list) -> list:
    """Call each `*_validation()` fn for a layer; a single one raising
    (e.g. typo'd column) is logged and skipped, not fatal."""
    validation_definitions = []
    for validation_fn in validation_fns:
        table_label = validation_fn.__name__.removesuffix("_validation")
        try:
            validation_definitions.append(validation_fn())
        except Exception:
            log.exception(
                f"[{layer}] failed to build suite for '{table_label}' -- skipping it"
            )
    return validation_definitions


def _describe_failure(r) -> str:
    """Describe one failed expectation result. If it failed because rows
    genuinely violated it, report the count. If it failed because the
    expectation itself errored (e.g. comparing a string column against a
    numeric min/max), `result` is empty and the real cause is in
    `exception_info` -- surface that instead of a bare '?'."""
    exc = getattr(r, "exception_info", None)
    if exc and exc.get("raised_exception"):
        return f"ERRORED: {exc.get('exception_message', 'unknown error')}"
    count = r.result.get("unexpected_count", r.result.get("unexpected_percent"))
    return f"{count if count is not None else '?'} unexpected"


def _run_layer(layer: str, validation_fns: list) -> LayerResult:
    context = get_context()
    validation_definitions = _build_validation_definitions(layer, validation_fns)

    if not validation_definitions:
        log.error(
            f"[{layer}] no validation definitions could be built -- skipping this layer"
        )
        return LayerResult(layer=layer, ran=False)

    checkpoint_name = f"{layer}_checkpoint"
    log.info(
        f"[{layer}] running '{checkpoint_name}' ({len(validation_definitions)} tables)"
    )
    try:
        checkpoint = context.checkpoints.add_or_update(
            gx.Checkpoint(
                name=checkpoint_name, validation_definitions=validation_definitions
            )
        )
        checkpoint_result = checkpoint.run()
    except Exception:
        log.exception(f"[{layer}] checkpoint '{checkpoint_name}' did not complete")
        return LayerResult(layer=layer, ran=False)

    result = LayerResult(layer=layer, ran=True, success=checkpoint_result.success)
    for validation_result in checkpoint_result.run_results.values():
        table_label = validation_result.suite_name.removeprefix(
            f"{layer}_"
        ).removesuffix("_suite")
        if validation_result.success:
            result.passed_tables.append(table_label)
            log.info(f"[{layer}] PASS  {table_label}")
        else:
            failures = [
                f"{r.expectation_config.type} on "
                f"'{r.expectation_config.kwargs.get('column', '?')}' "
                f"({_describe_failure(r)})"
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
        log.info(
            f"{result.layer:<8} {len(result.passed_tables)}/{total} tables passed{status}"
        )
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
    parser = argparse.ArgumentParser(
        description="Run Great Expectations suites for the pipeline."
    )
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

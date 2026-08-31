"""
Bronze-layer expectation suites.

One function per table, each returning a `great_expectations.ValidationDefinition`
ready to hand to a Checkpoint. Kept table-specific (rather than one generic
loop) because the meaningful checks differ per table — a generic "not null
on every column" pass would miss the checks that actually catch bad data
(negative prices, zero quantities, orphaned foreign keys can't be checked
here since GX validates one table at a time).

Notes on the schema as provided:
  - `_id` is the Mongo source ObjectId (text) — kept for lineage, not
    validated here.
  - `created_timestamp` / `updated_timestamp` are stored as `text`, not a
    native timestamp type — validated as not-null only; add a regex/format
    expectation once you confirm the exact string format coming out of Mongo.
  - `is_active` is `text`, not boolean, and uses the source system's `Y`/`N`
    flags. The expectations below preserve that representation in Bronze;
    Silver and Gold convert it to native booleans.

NOTE on the import below: `from pipeline.data_quality.context import ...`
only resolves if `pipeline` is importable as a top-level package, which
means (a) the repo root is on sys.path and (b) `pipeline/__init__.py`
exists. Run these modules from the repo root, e.g.:
    python -m pipeline.data_quality.run
not by `cd`-ing into this folder and running the file directly — that's
almost certainly the "ModuleNotFoundError: No module named 'pipeline'"
you're hitting from the `suites/` directory in your terminal session.
"""

import logging

import great_expectations as gx

from pipeline.data_quality.context import get_bronze_asset, get_context
from utils.logger import get_logger

log = get_logger("data_quality.bronze_suites", console_level=logging.WARNING)


def _build(table_name: str, suite_name: str, expectations: list) -> gx.ValidationDefinition:
    context = get_context()
    asset = get_bronze_asset(table_name)

    batch_definition_name = f"{table_name}_batch"
    existing_batch_defs = {bd.name for bd in asset.batch_definitions}
    batch_definition = (
        asset.get_batch_definition(batch_definition_name)
        if batch_definition_name in existing_batch_defs
        else asset.add_batch_definition_whole_table(batch_definition_name)
    )

    # `add_or_update` creates the suite if it's new and otherwise reconciles
    # its expectations against the ones passed in (keeping stable IDs for
    # unchanged expectations) instead of blindly appending on every call --
    # which is what the old add()-once / get()-then-loop-add_expectation()
    # pattern risked doing every time this function ran against an
    # already-existing suite.
    log.info(f"Building suite '{suite_name}' ({len(expectations)} expectations)")
    suite = context.suites.add_or_update(
        gx.core.expectation_suite.ExpectationSuite(name=suite_name, expectations=expectations)
    )

    validation_name = f"{table_name}_validation"
    existing_validations = {v.name for v in context.validation_definitions.all()}
    if validation_name in existing_validations:
        return context.validation_definitions.get(validation_name)

    log.info(f"Creating validation definition '{validation_name}'")
    validation_definition = gx.ValidationDefinition(
        data=batch_definition, suite=suite, name=validation_name
    )
    return context.validation_definitions.add(validation_definition)


def customers_validation() -> gx.ValidationDefinition:
    return _build(
        "customers",
        "bronze_customers_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="customer_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="email"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="first_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="last_name"),
            gx.expectations.ExpectColumnValuesToBeInSet(
                column="is_active", value_set=["Y", "N"]
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="created_timestamp"),
        ],
    )


def employees_validation() -> gx.ValidationDefinition:
    return _build(
        "employees",
        "bronze_employees_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="employee_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="employee_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="salary", min_value=0),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="job_title"),
            gx.expectations.ExpectColumnValuesToBeInSet(
                column="is_active", value_set=["Y", "N"]
            ),
        ],
    )


def orders_validation() -> gx.ValidationDefinition:
    return _build(
        "orders",
        "bronze_orders_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="order_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="total_amount", min_value=0),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_status"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method"),
        ],
    )


def order_items_validation() -> gx.ValidationDefinition:
    return _build(
        "order_items",
        "bronze_order_items_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_item_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="order_item_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="quantity", min_value=1),
            gx.expectations.ExpectColumnValuesToBeBetween(column="unit_price", min_value=0),
            gx.expectations.ExpectColumnValuesToBeBetween(column="line_amount", min_value=0),
        ],
    )


def products_validation() -> gx.ValidationDefinition:
    return _build(
        "products",
        "bronze_products_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="product_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_name"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="price", min_value=0),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category"),
        ],
    )


def stores_validation() -> gx.ValidationDefinition:
    return _build(
        "stores",
        "bronze_stores_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="store_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="city"),
            gx.expectations.ExpectColumnValuesToBeInSet(
                column="is_active", value_set=["Y", "N"]
            ),
        ],
    )


ALL_BRONZE_VALIDATIONS = [
    customers_validation,
    employees_validation,
    orders_validation,
    order_items_validation,
    products_validation,
    stores_validation,
]

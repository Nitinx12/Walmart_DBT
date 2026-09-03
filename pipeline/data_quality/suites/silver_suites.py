"""
Silver-layer expectation suites.

One function per table, mirroring `bronze_suites.py`'s structure (same
`_build()` helper, same "reconcile via add_or_update" pattern) but against
the silver schema, which differs from bronze in a few ways that change
what's worth asserting here:

  - `is_active` is a real `boolean` column in silver, not `text`. Bronze's
    suites had to assert `expect_column_values_to_be_in_set(["true",
    "false"])` as a stand-in for a type check; silver doesn't need that --
    the column type already rules out garbage values, so these suites just
    assert not-null instead.
  - `created_timestamp` / `updated_timestamp` are native `timestamp
    without time zone` columns here, not `text`, so (unlike bronze) there's
    no pending follow-up to add a format/regex expectation later.
  - Three lookup tables that don't exist in bronze -- `brands`,
    `categories`, `payment_methods` -- back new foreign keys that replace
    denormalized text columns from bronze: `products.category` (text) is
    now `products.category_id` / `products.brand_id`, and
    `orders.payment_method` (text) is now `orders.payment_method_id`.
  - Every silver table has `silver_loaded_at`, stamped by the silver load
    step itself, so it should always be non-null regardless of source data
    quality -- a failure there points at the load job, not upstream data.

ASSUMPTIONS to confirm against your actual data before relying on these
in a Checkpoint that blocks downstream loads:
  - `brand_id` / `category_id` on `products`, and `payment_method_id` on
    `orders`, are asserted not-null on the assumption that every row is
    fully resolved against its dimension table by the time it reaches
    silver. If unmatched/unresolved rows are expected to land here with a
    null FK (e.g. "brand unknown" is valid), drop those two
    not-null expectations rather than have the suite fail on legitimate
    data.
  - Referential integrity (e.g. every `products.brand_id` actually exists
    in `brands`) is NOT checked here -- GX validates one table/batch at a
    time, so cross-table FK checks need a separate multi-table check
    (e.g. a SQL-based custom expectation or a dbt test) rather than
    anything in this suite.
  - Dimension-table name columns (`brand_name`, `category_name`,
    `payment_method_name`) are asserted unique on the assumption the
    source dedupes lookup values; relax that if you expect legitimate
    duplicate labels with different IDs.

Same import caveat as bronze_suites.py: run via `python -m
pipeline.data_quality.run` from the repo root, not by executing this file
directly from inside `suites/`.
"""

import logging

import great_expectations as gx
from pipeline.data_quality.context import get_context, get_silver_asset
from utils.logger import get_logger

log = get_logger("data_quality.silver_suites", console_level=logging.WARNING)


def _build(
    table_name: str, suite_name: str, expectations: list
) -> gx.ValidationDefinition:
    context = get_context()
    asset = get_silver_asset(table_name)

    # Prefixed with "silver_" (unlike bronze_suites.py's bare f"{table_name}_batch")
    # only for readability here -- batch definitions live on the asset itself,
    # so a bronze asset and a silver asset for the same table_name can't collide
    # regardless of naming.
    batch_definition_name = f"silver_{table_name}_batch"
    existing_batch_defs = {bd.name for bd in asset.batch_definitions}
    batch_definition = (
        asset.get_batch_definition(batch_definition_name)
        if batch_definition_name in existing_batch_defs
        else asset.add_batch_definition_whole_table(batch_definition_name)
    )

    log.info(f"Building suite '{suite_name}' ({len(expectations)} expectations)")
    suite = context.suites.add_or_update(
        gx.core.expectation_suite.ExpectationSuite(
            name=suite_name, expectations=expectations
        )
    )

    # Unlike batch definitions, validation definitions ARE registered globally
    # on the context (context.validation_definitions.all() below is unscoped),
    # and bronze_suites.py already claims e.g. "customers_validation" for the
    # bronze customers table -- so this MUST be prefixed with "silver_" or it
    # would silently collide with (and return) bronze's validation definition
    # for every table name the two layers share.
    validation_name = f"silver_{table_name}_validation"
    existing_validations = {v.name for v in context.validation_definitions.all()}
    if validation_name in existing_validations:
        return context.validation_definitions.get(validation_name)

    log.info(f"Creating validation definition '{validation_name}'")
    validation_definition = gx.ValidationDefinition(
        data=batch_definition, suite=suite, name=validation_name
    )
    return context.validation_definitions.add(validation_definition)


def brands_validation() -> gx.ValidationDefinition:
    return _build(
        "brands",
        "silver_brands_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="brand_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="brand_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="brand_name"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="brand_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def categories_validation() -> gx.ValidationDefinition:
    return _build(
        "categories",
        "silver_categories_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="category_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category_name"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="category_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def payment_methods_validation() -> gx.ValidationDefinition:
    return _build(
        "payment_methods",
        "silver_payment_methods_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="payment_method_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method_name"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="payment_method_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def customers_validation() -> gx.ValidationDefinition:
    return _build(
        "customers",
        "silver_customers_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="customer_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="email"),
            # Basic shape check only ("something@something.something") -- not
            # a full RFC 5322 validation, just enough to catch obviously
            # malformed values that slipped past upstream validation.
            gx.expectations.ExpectColumnValuesToMatchRegex(
                column="email", regex=r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="created_timestamp"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def employees_validation() -> gx.ValidationDefinition:
    return _build(
        "employees",
        "silver_employees_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="employee_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="employee_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="employee_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="job_title"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="salary", min_value=0),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def orders_validation() -> gx.ValidationDefinition:
    return _build(
        "orders",
        "silver_orders_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="order_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_status"),
            # Replaces bronze's denormalized `payment_method` text column.
            # See module docstring's ASSUMPTIONS note before relying on this.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="total_amount", min_value=0
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_timestamp"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def order_items_validation() -> gx.ValidationDefinition:
    return _build(
        "order_items",
        "silver_order_items_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_item_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="order_item_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="quantity", min_value=1
            ),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="unit_price", min_value=0
            ),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="line_amount", min_value=0
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def products_validation() -> gx.ValidationDefinition:
    return _build(
        "products",
        "silver_products_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="product_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_name"),
            # Replace bronze's denormalized `category` text column.
            # See module docstring's ASSUMPTIONS note before relying on these.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="brand_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="price", min_value=0),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


def stores_validation() -> gx.ValidationDefinition:
    return _build(
        "stores",
        "silver_stores_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="store_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="city"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="silver_loaded_at"),
        ],
    )


ALL_SILVER_VALIDATIONS = [
    brands_validation,
    categories_validation,
    payment_methods_validation,
    customers_validation,
    employees_validation,
    orders_validation,
    order_items_validation,
    products_validation,
    stores_validation,
]

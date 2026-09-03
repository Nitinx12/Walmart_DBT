"""
Gold-layer expectation suites.

One function per table, mirroring `bronze_suites.py` / `silver_suites.py`'s
structure (same `_build()` helper, same "reconcile via add_or_update"
pattern) but against the gold star schema, which differs from silver in a
few ways that change what's worth asserting here:

  - Gold is a conformed star schema: `dim_brands`, `dim_categories`,
    `dim_customers`, `dim_payment_methods`, `dim_products`, and
    `dim_stores` are dimensions; `dim_orders` carries order-grain
    attributes and measures (`total_amount`, `order_status`, ...);
    `fact_order_items` is the line-item grain fact table
    (`quantity` / `unit_price` / `line_amount`). There's no separate
    "fact_orders" table -- order-level measures live on `dim_orders`
    itself.
  - `is_active` and the `*_timestamp` columns keep the native `boolean` /
    `timestamp` types they had in silver -- same reasoning as silver's
    docstring: no text-based stand-in checks needed here.
  - Every gold table has `gold_loaded_at` (`timestamp with time zone`),
    stamped by the gold load step itself, asserted not-null the same way
    silver asserts `silver_loaded_at` -- a failure there points at the
    load job, not upstream data.
  - `employees` does not appear anywhere in the gold schema (no
    `dim_employees`, nothing downstream built from it), even though both
    bronze and silver carry it. Confirm that's an intentional exclusion
    from the published star schema before treating this file's table
    coverage as incomplete -- there's no `employees_validation()` here
    because there's no gold table to point it at.

ASSUMPTIONS to confirm against your actual data before relying on these
in a Checkpoint that blocks downstream loads/BI consumption:
  - Referential integrity (e.g. every `fact_order_items.order_id` exists
    in `dim_orders`, every `dim_products.brand_id` exists in
    `dim_brands`) is NOT checked here, same limitation as bronze/silver --
    GX validates one table/batch at a time, so cross-table FK checks need
    a separate multi-table check (a SQL-based custom expectation or a dbt
    test) rather than anything in this suite.
  - `dim_customers.country` and `dim_stores.country` are asserted
    not-null on the assumption every conformed dimension row is fully
    geo-resolved by the time it reaches gold. `phone` / `phone_extension`
    on `dim_customers` are left unchecked since they read as optional
    contact fields, not required ones -- add a not-null expectation for
    either if your source actually treats them as required.
  - `line_amount` is NOT cross-checked against `quantity * unit_price`
    here (same as bronze/silver) -- that's a cross-column consistency
    check, not a single-column one. Add an
    `ExpectColumnPairValuesToBeEqual`-style or SQL-based expectation
    separately if you want that enforced.

Same import caveat as bronze_suites.py / silver_suites.py: run via
`python -m pipeline.data_quality.run` from the repo root, not by
executing this file directly from inside `suites/`.
"""

import logging

import great_expectations as gx
from pipeline.data_quality.context import get_context, get_gold_asset
from utils.logger import get_logger

log = get_logger("data_quality.gold_suites", console_level=logging.WARNING)


def _build(
    table_name: str, suite_name: str, expectations: list
) -> gx.ValidationDefinition:
    context = get_context()
    asset = get_gold_asset(table_name)

    # Prefixed with "gold_" for readability only, same as silver's
    # "silver_" prefix -- batch definitions live on the asset itself, so
    # they can't collide across layers regardless of naming.
    batch_definition_name = f"gold_{table_name}_batch"
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

    # validation_definitions are registered globally on the context (see
    # silver_suites.py's comment on this same line) -- gold's table names
    # (dim_*/fact_*) don't currently collide with bronze/silver's bare
    # table names, but prefixing with "gold_" keeps that true even if a
    # future bronze/silver table gets renamed to match one of these.
    validation_name = f"gold_{table_name}_validation"
    existing_validations = {v.name for v in context.validation_definitions.all()}
    if validation_name in existing_validations:
        return context.validation_definitions.get(validation_name)

    log.info(f"Creating validation definition '{validation_name}'")
    validation_definition = gx.ValidationDefinition(
        data=batch_definition, suite=suite, name=validation_name
    )
    return context.validation_definitions.add(validation_definition)


def dim_brands_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_brands",
        "gold_dim_brands_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="brand_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="brand_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="brand_name"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="brand_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def dim_categories_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_categories",
        "gold_dim_categories_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="category_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category_name"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="category_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def dim_payment_methods_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_payment_methods",
        "gold_dim_payment_methods_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="payment_method_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method_name"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="payment_method_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def dim_customers_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_customers",
        "gold_dim_customers_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="customer_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="email"),
            # Same shape-only check as silver_suites.py's customers suite --
            # not a full RFC 5322 validation, just enough to catch obviously
            # malformed values.
            gx.expectations.ExpectColumnValuesToMatchRegex(
                column="email", regex=r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            # phone/phone_extension deliberately left unchecked -- see
            # module docstring's ASSUMPTIONS note.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="country"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="created_timestamp"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def dim_stores_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_stores",
        "gold_dim_stores_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="store_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_name"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="city"),
            # See module docstring's ASSUMPTIONS note on country not-null.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="country"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def dim_products_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_products",
        "gold_dim_products_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="product_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_name"),
            # FKs to dim_brands / dim_categories -- see module docstring's
            # ASSUMPTIONS note; referential integrity itself isn't checked here.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="brand_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="category_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(column="price", min_value=0),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def dim_orders_validation() -> gx.ValidationDefinition:
    return _build(
        "dim_orders",
        "gold_dim_orders_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="order_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="store_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="customer_id"),
            # FK to dim_payment_methods -- see module docstring's
            # ASSUMPTIONS note.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="payment_method_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_status"),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="total_amount", min_value=0
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_timestamp"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


def fact_order_items_validation() -> gx.ValidationDefinition:
    return _build(
        "fact_order_items",
        "gold_fact_order_items_suite",
        [
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_item_id"),
            gx.expectations.ExpectColumnValuesToBeUnique(column="order_item_id"),
            # FKs to dim_orders / dim_products -- see module docstring's
            # ASSUMPTIONS note; referential integrity itself isn't checked here.
            gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="product_id"),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="quantity", min_value=1
            ),
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="unit_price", min_value=0
            ),
            # NOT cross-checked against quantity * unit_price -- see module
            # docstring's ASSUMPTIONS note.
            gx.expectations.ExpectColumnValuesToBeBetween(
                column="line_amount", min_value=0
            ),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="is_active"),
            gx.expectations.ExpectColumnValuesToNotBeNull(column="gold_loaded_at"),
        ],
    )


ALL_GOLD_VALIDATIONS = [
    dim_brands_validation,
    dim_categories_validation,
    dim_payment_methods_validation,
    dim_customers_validation,
    dim_stores_validation,
    dim_products_validation,
    dim_orders_validation,
    fact_order_items_validation,
]

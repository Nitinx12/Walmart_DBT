
```
walmart
├─ .dockerignore
├─ airflow
├─ docker
│  └─ Dockerfile
├─ jars
│  ├─ bson-5.1.4.jar
│  ├─ bson-record-codec-5.1.4.jar
│  ├─ mongo-spark-connector_2.12-10.4.0.jar
│  ├─ mongodb-driver-core-5.1.4.jar
│  ├─ mongodb-driver-sync-5.1.4.jar
│  └─ postgresql.jar
├─ main.py
├─ pipeline
│  └─ run_pipeline.ps1
├─ pyproject.toml
├─ README.md
├─ scripts
│  ├─ extract.py
│  └─ sql_test.py
├─ sql
│  └─ 00_init_schema.sql
├─ tests
│  ├─ bronze
│  │  ├─ 01_lp_check_bronze_tables.sql
│  │  ├─ 02_lp_check_columns_exist.sql.sql
│  │  └─ 03_lp_check_metadata_columns.sql
│  ├─ gold
│  │  ├─ 01_lp_check_not_empty.sql
│  │  ├─ 02_lp_check_date_ranges.sql
│  │  ├─ 03_lp_check_duplicates.sql
│  │  ├─ 04_lp_check_negative.sql
│  │  ├─ 05_lp_check_referential_integrity.sql
│  │  ├─ 06_lp_check_unwanted_spaces.sql
│  │  └─ 07_row_count_validation.sql
│  └─ silver
│     ├─ 01_lp_check_duplicates.sql
│     ├─ 02_lp_check_nulls.sql
│     ├─ 03_lp_check_numeric_format.sql
│     ├─ 04_lp_check_negative_values.sql
│     ├─ 05_lp_check_foreign_keys.sql
│     ├─ 06_lp_check_date_ranges.sql
│     ├─ 07_lp_check_domain_values.sql
│     ├─ 09_lp_check_unwanted_spaces.sql
│     └─ 10_lp_check_business_rules.sql
├─ utils
│  ├─ connection.py
│  ├─ engine.py
│  └─ logger.py
├─ uv.lock
└─ walmart_dbt
   ├─ analyses
   ├─ dbt_project.yml
   ├─ macros
   │  └─ generate_schema.sql
   ├─ models
   │  ├─ bronze
   │  │  └─ soucre.yml
   │  ├─ gold
   │  │  ├─ dim_brands.sql
   │  │  ├─ dim_categories.sql
   │  │  ├─ dim_customers.sql
   │  │  ├─ dim_orders.sql
   │  │  ├─ dim_payment_methods.sql
   │  │  ├─ dim_products.sql
   │  │  ├─ dim_stores.sql
   │  │  ├─ fact_order_items.sql
   │  │  └─ scgema.yml
   │  └─ silver
   │     ├─ brands.sql
   │     ├─ categories.sql
   │     ├─ customers.sql
   │     ├─ employees.sql
   │     ├─ orders.sql
   │     ├─ order_items.sql
   │     ├─ payment_methods.sql
   │     ├─ products.sql
   │     ├─ schema.yml
   │     └─ stores.sql
   ├─ package-lock.yml
   ├─ packages.yml
   ├─ README.md
   ├─ seeds
   ├─ snapshots
   └─ tests
      └─ generic
         ├─ test_accepted_range.sql
         ├─ test_matches_regex.sql
         └─ test_no_orphan_rows.sql

```
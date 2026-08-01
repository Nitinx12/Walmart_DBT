
```
walmart
├─ jars
│  ├─ bson-5.1.4.jar
│  ├─ bson-record-codec-5.1.4.jar
│  ├─ mongo-spark-connector_2.12-10.4.0.jar
│  ├─ mongodb-driver-core-5.1.4.jar
│  ├─ mongodb-driver-sync-5.1.4.jar
│  └─ postgresql.jar
├─ main.py
├─ pyproject.toml
├─ README.md
├─ scripts
│  └─ extract.py
├─ sql
├─ utils
│  ├─ connection.py
│  ├─ engine.py
│  ├─ logger.py
│  └─ __inti__.py
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
   │  └─ silver
   │     ├─ brands.sql
   │     ├─ categories.sql
   │     ├─ customers.sql
   │     ├─ employees.sql
   │     ├─ orders.sql
   │     ├─ order_items.sql
   │     ├─ payments_methods.sql
   │     ├─ products.sql
   │     ├─ schema.yml
   │     └─ stores.sql
   ├─ package-lock.yml
   ├─ packages.yml
   ├─ README.md
   ├─ seeds
   ├─ snapshots
   └─ tests
      └─ genric
         ├─ test_accepted_range.sql
         └─ test_matches_regex.sql

```
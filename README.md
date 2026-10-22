# Phoenix

The dbt project for the Revolution Dance enterprise data warehouse. It lands D365 F&O, Centric PLM, BigCommerce and Salesforce data in Databricks and builds a medallion model: bronze → silver → gold. The gold layer is the certified contract for reporting and analysis.

- **Specs:** Confluence, DATA space. Table and view specifications and Decision Records are the source of truth for field catalogs and business rules.
- **Work tracking:** Jira, project EDW.
- **Repo:** `NickRevDance/phoenix`. Work happens on the dev branch in the dbt Cloud IDE and merges to `main` by PR.

---

## 1. Environments and schemas

| | Prod | Dev |
|---|---|---|
| Catalog | `phoenix_prod_catalog` | `phoenix_dev_catalog` |
| `target.schema` | `prod` | `dbt_<developer>` |
| `target.name` | `default` | — |
| Job | Prod Daily: one `dbt build` step, nightly | IDE runs |

`generate_schema_name` builds every schema as `<target.schema>_<folder schema>`:

| Folder / config | Prod schema | Dev schema |
|---|---|---|
| `models/bronze` | `prod_bronze` | `dbt_<developer>_bronze` |
| `models/silver` | `prod_silver` | `dbt_<developer>_silver` |
| `models/gold` | `prod_gold` | `dbt_<developer>_gold` |
| `models/staging` | `prod_staging` | `dbt_<developer>_staging` |
| `seeds/` | `prod_seeds` | `dbt_<developer>_seeds` |
| snapshots | `prod_silver_history` | `dbt_<developer>_silver_history` |
| test failures and run log | `prod_dq_exceptions` | `dbt_<developer>_dq_exceptions` |

Rules:

- **Switch on `target.schema`.** Environment conditionals test `target.schema == 'prod'`. `target.name` is `default` in prod and can't tell the environments apart.
- **Dev and prod read the same raw data.** The D365, Centric and BigCommerce sources (`dwhvisualnext`) and Salesforce (`prod_raw`) are shared, so dev data matches prod. Whenever prod needs a full refresh, dev needs one too. Only the `refs` source switches: it reads `dev_raw` in dev.
- **New models build into plain `gold`.** Don't add sub-schemas such as `shared_gold` or `marketing_gold`.

---

## 2. Repository layout

```
analyses/
macros/                 shared macros and generic tests
models/
  bronze/   bronze_*    thin passthrough of each source table
  silver/   silver_*    cleaned, typed, joined; silver_stage_* feed snapshots and gold
  gold/     dim_*, fact_*, ref_*, v_*   the certified layer
  staging/  sources.yml (every source), stg_* models between a seed and gold
seeds/                  business-maintained CSVs, each with a .yml of column types
snapshots/silver/       dbt snapshots, one .yml each
tests/                  singular tests
dbt_project.yml         folder configs, data-quality settings, project vars
packages.yml            dbt_utils
```

- **Sources:** all of them are declared in `models/staging/sources.yml`.
- **One yml per model:** each model's yml sits beside it in the same folder.
- **Retired files:** move them to a top-level `archive/` folder beside `models/`. dbt parses every `.sql` and `.yml` under `models/`, `seeds/` and `snapshots/`, so a retired file left there can still break compile.

---

## 3. Build conventions

### Layers

| Layer | Naming | Materialization | Rules |
|---|---|---|---|
| Bronze | `bronze_<source_table>` | table | `select * from source()`. No renames, no filters. |
| Silver | `silver_<description>`, `silver_stage_<entity>` | table; incremental merge for large, slowly changing D365 transaction tables | Clean, cast, join. `silver_stage_<entity>` is the shaped input to a snapshot or a gold model. Gold always reads silver, never bronze. |
| Gold | `dim_<entity>`, `fact_<entity>`, `ref_<entity>`, `v_<entity>_<purpose>` | tables; `v_*` are views | Certified contract. `v_<entity>_current` is the consumer-facing current-row view of an SCD2 table. |

### Sourcing

- **Native D365 tables, not data entities.** BYOD exports both with the same `…Staging` naming:
  - Native tables have terse AOT names (`InventSum`, `InventDim`, `VendTable`).
  - Data entities have versioned, business-style names (`…V2Staging`).
  - Where only an entity carries a needed column, flag it rather than using it by default.
- **Reuse before you build.** Use an existing bronze or silver model before writing a new `source()` read.
- **Use governed gold models for attributes.** Read product, customer, vendor and warehouse attributes from the gold dimension, not its silver feed.

### SQL style

- **Alias every column** (`t.col`) in every layer, even when it isn't ambiguous.
- **Keyword case:**
  - Bronze and silver use uppercase keywords and keep raw D365 column names in their source case.
  - Gold uses lowercase keywords and a chain of named CTEs ending in `select * from final`.
- **Leading commas.**
- **Columns with no source:** `cast(null as <type>) as col -- Source once available: <where>`. Never a bare `null`, which types the column `VOID` in Delta and breaks a later incremental merge.
- **Comments:** short. One or two lines on a decision. No narrative blocks, no machine or folder paths, and no references to who reviewed what.
- **Databricks specifics:**
  - Backticks for special-character columns (`` `Style#` ``).
  - No `TIME` type: cast to string.
- **Boolean vs int flags:** they differ by table, so cast explicitly (`cast(x as boolean)`) rather than comparing to `true` or `1`.

### Keys

- **Surrogate keys:** `{{ generate_surrogate_key([...]) }}` (xxhash64 → bigint).
  - Build them from native source identifiers (D365 `RECID` / `REC`), not derived fields such as sequence counters or classifications.
  - Key a fact on the line's own RECID when the business key can repeat in D365.
- **`product_key`:** `md5(UPC)`, a string, at UPC grain. `product_id` (the D365 ItemId) is coarser, so joining an item-grain source to `dim_product` on `product_id` fans out.
- **Product resolution, the barcode path.** Every fact that carries a product resolves it through the D365 item barcode table: item + size + colour, read through `silver_d365_inventory_dim`, → UPC → `dim_product`. The barcode table's own `INVENTDIMID` is a reference-level record and doesn't join directly.
- **Reserved members:** hardcoded literals unioned into each dimension, never hashed. `-1` = Unknown (a value existed but didn't resolve); `0` = Not applicable / none by design. Facts coalesce misses to `-1` and keep the raw identifier so a miss stays diagnosable.
- **Fact key resolution:** facts resolve a dimension key against its latest version (`version_number = 1`). Consumer views that need what's current today filter `is_current_row = 1`.

### Amounts, types and currency

- **Computed amounts:** wrap computed money and quantity columns in `{{ amount(expr) }}` (decimal(38,6)). Delta can't change an existing column's decimal precision, so an incremental fact must keep one stable type.
- **Exchange rates:** come from the D365 spot table and are rebuilt into contiguous ranges. The first range reaches back to 1900-01-01 and the last stays open.
- **Placeholder dates:** a D365 placeholder date (1900-01-01) maps to the `dim_date` Unknown member, `-1`.

### Incremental models

- `incremental_strategy = 'merge'` on the model's key, `on_schema_change = 'sync_all_columns'`.
- Each run re-reads source rows modified within a lookback window (default 2 days) of the newest `etl_source_modified_datetime` already loaded.
- **Self-heal:** facts re-pull rows that still hold an Unknown key, so they resolve once the dimension catches up.
- **Insert-only columns:** values held once written use `merge_update_columns` / `merge_exclude_columns`, or read the existing row back in.
- **Empty extracts:** silver tables over BYOD extracts that can arrive empty mid-reload use `empty_extract_guard()`.

### Project variables

| Var | Purpose |
|---|---|
| `inventory_non_merchandise_items` | D365 service items that carry stock but aren't inventory positions. `CAT-%` items are excluded by pattern. Add items here, not in SQL. |
| `inventory_movement_lookback_days` | Incremental lookback for the inventory movement fact. |
| `inventory_movement_anomaly_qty_threshold` | Absolute quantity at which a movement leg is flagged as a keying anomaly. |
| `order_line_lookback_days` | Incremental lookback for the order line fact. |
| `inventory_demand_window_days` | Trailing demand window for the inventory metrics view. |

---

## 4. SCD2 standard

Every Type 2 table has four stages:

1. **`silver_stage_<entity>`** (table). This is where all joins and cleaning happen. Its last column is `<entity>_change_hash`, a hash of the Type 2 attributes only: never the business key, never a Type 1 attribute.
2. **`snapshots/silver/silver_snapshot_<entity>.yml`** in `silver_history`. Its config:
   - `strategy: check`, `check_cols: [<entity>_change_hash]`
   - `unique_key` = the business-key hash
   - `hard_deletes: invalidate`
   - the meta columns remapped to `effective_start_datetime`, `effective_end_datetime`, `row_hash` and `etl_update_datetime`
3. **`dim_<entity>`** (gold table).
   - Reads the snapshot and adds `version_number` (`scd2_version_number()`) and `is_current_row` (`scd2_is_current_row()`).
   - Type 1 attributes are read from the current stage row and applied to every version.
   - Reserved members are unioned in.
4. **`v_<entity>_current`** (gold view). Selects `is_current_row = 1` and strips the SCD2 and internal columns.

Rules:

- **Current = latest version and an open end date.** Under `hard_deletes: invalidate`, a record deleted at the source keeps `version_number = 1` on a closed row.
- **`is_current_row` is int 1/0.**
- **Never `--full-refresh` a snapshot, or drop its table, in prod.** That discards captured history permanently. A change to `check_cols` or the hash is a deliberate history reset.
- **No separate snapshot step.** `dbt build` runs seeds, snapshots, models and tests in DAG order.

---

## 5. Seed-managed reference tables

- **Where they live:** business-maintained tables are CSV seeds in `seeds/`, each with a `.yml` that loads every column as string.
- **Typing:** a `silver_stage_ref_*` model, or the gold model, casts the real types.
- **Seed names:** a seed's name must never equal the gold model it feeds. Use `sla_target` for gold `ref_sla_target`, and so on. If the names match, dbt binds the gold model's tests to the seed.
- **Two kinds:**
  - **Effective-dated:** settings and targets that change over time. They follow the convention below.
  - **Classification:** mappings with no history. A correction is a row edit, and a code with no row lands on a documented default and is caught by a test.

### Effective-dating convention

Every effective-dated reference table uses this shape:

- **`is_active`:** int 1/0, kept in the seed. 1 marks the row in force. It's never derived in the model.
- **Dates:** `effective_start_date` and `effective_end_date`, both `date`, both not null. The current row's end date is `9999-12-31`, never NULL.
- **Tests:** one active row per natural key. Effective windows don't overlap.
- **Current view:** where one is wanted, it's `select * … where is_active = 1`.

Snapshot-built SCD2 tables follow Section 4 instead.

### Changing a seed

1. **Edit the CSV.** Don't overwrite a row that was in force. Set its `is_active` to 0 and its end date to the day before the change, then add a new row with `is_active` = 1, the new start date and `9999-12-31` as the end date. Fix a mis-keyed value in place.
2. **Record the source** of the change in `notes`.
3. **Build in dev:** run `dbt build -s <seed>+`, then merge. `dbt build` reloads seeds in prod.
4. **Back-dated versions:** a version dated in the past needs a full refresh of any incremental model that reads the table as of a date.

---

## 6. Data quality framework

- **Failing rows** are stored for every test (`+store_failures: true`) in `<target.schema>_dq_exceptions.<test_name>`, refreshed each run.
- **Run log:** `log_test_run_results` (on-run-end) appends one row per test per invocation to `dq_test_run_log` in the same schema.
- **Views:**
  - `v_dq_open_exceptions`: tests flagged on their latest run.
  - `v_dq_exception_history`: full non-passing history.
  - Built in the same invocation as the tests, they show the previous invocation's results.
- **Severity:**
  - A known, source-driven, self-limiting gap gets a threshold: `severity: warn`, `warn_if: ">0"`, `error_if: ">N"`.
  - A real invariant, such as key validity or a relationship that must always resolve, stays `error`.
  - A warn test is how a data-quality exception is raised without failing the job.

Generic tests in `macros/`:

| Test | Checks |
|---|---|
| `is_valid_key` | not_null + unique on a primary or business key |
| `one_current_row_per_key` | exactly one current row per natural key on an SCD2 table |
| `no_overlapping_effective_periods` | effective windows don't overlap within a key |
| `relationship_coverage` | every value of a parent column is referenced at least once, the reverse of `relationships` |

---

## 7. Macros

| Macro | Purpose |
|---|---|
| `generate_surrogate_key(cols)` | Project key recipe: xxhash64 → bigint over natural-key columns only. |
| `generate_row_hash(exprs)` | SCD2 change hash, with one delimiter and hash function for the whole project. |
| `unknown_member_key()` / `default_member_key()` | The literals `-1` / `0` for reserved dimension rows. |
| `scd2_version_number(...)`, `scd2_is_current_row(...)` | SCD2 control columns: latest = 1; current = latest with an open end. |
| `amount(expr)` | Casts to decimal(38,6). |
| `empty_extract_guard(relation, min_rows)` | Keeps a silver table's last good contents when its extract is mid-reload. |
| `inventory_snapshot_branch_label(branch)`, `inventory_snapshot_native_start_date()` | Branch labels and seam date for the inventory snapshot fact. Always filter branches through these, never a string literal. |
| `log_test_run_results(results)` | On-run-end data-quality log writer. |
| `drop_orphaned_relations(dry_run=true)` | Finds, and optionally drops, tables and views in project schemas that nothing builds any more. |
| `generate_schema_name` | `<target.schema>_<folder schema>`. |

---

## 8. Sources

| Source | Location | Contents |
|---|---|---|
| `byod` | `dwhvisualnext.d365_byod` | D365 BYOD staging tables (inventory, product, sales, purchasing, vendor and party, pricing and cost, exchange rates). |
| `d365_reflection` | `dwhvisualnext.d365_reflection` | D365 reflection feeds (item coverage). |
| `dwhvisualnext` | `dwhvisualnext.analytics` | Centric PLM product master; legacy inventory history. |
| `dwhvisualnext_dimensions` | `dwhvisualnext.dw` | Legacy date dimension. |
| `bc` | `dwhvisualnext.bc` | BigCommerce customers and customer groups. |
| `SFDC` | `phoenix_prod_catalog.prod_raw` | Salesforce accounts and cases. |
| `refs` | `prod_raw` / `dev_raw` | BI-maintained reference tables. |
| `dq_internal` | `<target.schema>_dq_exceptions` | `dq_test_run_log`. |

---

## 9. Running and deploying

### Workflow

1. Edit on the dev branch in the dbt Cloud IDE and build with `dbt build -s <model>+`.
2. Commit and open a PR to `main`. Keep commit and PR messages short.
3. After merge, Prod Daily picks the change up on its next run.
4. When prod needs a full refresh, run the same full refresh in dev.

### Full-refresh rules

| Model | Full refresh |
|---|---|
| `fact_inventory_snapshot_daily` | **Never in prod.** It can only produce today, so a full refresh destroys accumulated history. Correct history in place (MERGE / INSERT / DELETE, after a backup clone), and keep `etl_insert_datetime` on corrected rows. New columns reach prod through `on_schema_change = 'append_new_columns'`. |
| Snapshots (`silver_snapshot_*`) | **Never in prod.** |
| `fact_inventory_movement` | Safe. Silver holds every leg. |
| `fact_inventory_quality_code_color_daily` | Safe. It rebuilds from the snapshot fact. Needed after a back-dated rule or threshold version. |
| Sales and order facts | Safe, but columns that are held once written (for example segment and standard cost) restate to today's values. |
| Tables and views | Rebuild every run. |

### Changing an incremental model

- **New columns:** `sync_all_columns` adds and drops columns, but existing rows stay NULL in a new column until they're re-merged or the model is full-refreshed.
- **Decimal precision:** it can't change on an existing Delta column, so use `amount()` from the start.
- **A `VOID` column** can be retyped in place with `ALTER TABLE … ALTER COLUMN … TYPE …`, no full refresh needed.

### Housekeeping

- After renaming or retiring models, run `dbt run-operation drop_orphaned_relations` as a dry run, then with `--args '{dry_run: false}'`.
- Keep Prod Daily as a single `dbt build` step.

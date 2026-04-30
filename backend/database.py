"""DB engine + lightweight migration.

We're not on Alembic yet (yet), but `SQLModel.metadata.create_all` only
creates tables that don't exist — it WILL NOT add columns to a table that
already exists. That broke prod when we added subtitle/level/badge/etc.

`migrate_add_missing_columns()` runs after `create_all`: it inspects each
table the metadata describes and ALTER TABLEs in any column that's in the
model but missing from the live schema. Idempotent — safe to run on every
boot. SQLite + Postgres only (which is all we ship to). Once we have
non-trivial data migrations (renames, type changes, backfills), switch to
Alembic.
"""
from sqlalchemy import inspect, text
from sqlmodel import SQLModel, create_engine, Session

from config import settings

engine = create_engine(
    settings.database_url,
    connect_args={"check_same_thread": False} if "sqlite" in settings.database_url else {},
)


def _column_ddl(col) -> str:
    """Render a column as ALTER TABLE-friendly DDL fragment."""
    type_str = col.type.compile(dialect=engine.dialect)
    parts = [col.name, type_str]
    if not col.nullable:
        # New columns must allow NULL on existing rows; if the model said
        # NOT NULL, we still add as NULLABLE to avoid breaking existing rows.
        # The application layer enforces non-null going forward.
        pass
    return " ".join(parts)


def migrate_add_missing_columns() -> list[str]:
    """ALTER TABLE … ADD COLUMN for every model field missing in the live DB.
    Returns a list of DDL strings actually executed (for logging).
    """
    executed: list[str] = []
    insp = inspect(engine)
    for table in SQLModel.metadata.sorted_tables:
        if not insp.has_table(table.name):
            continue  # create_all will handle it
        existing_cols = {c["name"] for c in insp.get_columns(table.name)}
        for col in table.columns:
            if col.name in existing_cols:
                continue
            ddl = f'ALTER TABLE "{table.name}" ADD COLUMN {_column_ddl(col)}'
            with engine.begin() as conn:
                conn.execute(text(ddl))
            executed.append(ddl)
    return executed


def migrate_add_missing_indexes() -> list[str]:
    """Create any Index() in the model metadata that's missing in the live DB.

    `create_all` only creates indexes when it creates the parent table, so
    indexes added later (e.g. EarnedBadge unique constraints) need explicit
    creation. `Index.create(..., checkfirst=True)` is a no-op if the index
    already exists.
    """
    created: list[str] = []
    insp = inspect(engine)
    for table in SQLModel.metadata.sorted_tables:
        if not insp.has_table(table.name):
            continue
        existing = {ix["name"] for ix in insp.get_indexes(table.name)}
        for index in table.indexes:
            if index.name in existing:
                continue
            try:
                index.create(bind=engine, checkfirst=True)
                created.append(f"CREATE INDEX {index.name} ON {table.name}")
            except Exception as e:
                # Most likely cause: existing duplicate rows preventing a
                # UNIQUE index from being created. Don't crash the boot —
                # log and continue; ops can dedupe + retry.
                import logging
                logging.getLogger(__name__).warning(
                    "skipping index %s: %s", index.name, e
                )
    return created


def create_db_and_tables():
    SQLModel.metadata.create_all(engine)
    added_cols = migrate_add_missing_columns()
    added_idx  = migrate_add_missing_indexes()
    if added_cols or added_idx:
        import logging
        log = logging.getLogger(__name__)
        for ddl in added_cols + added_idx:
            log.info("migration: %s", ddl)


def get_session():
    with Session(engine) as session:
        yield session

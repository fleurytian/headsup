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


def create_db_and_tables():
    SQLModel.metadata.create_all(engine)
    added = migrate_add_missing_columns()
    if added:
        import logging
        log = logging.getLogger(__name__)
        for ddl in added:
            log.info("migration: %s", ddl)


def get_session():
    with Session(engine) as session:
        yield session

"""
DatabaseConnection - core class for managing DB connections and running queries.

Supported backends:
    - SQL Server  (via pyodbc)
    - PostgreSQL  (via psycopg2)
    - MySQL       (via mysql-connector-python)
    - SQLite      (built-in)
"""

import logging
import os
import sqlite3
from contextlib import contextmanager
from typing import Any, Dict, Generator, List, Optional, Union
from urllib.parse import urlparse

from .exceptions import ConfigurationError, ConnectionError, QueryError
from .query import QueryResult

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _rows_to_dicts(cursor) -> tuple[List[dict], List[str]]:
    """Convert cursor rows to list-of-dicts plus a column name list."""
    if cursor.description is None:
        return [], []
    columns = [col[0] for col in cursor.description]
    rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    return rows, columns


# ---------------------------------------------------------------------------
# DatabaseConnection
# ---------------------------------------------------------------------------

class DatabaseConnection:
    """
    A simple, reusable database connection wrapper.

    Supports SQL Server, PostgreSQL, MySQL, and SQLite.
    Can be used as a context manager (with-statement) or standalone.

    Usage — SQL Server:
        db = DatabaseConnection(
            dialect="sqlserver",
            server="myserver",
            database="mydb",
            username="sa",
            password="secret",
        )
        result = db.query("SELECT TOP 10 * FROM orders")

    Usage — PostgreSQL:
        db = DatabaseConnection(
            dialect="postgresql",
            host="localhost",
            port=5432,
            database="mydb",
            username="postgres",
            password="secret",
        )

    Usage — SQLite:
        db = DatabaseConnection(dialect="sqlite", database="/path/to/db.sqlite3")

    Usage — from a connection string:
        db = DatabaseConnection.from_url("postgresql://user:pass@host:5432/dbname")

    Usage — as a context manager (auto-closes):
        with DatabaseConnection(...) as db:
            result = db.query("SELECT * FROM products")
    """

    SUPPORTED_DIALECTS = ("sqlserver", "postgresql", "mysql", "sqlite")

    def __init__(
        self,
        dialect: str,
        database: str,
        host: str = "localhost",
        port: Optional[int] = None,
        username: Optional[str] = None,
        password: Optional[str] = None,
        # SQL Server specific
        server: Optional[str] = None,
        driver: str = "ODBC Driver 17 for SQL Server",
        trusted_connection: bool = False,
        # General
        connect_timeout: int = 30,
        autocommit: bool = True,
        ssl: bool = False,
        extra_kwargs: Optional[Dict[str, Any]] = None,
    ):
        """
        Parameters
        ----------
        dialect : str
            One of: "sqlserver", "postgresql", "mysql", "sqlite"
        database : str
            Database name, or file path for SQLite.
        host : str
            Hostname or IP. Defaults to "localhost".
        port : int, optional
            Port number. Defaults per dialect if omitted.
        username : str, optional
            Database username.
        password : str, optional
            Database password.
        server : str, optional
            SQL Server alias for host (either works).
        driver : str
            ODBC driver string for SQL Server.
        trusted_connection : bool
            Use Windows authentication for SQL Server.
        connect_timeout : int
            Connection timeout in seconds.
        autocommit : bool
            Whether to autocommit after each statement.
        ssl : bool
            Enable SSL/TLS for PostgreSQL or MySQL.
        extra_kwargs : dict, optional
            Additional keyword arguments passed directly to the driver.
        """
        dialect = dialect.lower().strip()
        if dialect not in self.SUPPORTED_DIALECTS:
            raise ConfigurationError(
                f"Unsupported dialect '{dialect}'. "
                f"Choose from: {', '.join(self.SUPPORTED_DIALECTS)}"
            )

        self.dialect = dialect
        self.database = database
        self.host = server or host          # "server" is SQL Server shorthand
        self.port = port
        self.username = username
        self.password = password
        self.driver = driver
        self.trusted_connection = trusted_connection
        self.connect_timeout = connect_timeout
        self.autocommit = autocommit
        self.ssl = ssl
        self.extra_kwargs = extra_kwargs or {}

        self._conn = None

    # ------------------------------------------------------------------
    # Factory: build from a URL string
    # ------------------------------------------------------------------

    @classmethod
    def from_url(cls, url: str, **kwargs) -> "DatabaseConnection":
        """
        Create a DatabaseConnection from a connection URL.

        Supported formats:
            postgresql://user:pass@host:5432/dbname
            mysql://user:pass@host:3306/dbname
            sqlite:///path/to/file.db
            mssql+pyodbc://user:pass@server/dbname

        Extra keyword arguments are forwarded to __init__.
        """
        parsed = urlparse(url)
        scheme = parsed.scheme.split("+")[0].lower()

        dialect_map = {
            "postgresql": "postgresql",
            "postgres":   "postgresql",
            "pg":         "postgresql",
            "mysql":      "mysql",
            "sqlite":     "sqlite",
            "mssql":      "sqlserver",
            "sqlserver":  "sqlserver",
        }

        dialect = dialect_map.get(scheme)
        if dialect is None:
            raise ConfigurationError(f"Cannot determine dialect from URL scheme '{scheme}'.")

        if dialect == "sqlite":
            db_path = parsed.path.lstrip("/") or ":memory:"
            return cls(dialect="sqlite", database=db_path, **kwargs)

        return cls(
            dialect=dialect,
            host=parsed.hostname or "localhost",
            port=parsed.port,
            database=parsed.path.lstrip("/"),
            username=parsed.username,
            password=parsed.password,
            **kwargs,
        )

    @classmethod
    def from_env(cls, prefix: str = "DB", **kwargs) -> "DatabaseConnection":
        """
        Build a connection from environment variables.

        Reads:
            {PREFIX}_DIALECT   (required)
            {PREFIX}_HOST
            {PREFIX}_PORT
            {PREFIX}_DATABASE
            {PREFIX}_USERNAME
            {PREFIX}_PASSWORD

        Example:
            Set DB_DIALECT=postgresql, DB_HOST=localhost, etc.
            db = DatabaseConnection.from_env()
        """
        def env(key, default=None):
            return os.environ.get(f"{prefix}_{key}", default)

        dialect = env("DIALECT")
        if not dialect:
            raise ConfigurationError(
                f"Environment variable {prefix}_DIALECT is required."
            )

        port_str = env("PORT")
        return cls(
            dialect=dialect,
            host=env("HOST", "localhost"),
            port=int(port_str) if port_str else None,
            database=env("DATABASE", ""),
            username=env("USERNAME"),
            password=env("PASSWORD"),
            **kwargs,
        )

    # ------------------------------------------------------------------
    # Connection management
    # ------------------------------------------------------------------

    def connect(self) -> "DatabaseConnection":
        """Open the database connection. Returns self for chaining."""
        if self._conn is not None:
            return self     # already connected
        try:
            self._conn = self._build_connection()
            logger.debug("Connected to %s/%s", self.dialect, self.database)
        except Exception as exc:
            raise ConnectionError(
                f"Failed to connect to {self.dialect} database '{self.database}': {exc}"
            ) from exc
        return self

    def disconnect(self):
        """Close the database connection."""
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
            finally:
                self._conn = None
                logger.debug("Disconnected from %s/%s", self.dialect, self.database)

    def is_connected(self) -> bool:
        """Return True if a live connection is held."""
        return self._conn is not None

    # ------------------------------------------------------------------
    # Query execution
    # ------------------------------------------------------------------

    def query(
        self,
        sql: str,
        params: Optional[Union[tuple, list, dict]] = None,
    ) -> QueryResult:
        """
        Execute a SELECT query and return a QueryResult.

        Parameters
        ----------
        sql : str
            The SQL query to execute. Use ? (or %s for PG/MySQL) as placeholders.
        params : tuple | list | dict, optional
            Bind parameters for the query (prevents SQL injection).

        Returns
        -------
        QueryResult

        Example:
            result = db.query(
                "SELECT * FROM orders WHERE status = ? AND total > ?",
                ("shipped", 100)
            )
            for row in result:
                print(row["order_id"], row["total"])
        """
        self._ensure_connected()
        try:
            cursor = self._conn.cursor()
            logger.debug("Executing query: %s | params: %s", sql, params)
            if params:
                cursor.execute(sql, params)
            else:
                cursor.execute(sql)
            rows, columns = _rows_to_dicts(cursor)
            return QueryResult(rows=rows, columns=columns, rowcount=len(rows))
        except Exception as exc:
            raise QueryError(f"Query failed: {exc}\nSQL: {sql}") from exc

    def execute(
        self,
        sql: str,
        params: Optional[Union[tuple, list, dict]] = None,
    ) -> int:
        """
        Execute a non-SELECT statement (INSERT, UPDATE, DELETE, DDL).

        Returns the number of affected rows.

        Example:
            affected = db.execute(
                "UPDATE products SET price = ? WHERE id = ?",
                (29.99, 42)
            )
        """
        self._ensure_connected()
        try:
            cursor = self._conn.cursor()
            logger.debug("Executing statement: %s | params: %s", sql, params)
            if params:
                cursor.execute(sql, params)
            else:
                cursor.execute(sql)
            if not self.autocommit:
                self._conn.commit()
            return cursor.rowcount
        except Exception as exc:
            if not self.autocommit:
                self._conn.rollback()
            raise QueryError(f"Execute failed: {exc}\nSQL: {sql}") from exc

    def execute_many(
        self,
        sql: str,
        params_list: List[Union[tuple, list, dict]],
    ) -> int:
        """
        Execute a statement once per entry in params_list (bulk insert/update).

        Returns total affected rows.

        Example:
            db.execute_many(
                "INSERT INTO logs (level, message) VALUES (?, ?)",
                [("INFO", "started"), ("ERROR", "failed")]
            )
        """
        self._ensure_connected()
        try:
            cursor = self._conn.cursor()
            cursor.executemany(sql, params_list)
            if not self.autocommit:
                self._conn.commit()
            return cursor.rowcount
        except Exception as exc:
            if not self.autocommit:
                self._conn.rollback()
            raise QueryError(f"execute_many failed: {exc}\nSQL: {sql}") from exc

    # ------------------------------------------------------------------
    # Transaction support
    # ------------------------------------------------------------------

    @contextmanager
    def transaction(self) -> Generator:
        """
        Context manager for explicit transaction control.

        Example:
            with db.transaction():
                db.execute("INSERT INTO orders ...")
                db.execute("UPDATE inventory ...")
        """
        self._ensure_connected()
        original_autocommit = self.autocommit
        self.autocommit = False
        try:
            yield self
            self._conn.commit()
            logger.debug("Transaction committed.")
        except Exception as exc:
            self._conn.rollback()
            logger.warning("Transaction rolled back due to: %s", exc)
            raise
        finally:
            self.autocommit = original_autocommit

    # ------------------------------------------------------------------
    # Context manager support  (with DatabaseConnection(...) as db)
    # ------------------------------------------------------------------

    def __enter__(self) -> "DatabaseConnection":
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()
        return False    # don't suppress exceptions

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _ensure_connected(self):
        if self._conn is None:
            self.connect()

    def _build_connection(self):
        """Dispatch to the correct driver based on dialect."""
        if self.dialect == "sqlite":
            return self._connect_sqlite()
        elif self.dialect == "sqlserver":
            return self._connect_sqlserver()
        elif self.dialect == "postgresql":
            return self._connect_postgresql()
        elif self.dialect == "mysql":
            return self._connect_mysql()

    def _connect_sqlite(self):
        db = self.database or ":memory:"
        conn = sqlite3.connect(db, timeout=self.connect_timeout, **self.extra_kwargs)
        conn.row_factory = sqlite3.Row
        if self.autocommit:
            conn.isolation_level = None
        return conn

    def _connect_sqlserver(self):
        try:
            import pyodbc
        except ImportError:
            raise ConfigurationError(
                "pyodbc is required for SQL Server. Install: pip install pyodbc"
            )
        parts = [
            f"DRIVER={{{self.driver}}}",
            f"SERVER={self.host}",
            f"DATABASE={self.database}",
            f"CONNECTION TIMEOUT={self.connect_timeout}",
        ]
        if self.trusted_connection:
            parts.append("Trusted_Connection=yes")
        else:
            parts.append(f"UID={self.username}")
            parts.append(f"PWD={self.password}")
        conn_str = ";".join(parts)
        conn = pyodbc.connect(conn_str, **self.extra_kwargs)
        conn.autocommit = self.autocommit
        return conn

    def _connect_postgresql(self):
        try:
            import psycopg2
            import psycopg2.extras
        except ImportError:
            raise ConfigurationError(
                "psycopg2 is required for PostgreSQL. Install: pip install psycopg2-binary"
            )
        conn = psycopg2.connect(
            host=self.host,
            port=self.port or 5432,
            dbname=self.database,
            user=self.username,
            password=self.password,
            connect_timeout=self.connect_timeout,
            sslmode="require" if self.ssl else "prefer",
            cursor_factory=psycopg2.extras.RealDictCursor,
            **self.extra_kwargs,
        )
        conn.autocommit = self.autocommit
        return conn

    def _connect_mysql(self):
        try:
            import mysql.connector
        except ImportError:
            raise ConfigurationError(
                "mysql-connector-python is required for MySQL. "
                "Install: pip install mysql-connector-python"
            )
        conn = mysql.connector.connect(
            host=self.host,
            port=self.port or 3306,
            database=self.database,
            user=self.username,
            password=self.password,
            connection_timeout=self.connect_timeout,
            ssl_disabled=not self.ssl,
            **self.extra_kwargs,
        )
        conn.autocommit = self.autocommit
        return conn

    def __repr__(self) -> str:
        status = "connected" if self.is_connected() else "disconnected"
        return (
            f"<DatabaseConnection dialect={self.dialect!r} "
            f"host={self.host!r} database={self.database!r} [{status}]>"
        )

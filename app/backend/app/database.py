# app/backend/app/database.py
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

from .config import settings

# The engine manages the connection pool to Postgres.
# pool_pre_ping checks a connection is alive before using it (survives RDS
# failovers / idle drops
engine = create_engine(settings.database_url, pool_pre_ping=True)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base class all ORM models inherit from.
Base = declarative_base()


# FastAPI dependency: yields a DB session per request and always closes it.
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
import json
import logging
import os
import sys
from datetime import datetime, timedelta, timezone

from google.cloud import firestore

GCP_PROJECT = os.environ["GCP_PROJECT"]
FIRESTORE_COLLECTION = os.environ["FIRESTORE_COLLECTION"]
FIRESTORE_DATABASE = os.environ["FIRESTORE_DATABASE"]
RETENTION_MINUTES = int(os.environ.get("CLEANUP_RETENTION_MINUTES", "30"))

_RESERVED_LOG_ATTRS = set(vars(logging.LogRecord("", 0, "", 0, "", (), None)).keys())


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED_LOG_ATTRS and key != "message":
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)


def main() -> None:
    configure_logging()
    logger = logging.getLogger("assistant.cleanup")

    firestore_client = firestore.Client(project=GCP_PROJECT, database=FIRESTORE_DATABASE)
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=RETENTION_MINUTES)

    query = firestore_client.collection(FIRESTORE_COLLECTION).where("updated_at", "<", cutoff)

    deleted_count = 0
    for doc in query.stream():
        doc.reference.delete()
        deleted_count += 1

    logger.info(
        "cleanup complete",
        extra={"deleted_count": deleted_count, "retention_minutes": RETENTION_MINUTES},
    )


if __name__ == "__main__":
    main()

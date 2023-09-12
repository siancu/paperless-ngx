import logging
import uuid


class LoggingMixin:
    logging_name = "mixin"

    def __init__(self) -> None:
        self.renew_logging_group()

    def renew_logging_group(self) -> None:
        """
        Creates a new UUID to group subsequent log calls together with
        the extra data named group
        """
        self.logging_group = uuid.uuid4()
        self.log = logging.LoggerAdapter(
            logging.getLogger(self.logging_name),
            extra={"group": self.logging_group},
        )

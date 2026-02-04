# production_config.py
import os
import parlant.sdk as p
import os, sys, json, logging

class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "timestamp": self.formatTime(record, self.datefmt)
        })

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])

# MongoDB Configuration
MONGODB_SESSIONS_URI = os.environ["MONGODB_SESSIONS_URI"]
MONGODB_CUSTOMERS_URI = os.environ["MONGODB_CUSTOMERS_URI"]

# NLP Provider Configuration
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")

# Server Configuration
SERVER_HOST = os.environ.get("SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.environ.get("SERVER_PORT", "8800"))

# Choose your NLP service
NLP_SERVICE = p.NLPServices.gemini

def get_mongodb_config():
    """Returns MongoDB configuration for Parlant."""
    return {
        "session_store": MONGODB_SESSIONS_URI,
        "customer_store": MONGODB_CUSTOMERS_URI,
    }
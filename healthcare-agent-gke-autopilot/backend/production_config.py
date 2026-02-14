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
if os.environ.get("USE_VERTEX_AI") == "true":
    # set the following environment variables
    # - VERTEX_AI_PROJECT_ID
    # - VERTEX_AI_REGION, default to "us-central1"
    # - VERTEX_AI_MODEL, default to "gemini-2.5-flash"
    NLP_SERVICE = p.NLPServices.vertex
else:
    # set GEMINI_API_KEY
    NLP_SERVICE = p.NLPServices.gemini

def get_mongodb_config():
    """Returns MongoDB configuration for Parlant."""
    # Enforce pool limits for M0 Free Tier (500 limit / 10 max pods = 50 per pod)
    separator = "&" if "?" in MONGODB_SESSIONS_URI else "?"
    sessions_uri = f"{MONGODB_SESSIONS_URI}{separator}maxPoolSize=50"
    separator = "&" if "?" in MONGODB_CUSTOMERS_URI else "?"
    customers_uri = f"{MONGODB_CUSTOMERS_URI}{separator}maxPoolSize=50"
    return {
        "session_store": sessions_uri,
        "customer_store": customers_uri,
    }
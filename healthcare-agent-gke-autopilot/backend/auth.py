import parlant.sdk as p
import jwt
from parlant.api.authorization import (
    BasicRateLimiter,
    RateLimitItemPerMinute,
    Operation
)


class ProductionAuthPolicy(p.ProductionAuthorizationPolicy):
    """Production authorization with your custom rules."""

    def __init__(self, secret_key: str):
        super().__init__()
        self.secret_key = secret_key
        
        # Override default limiter to allow high traffic for load testing
        self.default_limiter = BasicRateLimiter(
            rate_limit_item_per_operation={
                op: RateLimitItemPerMinute(1000) 
                for op in Operation
            }
        )

    async def check_permission(self, request, operation) -> bool:
        auth_header = request.headers.get("Authorization")
        token = None
        
        if auth_header and auth_header.startswith("Bearer "):
            token = auth_header.split(" ")[1]
        elif "token" in request.query_params:
            token = request.query_params["token"]
            
        if not token:
            return False
            
        try:
            jwt.decode(token, self.secret_key, algorithms=["HS256"])
            return True
        except jwt.InvalidTokenError:
            return False
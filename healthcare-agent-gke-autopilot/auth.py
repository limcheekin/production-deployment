import parlant.sdk as p


class ProductionAuthPolicy(p.ProductionAuthorizationPolicy):
    """Production authorization with your custom rules."""

    def __init__(self, secret_key: str):
        super().__init__()
        self.secret_key = secret_key
        # Add your custom authorization logic here
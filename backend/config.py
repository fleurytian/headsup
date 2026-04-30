from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "sqlite:///./ask.db"
    secret_key: str = "dev-secret-change-in-production"
    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_private_key_path: str = "./apns_key.p8"
    apns_bundle_id: str = "com.yourcompany.headsup"
    apns_production: bool = False
    base_url: str = "http://localhost:8000"
    app_name: str = "HeadsUp"
    # Per-agent monthly push quota. 0 = no limit (open beta — flip back on
    # when the paid tier ships). Counter resets on the 1st of each calendar
    # month UTC. Override via env (FREE_TIER_MONTHLY_PUSHES=100 to re-enable).
    free_tier_monthly_pushes: int = 0
    # Token required to access /admin dashboards. If empty, /admin returns 401.
    # Set via env: ADMIN_TOKEN=<long random string>.
    admin_token: str = ""

    class Config:
        env_file = ".env"


settings = Settings()

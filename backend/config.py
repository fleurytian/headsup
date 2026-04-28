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

    class Config:
        env_file = ".env"


settings = Settings()

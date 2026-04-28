import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from config import settings
from database import create_db_and_tables
from routers import agents, app as app_router, categories, push, users, web
from services.webhook import retry_loop


@asynccontextmanager
async def lifespan(application: FastAPI):
    create_db_and_tables()
    task = asyncio.create_task(retry_loop())
    yield
    task.cancel()


api = FastAPI(
    title="HeadsUp API",
    description="Interactive push notification platform for AI agents",
    version="1.0.0",
    lifespan=lifespan,
)

api.include_router(agents.router, prefix="/v1")
api.include_router(users.router, prefix="/v1")
api.include_router(push.router, prefix="/v1")
api.include_router(categories.router, prefix="/v1")
api.include_router(app_router.router, prefix="/v1")
api.include_router(web.router)


@api.get("/health")
def health():
    return {"status": "ok", "app": settings.app_name}

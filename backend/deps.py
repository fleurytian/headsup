from fastapi import Depends, HTTPException, Security, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials, APIKeyHeader
from sqlmodel import Session, select
from database import get_session
from models import Agent
from auth import decode_access_token

bearer = HTTPBearer(auto_error=False)
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def get_current_agent(
    session: Session = Depends(get_session),
    credentials: HTTPAuthorizationCredentials = Security(bearer),
    api_key: str = Security(api_key_header),
) -> Agent:
    agent = None

    if api_key:
        agent = session.exec(select(Agent).where(Agent.api_key == api_key)).first()

    elif credentials:
        agent_id = decode_access_token(credentials.credentials)
        if agent_id:
            agent = session.get(Agent, agent_id)

    if not agent:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing credentials",
        )
    return agent

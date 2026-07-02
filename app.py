import os
import shutil
import tempfile

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from supabase import create_client

from rag_modell import (
    build_rag_chain,
    delete_document,
    ingest_document,
    query,
)

app = FastAPI(title="ChatDocs RAG API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# used only to verify tokens (get_user), not for db access
_auth_client = create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_KEY"))
_bearer = HTTPBearer()


def get_current_user_id(creds: HTTPAuthorizationCredentials = Depends(_bearer)) -> str:
    """
    verifies the supabase access token sent by the flutter app and returns
    the real, authenticated user id. user_id is never taken from the
    request body/form anymore - it always comes from this token.
    """
    try:
        response = _auth_client.auth.get_user(creds.credentials)
    except Exception:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    if not response or not response.user:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    return response.user.id


class ChatRequest(BaseModel):
    question: str


@app.post("/upload")
async def upload(
    file: UploadFile = File(...),
    doc_id: str = Form(...),
    user_id: str = Depends(get_current_user_id),
):
    suffix = os.path.splitext(file.filename or "")[1]
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        shutil.copyfileobj(file.file, tmp)
        tmp_path = tmp.name

    try:
        chunks = ingest_document(tmp_path, user_id=user_id, doc_id=doc_id)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    finally:
        os.remove(tmp_path)

    return {"status": "success", "chunks": chunks}


@app.post("/chat")
async def chat(payload: ChatRequest, user_id: str = Depends(get_current_user_id)):
    try:
        chain = build_rag_chain(user_id)
        result = query(chain, payload.question)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    return result


@app.delete("/document/{doc_id}")
async def remove_document(doc_id: str, user_id: str = Depends(get_current_user_id)):
    try:
        delete_document(doc_id, user_id=user_id)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    return {"status": "deleted"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=int(os.getenv("PORT", 8000)))